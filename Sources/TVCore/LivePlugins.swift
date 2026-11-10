import CryptoKit
import Foundation
import ImageIO

/// Live platforms added as plugins in the AngelLive ("LiveParse") format: a source is a JSON index
/// (`{apiVersion, sourceName, plugins: [{pluginId, version, platformName, zipURL, sha256, icon, ...}]}`, as
/// plugins.carsonn.works makes them), and each plugin a ZIP holding `manifest.json`, its scripts and its icons.
/// Plugins run in `LivePluginRuntime`; installed ones are live platforms (`LivePlatform.plugin`) like the
/// built-in ones. What is installed is kept in the app's preferences and the files in Application Support
/// (Caches on tvOS, which keeps nothing else: missing files are downloaded again when a plugin is used).
public final class LivePlugins: @unchecked Sendable {
    public static let shared = LivePlugins()
    public static let changed = Notification.Name("LivePluginsChanged")
    /// Short source keys (`angellive://install-source?source=<key>`) name an index here.
    static let keyHost = "https://plugins.carsonn.works/s/"
    static let largestZip = 8 << 20

    /// A source the viewer added.
    public struct Source: Codable, Hashable, Sendable, Identifiable {
        public var url: URL
        public var name: String
        public var id: URL { url }
    }

    /// A plugin a source lists.
    public struct Entry: Codable, Hashable, Sendable, Identifiable {
        public var pluginId: String
        public var version: String
        public var name: String
        public var summary: String
        public var zipURLs: [URL]
        public var sha256: String
        public var icon: String?
        public var requiresLogin: Bool
        public var id: String { pluginId }

        init?(json: [String: JSONValue], base: URL) {
            guard let id = json["pluginId"]?.string, LivePlugins.validID(id), let version = json["version"]?.string else { return nil }
            pluginId = id; self.version = version
            name = json["platformName"]?.string ?? json["displayName"]?.string ?? id
            summary = json["platformDescription"]?.string ?? ""
            var urls = (json["zipURLs"]?.array ?? []).compactMap { $0.string.flatMap { URL(string: $0, relativeTo: base)?.absoluteURL } }
            if let one = json["zipURL"]?.string, let url = URL(string: one, relativeTo: base)?.absoluteURL, !urls.contains(url) { urls.insert(url, at: 0) }
            guard !urls.isEmpty else { return nil }
            zipURLs = urls
            sha256 = (json["sha256"]?.string ?? "").lowercased()
            icon = json["icon"]?.string
            requiresLogin = json["auth"]?.object?["required"].map { if case .bool(true) = $0 { true } else { false } } ?? false
        }
    }

    /// An installed plugin.
    public struct Installed: Codable, Hashable, Sendable, Identifiable {
        public var pluginId: String
        public var version: String
        public var name: String
        public var summary: String
        public var sha256: String
        public var zipURLs: [URL]
        public var source: URL?
        public var icon: String?
        /// The icon's main colour, as "#RRGGBB".
        public var tint: String?
        public var requiresLogin: Bool
        public var installedAt: Date
        public var id: String { pluginId }
    }

    public enum Failure: LocalizedError {
        case notASource, checksum(String), noManifest, wrongPlugin(String), download(String)
        public var errorDescription: String? {
            switch self {
            case .notASource: L10n.text("This address isn't a live plugin source.")
            case .checksum(let name): L10n.text("%@ didn't match its checksum, so it wasn't installed.", name)
            case .noManifest: L10n.text("The plugin has no manifest.json.")
            case .wrongPlugin(let name): L10n.text("The download isn't the plugin %@.", name)
            case .download(let name): L10n.text("%@ couldn't be downloaded.", name)
            }
        }
    }

    private struct Saved: Codable {
        var sources: [Source] = []
        var installed: [Installed] = []
    }

    private static let key = "livePlugins.v1"
    private let lock = NSLock()
    /// Writes the preferences in order, never while `lock` is held (see `update`).
    private let saving = DispatchQueue(label: "LivePlugins.save")
    private let defaults: UserDefaults
    let folder: URL
    private var saved: Saved
    private var cachedPlatforms: [LivePlatform]?

    init(defaults: UserDefaults = .standard, folder: URL? = nil) {
        self.defaults = defaults
        #if os(tvOS)
        let location: FileManager.SearchPathDirectory = .cachesDirectory
        #else
        let location: FileManager.SearchPathDirectory = .applicationSupportDirectory
        #endif
        self.folder = folder ?? FileManager.default.urls(for: location, in: .userDomainMask)[0]
            .appendingPathComponent("com.tvbox.yingxia/LivePlugins", isDirectory: true)
        saved = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved()
    }

    public var sources: [Source] { lock.withLock { saved.sources } }
    public var installed: [Installed] { lock.withLock { saved.installed } }
    public func installed(_ id: String) -> Installed? { lock.withLock { saved.installed.first { $0.pluginId == id } } }

    /// The installed plugins as live platforms, in the order they were installed.
    public var platforms: [LivePlatform] {
        lock.withLock {
            if let cachedPlatforms { return cachedPlatforms }
            let made = saved.installed.map(LivePlatform.init(plugin:))
            cachedPlatforms = made
            return made
        }
    }

    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == ".") }
    }

    /// The index address a pasted text names: an index URL, an `angellive://` or `yingxia://` install link (its
    /// `source` an address or a short key), or a short key alone.
    public static func sourceAddress(_ text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased() {
            if scheme == "http" || scheme == "https" { return url }
            if ["angellive", "yingxia"].contains(scheme),
               let source = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "source" })?.value {
                return sourceAddress(source)
            }
            return nil
        }
        guard text.count <= 64, text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { return nil }
        return URL(string: keyHost + text + ".json")
    }

    /// Reads a source's index: its name and plugins.
    public func index(_ address: URL, http: HTTPClient = HTTPClient()) async throws -> (name: String, plugins: [Entry]) {
        let data = try await http.get(address).0
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data).object, let list = json["plugins"]?.array else { throw Failure.notASource }
        let plugins = list.compactMap(\.object).compactMap { Entry(json: $0, base: address) }
        guard !plugins.isEmpty else { throw Failure.notASource }
        let name = json["sourceName"]?.string ?? address.host() ?? address.absoluteString
        return (name, plugins)
    }

    /// Remembers a source (again, with its current name).
    public func addSource(_ address: URL, name: String) {
        update { saved in
            saved.sources.removeAll { $0.url == address }
            saved.sources.append(Source(url: address, name: name))
        }
    }

    /// Forgets a source and removes the plugins installed from it.
    public func removeSource(_ address: URL) {
        let removed = lock.withLock { saved.installed.filter { $0.source == address }.map(\.pluginId) }
        removed.forEach { uninstall($0) }
        update { $0.sources.removeAll { $0.url == address } }
    }

    /// Downloads, checks and unpacks a plugin, replacing the version installed.
    public func install(_ entry: Entry, from source: URL?, http: HTTPClient = HTTPClient()) async throws {
        let data = try await download(entry.zipURLs, sha256: entry.sha256, name: entry.name, http: http)
        let manifest = try unpack(data, pluginId: entry.pluginId, name: entry.name)
        let icon = entry.icon ?? (manifest["icon"]?.string)
        let record = Installed(pluginId: entry.pluginId, version: manifest["version"]?.string ?? entry.version, name: entry.name, summary: entry.summary,
                               sha256: entry.sha256, zipURLs: entry.zipURLs, source: source, icon: icon,
                               tint: icon.flatMap { Self.tint(of: directory(entry.pluginId).appending(path: $0)) },
                               requiresLogin: entry.requiresLogin, installedAt: Date())
        update { saved in
            if let index = saved.installed.firstIndex(where: { $0.pluginId == entry.pluginId }) { saved.installed[index] = record }
            else { saved.installed.append(record) }
        }
        await LivePluginRuntime.shared.unload(entry.pluginId)
        Diagnostics.shared.record(.info, "plugins", "installed \(entry.pluginId) \(record.version)")
    }

    public func uninstall(_ id: String) {
        update { $0.installed.removeAll { $0.pluginId == id } }
        try? FileManager.default.removeItem(at: directory(id))
        Task { await LivePluginRuntime.shared.unload(id) }
    }

    /// Plugins whose sources list a newer version than the one installed, with that entry.
    public func updates(http: HTTPClient = HTTPClient()) async -> [(installed: Installed, entry: Entry)] {
        var found: [(Installed, Entry)] = []
        for source in sources {
            guard let (_, entries) = try? await index(source.url, http: http) else { continue }
            for entry in entries {
                guard let current = installed(entry.pluginId), current.source == source.url || current.source == nil else { continue }
                if Self.newer(entry.version, than: current.version) || (entry.version == current.version && !entry.sha256.isEmpty && entry.sha256 != current.sha256) {
                    found.append((current, entry))
                }
            }
        }
        return found
    }

    /// Whether dotted version `a` is above `b` ("2.0.14" > "2.0.9").
    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(x.count, y.count) {
            let l = index < x.count ? x[index] : 0, r = index < y.count ? y[index] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: Files

    func directory(_ id: String) -> URL { folder.appending(path: id, directoryHint: .isDirectory) }

    /// The plugin's folder, downloaded again when its files are gone (tvOS clears caches).
    func files(_ id: String, http: HTTPClient = HTTPClient()) async throws -> URL {
        let folder = directory(id)
        if FileManager.default.fileExists(atPath: folder.appending(path: "manifest.json").path) { return folder }
        guard let record = installed(id) else { throw TVError.unsupported(L10n.text("The plugin %@ isn't installed.", id)) }
        Diagnostics.shared.record(.info, "plugins", "files of \(id) missing; downloading again")
        let data = try await download(record.zipURLs, sha256: record.sha256, name: record.name, http: http)
        _ = try unpack(data, pluginId: id, name: record.name)
        return folder
    }

    private func download(_ urls: [URL], sha256: String, name: String, http: HTTPClient) async throws -> Data {
        var failure: Error = Failure.download(name)
        for url in urls {
            do {
                let data = try await http.get(url).0
                guard data.count <= Self.largestZip else { throw SubtitleArchive.Failure.tooLarge }
                if !sha256.isEmpty {
                    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    guard digest == sha256 else { throw Failure.checksum(name) }
                }
                return data
            } catch let error as Failure {
                failure = error
            } catch {
                failure = error
            }
        }
        throw failure
    }

    /// Unpacks the ZIP into the plugin's folder (replacing it whole) and returns its manifest.
    private func unpack(_ data: Data, pluginId: String, name: String) throws -> [String: JSONValue] {
        var limits = SubtitleArchive.Limits()
        limits.archive = Self.largestZip; limits.entry = 16 << 20; limits.total = 48 << 20; limits.entries = 400; limits.anyFile = true
        let entries = try SubtitleArchive.entries(data, limits: limits)
        // Some ZIPs hold one folder with the plugin inside.
        guard let manifestEntry = entries.filter({ $0.name == "manifest.json" }).min(by: { $0.path.count < $1.path.count }) else { throw Failure.noManifest }
        let prefix = String(manifestEntry.path.dropLast("manifest.json".count))
        guard let manifest = try? JSONDecoder().decode(JSONValue.self, from: SubtitleArchive.extract(manifestEntry, from: data, limits: limits)).object else {
            throw Failure.noManifest
        }
        guard manifest["pluginId"]?.string == pluginId else { throw Failure.wrongPlugin(name) }
        let staging = folder.appending(path: ".\(pluginId)-\(UUID().uuidString)", directoryHint: .isDirectory)
        let manager = FileManager.default
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            for entry in entries where entry.path.hasPrefix(prefix) && !entry.path.hasSuffix("/") {
                let relative = String(entry.path.dropFirst(prefix.count))
                guard !relative.isEmpty, SubtitleArchive.safe(relative), !relative.hasPrefix("__MACOSX") else { continue }
                let target = staging.appending(path: relative)
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try SubtitleArchive.extract(entry, from: data, limits: limits).write(to: target)
            }
            let final = directory(pluginId)
            if manager.fileExists(atPath: final.path) { try manager.removeItem(at: final) }
            try manager.moveItem(at: staging, to: final)
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
        return manifest
    }

    /// The average colour of an icon's opaque, not-white, not-black pixels.
    static func tint(of file: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let size = 32
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let context = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        var red = 0, green = 0, blue = 0, count = 0
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] > 200 {
            let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
            let high = max(r, g, b), low = min(r, g, b)
            // Colourful pixels only: no white, black or grey.
            guard high > 40, high - low > 40 else { continue }
            red += r; green += g; blue += b; count += 1
        }
        guard count > 8 else { return nil }
        return String(format: "#%02X%02X%02X", red / count, green / count, blue / count)
    }

    private func update(_ change: (inout Saved) -> Void) {
        let data = lock.withLock {
            change(&saved)
            cachedPlatforms = nil
            return try? JSONEncoder().encode(saved)
        }
        // Not under `lock`, and not on this thread: setting a preference calls SwiftUI's @AppStorage observers at
        // once, and they wait for the view graph, which the main thread may hold while a row reads `installed(_:)`.
        // Writing under the lock froze the app while installing a plugin.
        if let data { saving.async { [defaults] in defaults.set(data, forKey: Self.key) } }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}

extension LivePlugins {
    /// An installed plugin's icon file, if it has one.
    public func iconFile(_ plugin: Installed) -> URL? {
        guard let icon = plugin.icon, SubtitleArchive.safe(icon) else { return nil }
        return directory(plugin.pluginId).appending(path: icon)
    }

    /// A plugin's icon before it is installed. Indexes name the icon by its path inside the ZIP, so the ZIP
    /// (tens of KB) is downloaded once and the icon kept in Caches, by version.
    public func previewIcon(_ entry: Entry, http: HTTPClient = HTTPClient()) async -> URL? {
        guard let icon = entry.icon, SubtitleArchive.safe(icon) else { return nil }
        let name = "\(entry.pluginId)-\(entry.version)" + (entry.sha256.isEmpty ? "" : "-\(entry.sha256.prefix(12))")
        let file = Self.previewFolder.appending(path: name).appendingPathExtension((icon as NSString).pathExtension)
        if FileManager.default.fileExists(atPath: file.path) { return file }
        do {
            let data = try await download(entry.zipURLs, sha256: entry.sha256, name: entry.name, http: http)
            var limits = SubtitleArchive.Limits()
            limits.archive = Self.largestZip; limits.entry = 2 << 20; limits.entries = 400; limits.anyFile = true
            // The path is the plugin's own; some ZIPs hold one folder with the plugin inside.
            guard let found = try SubtitleArchive.entries(data, limits: limits)
                .filter({ $0.path == icon || $0.path.hasSuffix("/" + icon) }).min(by: { $0.path.count < $1.path.count }) else {
                Diagnostics.shared.record(.info, "plugins", "\(entry.pluginId)'s ZIP has no \(icon)")
                return nil
            }
            let bytes = try SubtitleArchive.extract(found, from: data, limits: limits)
            try FileManager.default.createDirectory(at: Self.previewFolder, withIntermediateDirectories: true)
            try bytes.write(to: file, options: .atomic)
            return file
        } catch {
            Diagnostics.shared.record(.info, "plugins", "no icon for \(entry.pluginId): \(error.localizedDescription)")
            return nil
        }
    }

    static var previewFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("com.tvbox.yingxia/LivePluginIcons", isDirectory: true)
    }
}

extension Subscription {
    /// The live platforms of the installed plugins, after Yingxia's own and before the subscription's playlists.
    public func withLivePlugins(_ platforms: [LivePlatform] = LivePlugins.shared.platforms) -> Subscription {
        let added = platforms.map(\.source).filter { source in !lives.contains { $0.url == source.url } }
        guard !added.isEmpty else { return self }
        return Subscription(origin: origin, importedAt: importedAt, sites: sites, lives: lives.filter(\.isBuiltIn) + added + lives.filter { !$0.isBuiltIn }, raw: raw)
    }
}

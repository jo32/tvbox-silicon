import Foundation

/// LX Music (洛雪音乐) custom sources: scripts a listener imports that turn a catalog song ID into an
/// audio address, as in LX Music's "custom source" setting. Yingxia ships none. Each runs on QuickJS
/// with the `lx` object of LX Music desktop's user API (ScriptAssets/lx/lx.js), and the enabled ones
/// are one more channel, `MusicProviderID.lx`, tried after the built-in channels. Nothing runs until
/// a source is imported, and a source's runtime starts only when a song first needs it.

/// The comment LX Music reads at the top of a source: `@name`, `@description`, `@version`, `@author`, `@homepage`.
public struct LXSourceInfo: Codable, Hashable, Sendable {
    public var name: String
    public var description: String
    public var version: String
    public var author: String
    public var homepage: String

    public init(name: String, description: String = "", version: String = "", author: String = "", homepage: String = "") {
        self.name = name; self.description = description; self.version = version; self.author = author; self.homepage = homepage
    }

    /// Reads the header comment, which must open the script; LX Music's own length limits apply.
    public init(script: String) {
        var fields: [String: String] = [:]
        let text = script.drop { $0 == "\u{FEFF}" || $0.isWhitespace }
        if text.hasPrefix("/*"), let end = text.range(of: "*/") {
            for line in text[text.index(text.startIndex, offsetBy: 2)..<end.lowerBound].split(whereSeparator: \.isNewline) {
                let content = line.drop { $0 == " " || $0 == "\t" || $0 == "*" || $0 == "!" }
                guard content.hasPrefix("@") else { continue }
                let parts = content.dropFirst().split(maxSplits: 1, whereSeparator: \.isWhitespace)
                guard parts.count == 2 else { continue }
                let key = String(parts[0]), value = parts[1].trimmingCharacters(in: .whitespaces)
                if fields[key] == nil, !value.isEmpty { fields[key] = value }
            }
        }
        func field(_ key: String, _ limit: Int) -> String { String((fields[key] ?? "").prefix(limit)) }
        let name = field("name", 24)
        self.init(name: name.isEmpty ? L10n.text("LX Music Source") : name, description: field("description", 36), version: field("version", 36),
                  author: field("author", 56), homepage: field("homepage", 1024))
    }
}

/// LX Music's names for the catalogs. Kugou ("kg") has no catalog here, so its entries are ignored.
public enum LXSourceKey {
    public static func platform(_ key: String) -> MusicPlatform? {
        switch key {
        case "tx": .qq
        case "wy": .netease
        case "kw": .kuwo
        case "mg": .migu
        default: nil
        }
    }

    public static func key(_ platform: MusicPlatform) -> String {
        switch platform {
        case .qq: "tx"
        case .netease: "wy"
        case .kuwo: "kw"
        case .migu: "mg"
        case .ext: ""
        }
    }

    /// The quality a lookup asks for: lossless at CD quality first, as the other channels do; the
    /// stream is probed anyway. High and Standard ask only for a lossy tier the source declared,
    /// and a source with none is skipped rather than sent lossless audio the viewer chose to avoid.
    public static func quality(from declared: [String], for quality: MusicAudioQuality) -> String? {
        if declared.isEmpty {
            switch quality {
            case .lossless, .high: return "320k"
            case .standard: return "128k"
            }
        }
        switch quality {
        case .lossless: return ["flac", "flac24bit", "320k", "128k"].first(where: declared.contains) ?? "320k"
        case .high: return ["320k", "128k"].first(where: declared.contains)
        case .standard: return ["128k"].first(where: declared.contains)
        }
    }

    /// The `musicInfo` an LX source receives, in LX Music's format, from what the catalog listed.
    public static func musicInfo(songID: String, platform: MusicPlatform, track: MusicTrack?) -> [String: JSONValue] {
        var info: [String: JSONValue] = ["source": .string(key(platform)), "songmid": .string(songID)]
        switch platform {
        case .migu:
            // Yingxia's Migu ID is "contentId_copyrightId"; LX sources look songs up by the copyright ID.
            if let ids = MiguMusicCatalog.ids(songID) {
                info["songmid"] = .string(ids.copyright); info["copyrightId"] = .string(ids.copyright); info["contentId"] = .string(ids.content)
            }
        case .qq: info["strMediaMid"] = .string(songID)
        case .kuwo: info["rid"] = .string(songID)
        case .netease, .ext: break
        }
        info["name"] = .string(track?.title ?? "")
        info["singer"] = .string(track?.artists.joined(separator: "、") ?? "")
        info["albumName"] = .string(track?.album ?? "")
        info["img"] = .string(track?.artwork?.absoluteString ?? "")
        if let seconds = track?.duration, seconds > 0 {
            let whole = Int(seconds.rounded())
            info["interval"] = .string(String(format: "%02d:%02d", whole / 60, whole % 60))
        } else { info["interval"] = .string("") }
        info["types"] = .array([]); info["_types"] = .object([:]); info["typeUrl"] = .object([:])
        return info
    }
}

/// One imported source.
public struct LXSource: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var info: LXSourceInfo
    /// The LX catalog keys that answer `musicUrl`, each with the qualities it declared.
    public var sources: [String: [String]]
    /// Where it was imported from, to fetch it again if the system cleared its copy (tvOS keeps files in Caches).
    public var origin: URL?
    public var enabled: Bool
    public var added: Date

    public init(id: String = UUID().uuidString, info: LXSourceInfo, sources: [String: [String]], origin: URL?, enabled: Bool = true, added: Date = Date()) {
        self.id = id; self.info = info; self.sources = sources; self.origin = origin; self.enabled = enabled; self.added = added
    }

    /// The catalogs it can play, in the app's order.
    public var platforms: [MusicPlatform] { MusicPlatform.allCases.filter { sources[LXSourceKey.key($0)] != nil } }
}

/// The imported sources: a small list in user defaults and each script in a file.
public final class LXSourceLibrary: @unchecked Sendable {
    public static let shared = LXSourceLibrary(folder: LXSourceLibrary.defaultFolder, defaults: .standard)
    static var defaultFolder: URL {
        #if os(tvOS)
        // tvOS only permits Caches; a cleared script is fetched again from where it came from.
        URL.cachesDirectory.appending(path: "com.tvbox.yingxia/LXSources", directoryHint: .isDirectory)
        #else
        URL.applicationSupportDirectory.appending(path: "com.tvbox.yingxia/LXSources", directoryHint: .isDirectory)
        #endif
    }
    static let defaultsKey = "musicLXSources"
    /// LX Music refuses larger scripts too.
    static let scriptLimit = 9_000_000

    private let folder: URL
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var cached: [LXSource]?

    public init(folder: URL, defaults: UserDefaults) { self.folder = folder; self.defaults = defaults }

    public var sources: [LXSource] {
        lock.withLock {
            if let cached { return cached }
            let loaded = defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode([LXSource].self, from: $0) } ?? []
            cached = loaded
            return loaded
        }
    }

    public var enabled: [LXSource] { sources.filter(\.enabled) }

    /// Starts `script`, keeps it when it declares at least one catalog the app searches, and returns it.
    @discardableResult
    public func add(script: String, origin: URL?, runtime: LXSourceRuntime = .shared) async throws -> LXSource {
        guard !script.isEmpty, script.utf8.count <= Self.scriptLimit else { throw TVError.unsupported(L10n.text("This file is not an LX Music source.")) }
        let info = LXSourceInfo(script: script)
        var source = LXSource(info: info, sources: [:], origin: origin)
        let declared = try await runtime.start(source, script: script)
        source.sources = declared.filter { LXSourceKey.platform($0.key) != nil }
        guard !source.sources.isEmpty else {
            await runtime.close(source.id)
            throw TVError.unsupported(L10n.text("This source plays none of the catalogs Yingxia searches (QQ Music, NetEase Cloud Music, Kuwo, Migu)."))
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(script.utf8).write(to: file(source.id), options: .atomic)
        update { $0.append(source) }
        Diagnostics.shared.record(.info, "music", "lx source added: \(source.sources.keys.sorted().joined(separator: ","))")
        return source
    }

    public func setEnabled(_ id: String, _ enabled: Bool) {
        update { list in
            if let index = list.firstIndex(where: { $0.id == id }) { list[index].enabled = enabled }
        }
        if !enabled { Task { await LXSourceRuntime.shared.close(id) } }
    }

    public func remove(_ id: String) {
        update { $0.removeAll { $0.id == id } }
        try? FileManager.default.removeItem(at: file(id))
        Task { await LXSourceRuntime.shared.close(id) }
    }

    /// The script, fetched again from its origin when the system cleared the copy.
    func script(for source: LXSource) async throws -> String {
        if let data = try? Data(contentsOf: file(source.id)) { return String(decoding: data, as: UTF8.self) }
        guard let origin = source.origin else { throw MusicProviderError.noResource }
        let script = try await Self.download(origin)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data(script.utf8).write(to: file(source.id), options: .atomic)
        return script
    }

    /// A source's text from an HTTP or HTTPS address.
    public static func download(_ url: URL, transport: MusicTransport = URLSessionMusicTransport()) async throws -> String {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { throw TVError.invalidURL }
        let response = try await MusicHTTP.withTimeout(30) { try await transport.send(MusicHTTP.request(url, timeout: 30), limit: scriptLimit + 1) }
        guard (200..<300).contains(response.status) else { throw TVError.http(response.status) }
        guard response.body.count <= scriptLimit, let text = String(data: response.body, encoding: .utf8), !text.isEmpty else {
            throw TVError.unsupported(L10n.text("This file is not an LX Music source."))
        }
        return text
    }

    private func file(_ id: String) -> URL { folder.appending(path: id + ".js") }

    private func update(_ change: (inout [LXSource]) -> Void) {
        lock.withLock {
            var list = cached ?? defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode([LXSource].self, from: $0) } ?? []
            change(&list)
            cached = list
            if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: Self.defaultsKey) }
        }
    }
}

/// The sources' QuickJS runtimes, started on first use and kept for the next song.
public actor LXSourceRuntime {
    public static let shared = LXSourceRuntime()
    private var sessions: [String: ScriptSession] = [:]
    private var recent: [String] = []
    static let maximumSessions = 3
    /// A lookup's share of the resolver's eight seconds per channel.
    static let lookupSeconds: Double = 7.5

    public init() {}

    /// Runs `script` and answers what its `inited` event declared: LX catalog key → qualities.
    func start(_ source: LXSource, script: String) async throws -> [String: [String]] {
        close(source.id)
        let info = String(decoding: (try? JSONEncoder().encode(source.info)) ?? Data("{}".utf8), as: UTF8.self)
        let profile = ScriptAssets.profiles.appendingPathComponent("lx-" + source.id, isDirectory: true)
        let session = try await ScriptSession.start(module: "assets://lx/lx.js", supplied: ["lx://script": script, "lx://info": info],
                                                    profile: profile, label: "lx " + source.info.name)
        let envelope = await session.evaluate("__lx.load()", within: 20)
        guard let sources = envelope["value"]?["sources"]?.object else {
            session.close()
            let reason = envelope["value"]?["error"]?.string ?? envelope["error"]?.string ?? ""
            throw TVError.unsupported(L10n.text("The LX Music source did not start: %@", String(reason.prefix(200))))
        }
        keep(session, for: source.id)
        return sources.mapValues { $0.array?.compactMap(\.string) ?? [] }
    }

    /// The address `source` gives for one song.
    func musicURL(_ source: LXSource, library: LXSourceLibrary, key: String, quality: String, musicInfo: [String: JSONValue]) async throws -> URL {
        let session: ScriptSession
        if let running = sessions[source.id] {
            session = running
            recent.removeAll { $0 == source.id }; recent.append(source.id)
        } else {
            _ = try await start(source, script: try await library.script(for: source))
            guard let started = sessions[source.id] else { throw MusicProviderError.noResource }
            session = started
        }
        let input: JSONValue = .object(["source": .string(key), "quality": .string(quality), "musicInfo": .object(musicInfo)])
        let json = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
        let envelope = await session.evaluate("__lx.musicUrl(\(json))", within: Self.lookupSeconds)
        if let address = envelope["value"]?["url"]?.string, let url = URL(string: address), url.host() != nil { return url }
        // The script's own message can hold its API's address or key, so it is not passed on.
        if envelope["error"]?.string?.contains("interrupted") == true { throw MusicProviderError.timeout }
        throw MusicProviderError.noResource
    }

    func close(_ id: String) {
        sessions.removeValue(forKey: id)?.close()
        recent.removeAll { $0 == id }
    }

    private func keep(_ session: ScriptSession, for id: String) {
        sessions[id] = session
        recent.append(id)
        while recent.count > Self.maximumSessions { close(recent[0]) }
    }
}

/// The enabled LX sources as one channel: each source that covers the catalog is asked in turn.
public struct LXMusicProvider: MusicStreamProvider {
    public let id = MusicProviderID.lx
    public let platforms: Set<MusicPlatform>
    let sources: [LXSource]
    let library: LXSourceLibrary
    let runtime: LXSourceRuntime
    let health: MusicHealth

    public init?(sources: [LXSource], library: LXSourceLibrary = .shared, runtime: LXSourceRuntime = .shared, health: MusicHealth = .shared) {
        guard !sources.isEmpty else { return nil }
        self.sources = sources; self.library = library; self.runtime = runtime; self.health = health
        platforms = Set(sources.flatMap(\.platforms))
    }

    public func resolve(_ songID: String, platform: MusicPlatform, quality: MusicAudioQuality) async throws -> ResolvedMusicStream {
        try await resolve(songID, platform: platform, track: nil, quality: quality)
    }

    public func resolve(_ songID: String, platform: MusicPlatform, track: MusicTrack?, quality: MusicAudioQuality) async throws -> ResolvedMusicStream {
        let key = LXSourceKey.key(platform)
        let info = LXSourceKey.musicInfo(songID: songID, platform: platform, track: track)
        var failure = MusicProviderError.noResource
        for source in sources {
            guard let declared = source.sources[key],
                  let tier = LXSourceKey.quality(from: declared, for: quality) else { continue }
            try Task.checkCancellation()
            try await health.admit("lx")
            do {
                let url = try await runtime.musicURL(source, library: library, key: key, quality: tier, musicInfo: info)
                return ResolvedMusicStream(url: url, claimedQuality: tier, upstream: "lx:" + source.info.name)
            } catch { failure = MusicProviderError(error) }
        }
        throw failure
    }
}

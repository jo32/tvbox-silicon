import Foundation
import Security

/// A subtitle source as Settings lists it.
public struct SubtitleSourceItem: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public var version: String
    public var builtIn: Bool
    public var enabled: Bool
    /// Where an added script came from.
    public var origin: URL?
    public var credentials: [SubtitleProviderManifest.Credential]
    public var domains: [String]
    public var homepage: URL?

    init(_ manifest: SubtitleProviderManifest, builtIn: Bool, enabled: Bool, origin: URL?) {
        id = manifest.id; name = manifest.name; version = manifest.version; self.builtIn = builtIn; self.enabled = enabled; self.origin = origin
        credentials = manifest.credentials; domains = manifest.domains; homepage = manifest.homepage
    }
}

/// The sources the viewer can turn on (#576 M2): those that come with the app (off until the viewer turns them on
/// and gives a key) and scripts added by address. Their keys live in the Keychain (`SubtitleCredentialStore`).
public actor SubtitleSourceLibrary {
    public static let shared = SubtitleSourceLibrary()
    /// The scripts that ship with the app.
    static let builtIns = ["opensubtitles", "assrt"]
    static let largestScript = 512 << 10

    private let folder: URL
    private let credentials: any SubtitleCredentialStore
    private var saved: [SubtitleSourceItem]
    private var providers: [String: SubtitleScriptProvider] = [:]
    private var loadedBuiltIns = false

    public init(folder: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("SubtitleSources", isDirectory: true),
                credentials: any SubtitleCredentialStore = KeychainSubtitleCredentials()) {
        self.folder = folder; self.credentials = credentials
        saved = (try? JSONDecoder().decode([SubtitleSourceItem].self, from: Data(contentsOf: folder.appendingPathComponent("sources.json")))) ?? []
    }

    /// Every source, the app's first.
    public func items() async -> [SubtitleSourceItem] {
        await loadBuiltIns()
        return saved.sorted { ($0.builtIn ? 0 : 1, Self.builtIns.firstIndex(of: $0.id) ?? 0) < ($1.builtIn ? 0 : 1, Self.builtIns.firstIndex(of: $1.id) ?? 0) }
    }

    /// The enabled sources with their keys, for a search.
    public func searchSources() async -> [SubtitleSearchSource] {
        var out: [SubtitleSearchSource] = []
        for item in await items() where item.enabled {
            guard let provider = try? await provider(item.id) else { continue }
            out.append(SubtitleSearchSource(provider, credentials: credentials.values(for: item.id)))
        }
        return out
    }

    public func hasEnabledSources() async -> Bool { await items().contains(where: \.enabled) }

    public func setEnabled(_ id: String, _ enabled: Bool) {
        guard let index = saved.firstIndex(where: { $0.id == id }) else { return }
        saved[index].enabled = enabled
        save()
    }

    public func values(for id: String) -> [String: String] { credentials.values(for: id) }

    /// The viewer's values for a source; its earlier results are forgotten.
    public func setValues(_ values: [String: String], for id: String) async {
        let kept = values.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.value.isEmpty }
        credentials.set(kept, for: id)
        await SubtitleSearch.shared.forget(id)
    }

    /// A script from an address; it is run once to read its manifest and refused if this build can't run it.
    @discardableResult
    public func add(address: URL, session: URLSession = .shared) async throws -> SubtitleSourceItem {
        guard ["http", "https"].contains(address.scheme?.lowercased() ?? "") else {
            throw SubtitleProviderError.failed(L10n.text("Enter an address that starts with http:// or https://."))
        }
        let data: Data
        do { data = try await SubtitleFile.download(address, headers: [:], session: session, limit: Self.largestScript) }
        catch { throw SubtitleProviderError.failed(L10n.text("The script didn't download: %@", error.localizedDescription)) }
        return try await add(script: String(decoding: data, as: UTF8.self), origin: address)
    }

    @discardableResult
    public func add(script: String, origin: URL?) async throws -> SubtitleSourceItem {
        await loadBuiltIns()
        let provider = try await SubtitleScriptProvider.load(script: script, label: origin?.absoluteString ?? "added")
        let manifest = provider.manifest
        if let existing = saved.first(where: { $0.id == manifest.id }), existing.builtIn {
            throw SubtitleProviderError.incompatible(L10n.text("It has the same name as a source that comes with Yingxia."))
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(script.utf8).write(to: file(manifest.id), options: .atomic)
        let item = SubtitleSourceItem(manifest, builtIn: false, enabled: true, origin: origin)
        saved.removeAll { $0.id == item.id }
        saved.append(item)
        providers[item.id] = provider
        save()
        await SubtitleSearch.shared.forget(item.id)
        return item
    }

    public func remove(_ id: String) async {
        guard let item = saved.first(where: { $0.id == id }), !item.builtIn else { return }
        saved.removeAll { $0.id == id }
        providers[id] = nil
        try? FileManager.default.removeItem(at: file(id))
        credentials.set([:], for: id)
        save()
        await SubtitleSearch.shared.forget(id)
    }

    /// The source's running script, started on first use.
    public func provider(_ id: String) async throws -> SubtitleScriptProvider {
        if let running = providers[id] { return running }
        let script: String?
        if Self.builtIns.contains(id) { script = ScriptAssets.bundled("assets://subtitles/sources/\(id).js") } else { script = try? String(contentsOf: file(id), encoding: .utf8) }
        guard let script else { throw SubtitleProviderError.incompatible(L10n.text("The source's script is missing.")) }
        let provider = try await SubtitleScriptProvider.load(script: script, label: id)
        if let started = providers[id] { return started }
        providers[id] = provider
        return provider
    }

    /// The app's sources, listed by their manifests (each script run once).
    private func loadBuiltIns() async {
        guard !loadedBuiltIns else { return }
        loadedBuiltIns = true
        var changed = false
        for id in Self.builtIns {
            guard let provider = try? await provider(id) else { continue }
            let enabled = saved.first { $0.id == id }?.enabled ?? false
            let item = SubtitleSourceItem(provider.manifest, builtIn: true, enabled: enabled, origin: nil)
            if saved.first(where: { $0.id == id }) != item {
                saved.removeAll { $0.id == id }
                saved.append(item)
                changed = true
            }
        }
        if changed { save() }
    }

    private func file(_ id: String) -> URL { folder.appendingPathComponent(id + ".js") }

    private func save() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: folder.appendingPathComponent("sources.json"), options: .atomic) }
    }
}

/// Where the viewer's keys for subtitle sources are kept.
public protocol SubtitleCredentialStore: Sendable {
    func values(for provider: String) -> [String: String]
    /// Empty `values` removes them.
    func set(_ values: [String: String], for provider: String)
}

/// The Keychain, one item per source; never synced, readable after the first unlock (for a search while the
/// TV or Mac has been asleep).
public struct KeychainSubtitleCredentials: SubtitleCredentialStore {
    let service: String
    public init(service: String = "com.jo32.yingxia.subtitle-sources") { self.service = service }

    public func values(for provider: String) -> [String: String] {
        var query = base(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status != errSecSuccess, status != errSecItemNotFound { Diagnostics.shared.record(.warning, "subtitles", "keychain read failed status=\(status)") }
        guard status == errSecSuccess, let data = result as? Data else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    public func set(_ values: [String: String], for provider: String) {
        SecItemDelete(base(provider) as CFDictionary)
        guard !values.isEmpty, let data = try? JSONEncoder().encode(values) else { return }
        var item = base(provider)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { Diagnostics.shared.record(.warning, "subtitles", "keychain save failed status=\(status)") }
    }

    private func base(_ provider: String) -> [String: Any] {
        // On the Mac this is the login keychain: the data-protection one needs an entitlement Debug builds lack.
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: provider]
    }
}

/// Keys held in memory, for tests.
public final class MemorySubtitleCredentials: SubtitleCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: [String: String]] = [:]
    public init() {}
    public func values(for provider: String) -> [String: String] { lock.withLock { stored[provider] ?? [:] } }
    public func set(_ values: [String: String], for provider: String) { lock.withLock { stored[provider] = values.isEmpty ? nil : values } }
}

import Foundation

/// Platform identifiers used by Dandanplay-compatible services and the shared settings UI.
public enum DanmakuProvider: String, CaseIterable, Sendable {
    case automatic = ""
    case iqiyi, tencent, bilibili, youku, imgo, migu, dandan

    public var title: String {
        switch self {
        case .automatic: L10n.text("Automatic")
        case .iqiyi: L10n.text("iQIYI")
        case .tencent: L10n.text("Tencent Video")
        case .bilibili: L10n.text("Bilibili")
        case .youku: L10n.text("Youku")
        case .imgo: L10n.text("Mango TV")
        case .migu: L10n.text("Migu")
        case .dandan: L10n.text("Dandanplay")
        }
    }

    /// Recognize service identifiers and display tags without depending on the UI language.
    public init(source: String) {
        let key = CatalogDanmakuMatcher.normalized(source)
        self = Self.allCases.first { $0 != .automatic && $0.aliases.contains(key) } ?? .automatic
    }
    var aliases: [String] {
        switch self {
        case .automatic: []
        case .iqiyi: ["iqiyi", "qiyi", "爱奇艺"]
        case .tencent: ["tencent", "qq", "腾讯", "腾讯视频", "tencentvideo"]
        case .bilibili: ["bilibili", "哔哩哔哩", "b站"]
        case .youku: ["youku", "优酷"]
        case .imgo: ["imgo", "mgtv", "mango", "mangotv", "芒果", "芒果tv"]
        case .migu: ["migu", "咪咕", "咪咕视频"]
        case .dandan: ["dandan", "dandanplay", "弹弹play"]
        }
    }
}

/// Preferences shared by automatic matching and manual selection. No playback credentials belong here.
public enum DanmakuService {
    public static let serverKey = "danmakuServer"
    public static let automaticKey = "danmakuAutoMatch"
    public static let preferredSourceKey = "danmakuPreferredSource"
    /// With the official server: whether iQIYI and Tencent Video episode pages are looked up and sent to dmku.
    public static let officialLookupKey = "danmakuOfficialLookup"
    public static var officialLookupNote: String {
        L10n.text("Uses Dandanplay first, then tries iQIYI and Tencent Video if no comments are found or the service is unavailable. Official public episode pages are sent to dmku, or to danmu.zxz.ee when dmku has none; stream URLs and playback headers are never sent.")
    }
    public static let changed = Notification.Name("DanmakuService.changed")

    public static func server(defaults: UserDefaults = .standard) -> String {
        let address = defaults.string(forKey: serverKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return address.isEmpty ? CatalogDanmakuClient.defaultServer : address
    }
    /// The danmaku servers automatic matching asks in order, until one has comments (#1408). The official address
    /// stands for the built-in services (Dandanplay, then official episode pages through dmku). Before the list there
    /// was one address (`serverKey`): it is the list's only entry until another is added, so nothing changes by itself.
    public static let serversKey = "danmakuServers"
    public static func servers(defaults: UserDefaults = .standard) -> [String] {
        var seen = Set<String>()
        let saved = (defaults.stringArray(forKey: serversKey) ?? []).compactMap(canonical).filter { seen.insert($0).inserted }
        return saved.isEmpty ? [canonical(server(defaults: defaults)) ?? CatalogDanmakuClient.defaultServer] : saved
    }
    /// Saves the list in order. `serverKey` keeps its first entry, for what reads one address.
    public static func save(servers list: [String], defaults: UserDefaults = .standard) throws {
        var seen = Set<String>()
        let addresses = try list.map { try CatalogDanmakuClient(address: $0.trimmingCharacters(in: .whitespacesAndNewlines)).server.absoluteString }
            .filter { seen.insert($0).inserted }
        let saved = addresses.isEmpty ? [CatalogDanmakuClient.defaultServer] : addresses
        defaults.set(saved, forKey: serversKey)
        defaults.set(saved[0], forKey: serverKey)
        NotificationCenter.default.post(name: changed, object: nil)
    }
    public static func move(_ address: String, to index: Int, defaults: UserDefaults = .standard) throws {
        var list = servers(defaults: defaults)
        guard let from = list.firstIndex(of: address) else { return }
        list.remove(at: from); list.insert(address, at: min(max(index, 0), list.count))
        try save(servers: list, defaults: defaults)
    }
    /// Removing the last one leaves the built-in services.
    public static func remove(_ address: String, defaults: UserDefaults = .standard) throws {
        try save(servers: servers(defaults: defaults).filter { $0 != address }, defaults: defaults)
    }
    public static var serversNote: String {
        L10n.text("Servers are asked in order until one has comments. Add a Dandanplay-compatible server, such as a self-hosted danmu_api, by its root or an API prefix ending in /api/v2; a token in the path is supported. Each one is tested when added. Official episode pages from the source are sent to servers you add, to fetch their comments. Addresses are saved only on this device.")
    }
    /// Asks a server before it is added: it must answer a title search as Dandanplay does. The official one isn't asked
    /// (its requests are few and shared by every install). Returns the address as it is saved.
    public static func check(_ address: String, transport: DanmakuHTTP? = nil) async throws -> String {
        let client = try CatalogDanmakuClient(address: address.trimmingCharacters(in: .whitespacesAndNewlines), transport: transport)
        if client.server.absoluteString != CatalogDanmakuClient.defaultServer { try await client.check() }
        return client.server.absoluteString
    }
    /// A server's name on screen: the built-in services by name, another by its host. A token in its path isn't shown.
    public static func title(for address: String) -> String {
        guard let url = canonical(address).flatMap({ URL(string: $0) }) else { return address }
        if url.absoluteString == CatalogDanmakuClient.defaultServer { return L10n.text("Built-in Danmaku Services") }
        let host = (url.host() ?? address) + (url.port.map { ":\($0)" } ?? "")
        return url.path.isEmpty || url.path == "/" ? host : host + "/…"
    }
    static func canonical(_ address: String) -> String? { try? CatalogDanmakuClient(address: address).server.absoluteString }
    public static func preferredSource(defaults: UserDefaults = .standard) -> DanmakuProvider {
        DanmakuProvider(rawValue: defaults.string(forKey: preferredSourceKey) ?? "") ?? .automatic
    }
    public static func save(server: String, preferredSource: DanmakuProvider, automatic: Bool,
                            defaults: UserDefaults = .standard) throws {
        let address = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonical = try CatalogDanmakuClient(address: address.isEmpty ? CatalogDanmakuClient.defaultServer : address).server.absoluteString
        // With a list, the address given replaces its first entry, as it replaced the one address before the list.
        if let list = defaults.stringArray(forKey: serversKey), !list.isEmpty, Self.canonical(list[0]) != canonical {
            defaults.set([canonical] + list.dropFirst().filter { Self.canonical($0) != canonical }, forKey: serversKey)
        }
        defaults.set(canonical, forKey: serverKey)
        defaults.set(preferredSource.rawValue, forKey: preferredSourceKey)
        defaults.set(automatic, forKey: automaticKey)
        NotificationCenter.default.post(name: changed, object: nil)
    }
    /// Invalid settings are treated as custom so a bad address cannot activate the default service cascade.
    public static func isCustomServer(_ address: String) -> Bool {
        guard let canonical = try? CatalogDanmakuClient(address: address).server.absoluteString else { return true }
        return canonical != CatalogDanmakuClient.defaultServer
    }
    public static func cacheIdentity(server: String, preferredSource: DanmakuProvider = .automatic) -> String {
        let canonical = (try? CatalogDanmakuClient(address: server).server.absoluteString) ?? server.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(decoding: try! JSONEncoder().encode([canonical, preferredSource.rawValue]), as: UTF8.self)
    }
}

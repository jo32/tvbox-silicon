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
    public static let changed = Notification.Name("DanmakuService.changed")

    public static func server(defaults: UserDefaults = .standard) -> String {
        let address = defaults.string(forKey: serverKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return address.isEmpty ? CatalogDanmakuClient.defaultServer : address
    }
    public static func preferredSource(defaults: UserDefaults = .standard) -> DanmakuProvider {
        DanmakuProvider(rawValue: defaults.string(forKey: preferredSourceKey) ?? "") ?? .automatic
    }
    public static func save(server: String, preferredSource: DanmakuProvider, automatic: Bool,
                            defaults: UserDefaults = .standard) throws {
        let address = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonical = try CatalogDanmakuClient(address: address.isEmpty ? CatalogDanmakuClient.defaultServer : address).server.absoluteString
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

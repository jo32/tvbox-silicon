import Foundation

/// Kept outside disposable plugin caches; never included in subscription exports.
public struct CloudDriveAccounts: Codable, Sendable {
    public var quarkCookie = ""
    /// Quark's mobile service ticket is distinct from its web cookies; older saves omit it.
    public var quarkServiceTicket: String?
    public var ucCookie = ""
    public var ucToken = ""
    /// Aliyun Drive refresh token (32 characters); plugins read it as `token`.
    public var token = ""
    /// Baidu Netdisk sign-in cookies, "BDUSS=…; PTOKEN=…; STOKEN=…"; older saves omit it.
    public var baiduCookie: String?
    /// Xunlei's sign-in (`XunleiSignIn`), which CatPawOpen bundles take; older saves omit it.
    public var xunlei: XunleiAccount?
    /// Wex-family preferences a sign-in through the plugin's own code wrote (OwnDriveSignIn.java), which
    /// every Wex source then gets (CloudDriveBridge.seedWexCookies); older saves omit it.
    public var wexPreferences: [String: String]?
    public init() {}

    /// Keeps a sign-in a plugin made through its own QR code (`baiduCookie`, `token`) as the app's
    /// account for that drive, and a Wex sign-in's preferences (`wexPreferences`), so every source can
    /// use it. True when something changed.
    @discardableResult
    public static func adopt(_ offered: [String: Any]) -> Bool {
        var accounts = (try? load()) ?? Self()
        guard accounts.take(offered), (try? accounts.save()) != nil else { return false }
        Diagnostics.shared.record(.info, "cloud.signin", "saved a plugin sign-in for \(offered.keys.sorted().joined(separator: ","))")
        return true
    }
    /// Takes what `adopt` keeps from a plugin's offer. True when something changed.
    mutating func take(_ offered: [String: Any]) -> Bool {
        var changed = false
        if let cookie = offered["baiduCookie"] as? String, cookie.contains("BDUSS="), baiduCookie != cookie {
            baiduCookie = cookie; changed = true
        }
        if let token = offered["token"] as? String, token.count == 32, self.token != token {
            self.token = token; changed = true
        }
        if let preferences = offered["wexPreferences"] as? [String: String], !preferences.isEmpty {
            let merged = (wexPreferences ?? [:]).merging(preferences) { $1 }
            if merged != wexPreferences { wexPreferences = merged; changed = true }
        }
        return changed
    }
    /// The plugin runtime reads accounts from this file.
    public static var fileURL: URL {
        #if os(tvOS)
        // tvOS only permits Caches; `load` restores a purged copy from user defaults.
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #endif
        return base.appendingPathComponent("com.tvbox.yingxia/CloudDrive/accounts.json")
    }
    public static func load() throws -> Self {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: fileURL))
        }
        #if os(tvOS)
        if let data = UserDefaults.standard.data(forKey: defaultsKey), let accounts = try? JSONDecoder().decode(Self.self, from: data) {
            try accounts.save()
            return accounts
        }
        #endif
        return Self()
    }
    public func save() throws {
        let folder = Self.fileURL.deletingLastPathComponent()
        let data = try JSONEncoder().encode(self)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: Self.fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.fileURL.path)
        #if os(tvOS)
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        #endif
        NotificationCenter.default.post(name: CloudFiles.drivesChanged, object: nil)
    }
    /// Changes whenever the saved accounts do; empty when nothing is saved.
    public static var revision: String {
        _ = try? load()
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return "" }
        return String(PluginChecksum.sha256(data).prefix(12))
    }
    #if os(tvOS)
    private static let defaultsKey = "cloudDriveAccounts"
    #endif
}

/// The plugin tried to open an Android-only QR login flow. The app presents its own login for
/// Quark and UC. Baidu and Aliyun sign in inside the plugin (PluginSignIn shows its code); this
/// only reaches the viewer when that code couldn't be read.
public enum CloudDriveLoginRequired: String, LocalizedError, Sendable {
    case quark, uc, baidu, aliyun

    init?(envelope: [String: JSONValue]) {
        guard envelope["errorCode"]?.string == "cloud_login_required",
              let drive = envelope["drive"]?.string else { return nil }
        self.init(rawValue: drive)
    }

    /// A CatPawOpen bundle without a Baidu sign-in sends the viewer to its config center, which runs on the device's
    /// own address and can't be opened from another phone ("还没有配置百度网盘 Cookie，请先去配置中心登录百度网盘", #297).
    /// The app's Baidu sign-in reaches the bundle on its next request (Runtime/NodeHost `shareAccounts`).
    public init?(bundleMessage message: String) {
        guard message.contains("百度网盘"), message.contains("配置中心") || message.localizedCaseInsensitiveContains("cookie") else { return nil }
        self = .baidu
    }

    public func message(language: String? = nil) -> String {
        switch self {
        case .quark, .uc:
            return L10n.text("Your %@ sign-in is missing or has expired. Sign in again to play this episode.",
                             L10n.text(self == .quark ? "Quark" : "UC", language: language), language: language)
        case .baidu, .aliyun:
            return L10n.text("This line plays from %@, but its sign-in code couldn't be shown. Choose another line.",
                             L10n.text(self == .baidu ? "Baidu Netdisk" : "Aliyun Drive", language: language), language: language)
        }
    }
    public var errorDescription: String? { message() }
}

import Foundation

/// A complete, portable snapshot of everything the viewer can lose when the app is removed: sign-in
/// state (cookies and tokens), playback history, favourites, the passcode vault, custom proxies, and
/// the raw preferences that do not already travel through iCloud.
///
/// It deliberately does **not** carry subscriptions: those already round-trip through
/// `SubscriptionConfig` / `exportConfig()`, so a full backup embeds that payload rather than
/// duplicating it.
///
/// Every field is an opaque `Data` (a JSON blob or raw bytes) rather than a typed value, so the
/// backup survives a change to any individual model's Codable shape: what one version exports, a
/// later version still restores as long as it can still decode its own store.
public struct FullBackup: Codable, Equatable, Sendable {
    /// Bumped when the layout changes; an importer rejects an unknown version instead of guessing.
    public static let version = 1

    public var schemaVersion: Int
    /// When the backup was written, for the "last backup" label and freshness checks.
    public var createdAt: Date
    /// App name + version, so a restore can warn when the backup came from a newer build.
    public var appName: String
    public var appVersion: String

    // MARK: 数据类别（每类可独立导出/导入）

    /// Sign-in state: Bilibili, Douyin, cloud drives (Quark/UC/Aliyun/Baidu/115/Xunlei/Wex), AList/WebDAV/Emby servers.
    /// A JSON object keyed by account kind, each value the store's own encoded bytes.
    public var accounts: [String: Data]?
    /// Playback history entries (`PlaybackHistory.entries`), encoded as `[PlaybackHistoryEntry]`.
    public var history: Data?
    /// Favourites (`Favorites.syncValues`), encoded as `[String: FavoriteItem]`.
    public var favorites: Data?
    /// The passcode vault (`PrivacyVault`), encoded as `PrivacyVault`.
    public var vault: Data?
    /// Custom proxy endpoints and routes (`CustomProxyStore`), encoded as a `ProxySnapshot`.
    public var proxies: Data?
    /// Raw preference blobs, keyed by UserDefaults key (see `backupDefaultsKeys`).
    public var preferences: [String: Data]?
    /// Subscriptions, reusing the existing portable configuration payload.
    public var subscriptions: Data?

    public init(schemaVersion: Int = FullBackup.version, createdAt: Date = Date(),
                appName: String, appVersion: String,
                accounts: [String: Data]? = nil, history: Data? = nil, favorites: Data? = nil,
                vault: Data? = nil, proxies: Data? = nil, preferences: [String: Data]? = nil,
                subscriptions: Data? = nil) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.appName = appName
        self.appVersion = appVersion
        self.accounts = accounts
        self.history = history
        self.favorites = favorites
        self.vault = vault
        self.proxies = proxies
        self.preferences = preferences
        self.subscriptions = subscriptions
    }

    public var isEmpty: Bool {
        accounts == nil && history == nil && favorites == nil && vault == nil &&
        proxies == nil && preferences == nil && subscriptions == nil
    }
}

/// Which slices a backup carries. The user ticks these in the settings sheet.
public struct BackupCategory: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let accounts      = BackupCategory(rawValue: 1 << 0)
    public static let history       = BackupCategory(rawValue: 1 << 1)
    public static let favorites     = BackupCategory(rawValue: 1 << 2)
    public static let vault         = BackupCategory(rawValue: 1 << 3)
    public static let proxies       = BackupCategory(rawValue: 1 << 4)
    public static let preferences   = BackupCategory(rawValue: 1 << 5)
    public static let subscriptions = BackupCategory(rawValue: 1 << 6)

    public static let all: BackupCategory = [.accounts, .history, .favorites, .vault, .proxies, .preferences, .subscriptions]

    public static let titles: [(BackupCategory, String)] = [
        (.accounts, "Sign-in & accounts"),
        (.history, "Playback history"),
        (.favorites, "Favourites"),
        (.vault, "Privacy vault"),
        (.proxies, "Custom proxies"),
        (.preferences, "Settings & preferences"),
        (.subscriptions, "Subscriptions"),
    ]
}

/// A self-contained snapshot of the custom proxy store: endpoints (with their obfuscated credentials)
/// and the per-source routes, so both restore together.
public struct ProxySnapshot: Codable, Equatable, Sendable {
    public var endpoints: [CustomProxyEndpoint]
    public var routes: [String: CustomProxyRoute]
    public init(endpoints: [CustomProxyEndpoint], routes: [String: CustomProxyRoute]) {
        self.endpoints = endpoints; self.routes = routes
    }
}

/// The UserDefaults keys a full backup copies as raw blobs. A whitelist, not
/// `dictionaryRepresentation()`: the standard domain also holds system keys (NS…), QA toggles, and
/// one-shot flags that must not travel between installs.
///
/// The account stores (Douyin/Bilibili/cloud drives/AList) live in their own files and are carried by
/// `accounts`, not here; this list covers everything else that is not already an iCloud channel.
public enum FullBackupDefaults {
    /// Keys whose value is a `Data` blob (already JSON-encoded by their owner). These travel as
    /// raw bytes, so restoring them is a byte-for-byte `set(_, forKey:)` and never needs the model's
    /// type — a backup written by an older build still restores into a newer one.
    public static let dataKeys: [String] = [
        "favorites",              // Favorites.FavoriteDocument (all environments)
        "videoFavorites",         // legacy video favourites, read before adoption
        "videoSearchHistory",     // JSON-encoded [String] (search history, max 20)
        "sourceRouting.v1",
        "sourceOverrides.v1",
        "lineSettings.v1",
        "sourceReassignment.v2",
        "sourceReassignment.v1",
        "proxyEndpoints.v1",
        "proxyRoutes.v1",
        "pinnedSources.v1",
        "hiddenSources.v1",
        "hiddenSources.autoRestore.v1",
        "hiddenSources.builtInRestore.v1",
        "sourceOrder.v1",
        "sourceFoldState.v1",
        "musicExtensions",
        "musicLXSources",
        "episodeSkip.global.v1",
        "episodeSkip.auto.v2",
        "privacyVault",           // PrivacyVault (passcode + hidden sources)
        "artworkLanguage",
        "aiSubtitleTranslation",
        "environments",
        "skipSegmentSources",
        "resourceRanking",
        "player.playLine.probes",     // [String: SourceProbeResult]
        "player.playLine.rotation",   // HostRotation
        "player.playLine.learning",   // HostLearning
    ]

    /// Keys whose value is a scalar (Bool / String / Int / Double). Stored as a JSON-encoded scalar
    /// blob so one mechanism carries every type.
    public static let scalarKeys: [String] = [
        "sourceOrder.enabled",
        "musicQuality",
        "musicDisabledProviders",
        "musicHYWKey",
        "danmakuOpacity",
        "danmakuFontSize",
        "iCloudSync.enabled",
        "webCast.enabled",
        "webCast.port",
        "webCast.token",
        "webCast.requiresToken",
        "webCast.proxyMedia",
        "downloadsSimultaneous",
        "player.playLine.probes.order",
        "autoPlayNextEpisode",
        "keychainBackup.enabled",
        "discover.search.keywords",   // [String] (discover search history)
    ]

    /// A prefix match, for keys that fan out (`episodeSkip.v1.<scope>`).
    public static let prefixKeys: [String] = ["episodeSkip.v1.", "episodeSkip.auto.v2."]
}

/// Snapshots and restores the whitelisted preference keys a full backup carries. Lives in TVCore so
/// the logic is unit-testable without the app target.
public enum FullBackupPreferences {

    /// Copies the whitelist into `[key: Data]`. Data blobs travel as-is; scalars are JSON-wrapped so
    /// one mechanism carries every type.
    public static func snapshot(defaults: UserDefaults, playbackDefaults: UserDefaults) -> [String: Data] {
        var out: [String: Data] = [:]
        for key in FullBackupDefaults.dataKeys {
            if let data = defaults.data(forKey: key) { out[key] = data }
            else if let data = playbackDefaults.data(forKey: key) { out[key] = data }
        }
        for key in FullBackupDefaults.scalarKeys {
            let source = defaults.object(forKey: key) ?? playbackDefaults.object(forKey: key)
            guard let value = source, isJSONScalar(value) else { continue }
            if let data = try? JSONSerialization.data(withJSONObject: [key: value]) { out[key] = data }
        }
        for prefix in FullBackupDefaults.prefixKeys {
            for key in keys(matchingPrefix: prefix, in: defaults) + keys(matchingPrefix: prefix, in: playbackDefaults) {
                if let data = defaults.data(forKey: key) ?? playbackDefaults.data(forKey: key) { out[key] = data }
            }
        }
        return out
    }

    /// Writes a snapshot back. Data blobs are restored as-is; JSON-wrapped scalars are unwrapped first.
    /// Writes to both suites so whichever reader finds it.
    public static func restore(_ prefs: [String: Data], defaults: UserDefaults, playbackDefaults: UserDefaults) {
        for (key, data) in prefs {
            if FullBackupDefaults.dataKeys.contains(key) || FullBackupDefaults.prefixKeys.contains(where: { key.hasPrefix($0) }) {
                defaults.set(data, forKey: key)
                playbackDefaults.set(data, forKey: key)
            } else if let wrapped = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let value = wrapped[key] {
                defaults.set(value, forKey: key)
                playbackDefaults.set(value, forKey: key)
            }
        }
    }

    private static func keys(matchingPrefix prefix: String, in defaults: UserDefaults) -> [String] {
        defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) }
    }

    /// `JSONSerialization` throws NSException (not a Swift `Error`) on non-JSON types like `Data`,
    /// which `try?` cannot catch and crashes the app. Gate scalars to the plist/JSON-safe types first.
    private static func isJSONScalar(_ value: Any) -> Bool {
        switch value {
        case is String, is Bool, is NSNumber, is Int, is Double, is Float: return true
        case let array as [Any]: return array.allSatisfy(isJSONScalar)
        case let dict as [String: Any]: return dict.values.allSatisfy(isJSONScalar)
        default: return false
        }
    }
}

/// Collects the account stores a full backup carries, keyed by a stable name the importer maps back.
enum FullBackupAccounts {
    static let douyin = "douyin"
    static let bilibili = "bilibili"
    static let cloudDrive = "cloudDrive"
    static let alist = "alist"
}

/// The lightweight slice of a full backup that travels through iCloud key-value storage (the same
/// channel as favourites and history). It deliberately omits subscriptions — those are megabytes and
/// already have their own sync channel — and carries only what a fresh install otherwise loses:
/// sign-in state, the passcode vault, proxies, and the whitelisted preferences.
///
/// Every field is `Data` or a small value type so the whole payload stays far under the 256 KB
/// per-key limit the key-value store imposes.
public struct CloudBackupPayload: Codable, Equatable, Sendable {
    /// Sign-in files, keyed by `FullBackupAccounts`, verbatim bytes.
    public var accounts: [String: Data]
    /// The passcode vault, or nil when none is set.
    public var vault: PrivacyVault?
    /// The proxy endpoints and routes, or nil when none are configured.
    public var proxies: ProxySnapshot?
    /// Whitelisted preference keys → raw blob.
    public var preferences: [String: Data]

    public init(accounts: [String: Data] = [:], vault: PrivacyVault? = nil,
                proxies: ProxySnapshot? = nil, preferences: [String: Data] = [:]) {
        self.accounts = accounts; self.vault = vault; self.proxies = proxies; self.preferences = preferences
    }

    public var isEmpty: Bool { accounts.isEmpty && vault == nil && proxies == nil && preferences.isEmpty }
}

/// Reads and writes the sign-in files a full backup carries. Lives in TVCore so it can reach the
/// stores' `fileURL` members, which are internal (not public) on most of them.
public enum FullBackupAccountStore {

    /// The sign-in files, keyed by `FullBackupAccounts`, verbatim from disk. Missing files are omitted.
    public static func collect() -> [String: Data] {
        var accounts: [String: Data] = [:]
        if let data = try? Data(contentsOf: CloudDriveAccounts.fileURL) { accounts[FullBackupAccounts.cloudDrive] = data }
        if let data = try? Data(contentsOf: BilibiliAccount.fileURL) { accounts[FullBackupAccounts.bilibili] = data }
        if let data = try? Data(contentsOf: DouyinAccount.fileURL) { accounts[FullBackupAccounts.douyin] = data }
        if let data = try? Data(contentsOf: AListServers.fileURL) { accounts[FullBackupAccounts.alist] = data }
        return accounts
    }

    /// Writes the collected sign-in files back, with the same restrictive permissions each store uses.
    public static func restore(_ accounts: [String: Data]) {
        func write(_ data: Data, to url: URL) {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try data.write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                Diagnostics.shared.failure("backup", "restore account \(url.lastPathComponent)", error)
            }
        }
        if let data = accounts[FullBackupAccounts.cloudDrive] { write(data, to: CloudDriveAccounts.fileURL) }
        if let data = accounts[FullBackupAccounts.bilibili] { write(data, to: BilibiliAccount.fileURL) }
        if let data = accounts[FullBackupAccounts.douyin] { write(data, to: DouyinAccount.fileURL) }
        if let data = accounts[FullBackupAccounts.alist] { write(data, to: AListServers.fileURL) }
        // The tvOS copy in UserDefaults is redundant on iOS, but keep it fresh for a build that moves.
        #if os(tvOS)
        if let data = accounts[FullBackupAccounts.cloudDrive] { UserDefaults.standard.set(data, forKey: "cloudDriveAccounts") }
        if let data = accounts[FullBackupAccounts.bilibili] { UserDefaults.standard.set(data, forKey: "bilibiliAccount") }
        if let data = accounts[FullBackupAccounts.douyin] { UserDefaults.standard.set(data, forKey: "douyinAccount") }
        if let data = accounts[FullBackupAccounts.alist] { UserDefaults.standard.set(data, forKey: "alistServers") }
        #endif
    }
}

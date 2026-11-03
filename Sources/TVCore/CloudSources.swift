import Foundation

/// Yingxia's own sources (Bilibili, the short-drama sites, the live platforms) are not part of the app:
/// they live in a private repository and come from a subscription its Worker serves. The app adds that
/// subscription beside the viewer's own whenever they have one (`Subscription.withCloudSources`) and runs
/// its scripts on the device like any JavaScript source, with the language and the signed-in account of
/// the service passed in each source's ext.
public enum CloudSources {
    public static let address = URL(string: "https://yingxia-sources.getmegaportal.com/v1/tvbox.json")!
    /// Newer subscriptions may change shape; an app reads only the versions it knows.
    static let version = 1

    nonisolated(unsafe) private static var document: Subscription?
    nonisolated(unsafe) private static var livePlatforms: [LivePlatform] = []
    private static let lock = NSLock()

    /// The latest copy of the subscription the app has, which the app keeps current.
    public static var current: Subscription? {
        get { lock.withLock { document } }
        set {
            let platforms = (newValue?.raw["yingxiaLive"]?.array ?? []).compactMap { $0.object.flatMap(LivePlatform.init(json:)) }
            lock.withLock { document = newValue; livePlatforms = platforms }
        }
    }

    /// Its live platforms (`yingxiaLive`).
    static var platforms: [LivePlatform] { lock.withLock { livePlatforms } }

    /// One of Yingxia's own sources from the latest copy.
    public static func site(where matches: (Site) -> Bool) -> Site? { current?.sites.first(where: matches) }

    /// Fetches the subscription; it is only used in a shape this app reads.
    public static func fetch(http: HTTPClient) async throws -> Subscription {
        let (data, finalURL) = try await http.get(address, headers: ["User-Agent": HTTPClient.subscriptionUserAgent])
        let document = try Subscription.parse(data, origin: finalURL)
        guard accepts(document) else { throw TVError.unsupported(L10n.text("Update Yingxia to use its built-in sources.")) }
        return document
    }

    /// Whether a parsed document is this subscription in a shape this app reads.
    public static func accepts(_ subscription: Subscription) -> Bool {
        (subscription.raw["yingxia"]?.object?["version"]?.int ?? 0) == version
    }
}

extension Subscription {
    /// The subscription's sources and live playlists plus Yingxia's own (from `cloud`) and the drives in Cloud
    /// Files; the app shows this, the document keeps only its own. Yingxia's live platforms come first.
    public func withCloudSources(_ cloud: Subscription?) -> Subscription {
        let own = cloud.map { cloud in cloud.sites.filter { site in !sites.contains { $0.key == site.key } } } ?? []
        let extra = (own + CloudFilesSource.sites()).filter { site in !sites.contains { $0.key == site.key } }
        let platforms = (cloud?.lives ?? []).filter { live in !lives.contains { $0.url == live.url } }
        return Subscription(origin: origin, importedAt: importedAt, sites: sites + extra, lives: platforms + lives, raw: raw)
    }
}

/// Accounts a service's sources may act as. The app signs in; the source gets the cookie in its ext.
public enum SourceAccounts {
    public static func cookie(_ account: String?) -> String {
        switch account {
        case "bilibili": BilibiliAccount.load().cookie
        case "douyin": DouyinAccount.load().cookie
        default: ""
        }
    }
    public static func signedIn(_ account: String?) -> Bool {
        switch account {
        case "bilibili": BilibiliAccount.load().signedIn
        case "douyin": DouyinAccount.load().signedIn
        default: false
        }
    }
}

extension Site {
    /// What Yingxia's own subscription says about one of its sources (`yingxia` in the site entry).
    var yingxia: [String: JSONValue] { raw["yingxia"]?.object ?? [:] }
    /// A source the app provides itself: Yingxia's own (from its subscription) or a drive in Cloud Files.
    /// It never falls back to a subscription's JAR.
    public var isBuiltIn: Bool { isCloudFiles || yingxia["builtin"].map { if case .bool(true) = $0 { true } else { false } } == true }
    public var isBilibili: Bool { key == Bilibili.siteKey }
    /// The service account whose sign-in the source uses ("bilibili"), if any.
    public var account: String? { yingxia["account"]?.string }
    /// An SF Symbol for the source's icon, if its entry names one.
    public var symbol: String? { yingxia["symbol"]?.string }

    /// Yingxia's own sources run on the in-process runtime on every platform, even the Mac's.
    var runsInProcess: Bool { isBuiltIn && !isCloudFiles && runtime == .javascript }

    /// A built-in source's ext: its entry's own (an object) plus the app's language and the account's cookie.
    var builtInExtension: JSONValue {
        if isCloudFiles { return .object([:]) }
        var fields = raw["ext"]?.object ?? [:]
        fields["lang"] = .string(L10n.resolvedLanguage())
        if account != nil { fields["cookie"] = .string(SourceAccounts.cookie(account)) }
        return .object(fields)
    }

    /// The entry's name in `language`, when the entry gives names (`yingxia.names`).
    static func localizedName(_ entry: [String: JSONValue], language: String = L10n.resolvedLanguage()) -> String? {
        entry["yingxia"]?.object?["names"]?.object?[language]?.string ?? entry["names"]?.object?[language]?.string
    }
}

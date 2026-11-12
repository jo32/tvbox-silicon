import Foundation

/// Service metadata from a subscription explicitly enabled by the viewer.
/// No subscription address is bundled or fetched automatically.
public enum CloudSources {
    /// Relative service scripts resolve against the subscribed document, never a fixed server.
    public static var address: URL {
        get throws {
            guard let origin = current?.origin else { throw TVError.invalidConfiguration }
            return origin
        }
    }
    /// Newer subscriptions may change shape; an app reads only the versions it knows.
    static let version = 1

    nonisolated(unsafe) private static var document: Subscription?
    nonisolated(unsafe) private static var livePlatforms: [LivePlatform] = []
    nonisolated(unsafe) private static var musicListing: CloudMusic.Listing?
    private static let lock = NSLock()

    /// The active service subscription selected from the viewer's enabled subscriptions.
    public static var current: Subscription? {
        get { lock.withLock { document } }
        set {
            let platforms = (newValue?.raw["yingxiaLive"]?.array ?? []).compactMap { $0.object.flatMap(LivePlatform.init(json:)) }
            let listing = CloudMusic.Listing(json: newValue?.raw["yingxiaMusic"])
            lock.withLock { document = newValue; livePlatforms = platforms; musicListing = listing }
        }
    }

    /// Its live platforms (`yingxiaLive`).
    static var platforms: [LivePlatform] { lock.withLock { livePlatforms } }
    /// Its music channels (`yingxiaMusic`).
    static var music: CloudMusic.Listing? { lock.withLock { musicListing } }

    /// One of Yingxia's own sources from the latest copy.
    public static func site(where matches: (Site) -> Bool) -> Site? { current?.sites.first(where: matches) }

    /// Fetches the subscription; it is only used in a shape this app reads.
    public static func fetch(http: HTTPClient, address: URL) async throws -> Subscription {
        // Explicit diagnostic fetches should see current scripts rather than an HTTP-cached copy.
        let (data, finalURL) = try await http.get(address, headers: ["User-Agent": HTTPClient.subscriptionUserAgent], fresh: true)
        let document = try Subscription.parse(data, origin: finalURL)
        guard accepts(document) else { throw TVError.unsupported(L10n.text("Update the app to use the recommended sources.")) }
        return document
    }

    /// Whether a parsed document is this subscription in a shape this app reads.
    public static func accepts(_ subscription: Subscription) -> Bool {
        (subscription.raw["yingxia"]?.object?["version"]?.int ?? 0) == version
    }
}

extension Subscription {
    /// Adds only drives the viewer configured in Cloud Files.
    public func withCloudFiles() -> Subscription {
        let extra = CloudFilesSource.sites().filter { site in !sites.contains { $0.key == site.key } }
        return Subscription(origin: origin, importedAt: importedAt, sites: sites + extra, lives: lives, raw: raw)
    }
}

/// Accounts a service's sources may act as. The app signs in; the source gets the cookie in its ext.
public enum SourceAccounts {
    public static func cookie(_ account: String?) -> String {
        switch account {
        case "bilibili": BilibiliAccount.load().cookie
        case "douyin": DouyinAccount.load().cookie
        default: account.map { SourceAccount.load($0).cookie } ?? ""
        }
    }
    public static func signedIn(_ account: String?) -> Bool {
        switch account {
        case "bilibili": BilibiliAccount.load().signedIn
        case "douyin": DouyinAccount.load().signedIn
        default: account.map { SourceAccount.load($0).signedIn } ?? false
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

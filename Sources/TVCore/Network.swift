import Foundation

public struct HTTPClient: Sendable {
    public static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
    // Subscription hosts often send a landing page to browser user agents.
    public static let subscriptionUserAgent = "okhttp/3.12.13"
    public let session: URLSession
    let mirrors: GitHubMirrors
    public init(session: URLSession = .shared) { self.init(session: session, mirrors: .shared) }
    init(session: URLSession, mirrors: GitHubMirrors) { self.session = session; self.mirrors = mirrors }
    /// Most downloads stop at 20 MB; a subscription address can also be a book source list, and complete Legado lists
    /// run past 20 MB (one with 3907 sources is 21 MB).
    public static let subscriptionLimit = 64_000_000
    /// `fresh` asks the server again instead of taking a copy from this device's HTTP cache. `limit` is the most bytes
    /// accepted.
    public func get(_ url: URL, headers: [String: String] = [:], fresh: Bool = false, limit: Int = 20_000_000) async throws -> (Data, URL) {
        if let data = try ImportedFiles.data(at: url) { return (data, url) }
        return try await mirrors.fetch(url, timeout: 25) { [session] address, timeout in
            var request = URLRequest(url: address, timeoutInterval: timeout)
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            if fresh { request.cachePolicy = .reloadIgnoringLocalCacheData }
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            let data: Data, response: URLResponse
            do { (data, response) = try await BoundedHTTPData.load(request, session: session, maximumBytes: limit) }
            catch let error as URLError where error.code == .dataLengthExceedsMaximum {
                throw TVError.unsupported(limit == 20_000_000 ? L10n.text("The playlist exceeds 20 MB. Use a smaller subscription.")
                                          : L10n.text("The file is larger than %lld MB.", limit / 1_000_000))
            }
            guard let http = response as? HTTPURLResponse else { throw TVError.invalidConfiguration }
            guard (200..<300).contains(http.statusCode) else { throw TVError.http(http.statusCode) }
            // A mirror's address isn't the file's origin: relative paths resolve against the original.
            return (data, address == url ? response.url ?? url : url)
        }
    }
    public func subscription(_ url: URL) async throws -> Subscription {
        if let channel = TelegramSource.channel(url) { return TelegramSource.subscription(channel, origin: url) }
        let (data, finalURL) = try await get(url, headers: ["User-Agent": Self.subscriptionUserAgent])
        if let bundle = CatPawOpen.bundle(data, at: finalURL) { return try await CatPawOpen.subscription(bundle: bundle, origin: finalURL, http: self) }
        return try await Subscription.parse(data, origin: finalURL).sniffingScripts(http: self)
    }
    public func channels(_ source: LiveSource) async throws -> [Channel] { try await playlist(source).channels }
    /// A live source's channels, and the XMLTV guide its M3U header names, if any (#802).
    public func playlist(_ source: LiveSource) async throws -> (channels: [Channel], guide: String?) {
        if let platform = source.platform { return (try await LiveCatalog.channels(platform), nil) }
        let (data, finalURL) = try await playlistData(source)
        let text = Playlist.text(data)
        let guide = Playlist.guideAddress(in: text).flatMap { try? WebAddress.resolve($0, relativeTo: finalURL).absoluteString }
        return (try Playlist.parse(text, origin: finalURL, headers: source.headers), guide)
    }

    /// A live source's playlist, also one that Android TVBox players serve from their own local server
    /// (`LoopbackPlaylist`), and where its relative addresses resolve: the address it came from, never the
    /// Android server's 127.0.0.1:9978. A list given inline or answered by a plugin has none (nil).
    func playlistData(_ source: LiveSource) async throws -> (Data, URL?) {
        switch LoopbackPlaylist.route(source.url) {
        case nil: return try await get(source.url, headers: source.headers)
        case .playlist(let url)?: return try await get(url, headers: source.headers)
        case .text(let text)?: return (Data(text.utf8), nil)
        case .deviceFile?: throw LoopbackPlaylist.deviceFileError
        case .spider(let query)?:
            guard let spider = source.spider else { throw LoopbackPlaylist.needsPlugin }
            let answer = try await CatalogClient(site: spider.site, origin: spider.origin, http: self, jarURL: spider.archive).spiderProxy(query)
            if let location = answer.location, (300..<400).contains(answer.status) || answer.body.isEmpty {
                return try await get(location, headers: source.headers)
            }
            guard (200..<300).contains(answer.status) else { throw TVError.http(answer.status) }
            return (answer.body, nil)
        }
    }
}

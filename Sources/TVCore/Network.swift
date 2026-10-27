import Foundation

public struct HTTPClient: Sendable {
    public static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
    // Subscription hosts often send a landing page to browser user agents.
    public static let subscriptionUserAgent = "okhttp/3.12.13"
    public let session: URLSession
    let mirrors: GitHubMirrors
    public init(session: URLSession = .shared) { self.init(session: session, mirrors: .shared) }
    init(session: URLSession, mirrors: GitHubMirrors) { self.session = session; self.mirrors = mirrors }
    public func get(_ url: URL, headers: [String: String] = [:]) async throws -> (Data, URL) {
        try await mirrors.fetch(url, timeout: 25) { [session] address, timeout in
            var request = URLRequest(url: address, timeoutInterval: timeout)
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw TVError.invalidConfiguration }
            guard (200..<300).contains(http.statusCode) else { throw TVError.http(http.statusCode) }
            guard data.count <= 20_000_000 else { throw TVError.unsupported(L10n.text("The playlist exceeds 20 MB. Use a smaller subscription.")) }
            // A mirror's address isn't the file's origin: relative paths resolve against the original.
            return (data, address == url ? response.url ?? url : url)
        }
    }
    public func subscription(_ url: URL) async throws -> Subscription {
        let (data, finalURL) = try await get(url, headers: ["User-Agent": Self.subscriptionUserAgent])
        if let bundle = CatPawOpen.bundle(data, at: finalURL) { return try await CatPawOpen.subscription(bundle: bundle, origin: finalURL, http: self) }
        return try await Subscription.parse(data, origin: finalURL).sniffingScripts(http: self)
    }
    public func channels(_ source: LiveSource) async throws -> [Channel] {
        if let platform = source.platform { return try await LiveCatalog.channels(platform) }
        let (data, finalURL) = try await get(source.url, headers: source.headers)
        guard let text = String(data: data, encoding: .utf8) else { throw TVError.unsupported(L10n.text("Live playlists must use UTF-8 encoding.")) }
        return try Playlist.parse(text, origin: finalURL, headers: source.headers)
    }
}

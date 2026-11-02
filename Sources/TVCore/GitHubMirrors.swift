import Foundation

/// raw.githubusercontent.com, where many TVBox subscriptions and plugins live, is slow or blocked on many
/// networks in mainland China. When GitHub can't be reached, the same public file comes from a mirror.
/// Callers keep the GitHub address as the file's origin, so relative paths in a configuration still
/// resolve against GitHub (and come back here).
final class GitHubMirrors: @unchecked Sendable {
    static let shared = GitHubMirrors()
    /// Tried in order after GitHub. jsDelivr serves the repository's own files (a branch is cached for up
    /// to 12 hours); the prefix proxies are community services that come and go, so keep this list current.
    /// gh-proxy.org is gh-proxy.com's newer domain; listing both helps when a network blocks one of them.
    static let cdns = ["gcore.jsdelivr.net", "fastly.jsdelivr.net"]
    static let proxies = ["gh-proxy.org", "gh-proxy.com", "ghfast.top"]
    /// How long each address may stay silent before the next one is tried.
    static let patience: TimeInterval = 10
    private let lock = NSLock()
    private var preferred = 0
    private var gitHubFailed: Date?

    /// The file on raw.githubusercontent.com, also when a configuration wraps it in its own proxy
    /// (`https://proxy.example/https://raw.githubusercontent.com/...`). Nil for anything else, and for
    /// addresses with a query, which can carry access tokens that must not reach a mirror.
    static func gitHubFile(_ url: URL) -> URL? {
        guard url.query == nil, url.fragment == nil, url.user == nil else { return nil }
        if url.scheme == "https", url.host() == "raw.githubusercontent.com" { return url }
        let text = url.absoluteString
        guard let match = text.range(of: #"^https?://[^/]+/https:/+raw\.githubusercontent\.com/"#, options: .regularExpression) else { return nil }
        return URL(string: "https://raw.githubusercontent.com/" + text[match.upperBound...])
    }

    static func mirrors(of file: URL) -> [URL] {
        var parts = file.path(percentEncoded: true).split(separator: "/").map(String.init)
        if parts.count >= 6, parts[2] == "refs", ["heads", "tags"].contains(parts[3]) { parts.removeSubrange(2...3) }
        var urls: [URL] = []
        if parts.count >= 4 {
            let path = "\(parts[0])/\(parts[1])@\(parts[2])/" + parts[3...].joined(separator: "/")
            urls += cdns.compactMap { URL(string: "https://\($0)/gh/\(path)") }
        }
        return urls + proxies.compactMap { URL(string: "https://\($0)/\(file.absoluteString)") }
    }

    /// GitHub couldn't be reached. Its own answers (a 404, say) are final and never retried elsewhere.
    static func unreachable(_ error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        return [.timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost, .secureConnectionFailed,
                .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateHasBadDate,
                .serverCertificateNotYetValid].contains(code)
    }

    /// Runs `load` for `url`, and for a GitHub file that fails, again for GitHub and its mirrors: the
    /// configuration's own proxy first, then GitHub (skipped for ten minutes after it failed), then the
    /// mirrors starting with the one that last worked. Throws GitHub's error when every address fails.
    func fetch<T: Sendable>(_ url: URL, timeout: TimeInterval, _ load: @Sendable (URL, TimeInterval) async throws -> T) async throws -> T {
        guard let file = Self.gitHubFile(url) else { return try await load(url, timeout) }
        let mirrors = Self.mirrors(of: file)
        let (start, skipGitHub) = lock.withLock { (preferred, gitHubFailed.map { Date().timeIntervalSince($0) < 600 } ?? false) }
        let rotated = mirrors.indices.map { mirrors[(start + $0) % mirrors.count] }
        var order = file == url ? [] : [url]
        order += skipGitHub ? rotated + [file] : [file] + rotated
        var first: Error?
        var gitHub: Error?
        for candidate in order {
            try Task.checkCancellation()
            do {
                let value = try await load(candidate, min(timeout, Self.patience))
                lock.withLock {
                    if candidate == file { gitHubFailed = nil } else if let index = mirrors.firstIndex(of: candidate) { preferred = index }
                }
                return value
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                if candidate == file {
                    guard Self.unreachable(error) else { throw error }
                    lock.withLock { gitHubFailed = Date() }
                    gitHub = error
                }
                first = first ?? error
            }
        }
        throw gitHub ?? first ?? URLError(.cannotConnectToHost)
    }
}

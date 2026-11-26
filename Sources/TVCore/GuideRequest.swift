import Foundation

/// A guide belongs to the playlist and account that requested it. Headers are inherited only by the source's origin.
public struct GuideRequestContext: Hashable, Sendable {
    public let sourceID: String
    public let origin: URL?
    public let headers: [String: String]
    public let timeZone: TimeZone

    public init(sourceID: String = "", origin: URL? = nil, headers: [String: String] = [:],
                timeZone: TimeZone = TimeZone(identifier: "Asia/Shanghai")!) {
        self.sourceID = sourceID; self.origin = origin; self.timeZone = timeZone
        var normalized: [String: String] = [:]
        for key in headers.keys.sorted() { normalized[key.lowercased()] = headers[key] }
        self.headers = normalized
    }

    static func inherited(_ headers: [String: String], from origin: URL?, to target: URL) -> [String: String] {
        func port(_ url: URL) -> Int? { url.port ?? ["http": 80, "https": 443][url.scheme?.lowercased() ?? ""] }
        if let origin, origin.scheme?.lowercased() == target.scheme?.lowercased(),
           origin.host?.lowercased() == target.host?.lowercased(), port(origin) == port(target) { return headers }
        return headers.filter { ["user-agent", "accept", "accept-language"].contains($0.key.lowercased()) }
    }

    func day(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.startOfDay(for: date)
    }
}

/// A scoped download session avoids shared cookies, URL caches and stored credentials crossing playlist accounts.
/// Download progress enforces the received-size bound before the file is mapped into memory.
final class GuideDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct Response: Sendable {
        let data: Data
        let lifetime: TimeInterval
    }

    private let limit: Int
    private var previous: URLRequest
    private let lock = NSLock()
    private var exceeded = false

    init(request: URLRequest, limit: Int) { self.previous = request; self.limit = limit }

    static func fetch(_ url: URL, context: GuideRequestContext, limit: Int = 60_000_000) async throws -> Response {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw URLError(.unsupportedURL) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.allHTTPHeaderFields = GuideRequestContext.inherited(context.headers, from: context.origin, to: url)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let delegate = GuideDownload(request: request, limit: limit)
        let file: URL, response: URLResponse
        do { (file, response) = try await session.download(for: request, delegate: delegate) }
        catch {
            if delegate.lock.withLock({ delegate.exceeded }) { throw URLError(.dataLengthExceedsMaximum) }
            throw error
        }
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= limit else { throw URLError(.dataLengthExceedsMaximum) }
        let directives = (http.value(forHTTPHeaderField: "Cache-Control") ?? "").lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var lifetime: TimeInterval = 3 * 3600
        if directives.contains("no-store") || directives.contains("no-cache") { lifetime = 0 }
        for directive in directives where directive.hasPrefix("max-age=") {
            if let age = TimeInterval(directive.dropFirst(8).trimmingCharacters(in: CharacterSet(charactersIn: "\""))) { lifetime = min(lifetime, max(0, age)) }
        }
        return Response(data: try Data(contentsOf: file, options: .mappedIfSafe), lifetime: lifetime)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if max(totalBytesWritten, totalBytesExpectedToWrite) > limit {
            lock.withLock { exceeded = true }
            downloadTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { completionHandler(nil); return }
        var next = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        // Carry the previous accepted hop, never originalRequest or URLSession's proposed credential fields.
        // In particular, A -> B -> A must not regain the authorization removed on A -> B.
        lock.withLock {
            next.allHTTPHeaderFields = GuideRequestContext.inherited(previous.allHTTPHeaderFields ?? [:], from: previous.url, to: url)
            previous = next
        }
        completionHandler(next)
    }
}

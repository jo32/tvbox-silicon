import Foundation
import Testing
@testable import TVCore

private final class DownloadCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Int] = [:]
    func increment(_ key: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        values[key, default: 0] += 1
        return values[key]!
    }
    func count(_ key: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return values[key, default: 0]
    }
}

private final class DownloadProtocol: URLProtocol, @unchecked Sendable {
    static let counts = DownloadCounts()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let count = Self.counts.increment(url.absoluteString)
        let status = url.path.contains("retry") && count == 1 ? 503 : 200
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data("plugin".utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

private func downloadHTTP() -> HTTPClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DownloadProtocol.self]
    return HTTPClient(session: URLSession(configuration: configuration))
}

@Test func simultaneousSourcesShareOnePluginDownload() async throws {
    let cache = PluginDownloads()
    let http = downloadHTTP()
    let url = URL(string: "https://example.com/\(UUID()).jar")!
    try await withThrowingTaskGroup(of: Data.self) { group in
        for _ in 0..<8 { group.addTask { try await cache.data(at: url, http: http) } }
        for try await data in group { #expect(data == Data("plugin".utf8)) }
    }
    _ = try await cache.data(at: url, http: http)
    #expect(DownloadProtocol.counts.count(url.absoluteString) == 1)
}

@Test func pluginDownloadFailureCanBeRetried() async throws {
    let cache = PluginDownloads()
    let http = downloadHTTP()
    let url = URL(string: "https://example.com/retry/\(UUID()).jar")!
    await #expect(throws: (any Error).self) { try await cache.data(at: url, http: http) }
    #expect(try await cache.data(at: url, http: http) == Data("plugin".utf8))
    #expect(DownloadProtocol.counts.count(url.absoluteString) == 2)
}

@Test func pluginDownloadCacheExpiresAndEvicts() async throws {
    let http = downloadHTTP()
    let expired = PluginDownloads(lifetime: 0)
    let url = URL(string: "https://example.com/\(UUID()).jar")!
    _ = try await expired.data(at: url, http: http)
    _ = try await expired.data(at: url, http: http)
    #expect(DownloadProtocol.counts.count(url.absoluteString) == 2)
    let bounded = PluginDownloads()
    let urls = (0..<5).map { _ in URL(string: "https://example.com/\(UUID()).jar")! }
    for item in urls { _ = try await bounded.data(at: item, http: http) }
    _ = try await bounded.data(at: urls[0], http: http)
    #expect(DownloadProtocol.counts.count(urls[0].absoluteString) == 2)
}

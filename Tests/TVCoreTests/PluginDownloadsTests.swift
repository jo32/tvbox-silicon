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
        let conditional = url.path.contains("conditional") && request.value(forHTTPHeaderField: "If-None-Match") == "\"v1\""
        let status = conditional ? 304 : (url.path.contains("retry") && count == 1 ? 503 : 200)
        let body = url.path.contains("bytes") ? String(repeating: "p", count: 131_072) : (url.path.contains("changed") && count > 1 ? "plugin-v2" : "plugin")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["ETag": "\"v1\"", "Content-Length": String(status == 304 ? 0 : body.utf8.count)])!, cacheStoragePolicy: .notAllowed)
            if status != 304, url.path.contains("bytes") {
                self.client?.urlProtocol(self, didLoad: Data(body.utf8.prefix(65_536)))
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                    self.client?.urlProtocol(self, didLoad: Data(body.utf8.dropFirst(65_536)))
                    self.client?.urlProtocolDidFinishLoading(self)
                }
            } else {
                if status != 304 { self.client?.urlProtocol(self, didLoad: Data(body.utf8)) }
                self.client?.urlProtocolDidFinishLoading(self)
            }
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


@Test func pluginDiskCacheSurvivesRestartAndRepairsCorruption() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = URL(string: "https://example.com/\(UUID()).jar")!
    let first = PluginDownloads(directory: folder)
    let data = try await first.data(at: url, http: downloadHTTP())
    #expect(PluginChecksum.sha256(data) == "5e689e2b01672bf33996e75d5e372ff60c536ce1599a1458e867cd8f4bef5160")
    let restarted = PluginDownloads(directory: folder)
    #expect(try await restarted.data(at: url, http: downloadHTTP()) == data)
    #expect(DownloadProtocol.counts.count(url.absoluteString) == 1)
    let artifact = folder.appendingPathComponent(PluginChecksum.sha256(data) + ".bin")
    try Data("broken".utf8).write(to: artifact)
    let repaired = PluginDownloads(directory: folder)
    #expect(try await repaired.data(at: url, http: downloadHTTP()) == data)
    #expect(try Data(contentsOf: artifact) == data)
    #expect(DownloadProtocol.counts.count(url.absoluteString) == 2)
}

@Test func pluginDiskCacheRevalidatesAndDetectsSameURLChanges() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let conditional = URL(string: "https://example.com/conditional/\(UUID()).jar")!
    let first = PluginDownloads(lifetime: 0, directory: folder)
    let data = try await first.data(at: conditional, http: downloadHTTP())
    let restarted = PluginDownloads(lifetime: 0, directory: folder)
    #expect(try await restarted.data(at: conditional, http: downloadHTTP()) == data)
    #expect(DownloadProtocol.counts.count(conditional.absoluteString) == 2)
    let changed = URL(string: "https://example.com/changed/\(UUID()).jar")!
    let original = try await first.data(at: changed, http: downloadHTTP())
    let update = try await restarted.data(at: changed, http: downloadHTTP())
    #expect(update == Data("plugin-v2".utf8))
    #expect(PluginChecksum.sha256(update) != PluginChecksum.sha256(original))
    // The old immutable content remains available; existing sessions are not modified in place.
    #expect(try Data(contentsOf: folder.appendingPathComponent(PluginChecksum.sha256(original) + ".bin")) == original)
}

@Test func pluginBuildProgressIsRequestScopedAndHasNoInventedPercentage() async throws {
    let origin = URL(string: "https://example.com/progress")!
    let site = Site(key: UUID().uuidString, name: "Test", type: 3, api: "csp_Test", raw: [:])
    let progress = PluginPreparation(site: site, origin: origin)
    progress.report(.downloading, received: 25, expected: 100)
    #expect(PluginPreparation.snapshot(site: site, origin: origin)?.fraction == 0.25)
    progress.report(.converting, converted: 8, reused: 10)
    #expect(PluginPreparation.snapshot(site: site, origin: origin)?.fraction == nil)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("progress.json")
    let monitor = progress.observe(file)
    defer { monitor.cancel(); progress.finish() }
    try Data(#"{"stage":"converting","converted":12,"reused":30}"#.utf8).write(to: file, options: .atomic)
    let deadline = Date().addingTimeInterval(2)
    while PluginPreparation.snapshot(site: site, origin: origin)?.converted != 12, Date() < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(PluginPreparation.snapshot(site: site, origin: origin)?.reused == 30)
    progress.finish()
    progress.report(.loading)
    #expect(PluginPreparation.snapshot(site: site, origin: origin) == nil)
}

private final class TransferSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [(PluginPreparation.Stage, Int64, Int64?)] = []
    func add(_ stage: PluginPreparation.Stage, _ received: Int64, _ expected: Int64?) {
        lock.lock(); defer { lock.unlock() }; samples.append((stage, received, expected))
    }
    var hasBytes: Bool {
        lock.lock(); defer { lock.unlock() }
        return samples.contains { $0.0 == .downloading && $0.1 > 0 && $0.1 < 131_072 && $0.2 == 131_072 }
    }
}

@Test func pluginDownloadReportsActualByteProgress() async throws {
    let cache = PluginDownloads()
    let samples = TransferSamples()
    let url = URL(string: "https://example.com/bytes/\(UUID()).jar")!
    _ = try await cache.data(at: url, http: downloadHTTP()) { stage, received, expected in
        samples.add(stage, received, expected)
    }
    #expect(samples.hasBytes)
}

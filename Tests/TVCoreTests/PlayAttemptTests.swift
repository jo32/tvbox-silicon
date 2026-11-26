import Foundation
import Testing
@testable import TVCore

private func makeReports(_ name: String) -> (ErrorReports, UserDefaults, URL, () -> Void) {
    let suite = "play-attempt-\(name)-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    let reports = ErrorReports(defaults: defaults, directory: directory, interval: 0)
    return (reports, defaults, directory, {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    })
}

private func counters(_ reports: ErrorReports, _ directory: URL) throws -> [String: Int] {
    reports.save()
    let file = directory.appendingPathComponent("error-reports.json")
    guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
    let saved = try JSONDecoder().decode([String: ErrorReports.Group].self, from: Data(contentsOf: directory.appendingPathComponent("error-reports.json")))
    return Dictionary(uniqueKeysWithValues: saved.values.filter { $0.category == "player.stats" }.map { ($0.message, $0.count) })
}

@Test func playAttemptsCountOneOutcomeEachWithTheRungThatSavedThem() async throws {
    let (reports, _, directory, clean) = makeReports("outcomes")
    defer { clean() }
    await reports.start()

    var rescued = PlayAttempt(live: true, address: URL(string: "https://cdn.example.com/ch/1.m3u8?token=abc")!, reports: reports)
    rescued.retrying("repackage")
    rescued.retrying("line")
    rescued.resolve(.started, playing: URL(string: "http://127.0.0.1:52114/remux/1.m3u8")!)
    rescued.resolve(.failed, playing: nil)       // A later failure doesn't change a play already counted.
    rescued.retrying("drop")
    #expect(rescued.outcome == .started && rescued.rung == "line")

    var plain = PlayAttempt(live: false, address: URL(string: "https://cdn.example.com/Some%20Title.MP4")!, reports: reports)
    plain.resolve(.started, playing: URL(string: "https://cdn.example.com/Some%20Title.MP4")!)
    var again = PlayAttempt(live: false, address: URL(string: "https://other.example.org/x.mp4")!, reports: reports)
    again.resolve(.started, playing: URL(string: "https://other.example.org/x.mp4")!)
    var failed = PlayAttempt(live: false, address: URL(string: "https://cdn.example.com/watch.php?id=9")!, reports: reports)
    failed.resolve(.failed, playing: nil)
    var left = PlayAttempt(live: false, address: URL(string: "drive-stream://file/abc")!, reports: reports)
    left.resolve(.abandoned, playing: URL(string: "drive-stream://file/abc")!)

    #expect(try counters(reports, directory) == [
        "attempt live=1 via=local-proxy format=m3u8": 1,
        "started live=1 via=local-proxy format=m3u8": 1,
        "recovered rung=line live=1 via=local-proxy format=m3u8": 1,
        "attempt live=0 via=direct format=mp4": 2,
        "started live=0 via=direct format=mp4": 2,
        "attempt live=0 via=none format=other": 1,
        "failed live=0 via=none format=other": 1,
        "attempt live=0 via=drive-stream format=none": 1,
        "abandoned live=0 via=drive-stream format=none": 1,
    ])
}

/// Every counter's message is one the server keeps apart: its `normalize` (the same rules as `groupKey`) leaves it
/// as it is, and no two counters share a signature, so grouping never adds one counter into another.
@Test func playCountersNeverCollapseWhereErrorsGroup() {
    var messages = Set<String>()
    let vias = [nil, URL(string: "https://a.example/x"), URL(string: "http://127.0.0.1:9/x"), URL(fileURLWithPath: "/tmp/x.mp4"), URL(string: "cenc-stream://x")]
    let addresses = ["m3u8", "m3u", "mp4", "mkv", "flv", "ts", "mpd", "php", ""].map { URL(string: "https://a.example/v" + ($0.isEmpty ? "" : "." + $0))! }
    for live in [true, false] {
        for address in addresses {
            for via in vias {
                for rung in [nil, "range", "hdr-sdr", "audio", "loopback", "drop", "live", "line", "repackage", "segments"] {
                    var attempt = PlayAttempt(live: live, address: address)
                    if let rung { attempt.retrying(rung) }
                    for outcome in [PlayAttempt.Outcome.started, .failed, .abandoned] {
                        messages.formUnion(attempt.messages(outcome, via: PlayAttempt.via(via)))
                    }
                }
            }
        }
    }
    let keys = messages.map { ErrorReports.groupKey("player.stats", $0) }
    #expect(keys.allSatisfy { key in messages.contains(String(key.dropFirst("player.stats\n".count))) })
    #expect(Set(keys).count == messages.count)
}

@Test func playCountersCarryNoAddressTitleOrSource() {
    var attempt = PlayAttempt(live: false, address: URL(string: "https://secret-host.example/My%20Show/E01.mkv?token=hunter2")!)
    attempt.retrying("Line 2! 线路")
    let text = attempt.messages(.started, via: PlayAttempt.via(URL(string: "https://secret-host.example/My%20Show/E01.mkv?token=hunter2")))
        .joined(separator: "\n")
    #expect(text == "attempt live=0 via=direct format=mkv\nstarted live=0 via=direct format=mkv\nrecovered rung=line2 live=0 via=direct format=mkv")
    #expect(PlayAttempt.via(URL(string: "weird+scheme.with.a.very.long.name://x")) == "other")
    #expect(PlayAttempt.format(URL(string: "https://a.example/v.4k")!) == "other")
}

private final class ReportsMock: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var bodies: [Data] = []
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == "reports.play-attempt.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 65536)
            while case let read = stream.read(&buffer, maxLength: buffer.count), read > 0 { body.append(buffer, count: read) }
        }
        Self.bodies.append(body)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Sends what is due to the mock and returns the body. Each new count or error also starts a send of its own when one
/// is due: let those find no address first, so exactly one upload carries everything.
private func upload(_ reports: ErrorReports, _ defaults: UserDefaults) async -> Data? {
    try? await Task.sleep(for: .milliseconds(300))
    ReportsMock.bodies = []
    defaults.set("https://reports.play-attempt.test/v1/reports", forKey: "qaErrorReports")
    await reports.sendIfDue()
    for _ in 0..<20 where ReportsMock.bodies.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
    return ReportsMock.bodies.last
}

@Test func playCountersUploadAheadOfErrorsAndWithoutAnyError() async throws {
    URLProtocol.registerClass(ReportsMock.self)
    defer { URLProtocol.unregisterClass(ReportsMock.self) }
    let (reports, defaults, directory, clean) = makeReports("upload")
    defer { clean() }
    await reports.start()

    // An install with plays and no error still sends its counters.
    var attempt = PlayAttempt(live: false, address: URL(string: "https://a.example/v.mp4")!, reports: reports)
    attempt.resolve(.started, playing: URL(string: "https://a.example/v.mp4"))
    var sent = try #require(await upload(reports, defaults).flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
    var items = try #require(sent["items"] as? [[String: Any]])
    #expect(items.map { $0["message"] as? String } == ["attempt live=0 via=direct format=mp4", "started live=0 via=direct format=mp4"]
        || items.map { $0["message"] as? String } == ["started live=0 via=direct format=mp4", "attempt live=0 via=direct format=mp4"])
    #expect(items.allSatisfy { $0["category"] as? String == "player.stats" && ($0["count"] as? Int ?? 0) >= 1 })
    #expect(try counters(reports, directory).isEmpty)

    // No upload address while they come in, so none starts by itself before the one below.
    defaults.removeObject(forKey: "qaErrorReports")
    // Many errors, more frequent than any counter: the counters still go in this upload, within the server's 50.
    let entries = (0..<70).flatMap { index in
        (0..<3).map { _ in LogEntry(id: UUID(), date: Date(), level: .error, category: "player", message: "failed code=-\(1000 + index)") }
    }
    reports.collect(entries)
    for _ in 0..<2 {
        var attempt = PlayAttempt(live: true, address: URL(string: "https://a.example/c.m3u8")!, reports: reports)
        attempt.resolve(.failed, playing: URL(string: "https://a.example/c.m3u8"))
    }
    sent = try #require(await upload(reports, defaults).flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
    items = try #require(sent["items"] as? [[String: Any]])
    #expect(items.count == 50)
    #expect(items.prefix(2).allSatisfy { $0["category"] as? String == "player.stats" && $0["count"] as? Int == 2 })
    #expect(Set(items.prefix(2).compactMap { $0["message"] as? String }) == ["attempt live=1 via=direct format=m3u8", "failed live=1 via=direct format=m3u8"])
    #expect(items.dropFirst(2).allSatisfy { $0["category"] as? String == "player" })
}

@Test func playCountersStopWhenReportsAreOff() async throws {
    let (reports, defaults, directory, clean) = makeReports("off")
    defer { clean() }
    await reports.start()
    defaults.set(false, forKey: ErrorReports.key)
    var attempt = PlayAttempt(live: false, address: URL(string: "https://a.example/v.mp4")!, reports: reports)
    attempt.resolve(.started, playing: nil)
    reports.save()
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("error-reports.json").path))
}

import Foundation
final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "flv.fixture" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let mode = request.url!.deletingLastPathComponent().lastPathComponent
        let index = Self.lock.withLock {
            Self.requests.append(request)
            return Self.requests.filter { $0.url!.deletingLastPathComponent().lastPathComponent == mode }.count
        }
        let count = mode == "continuous" ? 7 : mode == "normal" ? 3 : mode == "codec" ? 2 : 1
        let status = mode == "empty" ? 200 : index == count + 1 ? 403 : index == count + 2 ? 429 : index == count + 3 ? 503 : 200
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"video/x-flv"])!, cacheStoragePolicy: .notAllowed)
        if status == 200 {
            // First 0..6 seconds, then cached 0..10, then cached 0..14. Later empty EOFs must exhaust the budget.
            if index <= count { client?.urlProtocol(self, didLoad: Self.file(until: UInt32(2 + index * 4) * 1000, config: mode == "codec" && index > 1 ? 8 : 3)) }
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func file(until: UInt32, config: UInt8 = 3) -> Data {
        var file = Data([0x46,0x4c,0x56,1,5,0,0,0,9,0,0,0,0])
        FLVSegmenter.write(.init(type: 9, time: 0, body: Data([0x17,0,0,0,0,1,2,config])), to: &file)
        FLVSegmenter.write(.init(type: 8, time: 0, body: Data([0xaf,0,0x12,0x10])), to: &file)
        for time in stride(from: UInt32(0), through: until, by: 1000) {
            FLVSegmenter.write(.init(type: 9, time: time, body: Data([time % 2000 == 0 ? 0x17 : 0x27,1,0,0,0,9,9])), to: &file)
            FLVSegmenter.write(.init(type: 8, time: time + 10, body: Data([0xaf,1,7,7])), to: &file)
        }
        return file
    }
}
actor Resolver {
    var calls = 0
    var gate: CheckedContinuation<Void, Never>?
    let waits: Bool
    let mode: String
    init(waits: Bool = false, mode: String = "normal") { self.waits = waits; self.mode = mode }
    func release() { gate?.resume(); gate = nil }
    func next() async -> (url: URL, headers: [String: String]) {
        calls += 1
        if waits { await withCheckedContinuation { gate = $0 } }
        return (URL(string: "https://flv.fixture/\(mode)/live.flv?token=\(calls)")!, ["X-Renewal":String(calls)])
    }
}
@main struct Check {
    static func main() async throws {
        let resolver = Resolver()
        let source = FLVLive.Source { await resolver.next() }
        let session = FLVLiveSession(url: URL(string: "https://flv.fixture/normal/live.flv")!, headers: ["X-Renewal":"0"], device: .init(), source: source)
        defer { session.close() }
        try await session.start()
        let owner = session.id
        let limit = Date().addingTimeInterval(10)
        while await resolver.calls < 3, Date() < limit { try await Task.sleep(for: .milliseconds(10)) }
        let firstCalls = await resolver.calls
        precondition(firstCalls >= 2, "EOF ended the HLS owner instead of refreshing its source")
        let playlist = await session.playlist(0) ?? ""
        precondition(session.id == owner && playlist.contains("#EXT-X-DISCONTINUITY"))
        // Six 2-second GOPs are unique across three overlapping responses. Cached GOPs must not be replayed.
        let video = try await session.segment(track: 0, index: 3)
        var reader = FLVTagReader(); let tags = try reader.append(video)
        let first = tags.first { $0.type == 9 && !FLVSegmenter.isVideoConfig($0.body) }!
        precondition(first.time == 6000, "reconnected CDN replayed old GOPs")
        let deadline = Date().addingTimeInterval(12)
        var ended = false
        while Date() < deadline {
            if (await session.playlist(0) ?? "").contains("#EXT-X-ENDLIST") { ended = true; break }
            try await Task.sleep(for: .milliseconds(25))
        }
        precondition(ended, "empty/403/503 connections kept retrying indefinitely")
        let calls = await resolver.calls
        precondition(calls == 5, "new media did not reset one bounded recovery budget")
        let requests = FixtureProtocol.lock.withLock { FixtureProtocol.requests.filter { $0.url!.path.hasPrefix("/normal/") } }
        precondition(requests.dropFirst().allSatisfy { $0.value(forHTTPHeaderField: "X-Renewal") != "0" })
        session.close()
        // More than three independent EOFs remain recoverable only while new media is published.
        let continuous = Resolver(mode: "continuous")
        let long = FLVLiveSession(url: URL(string: "https://flv.fixture/continuous/live.flv")!, headers: [:], device: .init(), source: .init { await continuous.next() })
        try await long.start()
        let progressiveDeadline = Date().addingTimeInterval(12)
        while await continuous.calls < 9, Date() < progressiveDeadline { try await Task.sleep(for: .milliseconds(25)) }
        let progressed = await continuous.calls
        precondition(progressed == 9, "healthy short connections lost renewal credit")
        let longPlaylist = await long.playlist(0) ?? ""
        precondition(longPlaylist.contains("#EXT-X-MEDIA-SEQUENCE:"))
        long.close()
        // A resolver ignoring cancellation can return after close; its old owner must not revive HTTP.
        let late = Resolver(waits: true, mode: "late")
        let closing = FLVLiveSession(url: URL(string: "https://flv.fixture/late/live.flv")!, headers: [:], device: .init(), source: .init { await late.next() })
        try await closing.start()
        while await late.calls == 0 { try await Task.sleep(for: .milliseconds(10)) }
        closing.close()
        await late.release()
        try await Task.sleep(for: .milliseconds(80))
        precondition(FixtureProtocol.lock.withLock { FixtureProtocol.requests.filter { $0.url!.path.hasPrefix("/late/") }.count } == 1, "late resolver revived a closed stream")
        // The upstream per-run init/discontinuity path remains usable for a configuration change.
        let codecs = Resolver(mode: "codec")
        let changed = FLVLiveSession(url: URL(string: "https://flv.fixture/codec/live.flv")!, headers: [:], device: .init(), source: .init { await codecs.next() })
        try await changed.start()
        while await codecs.calls < 2 { try await Task.sleep(for: .milliseconds(10)) }
        let oldInit = try await changed.initialization(track: 0, index: 0)
        let newInit = try await changed.initialization(track: 0, index: 3)
        precondition(oldInit != newInit, "configuration changes reused an old initialization")
        changed.close()
        let legacy = FLVLiveSession(url: URL(string: "https://flv.fixture/legacy/live.flv")!, headers: [:], device: .init())
        try await legacy.start()
        let legacyLimit = Date().addingTimeInterval(2)
        var legacyEnded = false
        while Date() < legacyLimit {
            if (await legacy.playlist(0) ?? "").contains("#EXT-X-ENDLIST") { legacyEnded = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(legacyEnded, "no-source EOF behavior changed")
        legacy.close()
        let empties = Resolver(mode: "empty")
        let empty = FLVLiveSession(url: URL(string: "https://flv.fixture/empty/live.flv")!, headers: [:], device: .init(), source: .init { await empties.next() })
        try await empty.start()
        let emptyLimit = Date().addingTimeInterval(7)
        var emptyEnded = false
        while Date() < emptyLimit {
            if (await empty.playlist(0) ?? "").contains("#EXT-X-ENDLIST") { emptyEnded = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let emptyAttempts = await empties.calls
        precondition(emptyEnded && emptyAttempts == 3, "empty EOFs renewed forever")
        empty.close()
        // A resolver which never completes cannot hold a dead stream open beyond the recovery window.
        let stalled = Resolver(waits: true, mode: "deadline")
        let expiring = FLVLiveSession(url: URL(string: "https://flv.fixture/deadline/live.flv")!, headers: [:], device: .init(), source: .init { await stalled.next() })
        try await expiring.start()
        let expiry = Date().addingTimeInterval(11)
        var expired = false
        while Date() < expiry {
            if (await expiring.playlist(0) ?? "").contains("#EXT-X-ENDLIST") { expired = true; break }
            try await Task.sleep(for: .milliseconds(25))
        }
        precondition(expired, "stalled resolver exceeded recovery deadline")
        await stalled.release()
        try await Task.sleep(for: .milliseconds(30))
        precondition(FixtureProtocol.lock.withLock { FixtureProtocol.requests.filter { $0.url!.path.hasPrefix("/deadline/") }.count } == 1)
        expiring.close()
        print("PASS: no-source EOF and stalled resolver deadline")
        print("PASS: advancing EOF credit, close/late resolver fencing and per-run codec initialization")
        print("PASS: stable owner, repeated EOF, cached GOP floor, discontinuity, refreshed headers and bounded empty/HTTP failure recovery (\(calls) resolver calls)")
    }
}

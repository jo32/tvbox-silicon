import Foundation
import TVCore

final class RenewalOrigin: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) static var held: RenewalOrigin?
    nonisolated(unsafe) static var heldRenewal: RenewalOrigin?
    nonisolated(unsafe) static var requested: [(URL, String?)] = []
    static func reset() { lock.withLock { held = nil; requested = [] } }
    static func releaseSegment() {
        let request = lock.withLock { let value = held; held = nil; return value }
        request?.reply("original-segment")
    }
    static var segmentHeld: Bool { lock.withLock { held != nil } }
    static var renewalHeld: Bool { lock.withLock { heldRenewal != nil } }
    static func releaseRenewal() {
        let request = lock.withLock { let value = heldRenewal; heldRenewal = nil; return value }
        request?.reply("#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:7\n#EXTINF:2,\nheld.ts\n")
    }
    static var requests: [(URL, String?)] { lock.withLock { requested } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "edge.fixture" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.lock.withLock { Self.requested.append((url, request.value(forHTTPHeaderField: "Authorization"))) }
        if url.path.hasSuffix("held.ts") { Self.lock.withLock { Self.held = self }; return }
        let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "token" }?.value ?? ""
        if token == "delayed" { Self.lock.withLock { Self.heldRenewal = self }; return }
        if token == "flv" { reply("FLV\u{01}fixture"); return }
        if token == "refused" { reply("denied", status: 403); return }
        if token == "master" { reply("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100\nvariant.m3u8\n"); return }
        if token == "vod" { reply("#EXTM3U\n#EXTINF:2,\nheld.ts\n#EXT-X-ENDLIST\n"); return }
        reply("#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:7\n#EXTINF:2,\nheld.ts\n")
    }
    func reply(_ text: String, status: Int = 200) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct LiveHLSRenewalRegression {
    static func main() async throws {
        func expect(_ value: Bool, _ message: String = "HLS renewal regression") { precondition(value, message) }
        func address(_ token: String, room: String = "1", host: String = "edge.fixture") -> URL { URL(string: "https://\(host)/live/main.m3u8?room=\(room)&quality=1080&token=\(token)")! }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [RenewalOrigin.self]
        let origin = URLSession(configuration: configuration)
        let proxy = HLSProxy(headers: ["Authorization": "old"], renewableLive: true, session: origin)
        let root = try await proxy.start(url: address("old"))
        expect(await proxy.renewableRoot() == nil, "Unread roots must not request periodic renewal")
        let (data, _) = try await URLSession.shared.data(from: root)
        let playlist = String(decoding: data, as: UTF8.self)
        let segment = URL(string: playlist.split(separator: "\n").first { $0.hasPrefix("http") }.map(String.init)!)!
        let expected = await proxy.renewableRoot()!
        let acquired = Task { try await URLSession.shared.data(from: segment) }
        for _ in 0..<200 where !RenewalOrigin.segmentHeld { try await Task.sleep(for: .milliseconds(5)) }
        precondition(RenewalOrigin.segmentHeld, "Fixture must hold a real in-flight segment")
        expect(await proxy.renew(expected: expected, to: .init(url: address("new"), headers: ["Authorization": "new"])))
        expect(await proxy.renewableRoot()?.url == address("new"))
        RenewalOrigin.releaseSegment()
        let (retained, _) = try await acquired.value
        precondition(String(decoding: retained, as: UTF8.self) == "original-segment", "Renewal must not cancel an acquired segment")
        let (_, rootReply) = try await URLSession.shared.data(from: root)
        precondition((rootReply as? HTTPURLResponse)?.statusCode == 200, "Root loopback URL must remain usable")
        precondition(RenewalOrigin.requests.contains { $0.0 == address("new") && $0.1 == "new" })
        precondition(RenewalOrigin.requests.contains { $0.0.path.hasSuffix("held.ts") && $0.1 == "old" })
        let current = await proxy.renewableRoot()!
        for candidate in [address("refused"), address("master"), address("vod"), address("new", room: "2"), address("new", host: "other.fixture")] {
            expect(!(await proxy.renew(expected: current, to: .init(url: candidate, headers: [:]))))
            expect(await proxy.renewableRoot() == current, "Failed/incompatible maintenance must preserve the healthy root")
        }
        precondition(proxy.stats.snapshot.failure == nil && proxy.stats.snapshot.status == nil, "Maintenance failure must not become a player transfer error")
        await proxy.stop()
        expect(!(await proxy.renew(expected: current, to: .init(url: address("later"), headers: [:]))))
        for excluded in ["master", "vod", "flv"] {
            let unsupported = HLSProxy(headers: [:], renewableLive: true, session: origin)
            let root = try await unsupported.start(url: address(excluded)); _ = try await URLSession.shared.data(from: root)
            expect(await unsupported.renewableRoot() == nil)
            await unsupported.stop()
        }
        let late = HLSProxy(headers: [:], renewableLive: true, session: origin)
        let lateRoot = try await late.start(url: address("old")); _ = try await URLSession.shared.data(from: lateRoot)
        let lateExpected = await late.renewableRoot()!
        let pending = Task { await late.renew(expected: lateExpected, to: .init(url: address("delayed"), headers: [:])) }
        for _ in 0..<200 where !RenewalOrigin.renewalHeld { try await Task.sleep(for: .milliseconds(5)) }
        precondition(RenewalOrigin.renewalHeld)
        await late.stop(); RenewalOrigin.releaseRenewal()
        expect(!(await pending.value), "A released owner must reject a late successful preflight")
        expect(await late.renewableRoot() == nil)

        let canceled = HLSProxy(headers: [:], renewableLive: true, session: origin)
        let canceledRoot = try await canceled.start(url: address("old")); _ = try await URLSession.shared.data(from: canceledRoot)
        let canceledExpected = await canceled.renewableRoot()!
        let canceledTask = Task { await canceled.renew(expected: canceledExpected, to: .init(url: address("delayed"), headers: [:])) }
        for _ in 0..<200 where !RenewalOrigin.renewalHeld { try await Task.sleep(for: .milliseconds(5)) }
        precondition(RenewalOrigin.renewalHeld)
        canceledTask.cancel(); RenewalOrigin.releaseRenewal()
        expect(!(await canceledTask.value), "Item/quality task cancellation must prevent commit")
        expect(await canceled.renewableRoot() == canceledExpected)
        await canceled.stop()

        let live = "#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:1\n#EXTINF:2,\none.ts\n"
        for forbidden in ["#EXT-X-MEDIA:TYPE=AUDIO,URI=\"audio.m3u8\"", "#EXT-X-DEFINE:NAME=\"a\",VALUE=\"b\"", "#EXT-X-ENDLIST", "#EXT-X-PLAYLIST-TYPE:VOD"] {
            precondition(!LiveHLSRenewal.directMedia(live + forbidden))
        }
        let repaired = LiveRepair.repairedMediaPlaylist("#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-DISCONTINUITY\n#EXTINF:2,\none.ts?token=old\n", origin: address("old"), identity: "fixture-repair")
        let steady = LiveRepair.repairedMediaPlaylist("#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:2,\none.ts?token=fresh\n", origin: address("new"), identity: "fixture-repair")
        precondition(!repaired.contains("#EXT-X-DISCONTINUITY") && steady.contains("one.ts?token=old"), "The existing discontinuity and stable-segment rules must survive root renewal")
        precondition(!LiveHLSRenewal.directMedia(live.replacingOccurrences(of: "one.ts", with: "{$name}.ts")))
        precondition(LiveHLSRenewal.compatible(address("old"), address("fresh")))
        for changed in ["https://edge.fixture/live/other.m3u8?room=1&quality=1080&token=x", "https://edge.fixture/live/main.m3u8?room=1&quality=720&token=x", "https://user:secret@edge.fixture/live/main.m3u8?room=1&quality=1080", "https://edge.fixture/live/main.m3u8?room=1&quality=1080#fragment"] {
            precondition(!LiveHLSRenewal.compatible(address("old"), URL(string: changed)!))
        }
        print("PASS stable live root, retained in-flight segment URL/headers, preflight/HTTP failures, room/quality/origin identity, unsupported-playlist gating, late-owner rejection and task cancellation")
    }
}

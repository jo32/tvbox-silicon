import Foundation
import TVCore

final class RenewalOrigin: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) static var held: RenewalOrigin?
    nonisolated(unsafe) static var heldRenewal: RenewalOrigin?
    nonisolated(unsafe) static var requested: [(URL, String?)] = []
    nonisolated(unsafe) private static var holdNextWindow = false
    nonisolated(unsafe) private static var heldWindow: (RenewalOrigin, String)?
    static func holdWindow() { lock.withLock { holdNextWindow = true } }
    static var windowHeld: Bool { lock.withLock { heldWindow != nil } }
    static func releaseWindow() {
        let window = lock.withLock { let saved = heldWindow; heldWindow = nil; return saved }
        if let (request, playlist) = window { request.reply(playlist) }
    }
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
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        guard url.host == "edge.fixture" else { reply("unexpected fixture origin", status: 404); return }
        Self.lock.withLock { Self.requested.append((url, request.value(forHTTPHeaderField: "Authorization"))) }
        if url.path.hasPrefix("/window/") {
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? "-"
            let cookie = request.value(forHTTPHeaderField: "Cookie") ?? "-"
            if url.lastPathComponent == "index.m3u8" {
                let version = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "token" }?.value
                let keyURI = version == "rotated" ? "key.bin?id=2%2F3" : "key.bin?id=1%2F3"
                let sequence = authorization == "first" ? 7 : 8
                func segment(_ number: Int) -> String {
                    let signature = number.isMultiple(of: 2) ? "&sig=\(authorization)" : ""
                    return "#EXTINF:2,\nchunk.ts?slot=\(number % 2)\(signature)"
                }
                let playlist = """
                #EXTM3U
                #EXT-X-VERSION:6
                #EXT-X-TARGETDURATION:2
                #EXT-X-MEDIA-SEQUENCE:\(sequence)
                #EXT-X-KEY:METHOD=AES-128,URI="\(keyURI)",IV=0x00000000000000000000000000000001
                #EXT-X-MAP:URI="init.mp4",BYTERANGE="64@0"
                \(segment(sequence))
                #EXT-X-KEY:METHOD=AES-128,URI="key.bin?id=1/3"
                \(segment(sequence + 1))
                """
                let held = Self.lock.withLock {
                    guard Self.holdNextWindow else { return false }
                    Self.holdNextWindow = false; Self.heldWindow = (self, playlist)
                    return true
                }
                if !held { reply(playlist) }
            } else {
                reply("\(url.absoluteString) | \(authorization) | \(cookie)")
            }
            return
        }
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
    static func check(_ value: Bool, _ message: String) {
        if !value { print("FAIL: " + message); exit(1) }
    }

    struct Window: Equatable {
        let keys: [URL]
        let map: URL
        let segments: [URL]
        init(_ playlist: String) {
            func attributes(_ tag: String) -> [URL] {
                playlist.split(separator: "\n").filter { $0.hasPrefix(tag) }.compactMap { line in
                    line.firstMatch(of: /[:,]URI="([^"]+)"/).flatMap { URL(string: String($0.1)) }
                }
            }
            keys = attributes("#EXT-X-KEY:")
            let maps = attributes("#EXT-X-MAP:")
            segments = playlist.split(separator: "\n").filter { !$0.hasPrefix("#") }.compactMap { URL(string: String($0)) }
            check(keys.count == 2 && maps.count == 1 && segments.count == 2, "unexpected rewritten media window")
            map = maps[0]
            check(playlist.contains(",BYTERANGE=\"64@0\"") && playlist.contains(",IV=0x00000000000000000000000000000001"), "non-URI attributes changed")
        }
    }

    static func resourceRoutes(origin: URLSession, client: URLSession) async throws {
        let root = URL(string: "https://edge.fixture/window/index.m3u8?room=1&token=same")!
        let oldHeaders = ["Authorization": "first", "Cookie": "window=one"]
        let proxy = HLSProxy(headers: oldHeaders, renewableLive: true, session: origin)
        let local = try await proxy.start(url: root)
        func get(_ route: URL) async throws -> String {
            check(route.host == "127.0.0.1" && route.port == local.port, "resource escaped the playback listener")
            let (data, response) = try await client.data(from: route)
            check((response as? HTTPURLResponse)?.statusCode == 200, "advertised resource not served")
            return String(decoding: data, as: UTF8.self)
        }
        func renew(_ headers: [String: String], rotated: Bool = false) async {
            guard let expected = await proxy.renewableRoot() else { check(false, "no live root"); return }
            let url = rotated ? URL(string: "https://edge.fixture/window/index.m3u8?room=1&token=rotated")! : root
            check(await proxy.renew(expected: expected, to: .init(url: url, headers: headers)), "compatible renewal refused")
        }
        func resource(_ route: URL, _ uri: String, _ auth: String, _ cookie: String) async throws {
            let expected = "https://edge.fixture/window/" + uri + " | " + auth + " | " + cookie
            let actual = try await get(route)
            check(actual == expected, "resource request mismatch: expected [\(expected)], received [\(actual)]")
        }
        let old = try await Window(get(local))
        RenewalOrigin.holdWindow()
        let oldReload = Task { try await client.data(from: local) }
        for _ in 0..<200 where !RenewalOrigin.windowHeld { try await Task.sleep(for: .milliseconds(5)) }
        check(RenewalOrigin.windowHeld, "old playlist request was not acquired")
        await renew(["Authorization": "second", "Cookie": "window=two"])
        let fresh = try await Window(get(local))
        try await resource(fresh.keys[0], "key.bin?id=1%2F3", "second", "window=two")
        try await resource(fresh.map, "init.mp4", "second", "window=two")
        check(old.keys[0] != fresh.keys[0] && old.map != fresh.map, "new key/map reused an old context")
        check(fresh.keys[0] != fresh.keys[1], "distinct encoded key URIs collapsed")
        try await resource(fresh.keys[1], "key.bin?id=1/3", "second", "window=two")
        check(old.segments[1] == fresh.segments[0], "overlapping sequence changed its advertised URL")
        try await resource(fresh.segments[0], "chunk.ts?slot=0&sig=first", "first", "window=one")
        check(old.segments[0] != fresh.segments[1], "a recycled media URI reused old headers for a new sequence")
        try await resource(fresh.segments[1], "chunk.ts?slot=1", "second", "window=two")
        check(try await Window(get(local)) == fresh, "unchanged playlist churned routes")

        await renew(["authorization": "second", "cookie": "window=two"])
        check(try await Window(get(local)) == fresh, "header-name casing churned equivalent routes")
        await renew(["Authorization": "second"])
        RenewalOrigin.releaseWindow()
        let (lateData, _) = try await oldReload.value
        check(Window(String(decoding: lateData, as: UTF8.self)) == old, "late root did not retain its advertised context")
        let noCookie = try await Window(get(local))
        check(noCookie.segments == fresh.segments, "late old root discarded a newer advertised segment route")
        try await resource(noCookie.keys[0], "key.bin?id=1%2F3", "second", "-")
        check(noCookie.keys[0] != fresh.keys[0], "removed cookie was ignored")
        await renew(["Authorization": "second"], rotated: true)
        let rotated = try await Window(get(local))
        try await resource(rotated.keys[0], "key.bin?id=2%2F3", "second", "-")
        check(rotated.keys[0] != noCookie.keys[0] && rotated.keys[1] == noCookie.keys[1] && rotated.map == noCookie.map, "key URI rotation disturbed unchanged resources")
        check(rotated.segments == fresh.segments, "key rotation disturbed stable media identities")
        try await resource(noCookie.keys[0], "key.bin?id=1%2F3", "second", "-")
        try await resource(old.keys[0], "key.bin?id=1%2F3", "first", "window=one")
        try await resource(old.map, "init.mp4", "first", "window=one")
        try await resource(old.segments[0], "chunk.ts?slot=1", "first", "window=one")
        try await resource(fresh.keys[0], "key.bin?id=1%2F3", "second", "window=two")
        await proxy.stop()
        print("PASS fixed key/map with new headers, rotation, encoded URI identity, late old routes and overlapping media sequence")
    }

    static func rootIdentity() {
        func root(_ query: String) -> URL { URL(string: "https://edge.fixture/live/index.m3u8?" + query)! }
        let original = root("room=a%2Fb&flag&line=1&line=2&token=first")
        check(LiveHLSRenewal.compatible(original, root("line=1&token=second&line=2&room=a%2Fb&flag")), "distinct query fields may reorder")
        for query in ["room=a/b&flag&line=1&line=2", "room=a%2Fb&flag=&line=1&line=2",
                      "room=a%2Fb&flag&line=2&line=1", "room=a%2Fb&flag&line=1",
                      "room=a%2Fb&flag&line=1&line=2&profile=other"] {
            check(!LiveHLSRenewal.compatible(original, root(query)), "distinct non-auth query accepted: " + query)
        }
        print("PASS root query identity: encoded values, flag vs empty, duplicate order/count, and authentication-only changes")
    }

    static func main() async throws {
        func expect(_ value: Bool, _ message: String = "HLS renewal regression") { precondition(value, message) }
        func address(_ token: String, room: String = "1", host: String = "edge.fixture") -> URL { URL(string: "https://\(host)/live/main.m3u8?room=\(room)&quality=1080&token=\(token)")! }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [RenewalOrigin.self]
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        let origin = URLSession(configuration: configuration)
        let localConfiguration = URLSessionConfiguration.ephemeral
        localConfiguration.httpCookieStorage = nil; localConfiguration.urlCache = nil
        localConfiguration.timeoutIntervalForRequest = 3; localConfiguration.timeoutIntervalForResource = 5
        let client = URLSession(configuration: localConfiguration)
        defer { client.invalidateAndCancel(); origin.invalidateAndCancel() }
        try await resourceRoutes(origin: origin, client: client)
        rootIdentity()
        let proxy = HLSProxy(headers: ["Authorization": "old"], renewableLive: true, session: origin)
        let root = try await proxy.start(url: address("old"))
        expect(await proxy.renewableRoot() == nil, "Unread roots must not request periodic renewal")
        let (data, _) = try await client.data(from: root)
        let playlist = String(decoding: data, as: UTF8.self)
        let segment = URL(string: playlist.split(separator: "\n").first { $0.hasPrefix("http") }.map(String.init)!)!
        let expected = await proxy.renewableRoot()!
        let acquired = Task { try await client.data(from: segment) }
        for _ in 0..<200 where !RenewalOrigin.segmentHeld { try await Task.sleep(for: .milliseconds(5)) }
        precondition(RenewalOrigin.segmentHeld, "Fixture must hold a real in-flight segment")
        expect(await proxy.renew(expected: expected, to: .init(url: address("new"), headers: ["Authorization": "new"])))
        expect(await proxy.renewableRoot()?.url == address("new"))
        RenewalOrigin.releaseSegment()
        let (retained, _) = try await acquired.value
        precondition(String(decoding: retained, as: UTF8.self) == "original-segment", "Renewal must not cancel an acquired segment")
        let (_, rootReply) = try await client.data(from: root)
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
            let root = try await unsupported.start(url: address(excluded)); _ = try await client.data(from: root)
            expect(await unsupported.renewableRoot() == nil)
            await unsupported.stop()
        }
        let late = HLSProxy(headers: [:], renewableLive: true, session: origin)
        let lateRoot = try await late.start(url: address("old")); _ = try await client.data(from: lateRoot)
        let lateExpected = await late.renewableRoot()!
        let pending = Task { await late.renew(expected: lateExpected, to: .init(url: address("delayed"), headers: [:])) }
        for _ in 0..<200 where !RenewalOrigin.renewalHeld { try await Task.sleep(for: .milliseconds(5)) }
        precondition(RenewalOrigin.renewalHeld)
        await late.stop(); RenewalOrigin.releaseRenewal()
        expect(!(await pending.value), "A released owner must reject a late successful preflight")
        expect(await late.renewableRoot() == nil)

        let canceled = HLSProxy(headers: [:], renewableLive: true, session: origin)
        let canceledRoot = try await canceled.start(url: address("old")); _ = try await client.data(from: canceledRoot)
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
        let repaired = LiveRepair.repairedMediaPlaylist("#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-DISCONTINUITY\n#EXTINF:2,\none.ts?token=old\n", identity: "fixture-repair") { $0 }
        let steady = LiveRepair.repairedMediaPlaylist("#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:2,\none.ts?token=fresh\n", identity: "fixture-repair") { $0 }
        precondition(!repaired.contains("#EXT-X-DISCONTINUITY") && steady.contains("one.ts?token=old"), "The existing discontinuity and stable-segment rules must survive root renewal")
        precondition(!LiveHLSRenewal.directMedia(live.replacingOccurrences(of: "one.ts", with: "{$name}.ts")))
        precondition(LiveHLSRenewal.compatible(address("old"), address("fresh")))
        for changed in ["https://edge.fixture/live/other.m3u8?room=1&quality=1080&token=x", "https://edge.fixture/live/main.m3u8?room=1&quality=720&token=x", "https://user:secret@edge.fixture/live/main.m3u8?room=1&quality=1080", "https://edge.fixture/live/main.m3u8?room=1&quality=1080#fragment"] {
            precondition(!LiveHLSRenewal.compatible(address("old"), URL(string: changed)!))
        }
        print("PASS stable live root, retained in-flight segment URL/headers, preflight/HTTP failures, room/quality/origin identity, unsupported-playlist gating, late-owner rejection and task cancellation")
    }
}

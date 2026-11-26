import Foundation
import Testing
@testable import TVCore

/// A signed live playlist renewed in place by the HLS proxy, against a stand-in CDN (`LiveOrigin`) whose signed
/// addresses start answering 403 when the test expires their token, while a fresh token is to be had.
@Suite(.serialized) struct LiveHLSRenewalTests {
    private let loopback = URLSession(configuration: .ephemeral)

    private func get(_ url: URL) async throws -> (String, Int) {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await loopback.data(for: request)
        return (String(decoding: data, as: UTF8.self), try #require(response as? HTTPURLResponse).statusCode)
    }

    /// The segments a served playlist lists: media sequence number → the proxy name AVPlayer would fetch.
    private func window(_ text: String) -> [(number: Int, name: URL)] {
        var number = 0, segments: [(Int, URL)] = []
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") { number = Int(line.dropFirst(22)) ?? 0 }
            else if line.hasPrefix("http://127.0.0.1"), let url = URL(string: line) { segments.append((number, url)); number += 1 }
        }
        return segments
    }

    private func address(_ id: String, _ path: String, token: String) -> URL {
        URL(string: "http://liverenewal.test/\(id)/\(path)?room=1&quality=1080&token=\(token)")!
    }

    /// Reads the playlist as AVPlayer's reloads would, the server's live edge one segment further each time, and
    /// checks the windows follow on: each number keeps one name, no name is two numbers, and no number is skipped.
    private final class Reader {
        var names: [Int: URL] = [:]
        var numbers: [URL: Int] = [:]
        var last: Int?
        func read(_ segments: [(number: Int, name: URL)]) {
            #expect(!segments.isEmpty)
            if let last, let first = segments.first?.number { #expect(first <= last + 1, "skipped \(last + 1)..<\(first)") }
            for (number, name) in segments {
                if let known = names[number] { #expect(known == name, "segment \(number) renamed: fetched twice") }
                if let known = numbers[name] { #expect(known == number, "\(name.lastPathComponent) names two segments") }
                names[number] = name; numbers[name] = number
            }
            last = segments.last?.number
        }
    }

    /// Fresh addresses handed out one by one, as a room's platform would.
    private final class Source: @unchecked Sendable {
        private let lock = NSLock()
        private var addresses: [URL?]
        private(set) var calls = 0
        init(_ addresses: [URL?]) { self.addresses = addresses }
        func next() -> URL? { lock.withLock { calls += 1; return addresses.isEmpty ? nil : addresses.removeFirst() } }
        var asked: Int { lock.withLock { calls } }
    }

    @Test func refusedReloadIsRenewedInPlaceTwice() async throws {
        let id = LiveOrigin.add()
        let source = Source([address(id, "live/index.m3u8", token: "B"), address(id, "live/index.m3u8", token: "C")])
        let proxy = HLSProxy(headers: ["Referer": "https://example.test/"])
        let root = try await proxy.start(url: address(id, "live/index.m3u8", token: "A"))
        await proxy.renewsLive(with: { source.next().map { (url: $0, headers: ["referer": "https://example.test/"]) } }, cooldown: .zero)
        let reader = Reader()
        for round in 0..<9 {
            if round == 3 { LiveOrigin.update(id) { $0.expired.insert("A") } }
            if round == 6 { LiveOrigin.update(id) { $0.expired.insert("B") } }
            let (text, status) = try await get(root)
            #expect(status == 200, "round \(round)")
            reader.read(window(text))
            LiveOrigin.update(id) { $0.head += 1 }
        }
        #expect(source.asked == 2)
        // Every segment, the renewed ones too, under the name AVPlayer knows it by: served from the current address.
        let (old, status) = try await get(try #require(reader.names[6]))
        #expect(status == 200 && old == "segment live/seg6.ts?token=C")
        let requests = LiveOrigin.stream(id).requests
        #expect(requests.contains("live/index.m3u8?token=B") && requests.contains("live/index.m3u8?token=C"))
        #expect(!LiveOrigin.stream(id).headers.isEmpty && LiveOrigin.stream(id).headers.allSatisfy { $0 == "https://example.test/" })
        await proxy.stop()
    }

    @Test func variantOfMasterIsRenewed() async throws {
        let id = LiveOrigin.add()
        let source = Source([address(id, "master.m3u8", token: "B")])
        let proxy = HLSProxy(headers: [:])
        let root = try await proxy.start(url: address(id, "master.m3u8", token: "A"))
        await proxy.renewsLive(with: { source.next().map { (url: $0, headers: [:]) } }, cooldown: .zero)
        let master = try await get(root).0
        let variants = master.components(separatedBy: "\n").filter { $0.hasPrefix("http://127.0.0.1") }.compactMap(URL.init(string:))
        #expect(variants.count == 2)
        let reader = Reader()
        for round in 0..<4 {
            if round == 2 { LiveOrigin.update(id) { $0.expired.insert("A") } }
            let (text, status) = try await get(variants[0])
            #expect(status == 200)
            reader.read(window(text))
            LiveOrigin.update(id) { $0.head += 1 }
        }
        #expect(source.asked == 1)
        // The other quality moved to the fresh address too: switching to it later still plays.
        let (other, status) = try await get(variants[1])
        #expect(status == 200 && other.contains("#EXTINF"))
        #expect(LiveOrigin.stream(id).requests.contains("v1080/index.m3u8?token=B"))
        await proxy.stop()
    }

    enum Fallback: CaseIterable { case noAddress, otherStream, startedOver, otherHeaders, sameAddress }

    /// When the fresh address isn't the same stream, or there is none, AVPlayer gets the refusal (and the player opens
    /// the stream again, as before), and no other renewal is tried.
    @Test(arguments: Fallback.allCases) func refusalPassesOnWhenRenewalCant(_ fallback: Fallback) async throws {
        let id = LiveOrigin.add()
        var headers: [String: String] = [:]
        let fresh: URL?
        switch fallback {
        case .noAddress: fresh = nil
        case .otherStream: fresh = address(id, "live/other.m3u8", token: "B")
        case .startedOver: fresh = address(id, "live/index.m3u8", token: "B"); LiveOrigin.update(id) { $0.restarted.insert("B") }
        case .otherHeaders: fresh = address(id, "live/index.m3u8", token: "B"); headers = ["Cookie": "other"]
        case .sameAddress: fresh = address(id, "live/index.m3u8", token: "A")
        }
        let source = Source([fresh, address(id, "live/index.m3u8", token: "C")])
        LiveOrigin.update(id) { $0.head = 10 }
        let proxy = HLSProxy(headers: [:])
        let root = try await proxy.start(url: address(id, "live/index.m3u8", token: "A"))
        await proxy.renewsLive(with: { [headers] in source.next().map { (url: $0, headers: headers) } }, cooldown: .zero)
        #expect(try await get(root).1 == 200)
        LiveOrigin.update(id) { $0.head += 1; $0.expired.insert("A") }
        #expect(try await get(root).1 == 403)
        #expect(try await get(root).1 == 403)
        #expect(source.asked == 1)
        #expect(!LiveOrigin.stream(id).requests.contains("live/index.m3u8?token=C"))
        await proxy.stop()
    }

    /// A refused playlist the proxy never served as a live window (the first one, or a finished video) isn't renewed.
    @Test func onlyALiveWindowAlreadyReadIsRenewed() async throws {
        let id = LiveOrigin.add()
        LiveOrigin.update(id) { $0.ended = true }
        let source = Source([address(id, "live/index.m3u8", token: "B")])
        let proxy = HLSProxy(headers: [:])
        let root = try await proxy.start(url: address(id, "live/index.m3u8", token: "A"))
        await proxy.renewsLive(with: { source.next().map { (url: $0, headers: [:]) } }, cooldown: .zero)
        #expect(try await get(root).1 == 200)
        LiveOrigin.update(id) { $0.expired.insert("A") }
        #expect(try await get(root).1 == 403)
        #expect(source.asked == 0)
        await proxy.stop()
    }

    @Test func addressIdentity() {
        func root(_ query: String) -> URL { URL(string: "https://edge.fixture/live/index.m3u8?" + query)! }
        let original = root("room=a%2Fb&flag&line=1&line=2&token=first")
        #expect(LiveHLSRenewal.compatible(original, root("line=1&token=second&line=2&room=a%2Fb&flag")))
        #expect(LiveHLSRenewal.compatible(root("wsSecret=1&wsTime=2&room=3"), root("room=3&wsSecret=9&wsTime=8")))
        for query in ["room=a/b&flag&line=1&line=2", "room=a%2Fb&flag=&line=1&line=2", "room=a%2Fb&flag&line=2&line=1",
                      "room=a%2Fb&flag&line=1", "room=a%2Fb&flag&line=1&line=2&profile=other"] {
            #expect(!LiveHLSRenewal.compatible(original, root(query)), "\(query)")
        }
        let main = URL(string: "https://edge.fixture/live/main.m3u8?room=1&quality=1080&token=old")!
        for changed in ["https://edge.fixture/live/other.m3u8?room=1&quality=1080&token=x", "https://edge.fixture/live/main.m3u8?room=1&quality=720&token=x",
                        "https://user:secret@edge.fixture/live/main.m3u8?room=1&quality=1080", "https://edge.fixture/live/main.m3u8?room=1&quality=1080#fragment",
                        "http://edge.fixture/live/main.m3u8?room=1&quality=1080&token=x", "https://edge2.fixture/live/main.m3u8?room=1&quality=1080&token=x",
                        "tvbox-live-repair://edge.fixture/live/main.m3u8?room=1&quality=1080&token=x"] {
            #expect(!LiveHLSRenewal.compatible(main, URL(string: changed)!), "\(changed)")
        }
    }

    @Test func onlyLiveMediaPlaylistsAreRenewable() {
        let live = "#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:1\n#EXTINF:2,\none.ts\n"
        #expect(LiveHLSRenewal.directMedia(live))
        for extra in ["#EXT-X-MEDIA:TYPE=AUDIO,URI=\"audio.m3u8\"", "#EXT-X-DEFINE:NAME=\"a\",VALUE=\"b\"", "#EXT-X-ENDLIST",
                      "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-STREAM-INF:BANDWIDTH=1\nv.m3u8"] {
            #expect(!LiveHLSRenewal.directMedia(live + extra + "\n"), "\(extra)")
        }
        #expect(!LiveHLSRenewal.directMedia(live.replacingOccurrences(of: "one.ts", with: "{$name}.ts")))
    }

    @Test func windowsCarryOnOnlyAsTheSameStream() throws {
        let origin = URL(string: "https://cdn.test/live/index.m3u8?token=A")!
        func window(_ first: Int, _ count: Int = 4, token: String = "A", discontinuityAt: Int? = nil,
                    segment: (Int) -> String = { "seg\($0).ts" }) throws -> LiveHLSRenewal.Window {
            var text = "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:\(first)\n#EXT-X-KEY:METHOD=AES-128,URI=\"key?token=\(token)\"\n"
            for number in first..<(first + count) {
                if number == discontinuityAt { text += "#EXT-X-DISCONTINUITY\n" }
                text += "#EXTINF:2,\n\(segment(number))?token=\(token)\n"
            }
            return try #require(LiveHLSRenewal.Window(text, origin: origin))
        }
        let before = try window(10)
        #expect(before.first == 10 && before.last == 13 && before.tags.count == 1)
        #expect(before.segments[12]?.url.absoluteString == "https://cdn.test/live/seg12.ts?token=A")
        #expect(before.continues(to: try window(11, token: "B")))
        #expect(before.continues(to: try window(13, token: "B")))
        #expect(before.continues(to: try window(8, 8, token: "B")))
        // A gap (segments skipped), a window behind the one read, numbers counted afresh, other segments under the same numbers.
        #expect(!before.continues(to: try window(14, token: "B")))
        #expect(!before.continues(to: try window(9, token: "B")))
        #expect(!before.continues(to: try window(0, token: "B")))
        #expect(!before.continues(to: try window(11, token: "B") { "other\($0).ts" }))
        // A discontinuity where the window read had none.
        #expect(!before.continues(to: try window(11, token: "B", discontinuityAt: 12)))
        // Segments told apart only by their signature can't be matched.
        #expect(!before.continues(to: try window(11, token: "B") { _ in "chunk.ts" }))
        #expect(LiveHLSRenewal.Window("#EXTM3U\n#EXTINF:2,\na.ts\n#EXT-X-ENDLIST\n", origin: origin) == nil)
    }
}

/// A stand-in CDN for host `liverenewal.test`: `/<id>/live/index.m3u8?token=…` is a live window of four segments
/// ending at `head`, each segment signed with the playlist's token; `/<id>/master.m3u8` lists two such variants.
/// A token in `expired` is refused (403) for playlists and segments alike; one in `restarted` numbers from 0 again.
final class LiveOrigin: URLProtocol, @unchecked Sendable {
    struct Stream {
        var head = 3
        var expired: Set<String> = []
        var restarted: Set<String> = []
        var ended = false
        var requests: [String] = []
        var headers: [String] = []
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var streams: [String: Stream] = [:]
    private static let registered: Void = { URLProtocol.registerClass(LiveOrigin.self) }()

    static func add() -> String {
        _ = registered
        let id = UUID().uuidString
        lock.withLock { streams[id] = Stream() }
        return id
    }
    static func update(_ id: String, _ change: (inout Stream) -> Void) { lock.withLock { change(&streams[id, default: Stream()]) } }
    static func stream(_ id: String) -> Stream { lock.withLock { streams[id] ?? Stream() } }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == "liverenewal.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let parts = url.path.split(separator: "/").map(String.init)
        let id = parts.first ?? "", path = parts.dropFirst().joined(separator: "/")
        let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "token" }?.value ?? ""
        let referer = request.value(forHTTPHeaderField: "Referer")
        let stream = Self.lock.withLock { () -> Stream? in
            guard Self.streams[id] != nil else { return nil }
            Self.streams[id]?.requests.append(path + "?token=" + token)
            if let referer { Self.streams[id]?.headers.append(referer) }
            return Self.streams[id]
        }
        guard let stream else { reply(404, ""); return }
        if stream.expired.contains(token) { reply(403, "expired"); return }
        if path == "master.m3u8" {
            reply(200, "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\nv720/index.m3u8?room=1&token=\(token)\n#EXT-X-STREAM-INF:BANDWIDTH=1600000\nv1080/index.m3u8?room=1&token=\(token)\n")
            return
        }
        if path.hasSuffix(".m3u8") {
            let last = stream.restarted.contains(token) ? 3 : stream.head
            var text = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:\(last - 3)\n"
            for number in (last - 3)...last { text += "#EXTINF:2.0,\nseg\(number).ts?token=\(token)\n" }
            if stream.ended { text += "#EXT-X-ENDLIST\n" }
            reply(200, text)
            return
        }
        if path.hasSuffix(".ts") { reply(200, "segment \(path)?token=\(token)"); return }
        reply(404, "")
    }
    private func reply(_ status: Int, _ body: String) {
        guard let url = request.url else { return }
        let data = Data(body.utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                                              headerFields: ["Content-Length": "\(data.count)", "Content-Type": "text/plain"])!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

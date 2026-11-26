import Foundation
import Testing
@testable import TVCore

/// The proxy against a stand-in upstream (`HLSUpstream`, answering `http://hlsproxy.test/...` for the shared session).
@Suite(.serialized) struct HLSProxyTests {
    private static let ts: Data = {
        var data = Data()
        for index in 0..<600 { data.append(0x47); data.append(contentsOf: [UInt8](repeating: UInt8(index % 251), count: 187)) }
        return data
    }()
    private static let picture = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 7, count: 300)
    private let loopback = URLSession(configuration: .ephemeral)

    private func playlist(_ segment: String) -> Data {
        Data("#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:10,\nhttp://hlsproxy.test/\(segment)\n#EXT-X-ENDLIST\n".utf8)
    }
    private func get(_ url: URL, range: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        if let range { request.setValue("bytes=" + range, forHTTPHeaderField: "Range") }
        let (data, response) = try await loopback.data(for: request)
        return (data, try #require(response as? HTTPURLResponse))
    }
    private func segmentAddress(in playlist: Data) throws -> URL {
        let line = try #require(String(decoding: playlist, as: UTF8.self).split(separator: "\n").first { $0.hasPrefix("http://127.0.0.1") })
        return try #require(URL(string: String(line)))
    }

    /// An `.m3u8` address that sends an endless MPEG-TS stream: given up on at its first kilobyte, not read on.
    /// The stand-in's stream never ends and never goes quiet, so nothing but giving up on its first bytes returns
    /// `notPlaylist`: reading on would wait for an end that never comes, and the start's time budget would end it
    /// as a timeout (30 s, 45 s), not as this. No clock is read; the time limit only keeps a broken proxy from
    /// hanging the run.
    @Test(.timeLimit(.minutes(2))) func endlessStreamIsGivenUpOnAtOnce() async throws {
        for patience in [HLSProxy.Patience.retry, .opening] {
            let id = HLSUpstream.add(["/endless/index.m3u8": .endless(Self.ts)])
            let proxy = HLSProxy(headers: [:])
            await #expect(throws: HLSProxy.Failure.notPlaylist("mpeg-ts")) {
                _ = try await proxy.start(url: URL(string: "http://hlsproxy.test/\(id)/endless/index.m3u8")!, patience: patience)
            }
            // And the transfer was stopped, not left running into memory.
            #expect(await HLSUpstream.stopped(id))
        }
    }

    /// The check for spliced-in ads that iPhone and Apple TV make before playing an .m3u8 doesn't hold an endless
    /// stream either: it stops at the first kilobyte, and AVPlayer gets the address as it is. The stream never goes
    /// quiet, so the check's 6 s idle timeout can't be what ends it: reading on would never return.
    @Test(.timeLimit(.minutes(2))) func adCheckStopsAtAStream() async throws {
        let id = HLSUpstream.add(["/endless/index.m3u8": .endless(Self.ts)])
        #expect(await AdSkip.route(URL(string: "http://hlsproxy.test/\(id)/endless/index.m3u8")!, headers: [:]) == nil)
        #expect(await HLSUpstream.stopped(id))
    }

    /// A certificate the system refused reaches AVPlayer as 495, not 502, and its code is in the stats.
    @Test func certificateFailureIsTold() async throws {
        let id = HLSUpstream.add(["/tls/index.m3u8": .failure(URLError(.serverCertificateUntrusted))])
        let url = URL(string: "http://hlsproxy.test/\(id)/tls/index.m3u8")!
        let proxy = HLSProxy(headers: [:])
        let address = try await proxy.start(url: url)
        let (_, response) = try await get(address)
        #expect(response.statusCode == 495)
        #expect(proxy.stats.snapshot.code == URLError.Code.serverCertificateUntrusted.rawValue)
        #expect(HLSProxy.certificate(proxy.stats.snapshot.code))
        await proxy.stop()
        await #expect(throws: URLError.self) { _ = try await HLSProxy(headers: [:]).start(url: url, patience: .retry) }
    }

    /// After its listener is taken back, the same stream listens again on a new port, with the same names.
    @Test func listensAgain() async throws {
        let id = HLSUpstream.add(["/index.m3u8": .body(playlist("none/s0.ts"), "application/vnd.apple.mpegurl")])
        let proxy = HLSProxy(headers: [:])
        let address = try await proxy.start(url: URL(string: "http://hlsproxy.test/\(id)/index.m3u8")!)
        #expect(proxy.serves(address) && !proxy.serves(URL(string: "http://127.0.0.1:1/other/x.m3u8")!))
        let fresh = try await proxy.relisten(address)
        #expect(fresh.lastPathComponent == address.lastPathComponent && fresh.port != address.port && proxy.serves(fresh))
        let (body, response) = try await get(fresh)
        #expect(response.statusCode == 200 && String(decoding: body, as: UTF8.self).contains("#EXTINF"))
        await #expect(throws: (any Error).self) { _ = try await get(address) }
        await proxy.stop()
    }

    /// A segment is passed on as it comes: the picture before it dropped, its length told shortened, a byte range
    /// cut from it when the server sent the whole file.
    @Test func segmentsArePassedOn() async throws {
        let id = HLSUpstream.add([:])
        HLSUpstream.set(id, ["/index.m3u8": .body(playlist("\(id)/s0.ts"), "application/vnd.apple.mpegurl"),
                             "/s0.ts": .body(Self.picture + Self.ts, "image/png")])
        let proxy = HLSProxy(headers: [:])
        let address = try await proxy.start(url: URL(string: "http://hlsproxy.test/\(id)/index.m3u8")!)
        let segment = try segmentAddress(in: try await get(address).0)
        let (whole, response) = try await get(segment)
        #expect(response.statusCode == 200 && whole == Self.ts)
        #expect(response.value(forHTTPHeaderField: "Content-Length") == "\(Self.ts.count)")
        #expect(response.value(forHTTPHeaderField: "Content-Type") == "video/mp2t")
        let (part, partial) = try await get(segment, range: "70000-70999")
        #expect(partial.statusCode == 206 && part == Self.ts[70000..<71000])
        #expect(partial.value(forHTTPHeaderField: "Content-Range") == "bytes 70000-70999/\(Self.ts.count)")
        #expect(await proxy.repairs.contains("image-header"))
        await proxy.stop()
    }

    @Test func streamsAreToldFromText() {
        #expect(HLSProxy.binary(Self.ts) == "mpeg-ts")
        #expect(HLSProxy.binary(Data("FLV".utf8) + Data([1, 5, 0, 0, 0, 9])) == "flv")
        #expect(HLSProxy.binary(Data([0, 0, 0, 0x20]) + Data("ftypisom".utf8)) == "mp4")
        #expect(HLSProxy.binary(Data("#EXTM3U\n#EXT-X-TARGETDURATION:10\n".utf8)) == nil)
        #expect(HLSProxy.binary(Data("<br />\n<b>Notice</b>\n#EXTM3U\n".utf8)) == nil)
        #expect(HLSProxy.startsPlaylist(Data([0xEF, 0xBB, 0xBF]) + Data("#EXTM3U\n".utf8)))
        #expect(!HLSProxy.startsPlaylist(Self.ts))
        #expect(HLSProxy.gatewayStatus(for: URLError(.serverCertificateHasUnknownRoot)) == 495)
        #expect(HLSProxy.gatewayStatus(for: URLError(.secureConnectionFailed)) == 495)
        #expect(HLSProxy.gatewayStatus(for: URLError(.cannotConnectToHost)) == 502)
    }
}

/// A stand-in upstream for `URLSession.shared`, for host `hlsproxy.test` only: `/<id>/<path>` answers from the routes
/// added under `id`.
final class HLSUpstream: URLProtocol, @unchecked Sendable {
    /// `endless` sends its data, then one more MPEG-TS packet every 20 ms until the client stops it: it never ends and
    /// never goes quiet (so no idle timeout fires), and it can't outrun a slow reader into memory.
    enum Reply { case body(Data, String), endless(Data), failure(URLError) }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: [String: Reply]] = [:]
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    nonisolated(unsafe) private static var stops: Set<String> = []
    private static let registered: Void = { URLProtocol.registerClass(HLSUpstream.self) }()
    private let stopped = NSLock()
    nonisolated(unsafe) private var running = true
    nonisolated(unsafe) private var id = ""

    static func add(_ replies: [String: Reply]) -> String {
        _ = registered
        let id = UUID().uuidString
        lock.withLock { routes[id] = replies; counts[id] = 0 }
        return id
    }
    static func set(_ id: String, _ replies: [String: Reply]) { lock.withLock { routes[id] = replies } }
    static func sent(_ id: String) -> Int { lock.withLock { counts[id] ?? 0 } }
    /// Whether a client stopped a transfer of `id` (waiting up to 30 s for URLSession to say so; it does it on its
    /// own queue, after the task was cancelled).
    static func stopped(_ id: String) async -> Bool {
        for _ in 0..<600 {
            if lock.withLock({ stops.contains(id) }) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == "hlsproxy.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let parts = url.path.split(separator: "/", maxSplits: 1)
        let id = parts.first.map(String.init) ?? ""
        stopped.withLock { self.id = id }
        let path = "/" + (parts.count > 1 ? String(parts[1]) : "")
        guard let reply = Self.lock.withLock({ Self.routes[id]?[path] }) else {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self); return
        }
        switch reply {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .body(let data, let mime):
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            Self.lock.withLock { Self.counts[id, default: 0] += data.count }
            client?.urlProtocolDidFinishLoading(self)
        case .endless(let chunk):
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/vnd.apple.mpegurl"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: chunk)
            Self.lock.withLock { Self.counts[id, default: 0] += chunk.count }
            let packet = chunk.prefix(188)
            Thread.detachNewThread { [self] in
                while stopped.withLock({ running }) {
                    usleep(20_000)
                    guard stopped.withLock({ running }) else { break }
                    client?.urlProtocol(self, didLoad: packet)
                    Self.lock.withLock { Self.counts[id, default: 0] += packet.count }
                }
            }
        }
    }
    override func stopLoading() {
        let id = stopped.withLock { running = false; return self.id }
        _ = Self.lock.withLock { Self.stops.insert(id) }
    }
}

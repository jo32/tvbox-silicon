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
    @Test func endlessStreamIsGivenUpOnAtOnce() async throws {
        let id = HLSUpstream.add(["/endless/index.m3u8": .endless(Self.ts)])
        for patience in [HLSProxy.Patience.retry, .opening] {
            let proxy = HLSProxy(headers: [:])
            let started = ContinuousClock.now
            await #expect(throws: HLSProxy.Failure.notPlaylist("mpeg-ts")) {
                _ = try await proxy.start(url: URL(string: "http://hlsproxy.test/\(id)/endless/index.m3u8")!, patience: patience)
            }
            #expect(ContinuousClock.now - started < .seconds(5))
        }
        let sent = HLSUpstream.sent(id)
        try await Task.sleep(for: .milliseconds(300))
        #expect(HLSUpstream.sent(id) == sent && sent < 4 << 20)
    }

    /// The check for spliced-in ads that iPhone and Apple TV make before playing an .m3u8 doesn't hold an endless
    /// stream either: it stops at the first kilobyte, and AVPlayer gets the address as it is.
    @Test func adCheckStopsAtAStream() async throws {
        let id = HLSUpstream.add(["/endless/index.m3u8": .endless(Self.ts)])
        let started = ContinuousClock.now
        #expect(await AdSkip.route(URL(string: "http://hlsproxy.test/\(id)/endless/index.m3u8")!, headers: [:]) == nil)
        #expect(ContinuousClock.now - started < .seconds(5))
        let sent = HLSUpstream.sent(id)
        try await Task.sleep(for: .milliseconds(300))
        #expect(HLSUpstream.sent(id) == sent && sent < 4 << 20)
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
    enum Reply { case body(Data, String), endless(Data), failure(URLError) }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: [String: Reply]] = [:]
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    private static let registered: Void = { URLProtocol.registerClass(HLSUpstream.self) }()
    private let stopped = NSLock()
    nonisolated(unsafe) private var running = true

    static func add(_ replies: [String: Reply]) -> String {
        _ = registered
        let id = UUID().uuidString
        lock.withLock { routes[id] = replies; counts[id] = 0 }
        return id
    }
    static func set(_ id: String, _ replies: [String: Reply]) { lock.withLock { routes[id] = replies } }
    static func sent(_ id: String) -> Int { lock.withLock { counts[id] ?? 0 } }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == "hlsproxy.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let parts = url.path.split(separator: "/", maxSplits: 1)
        let id = parts.first.map(String.init) ?? ""
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
            Thread.detachNewThread { [self] in
                // Never ends by itself; 256 MB at most, so a broken test can't take the machine with it.
                var total = 0
                while stopped.withLock({ running }), total < 256 << 20 {
                    client?.urlProtocol(self, didLoad: chunk)
                    total += chunk.count
                    Self.lock.withLock { Self.counts[id, default: 0] += chunk.count }
                    usleep(2000)
                }
            }
        }
    }
    override func stopLoading() { stopped.withLock { running = false } }
}

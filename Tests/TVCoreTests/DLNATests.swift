import Foundation
import Network
import Testing
@testable import TVCore

// MARK: Finding renderers (#749)

@Test func dlnaSearchAsksForMediaRenderers() {
    let multicast = DLNA.search()
    #expect(multicast.hasPrefix("M-SEARCH * HTTP/1.1\r\n"))
    #expect(multicast.contains("HOST: 239.255.255.250:1900\r\n"))
    #expect(multicast.contains("MAN: \"ssdp:discover\"\r\n"))
    #expect(multicast.contains("MX: 2\r\n"))
    #expect(multicast.contains("ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n"))
    #expect(multicast.hasSuffix("\r\n\r\n"))
    // A unicast search (UPnP 1.1) names the device and takes no MX.
    let unicast = DLNA.search(host: "192.168.1.20")
    #expect(unicast.contains("HOST: 192.168.1.20:1900\r\n"))
    #expect(!unicast.contains("MX:"))
}

@Test func dlnaReadsTheLocationOfASearchAnswer() {
    let answer = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nEXT:\r\nlocation: http://192.168.1.20:49152/description.xml\r\n"
        + "SERVER: Linux UPnP/1.0\r\nST: urn:schemas-upnp-org:device:MediaRenderer:1\r\nUSN: uuid:abc::urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n"
    #expect(DLNA.location(inResponse: answer) == URL(string: "http://192.168.1.20:49152/description.xml"))
    // Another controller's search, and answers without an HTTP location, are ignored.
    #expect(DLNA.location(inResponse: DLNA.search()) == nil)
    #expect(DLNA.location(inResponse: "HTTP/1.1 200 OK\r\nLOCATION: file:///etc/passwd\r\n\r\n") == nil)
    #expect(DLNA.location(inResponse: "HTTP/1.1 404 Not Found\r\nLOCATION: http://1.2.3.4/d.xml\r\n\r\n") == nil)
}

@Test func dlnaReadsARendererDescription() throws {
    // As Xiaomi and Hisense TVs describe themselves: AVTransport in an embedded device, relative control addresses.
    let description = """
    <?xml version="1.0"?>
    <root xmlns="urn:schemas-upnp-org:device-1-0">
      <specVersion><major>1</major><minor>0</minor></specVersion>
      <device>
        <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
        <friendlyName>客厅的小米电视</friendlyName>
        <modelName>MiTV-AXFR0</modelName>
        <UDN>uuid:5f7a-tv</UDN>
        <serviceList>
          <service><serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType><controlURL>/cm/control</controlURL></service>
        </serviceList>
        <deviceList><device>
          <friendlyName>inner</friendlyName><UDN>uuid:inner</UDN>
          <serviceList>
            <service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType><controlURL>_urn:schemas-upnp-org:service:AVTransport_control</controlURL></service>
            <service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType><controlURL>/upnp/control/rendering</controlURL></service>
          </serviceList>
        </device></deviceList>
      </device>
    </root>
    """
    let location = URL(string: "http://192.168.1.20:49152/upnp/description.xml")!
    let device = try #require(DLNA.device(fromDescription: Data(description.utf8), location: location))
    #expect(device.id == "uuid:5f7a-tv")
    #expect(device.name == "客厅的小米电视")
    #expect(device.model == "MiTV-AXFR0")
    #expect(device.avTransport.absoluteString == "http://192.168.1.20:49152/upnp/_urn:schemas-upnp-org:service:AVTransport_control")
    #expect(device.renderingControl?.absoluteString == "http://192.168.1.20:49152/upnp/control/rendering")
}

@Test func dlnaUsesURLBaseAndSkipsDevicesThatCannotPlay() throws {
    let withBase = """
    <root><URLBase>http://10.0.0.5:8080/</URLBase><device><friendlyName>Box</friendlyName><UDN>uuid:box</UDN>
    <serviceList><service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType><controlURL>AVTransport/ctrl</controlURL></service></serviceList>
    </device></root>
    """
    let device = try #require(DLNA.device(fromDescription: Data(withBase.utf8), location: URL(string: "http://10.0.0.5:1400/desc.xml")!))
    #expect(device.avTransport.absoluteString == "http://10.0.0.5:8080/AVTransport/ctrl")
    #expect(device.renderingControl == nil)
    #expect(DLNA.resolve("/MediaRenderer/AVTransport/Control?ch=1", against: URL(string: "http://10.0.0.5:1400/xml/desc.xml")!)?.absoluteString
            == "http://10.0.0.5:1400/MediaRenderer/AVTransport/Control?ch=1")
    #expect(DLNA.resolve("http://10.0.0.6:9000/ctl", against: URL(string: "http://10.0.0.5:1400/desc.xml")!)?.absoluteString == "http://10.0.0.6:9000/ctl")
    // A NAS's media server and a router describe no AVTransport: not something to cast to.
    let server = """
    <root><device><friendlyName>NAS</friendlyName><serviceList>
    <service><serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType><controlURL>/cd</controlURL></service>
    </serviceList></device></root>
    """
    #expect(DLNA.device(fromDescription: Data(server.utf8), location: URL(string: "http://10.0.0.9/d.xml")!) == nil)
}

// MARK: Controlling a renderer

@Test func dlnaBuildsSOAPAndReadsItsAnswers() {
    let body = String(decoding: DLNA.envelope(action: "Seek", service: DLNA.avTransportType,
                                              arguments: [("InstanceID", "0"), ("Unit", "REL_TIME"), ("Target", "0:01:05")]), as: UTF8.self)
    #expect(body.contains("<u:Seek xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\"><InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>0:01:05</Target></u:Seek>"))
    let position = """
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:GetPositionInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
    <Track>1</Track><TrackDuration>00:45:10</TrackDuration><RelTime>0:12:03.500</RelTime></u:GetPositionInfoResponse></s:Body></s:Envelope>
    """
    let values = DLNA.values(in: Data(position.utf8))
    #expect(values["TrackDuration"].flatMap(DLNA.seconds) == 2710)
    #expect(values["RelTime"].flatMap(DLNA.seconds) == 723.5)
    #expect(DLNA.seconds("NOT_IMPLEMENTED") == nil)
    let fault = """
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring>
    <detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>714</errorCode><errorDescription>Illegal MIME-type</errorDescription></UPnPError></detail>
    </s:Fault></s:Body></s:Envelope>
    """
    #expect(DLNA.fault(in: Data(fault.utf8)) == "714 Illegal MIME-type")
}

@Test func dlnaDescribesTheVideoForTheTV() {
    let url = URL(string: "http://192.168.1.5:5000/t/1/index.m3u8?a=1&b=2")!
    let didl = DLNA.didl(title: "庆余年 <第2季> & 特别篇", url: url, mime: DLNA.mime(for: url))
    #expect(didl.contains("<dc:title>庆余年 &lt;第2季&gt; &amp; 特别篇</dc:title>"))
    #expect(didl.contains("protocolInfo=\"http-get:*:application/vnd.apple.mpegurl:*\""))
    #expect(didl.contains(">http://192.168.1.5:5000/t/1/index.m3u8?a=1&amp;b=2</res>"))
    // Sent as CurrentURIMetaData, the DIDL is escaped once more inside the SOAP body.
    let body = String(decoding: DLNA.envelope(action: "SetAVTransportURI", service: DLNA.avTransportType, arguments: [("CurrentURIMetaData", didl)]), as: UTF8.self)
    #expect(body.contains("&lt;DIDL-Lite"))
    #expect(DLNA.mime(for: URL(string: "https://cdn.example/v/1.mp4")!) == "video/mp4")
    #expect(DLNA.mime(for: URL(string: "https://cdn.example/v/1.mkv")!) == "video/x-matroska")
    #expect(DLNA.mime(for: URL(string: "https://cdn.example/play?id=3")!) == "video/mp4")
    #expect(DLNA.clock(3725.9) == "1:02:05")
    #expect(DLNA.clock(-4) == "0:00:00")
}

@Test func dlnaUnicastSearchCoversTheLocalNetwork() {
    let home = DLNA.neighbours(of: "192.168.1.23", netmask: "255.255.255.0")
    #expect(home.count == 254)
    #expect(home.first == "192.168.1.1" && home.last == "192.168.1.254")
    // A large office network is cut to the /24 around this device.
    let office = DLNA.neighbours(of: "10.4.7.9", netmask: "255.255.0.0")
    #expect(office.count == 254 && office.allSatisfy { $0.hasPrefix("10.4.7.") })
    #expect(DLNA.neighbours(of: "10.0.0.1", netmask: "255.255.255.252") == ["10.0.0.1", "10.0.0.2"])
    #expect(DLNA.neighbours(of: "nonsense", netmask: "255.255.255.0").isEmpty)
}

// MARK: Relaying what the TV can't fetch itself

@Test func castRelayRewritesEveryAddressInAPlaylist() {
    let master = """
    #EXTM3U
    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="国语",URI="audio/zh.m3u8"
    #EXT-X-STREAM-INF:BANDWIDTH=4000000,AUDIO="a"
    1080/index.m3u8?sign=x
    #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=90000,URI="iframes.m3u8"
    """
    var registered: [(String, Bool)] = []
    let rewritten = CastRelay.rewrite(master, base: URL(string: "https://cdn.example/show/master.m3u8")!) { url, playlist in
        registered.append((url.absoluteString, playlist)); return "/t/\(registered.count)"
    }
    #expect(registered.map(\.0) == ["https://cdn.example/show/audio/zh.m3u8", "https://cdn.example/show/1080/index.m3u8?sign=x",
                                    "https://cdn.example/show/iframes.m3u8"])
    #expect(registered.allSatisfy { $0.1 })
    #expect(rewritten.contains("URI=\"/t/1\"") && rewritten.contains("\n/t/2\n") && rewritten.contains("URI=\"/t/3\""))
    #expect(rewritten.contains("#EXT-X-STREAM-INF:BANDWIDTH=4000000,AUDIO=\"a\""))

    let media = "#EXTM3U\r\n#EXT-X-KEY:METHOD=AES-128,URI=\"https://keys.example/k?id=1\"\r\n#EXT-X-MAP:URI=\"init.mp4\"\r\n#EXTINF:6.0,\r\nseg0.ts\r\n#EXTINF:6.0,\r\nhttps://other.example/seg1.ts\r\n#EXT-X-ENDLIST"
    registered = []
    let segments = CastRelay.rewrite(media, base: URL(string: "https://cdn.example/show/1080/index.m3u8")!) { url, playlist in
        registered.append((url.absoluteString, playlist)); return "/t/\(registered.count)"
    }
    #expect(registered.map(\.0) == ["https://keys.example/k?id=1", "https://cdn.example/show/1080/init.mp4",
                                    "https://cdn.example/show/1080/seg0.ts", "https://other.example/seg1.ts"])
    #expect(registered.allSatisfy { !$0.1 })
    #expect(segments.components(separatedBy: "\n") == ["#EXTM3U", "#EXT-X-KEY:METHOD=AES-128,URI=\"/t/1\"", "#EXT-X-MAP:URI=\"/t/2\"",
                                                       "#EXTINF:6.0,", "/t/3", "#EXTINF:6.0,", "/t/4", "#EXT-X-ENDLIST"])
}

@Test func castRelayNamesKeepTheExtensionTVsGoBy() {
    #expect(CastRelay.name(for: URL(string: "https://a.example/v/电影 1.mp4?x=1")!, playlist: false) == "1.mp4")
    #expect(CastRelay.name(for: URL(string: "http://127.0.0.1:9978/proxy?do=play")!, playlist: false) == "proxy.mp4")
    #expect(CastRelay.name(for: URL(string: "http://127.0.0.1:9978/proxy?do=m3u8")!, playlist: true) == "index.m3u8")
    #expect(CastRelay.name(for: URL(string: "https://a.example/live/index.m3u8")!, playlist: true) == "index.m3u8")
}

/// The relay end to end, against a server that, like many video hosts, refuses requests without its Referer:
/// ranges pass through, playlists come back rewritten and their segments fetch through the relay too.
@Test func castRelayFetchesWithTheSourcesHeaders() async throws {
    let video = Data((0..<300_000).map { UInt8($0 % 251) })
    let upstream = try await FixtureServer.start { path, headers in
        guard headers["referer"] == "https://site.example/" else { return (403, "text/plain", Data("no referer".utf8)) }
        switch path {
        case "/v/movie.mp4": return (200, "video/mp4", video)
        case "/live/index.m3u8": return (200, "application/vnd.apple.mpegurl", Data("#EXTM3U\n#EXTINF:4,\nseg/0.ts\n#EXT-X-ENDLIST\n".utf8))
        case "/live/seg/0.ts": return (200, "video/mp2t", Data("TS-SEGMENT".utf8))
        default: return (404, "text/plain", Data())
        }
    }
    defer { upstream.stop() }
    let relay = CastRelay()
    let headers = ["Referer": "https://site.example/"]
    let movie = try await relay.address(for: URL(string: "http://127.0.0.1:\(upstream.port)/v/movie.mp4")!, headers: headers, playlist: false, towards: nil)
    #expect(movie.lastPathComponent == "movie.mp4")
    #expect(movie.host() != "127.0.0.1")

    var request = URLRequest(url: movie)
    request.setValue("bytes=1000-1999", forHTTPHeaderField: "Range")
    let (part, response) = try await URLSession.shared.data(for: request)
    let http = try #require(response as? HTTPURLResponse)
    #expect(http.statusCode == 206)
    #expect(http.value(forHTTPHeaderField: "Content-Range") == "bytes 1000-1999/300000")
    #expect(part == video[1000..<2000])
    let (whole, _) = try await URLSession.shared.data(from: movie)
    #expect(whole == video)

    let live = try await relay.address(for: URL(string: "http://127.0.0.1:\(upstream.port)/live/index.m3u8")!, headers: headers, playlist: true, towards: nil)
    let (playlist, _) = try await URLSession.shared.data(from: live)
    let lines = String(decoding: playlist, as: UTF8.self).components(separatedBy: "\n")
    let segment = try #require(lines.first { $0.hasSuffix("/0.ts") })
    #expect(segment.hasPrefix("/"))
    let (bytes, _) = try await URLSession.shared.data(from: try #require(URL(string: segment, relativeTo: live)))
    #expect(bytes == Data("TS-SEGMENT".utf8))

    // Unregistered paths and a wrong token get nothing.
    let other = live.deletingLastPathComponent().deletingLastPathComponent().appending(path: "zz/x.mp4")
    let (_, unknown) = try await URLSession.shared.data(from: other)
    #expect((unknown as? HTTPURLResponse)?.statusCode == 404)
    var forged = URLComponents(url: movie, resolvingAgainstBaseURL: false)!
    forged.path = "/wrongtoken/1/movie.mp4"
    let (_, wrongToken) = try await URLSession.shared.data(from: forged.url!)
    #expect((wrongToken as? HTTPURLResponse)?.statusCode == 404)
}

/// Casting end to end against a renderer on this network (a TV, or `Scripts/dlna-renderer.py "QA TV"`, which logs what a
/// TV would be asked and fetches what it is sent): `DLNA_E2E="QA TV" swift test --filter dlnaCastsToARealRenderer`, with `DLNA_UNICAST=1` to search as an iPhone
/// without the multicast entitlement does. Off in normal runs: it needs the network and a renderer.
@Test(.enabled(if: ProcessInfo.processInfo.environment["DLNA_E2E"] != nil))
func dlnaCastsToARealRenderer() async throws {
    let environment = ProcessInfo.processInfo.environment
    let name = try #require(environment["DLNA_E2E"])
    let video = Data((0..<500_000).map { UInt8($0 % 241) })
    let upstream = try await FixtureServer.start { path, headers in
        guard headers["referer"] == "https://site.example/" else { return (403, "text/plain", Data()) }
        switch path {
        case "/v/movie.mp4": return (200, "video/mp4", video)
        case "/hls/index.m3u8": return (200, "application/vnd.apple.mpegurl", Data("#EXTM3U\n#EXTINF:4,\nseg0.ts\n#EXT-X-ENDLIST\n".utf8))
        case "/hls/seg0.ts": return (200, "video/mp2t", Data(repeating: 0x47, count: 4096))
        default: return (404, "text/plain", Data())
        }
    }
    defer { upstream.stop() }

    let found = await DLNADiscovery.search(seconds: 4, forceUnicast: environment["DLNA_UNICAST"] != nil)
    print("e2e: found \(found.devices.map(\.name)) multicastBlocked=\(found.multicastBlocked)")
    let device = try #require(found.devices.first { $0.name == name })
    let renderer = DLNARenderer(device)
    let relay = CastRelay()
    let headers = ["Referer": "https://site.example/"]
    func tvState() async throws -> [String: Any] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "/state", relativeTo: device.location)!)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    let movie = try await relay.address(for: URL(string: "http://127.0.0.1:\(upstream.port)/v/movie.mp4")!, headers: headers,
                                        playlist: false, towards: device.location.host())
    try await renderer.load(movie, title: "庆余年 · 第5集", mime: DLNA.mime(for: movie))
    try await Task.sleep(for: .seconds(2))
    #expect(try await renderer.state() == "PLAYING")
    let fetched = try await tvState()["fetched"] as? [[String: Any]] ?? []
    print("e2e: tv fetched \(fetched)")
    #expect(fetched.last?["status"] as? Int == 206 && fetched.last?["bytes"] as? Int == 1024)
    try await renderer.seek(to: 125)
    let (position, duration) = try await renderer.position()
    #expect(position >= 125 && position < 130)
    #expect(duration == 600)
    try await renderer.setVolume(42)
    #expect(try await renderer.volume() == 42)
    try await renderer.pause()
    #expect(try await renderer.state() == "PAUSED_PLAYBACK")

    let live = try await relay.address(for: URL(string: "http://127.0.0.1:\(upstream.port)/hls/index.m3u8")!, headers: headers,
                                       playlist: true, towards: device.location.host())
    try await renderer.load(live, title: "直播", mime: DLNA.mime(for: live))
    try await Task.sleep(for: .seconds(2))
    let afterLive = try await tvState()["fetched"] as? [[String: Any]] ?? []
    print("e2e: tv fetched \(afterLive)")
    #expect(afterLive.contains { ($0["uri"] as? String)?.hasSuffix("seg0.ts") == true && $0["status"] as? Int == 206 })
    try await renderer.stop()
    #expect(try await renderer.state() == "STOPPED")
}

/// A one-file HTTP/1.1 server for the relay test: whole responses or byte ranges, one request per connection.
private final class FixtureServer: @unchecked Sendable {
    typealias Handler = @Sendable (String, [String: String]) -> (Int, String, Data)
    let port: UInt16
    private let listener: NWListener

    private init(listener: NWListener, port: UInt16) { self.listener = listener; self.port = port }

    static func start(_ handler: @escaping Handler) async throws -> FixtureServer {
        let listener = try NWListener(using: .tcp)
        let queue = DispatchQueue(label: "fixture.server")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                let head = String(decoding: data ?? Data(), as: UTF8.self).components(separatedBy: "\r\n")
                let path = head.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                var headers: [String: String] = [:]
                for line in head.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                var (status, type, body) = handler(path, headers)
                var extra = ""
                if status == 200, let range = headers["range"], range.hasPrefix("bytes=") {
                    let bounds = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
                    let start = bounds.first.flatMap { $0 } ?? 0, end = min(body.count - 1, (bounds.count > 1 ? bounds[1] : nil) ?? body.count - 1)
                    extra = "Content-Range: bytes \(start)-\(end)/\(body.count)\r\n"
                    body = body.subdata(in: start..<end + 1); status = 206
                }
                let reason = [200: "OK", 206: "Partial Content", 403: "Forbidden", 404: "Not Found"][status] ?? "Error"
                let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nAccept-Ranges: bytes\r\n\(extra)Connection: close\r\n\r\n"
                connection.send(content: Data(header.utf8) + body, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            // Called on the one queue, so the flag needs no lock.
            final class Flag: @unchecked Sendable { var done = false }
            let resumed = Flag()
            listener.stateUpdateHandler = { state in
                guard !resumed.done else { return }
                if case .ready = state, let port = listener.port?.rawValue { resumed.done = true; continuation.resume(returning: port) }
                if case .failed(let error) = state { resumed.done = true; continuation.resume(throwing: error) }
            }
            listener.start(queue: queue)
        }
        return FixtureServer(listener: listener, port: port)
    }

    func stop() { listener.cancel() }
}

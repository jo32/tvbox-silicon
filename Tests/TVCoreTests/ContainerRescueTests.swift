import AVFoundation
import Foundation
import Testing
@testable import TVCore

struct ContainerRescueTests {
    private func head(_ bytes: [UInt8], padTo count: Int = 400) -> Data {
        Data(bytes + [UInt8](repeating: 0x11, count: max(0, count - bytes.count)))
    }

    @Test func sniffingNamesTheContainerFromItsBytes() {
        #expect(MediaSniff.kind(head([0, 0, 0, 0x20] + Array("ftypisom".utf8))) == .mp4)
        #expect(MediaSniff.kind(head([0, 0, 0, 0x14] + Array("ftypqt  ".utf8))) == .quickTime)
        #expect(MediaSniff.kind(head([0, 0, 0x10, 0] + Array("moov".utf8))) == .mp4)
        var ts = [UInt8](repeating: 0xFF, count: 600); ts[0] = 0x47; ts[188] = 0x47; ts[376] = 0x47
        #expect(MediaSniff.kind(Data(ts)) == .transportStream)
        var m2ts = [UInt8](repeating: 0xFF, count: 600); m2ts[4] = 0x47; m2ts[196] = 0x47
        #expect(MediaSniff.kind(Data(m2ts)) == .repackage)
        #expect(MediaSniff.kind(head([0x1A, 0x45, 0xDF, 0xA3])) == .repackage)                       // MKV
        #expect(MediaSniff.kind(head(Array("FLV".utf8) + [1, 5, 0, 0, 0, 9])) == .repackage)
        #expect(MediaSniff.kind(head(Array("RIFF".utf8) + [0, 0, 0, 0] + Array("AVI ".utf8))) == .repackage)
        #expect(MediaSniff.kind(head([0x30, 0x26, 0xB2, 0x75])) == .repackage)                       // ASF
        #expect(MediaSniff.kind(head([0x00, 0x00, 0x01, 0xBA])) == .repackage)                       // MPEG-PS
        #expect(MediaSniff.kind(head(Array("ID3".utf8) + [4, 0])) == .audio("audio/mpeg"))
        #expect(MediaSniff.kind(head([0xFF, 0xF1, 0x50, 0x80])) == .audio("audio/aac"))
        #expect(MediaSniff.kind(head([0x89, 0x50, 0x4E, 0x47])) == .image)
        #expect(MediaSniff.kind(Data("\u{FEFF}  #EXTM3U\n#EXT-X-VERSION:3\n".utf8)) == .hlsPlaylist)
        #expect(MediaSniff.kind(Data("<?xml version=\"1.0\"?>\n<MPD xmlns=\"urn:mpeg:dash:schema:mpd:2011\">".utf8)) == .dashManifest)
        #expect(MediaSniff.kind(Data("\n<!DOCTYPE html><html><head>".utf8)) == .webPage)
        #expect(MediaSniff.kind(Data("<html lang=zh>".utf8)) == .webPage)
        #expect(MediaSniff.kind(Data("{\"code\":403}".utf8)) == .json)
        #expect(MediaSniff.kind(head([0x12, 0x34, 0x56, 0x78])) == .unknown)
        #expect(MediaSniff.Kind.mp4.mimeType == "video/mp4")
        #expect(MediaSniff.Kind.repackage.mimeType == nil)
    }

    @Test func onlyContainerRefusalsAreRescued() {
        func error(_ domain: String, _ code: Int, under: NSError? = nil) -> NSError {
            NSError(domain: domain, code: code, userInfo: under.map { [NSUnderlyingErrorKey: $0] } ?? [:])
        }
        #expect(ContainerRescue.refusedContainer(error("AVFoundationErrorDomain", -11828, under: error(NSOSStatusErrorDomain, -12847))))
        #expect(ContainerRescue.refusedContainer(error("AVFoundationErrorDomain", -11829)))
        #expect(ContainerRescue.refusedContainer(error("AVFoundationErrorDomain", -11800, under: error(NSOSStatusErrorDomain, -12848))))
        #expect(!ContainerRescue.refusedContainer(error("AVFoundationErrorDomain", -11850, under: error("CoreMediaErrorDomain", -12939))))
        #expect(!ContainerRescue.refusedContainer(error(NSURLErrorDomain, -1004)))
        #expect(!ContainerRescue.refusedContainer(nil))
        #expect(ContainerRescue.handles(URL(string: "https://a.test/v")!))
        #expect(ContainerRescue.handles(URL(string: "tvbox-cloud://x/video")!))
        #expect(!ContainerRescue.handles(URL(string: "tvbox-dash://x/master.m3u8")!))
    }

    /// A Bili plugin's proxy manifest: kinds named by ContentComponent, escaped addresses with a backup, SegmentBase.
    static let biliManifest = """
    <?xml version="1.0" encoding="UTF-8"?>
    <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" profiles="urn:mpeg:dash:profile:isoff-on-demand:2011" type="static" mediaPresentationDuration="PT1M30.5S" minBufferTime="PT1.5S">
    <Period duration="PT90.5S" start="PT0S">
    <AdaptationSet>
    <ContentComponent contentType="video" mimeType="video/mp4"/>
    <Representation id="80" bandwidth="1500000" codecs="avc1.640032" mimeType="video/mp4" width="1920" height="1080" frameRate="30000/1001" sar="1:1" startWithSap="1">
    <BaseURL>https://upos.bilivideo.test/v/80.m4s?e=1&amp;deadline=2</BaseURL>
    <BaseURL>https://backup.bilivideo.test/v/80.m4s?e=1&amp;deadline=2</BaseURL>
    <SegmentBase indexRange="930-1200"><Initialization range="0-929"/></SegmentBase>
    </Representation>
    </AdaptationSet>
    <AdaptationSet>
    <ContentComponent contentType="audio" mimeType="audio/mp4"/>
    <Representation id="30280" bandwidth="192000" codecs="mp4a.40.2" mimeType="audio/mp4" numChannels="2" sampleRate="44100">
    <BaseURL>audio/30280.m4s</BaseURL>
    <SegmentBase indexRange="850-1100"><Initialization range="0-849"/></SegmentBase>
    </Representation>
    </AdaptationSet>
    </Period>
    </MPD>
    """

    @Test func aSegmentBaseManifestBecomesTheDashOfAPlayResult() throws {
        let manifest = URL(string: "http://127.0.0.1:9978/proxy?do=bili&aid=1&cid=2")!
        let dash = try #require(DashManifest.dash(Data(Self.biliManifest.utf8), url: manifest))
        let video = try #require(dash["video"]?.array?.first?.object)
        #expect(video["id"]?.double == 80)
        #expect(video["codecs"]?.string == "avc1.640032")
        #expect(video["initialization"]?.string == "0-929" && video["indexRange"]?.string == "930-1200")
        #expect(video["urls"]?.array?.compactMap(\.string) == ["https://upos.bilivideo.test/v/80.m4s?e=1&deadline=2",
                                                              "https://backup.bilivideo.test/v/80.m4s?e=1&deadline=2"])
        let audio = try #require(dash["audio"]?.array?.first?.object)
        #expect(audio["urls"]?.array?.compactMap(\.string) == ["http://127.0.0.1:9978/audio/30280.m4s"])
        #expect(dash["duration"]?.string == "90.5")
        // DashStreams reads them as it reads a play result's.
        let representation = try #require(Representation(video))
        #expect(representation.quality == 80 && representation.height == 1080 && representation.frameRate.map { abs($0 - 29.97) < 0.01 } == true)
        #expect(Representation(audio) != nil)
        // Templated or listed segments are not read here.
        let templated = "<MPD><Period><AdaptationSet mimeType=\"video/mp4\"><Representation id=\"1\" codecs=\"avc1.64001f\" bandwidth=\"1\"><SegmentTemplate media=\"$Number$.m4s\"/></Representation></AdaptationSet></Period></MPD>"
        #expect(DashManifest.dash(Data(templated.utf8), url: manifest) == nil)
        #expect(DashManifest.seconds("PT1H2M3.5S") == 3723.5)
        #expect(DashManifest.seconds("P1DT1S") == 86401)
        #expect(DashManifest.seconds("garbage") == nil)
    }

    @Test func backoffDoublesUpToItsCeilingAndStops() {
        var backoff = Backoff(base: 0.5, ceiling: 3, attempts: 4)
        #expect(backoff.upcoming == 0.5)
        #expect([backoff.next(), backoff.next(), backoff.next(), backoff.next(), backoff.next()] == [0.5, 1, 2, 3, nil])
        backoff.reset()
        #expect(backoff.next() == 0.5)
    }

    @Test func aRunOfFailuresIsReportedOnceAndHeldOff() {
        var streak = FailureStreak(threshold: 3, base: 1, ceiling: 4)
        let runs = (1...12).map { _ in streak.fail() }
        #expect(runs.map(\.report) == [true, false, false, false, false, false, false, false, false, true, false, false])
        #expect(runs.map(\.wait) == [0, 0, 1, 2, 4, 4, 4, 4, 4, 4, 4, 4])
        #expect(streak.succeed() == 12)
        #expect(streak.fail().wait == 0)
        #expect(streak.succeed() == nil)
    }

    @Test func transientErrorsAreToldFromRefusedLinks() {
        #expect(TransientRetry.isTransient(URLError(.networkConnectionLost)))
        #expect(TransientRetry.isTransient(URLError(.timedOut)))
        #expect(TransientRetry.isTransient(URLError(.cannotConnectToHost)))
        #expect(TransientRetry.isTransient(TVError.http(502)))
        #expect(TransientRetry.isTransient(NSError(domain: "x", code: 1, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: -1001)])))
        #expect(!TransientRetry.isTransient(TVError.http(403)))
        #expect(!TransientRetry.isTransient(URLError(.cancelled)))
        #expect(!TransientRetry.isTransient(TVError.unsupported("x")))
        #expect(TransientRetry.isExpired(TVError.http(403)) && TransientRetry.isExpired(TVError.http(410)))
        #expect(!TransientRetry.isExpired(TVError.http(502)))
        #expect(TransientRetry.isCancellation(CancellationError()) && TransientRetry.isCancellation(URLError(.cancelled)))
        #expect(CloudByteStream.refreshWait(failures: 0) == 10)
        #expect([1, 2, 3, 6, 9].map { CloudByteStream.refreshWait(failures: $0) } == [10, 20, 40, 300, 300])
    }
}

/// Links that expire, servers that answer 502 now and then, and pages, for the rescue and the stream readers.
/// https://flaky.test/<token>/<name>: a token answers `budget` requests, then 403; `/bad/<name>` answers 502 to
/// its first `gateway` requests.
final class FlakyServer: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var files: [String: (data: Data, type: String)] = [:]
    nonisolated(unsafe) private static var budgets: [String: Int] = [:]
    nonisolated(unsafe) private static var gateways: [String: Int] = [:]
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FlakyServer.self]
        return URLSession(configuration: configuration)
    }()
    static func add(_ name: String, _ data: Data, type: String = "application/octet-stream") { lock.withLock { files[name] = (data, type) } }
    /// A fresh link to `name` that answers `budget` requests.
    static func link(_ name: String, budget: Int) -> URL {
        let token = UUID().uuidString.prefix(8)
        lock.withLock { budgets[String(token)] = budget }
        return URL(string: "https://flaky.test/\(token)/\(name)")!
    }
    static func gateway(_ name: String, failures: Int) -> URL {
        lock.withLock { gateways[name] = failures }
        return URL(string: "https://flaky.test/bad/\(name)")!
    }
    static func requests(_ key: String) -> Int { lock.withLock { counts[key, default: 0] } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == "flaky.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let client else { return }
        let parts = url.path().split(separator: "/").map(String.init)
        guard parts.count == 2 else { return finish(url, 404, [:], Data()) }
        let (token, name) = (parts[0], parts[1])
        let (file, status): ((data: Data, type: String)?, Int) = Self.lock.withLock {
            Self.counts[token, default: 0] += 1; Self.counts[name, default: 0] += 1
            if token == "bad", Self.gateways[name, default: 0] > 0 { Self.gateways[name]! -= 1; return (nil, 502) }
            if token != "bad" {
                guard let left = Self.budgets[token], left > 0 else { return (nil, 403) }
                Self.budgets[token] = left - 1
            }
            return (Self.files[name], Self.files[name] == nil ? 404 : 200)
        }
        guard let file else { return finish(url, status, [:], Data("refused".utf8)) }
        var range = 0..<file.data.count, code = 200
        var headers = ["Content-Type": file.type]
        if let header = request.value(forHTTPHeaderField: "Range"), let match = header.firstMatch(of: /^bytes=(\d+)-(\d*)$/),
           let first = Int(match.1), first < file.data.count {
            range = first..<min(file.data.count, (Int(match.2) ?? file.data.count - 1) + 1); code = 206
            headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(file.data.count)"
        }
        headers["Content-Length"] = "\(range.count)"
        _ = client
        finish(url, code, headers, file.data.subdata(in: range))
    }
    private func finish(_ url: URL, _ status: Int, _ headers: [String: String], _ body: Data) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct StreamRecoveryTests {
    init() { CloudByteStream.retryBase = 0.01; StreamingRemuxSource.retryBase = 0.01; ContainerRescue.retryBase = 0.01 }

    private func file(_ size: Int) -> Data {
        var bytes = Data(count: size)
        bytes.withUnsafeMutableBytes { raw in for i in 0..<size { raw[i] = UInt8(truncatingIfNeeded: i &* 7 &+ i >> 11) } }
        return bytes
    }

    /// A plugin's proxy answers the expired link it kept: that is no refresh, and the episode resolved again
    /// (`renewal`) gives the fresh one. Reading goes on where it was.
    @Test func anExpiredLinkIsRenewedThroughTheSourceWhenTheRefreshGivesTheSameOne() async throws {
        let size = CloudByteStream.chunkSize * 4
        let bytes = file(size)
        FlakyServer.add("renew.mkv", bytes)
        let first = FlakyServer.link("renew.mkv", budget: 2)
        let source = CloudStreams.Source(url: first, headers: [:], length: size, name: "renew.mkv")
        let refreshes = Counter(), renewals = Counter()
        let stream = CloudByteStream(source: source, session: FlakyServer.session, parallel: 1, rewritesSampleEntries: false,
                                     refresh: { refreshes.add(); return source },
                                     renewal: { renewals.add(); return CloudStreams.Source(url: FlakyServer.link("renew.mkv", budget: 100), headers: [:], length: size, name: "renew.mkv") })
        var copy = Data(), at = 0
        while at < size {
            let part = try await stream.read(at: at, count: size - at)
            copy.append(part); at += part.count
        }
        #expect(copy == bytes)
        #expect(refreshes.value == 1 && renewals.value == 1)
        await stream.clear()
    }

    /// A link that can't be renewed fails, and the next refused chunk doesn't ask again at once.
    @Test func aFailedRefreshIsNotRepeatedForEveryChunk() async throws {
        let size = CloudByteStream.chunkSize * 3
        FlakyServer.add("dead.mp4", file(size))
        let dead = FlakyServer.link("dead.mp4", budget: 0)
        let refreshes = Counter()
        let stream = CloudByteStream(source: .init(url: dead, headers: [:], length: size, name: "dead.mp4"), session: FlakyServer.session,
                                     parallel: 1, rewritesSampleEntries: false, refresh: { refreshes.add(); return nil })
        for offset in [0, CloudByteStream.chunkSize, CloudByteStream.chunkSize * 2] {
            await #expect(throws: TVError.self) { _ = try await stream.read(at: offset, count: 16) }
        }
        #expect(refreshes.value == 1)
        await stream.clear()
    }

    /// A gateway's 502s are tried again a little later instead of failing the read.
    @Test func aPassingGatewayErrorIsTriedAgain() async throws {
        let size = CloudByteStream.chunkSize + 100
        let bytes = file(size)
        FlakyServer.add("gateway.mp4", bytes)
        let url = FlakyServer.gateway("gateway.mp4", failures: 2)
        let stream = CloudByteStream(source: .init(url: url, headers: [:], length: size, name: "gateway.mp4"), session: FlakyServer.session,
                                     parallel: 1, rewritesSampleEntries: false, refresh: { nil })
        let part = try await stream.read(at: 10, count: 64)
        #expect(part == bytes[10..<74])
        await stream.clear()
    }

    /// What a refused link turns out to be decides how it plays.
    @Test func theRescuePlanFollowsTheBytes() async throws {
        var mp4 = Data([0, 0, 0, 0x20] + Array("ftypisom".utf8)); mp4.append(file(5000))
        FlakyServer.add("plain", mp4)
        FlakyServer.add("page", Data("<!DOCTYPE html><html><body>episode</body></html>".utf8), type: "text/html")
        let plainLink = FlakyServer.link("plain", budget: 10), pageLink = FlakyServer.link("page", budget: 10)
        guard case .mimeType(let type) = await ContainerRescue.plan(for: plainLink, headers: [:], hinted: false, renewal: nil, session: FlakyServer.session) else {
            Issue.record("an MP4 is told to AVPlayer"); return
        }
        #expect(type == "video/mp4")
        guard case .webPage = await ContainerRescue.plan(for: pageLink, headers: [:], hinted: false, renewal: nil, session: FlakyServer.session) else {
            Issue.record("a page is a page"); return
        }
        // A gateway's passing 502 is asked again.
        guard case .mimeType = await ContainerRescue.plan(for: FlakyServer.gateway("plain", failures: 2), headers: [:], hinted: false, renewal: nil, session: FlakyServer.session) else {
            Issue.record("a passing 502 is tried again"); return
        }
        guard case .nothing = await ContainerRescue.plan(for: FlakyServer.link("plain", budget: 0), headers: [:], hinted: false, renewal: nil, session: FlakyServer.session) else {
            Issue.record("a refused link is left to the player's own handling"); return
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}

import Foundation
import Testing
@testable import TVCore

struct HongguoTests {
    @Test(arguments: [false, true]) func cencDecryptionPreservesOffsetsAndClearSubsamples(subsamples: Bool) throws {
        let fixture = makeMovie(subsamples: subsamples)
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: file) }
        try fixture.encrypted.write(to: file)
        try HongguoMP4.decrypt(file: file, key: hex("2b7e151628aed2a6abf7158809cf4f3c"))
        let clear = try Data(contentsOf: file)
        #expect(clear.count == fixture.encrypted.count)
        #expect(clear.suffix(fixture.plain.count) == fixture.plain)
        #expect(clear.range(of: Data("encv".utf8)) == nil)
        #expect(clear.range(of: Data("senc".utf8)) == nil)
        #expect(clear.range(of: Data("avc1".utf8)) != nil)
    }

    @Test func malformedMediaFailsWithoutReturningAPartialMovie() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: file) }
        let data = makeMovie(subsamples: false).encrypted.dropLast()
        try data.write(to: file)
        #expect(throws: HongguoMP4.Failure.self) { try HongguoMP4.decrypt(file: file, key: Data(count: 16)) }
        #expect(throws: HongguoMP4.Failure.self) { try HongguoMP4.boxes(Data([0, 0, 0, 1, 109, 111, 111, 118]), 0..<8) }
    }

    @Test(arguments: [false, true]) func streamingDecryptsOnlyRequestedRangesAndSupportsTailMetadata(movieAtEnd: Bool) async throws {
        let fixture = makeMovie(subsamples: true, sampleCount: 180, prefixSize: 32000, movieAtEnd: movieAtEnd)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "fixture.mp4")
        try fixture.encrypted.write(to: file)
        let server = LocalMediaServer()
        let url = try await server.address(of: file, root: root)
        let stream = HongguoByteStream(urls: [url], key: hex("2b7e151628aed2a6abf7158809cf4f3c"), headers: [:], http: HTTPClient())
        let index = try await stream.metadata()
        #expect(index.duration == 180)
        #expect(index.samples.count == 180)
        let metadataStats = await stream.statistics
        #expect(metadataStats.received < fixture.encrypted.count / 20)
        // A request starts inside encrypted bytes, rather than at a sample or AES block boundary.
        let sample = index.samples[2]
        let start = sample.bytes.lowerBound + 32003
        let partial = try await stream.read(at: start, count: 13)
        #expect(partial == fixture.plain[32003..<32016])
        let beforeRepeat = await stream.statistics
        #expect(try await stream.read(at: start, count: 13) == partial)
        #expect(await stream.statistics.requests == beforeRepeat.requests)
        // A far seek fetches that sample, without downloading the intervening 147 seconds.
        let destination = index.samples[150].bytes.lowerBound + 32004
        try await stream.beginRequest(at: destination)
        #expect(try await stream.read(at: destination, count: 17) == fixture.plain[32004..<32021])
        let afterSeek = await stream.statistics
        #expect(afterSeek.received < fixture.encrypted.count / 10)
        #expect(afterSeek.cached <= HongguoByteStream.cacheLimit)
        await stream.clear()
        #expect(await stream.statistics.cached == 0)
    }

    @Test func sequentialReadsDoNotFetchTheSameBytesTwice() async throws {
        // Samples of about 60 KB: a 128 KB read widens to whole samples, past where the next read starts.
        let fixture = makeMovie(subsamples: true, sampleCount: 40, prefixSize: 60_000)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "fixture.mp4")
        try fixture.encrypted.write(to: file)
        let server = LocalMediaServer()
        let url = try await server.address(of: file, root: root)
        let stream = HongguoByteStream(urls: [url], key: hex("2b7e151628aed2a6abf7158809cf4f3c"), headers: [:], http: HTTPClient())
        let index = try await stream.metadata()
        let before = await stream.statistics
        let start = index.samples[0].bytes.lowerBound, end = index.samples[30].bytes.upperBound
        var at = start, played = Data()
        while at < end {
            let bytes = try await stream.read(at: at, count: end - at)
            played.append(bytes); at += bytes.count
        }
        #expect(played == Data(repeating: fixture.plain, count: 31))
        #expect(await stream.statistics.received - before.received == end - start)
    }

    @Test func forwardWindowStopsReadingAndCancellationDoesNotFetchTheRest() async throws {
        let fixture = makeMovie(subsamples: true, sampleCount: 180, prefixSize: 32000)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "fixture.mp4")
        try fixture.encrypted.write(to: file)
        let server = LocalMediaServer()
        let url = try await server.address(of: file, root: root)
        let stream = HongguoByteStream(urls: [url], key: hex("2b7e151628aed2a6abf7158809cf4f3c"), headers: [:], http: HTTPClient())
        let index = try await stream.metadata()
        let before = await stream.statistics
        let future = Task { try await stream.read(at: index.samples[90].bytes.lowerBound, count: 100) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await stream.statistics.requests == before.requests)
        future.cancel()
        await #expect(throws: CancellationError.self) { try await future.value }
        await stream.updatePosition(90)
        #expect(try await stream.read(at: index.samples[90].bytes.lowerBound, count: 100) == fixture.plain.prefix(100))
        #expect(await stream.statistics.received < fixture.encrypted.count / 10)
    }

    @Test(arguments: ["ignored", "wrong", "short"]) func streamingRejectsUnusableRangeResponses(response: String) async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HongguoRangeProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let reader = HongguoRangeReader(urls: [URL(string: "https://fixture.example/\(response)")!], headers: [:], http: HTTPClient(session: session))
        await #expect(throws: (any Error).self) { try await reader.read(0..<32) }
    }

    @Test(arguments: ["referer-required", "referer-forbidden", "always-forbidden"])
    func streamingKeepsAppHeadersAndBoundsRefererRetry(policy: String) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HongguoRangeProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://fixture.example/\(policy)?test=\(UUID())")!
        let reader = HongguoRangeReader(urls: [url], headers: ["User-Agent": "com.phoenix.read/test"], http: HTTPClient(session: session))
        if policy == "always-forbidden" {
            await #expect(throws: (any Error).self) { try await reader.read(0..<32) }
        } else {
            #expect(try await reader.read(0..<32).data.count == 32)
            #expect(try await reader.read(32..<64).data.count == 32)
        }
        let requests = HongguoRangeProtocol.requests(for: url)
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent") == "com.phoenix.read/test" })
        #expect(requests.first?.value(forHTTPHeaderField: "Referer") == nil)
        let ranges = requests.map { $0.value(forHTTPHeaderField: "Range") ?? "" }
        if policy == "referer-forbidden" {
            #expect(ranges == ["bytes=0-31", "bytes=32-63"])
            #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Referer") == nil })
        } else {
            #expect(ranges == (policy == "always-forbidden" ? ["bytes=0-31", "bytes=0-31"] : ["bytes=0-31", "bytes=0-31", "bytes=32-63"]))
            #expect(requests.dropFirst().allSatisfy { $0.value(forHTTPHeaderField: "Referer") == HongguoStreams.mediaReferer })
        }
    }

    @Test func streamingMovesToTheBackupNodeWhenOneFails() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HongguoRangeProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let failing = URL(string: "https://fixture.example/always-forbidden?test=\(UUID())")!
        let backup = URL(string: "https://fixture.example/backup?test=\(UUID())")!
        let reader = HongguoRangeReader(urls: [failing, backup], headers: [:], http: HTTPClient(session: session))
        #expect(try await reader.read(0..<32).data.count == 32)
        #expect(try await reader.read(32..<64).data.count == 32)
        // The failed node had its Referer retry and is not asked again for later ranges.
        #expect(HongguoRangeProtocol.requests(for: failing).count == 2)
        let requests = HongguoRangeProtocol.requests(for: backup)
        #expect(requests.map { $0.value(forHTTPHeaderField: "Range") } == ["bytes=0-31", "bytes=32-63"])
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Referer") == nil })
    }

    @Test func scriptRequestsRaceAStalledOrFailedConnection() {
        final class Tries: @unchecked Sendable { let lock = NSLock(); var started = 0; var cancelled = 0 }
        // The first try stalls: the second starts after the hedge and wins; both are then cancelled.
        let stalled = Tries()
        var start = Date()
        var result = ScriptHTTP.race(racers: 3, hedge: 0.2) { finish in
            let attempt = stalled.lock.withLock { stalled.started += 1; return stalled.started }
            if attempt == 2 { DispatchQueue.global().async { finish(raceReply(200)) } }
            return { stalled.lock.withLock { stalled.cancelled += 1 } }
        }
        #expect((result.1 as? HTTPURLResponse)?.statusCode == 200)
        // On a loaded machine the winner's reply can take longer than the hedge, which starts a third try.
        #expect((2...3).contains(stalled.started) && stalled.cancelled == stalled.started)
        #expect(Date().timeIntervalSince(start) < 1.5)
        // A failure starts the next try at once, without waiting for the hedge; a 4xx answer is final.
        let failing = Tries()
        start = Date()
        result = ScriptHTTP.race(racers: 4, hedge: 10) { finish in
            let attempt = failing.lock.withLock { failing.started += 1; return failing.started }
            DispatchQueue.global().async { finish(attempt == 1 ? (nil, nil, URLError(.timedOut)) : raceReply(attempt == 2 ? 502 : 404)) }
            return {}
        }
        #expect((result.1 as? HTTPURLResponse)?.statusCode == 404)
        #expect(failing.started == 3)
        #expect(Date().timeIntervalSince(start) < 1.5)
        // When nothing wins, every try is used and the last failure comes back.
        let losing = Tries()
        result = ScriptHTTP.race(racers: 2, hedge: 10) { finish in
            losing.lock.withLock { losing.started += 1 }
            DispatchQueue.global().async { finish(raceReply(503)) }
            return {}
        }
        #expect((result.1 as? HTTPURLResponse)?.statusCode == 503)
        #expect(losing.started == 2)
    }

    private func hex(_ value: String) -> Data {
        Data(stride(from: 0, to: value.count, by: 2).map { offset in
            let start = value.index(value.startIndex, offsetBy: offset)
            return UInt8(value[start..<value.index(start, offsetBy: 2)], radix: 16)!
        })
    }
    private func makeMovie(subsamples: Bool, sampleCount: Int = 1, prefixSize: Int = 5, movieAtEnd: Bool = false) -> (encrypted: Data, plain: Data) {
        func u32(_ values: Int...) -> Data { Data(values.flatMap { value in [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) } }) }
        func box(_ type: String, _ data: Data) -> Data { u32(data.count + 8) + Data(type.utf8) + data }
        // NIST SP 800-38A AES-128-CTR vector; clear bytes must not consume the keystream.
        let clear1 = hex("6bc1bee22e409f96e93d7e117393172a"), clear2 = hex("ae2d8a571e03ac9c9eb76fac45af8e51")
        let cipher1 = hex("874d6191b620e3261bef6864990db6ce"), cipher2 = hex("9806f66b7970fdff8617187bb9fffdff")
        let prefix = subsamples ? Data(repeating: 0x41, count: prefixSize) : Data(), middle = subsamples ? Data(repeating: 0x42, count: 7) : Data()
        let plain = prefix + clear1 + middle + clear2, encrypted = prefix + cipher1 + middle + cipher2
        let tenc = box("tenc", u32(0) + Data([0, 0, 1, 16]) + Data(count: 16))
        let sinf = box("sinf", box("frma", Data("avc1".utf8)) + box("schm", u32(0) + Data("cenc".utf8) + u32(0x10000)) + box("schi", tenc))
        let stsd = box("stsd", u32(0, 1) + box("encv", Data(count: 78) + sinf))
        let subs = subsamples ? Data([0, 2, UInt8(prefixSize >> 8), UInt8(truncatingIfNeeded: prefixSize)]) + u32(16) + Data([0, 7]) + u32(16) : Data()
        let encryption = hex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff") + subs
        let senc = box("senc", u32(subsamples ? 2 : 0, sampleCount) + Data(repeating: encryption, count: sampleCount))
        func movie(_ offset: Int) -> Data {
            let table = stsd + box("stsz", u32(0, encrypted.count, sampleCount)) + box("stsc", u32(0, 1, 1, sampleCount, 1))
                + box("stco", u32(0, 1, offset)) + box("stts", u32(0, 1, sampleCount, 1000)) + senc
            return box("moov", box("trak", box("mdia", box("mdhd", u32(0, 0, 0, 1000, sampleCount * 1000, 0)) + box("minf", box("stbl", table)))))
        }
        let moov = movie(movieAtEnd ? 8 : movie(0).count + 8), mdat = box("mdat", Data(repeating: encrypted, count: sampleCount))
        return (movieAtEnd ? mdat + moov : moov + mdat, plain)
    }
}

private func raceReply(_ status: Int) -> ScriptHTTP.Reply {
    (Data(), HTTPURLResponse(url: URL(string: "https://fixture.example/")!, statusCode: status, httpVersion: nil, headerFields: nil), nil)
}

private extension Data {
    init(repeating pattern: Data, count: Int) {
        self.init()
        reserveCapacity(pattern.count * count)
        for _ in 0..<count { append(pattern) }
    }
}

private final class HongguoRangeProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var observed: [URLRequest] = []
    static func requests(for url: URL) -> [URLRequest] { lock.withLock { observed.filter { $0.url == url } } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.observed.append(request) }
        let mode = request.url!.lastPathComponent
        let hasReferer = request.value(forHTTPHeaderField: "Referer") == HongguoStreams.mediaReferer
        let forbidden = mode == "always-forbidden" || (mode == "referer-required" && !hasReferer) || (mode == "referer-forbidden" && hasReferer)
        let range = request.value(forHTTPHeaderField: "Range")?.replacingOccurrences(of: "bytes=", with: "bytes ") ?? "bytes 0-31"
        let response = HTTPURLResponse(url: request.url!, statusCode: forbidden ? 403 : mode == "ignored" ? 200 : 206, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Range": mode == "wrong" ? "bytes 1-32/100" : range + "/100"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(count: mode == "short" ? 10 : 32))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

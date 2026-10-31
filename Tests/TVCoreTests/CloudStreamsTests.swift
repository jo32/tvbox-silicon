import AVFoundation
import Foundation
import Testing
@testable import TVCore

struct CloudStreamsTests {
    /// A file the size of a few chunks whose bytes encode their own offset, behind a Range server.
    private func served(_ name: String, size: Int) async throws -> (url: URL, bytes: Data) {
        var bytes = Data(count: size)
        bytes.withUnsafeMutableBytes { raw in for i in 0..<size { raw[i] = UInt8(truncatingIfNeeded: i &* 31 &+ i >> 9) } }
        bytes.replaceSubrange(0..<12, with: Data([0, 0, 0, 0x20, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D]))
        return (RangeServer.add(name, bytes), bytes)
    }

    @Test func hevcThatPlaysOnlyItsSoundIsRetagged() {
        func entry(_ tag: String, size: UInt32 = 120, reference: UInt8 = 1) -> Data {
            Data([UInt8(size >> 24), UInt8(size >> 16 & 0xff), UInt8(size >> 8 & 0xff), UInt8(size & 0xff)])
                + Data(tag.utf8) + Data(repeating: 0, count: 6) + Data([0, reference]) + Data(repeating: 7, count: 20)
        }
        let header = Data([0, 0, 0, 0x7a]) + Data("stsd".utf8) + Data([0, 0, 0, 0, 0, 0, 0, 1])
        #expect(CloudStreams.playableSampleEntries(header + entry("hev1")) == header + entry("hvc1"))
        #expect(CloudStreams.playableSampleEntries(entry("dvhe")) == entry("dvh1"))
        // Bytes that merely contain the letters stay as they are.
        for other in [entry("hev1", size: 40), entry("hev1", reference: 2), Data("hev1 in some text".utf8), entry("avc1"), Data("hev1".utf8)] {
            #expect(CloudStreams.playableSampleEntries(other) == other)
        }
        // A slice keeps its own indices.
        let slice = (Data(repeating: 9, count: 5) + entry("hev1")).dropFirst(5)
        #expect(CloudStreams.playableSampleEntries(slice) == entry("hvc1"))
    }

    @Test func containerComesFromTheBytesNotTheName() throws {
        let mp4 = Data([0, 0, 0, 0x20, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D])
        #expect(try CloudStreams.contentType(mp4, name: "4KXIN 192.mp3") == AVFileType.mp4.rawValue)
        let quickTime = Data([0, 0, 0, 0x14, 0x66, 0x74, 0x79, 0x70, 0x71, 0x74, 0x20, 0x20])
        #expect(try CloudStreams.contentType(quickTime, name: "a.mp4") == AVFileType.mov.rawValue)
        #expect(throws: TVError.self) { try CloudStreams.contentType(Data([0x1A, 0x45, 0xDF, 0xA3, 0, 0, 0, 0]), name: "a.mp4") }
        #expect(try CloudStreams.contentType(Data(repeating: 0x47, count: 16), name: "a.bin") == "public.mpeg-2-transport-stream")
        #expect(try CloudStreams.contentType(Data(repeating: 1, count: 16), name: "a.mov") == AVFileType.mov.rawValue)
    }

    @Test func readsEveryByteAcrossChunksAndSeeks() async throws {
        let size = CloudByteStream.chunkSize * 5 + 12345
        let (url, bytes) = try await served("192.mp3", size: size)
        let stream = CloudByteStream(source: .init(url: url, headers: ["X-Test": "1"], length: size, name: "192.mp3"), session: RangeServer.session) { nil }
        #expect(try await stream.contentType() == AVFileType.mp4.rawValue)
        // Sequential reads, as AVPlayer delivers a to-the-end request chunk by chunk.
        var at = 0, copy = Data()
        while at < size {
            let part = try await stream.read(at: at, count: size - at)
            #expect(!part.isEmpty && part.count <= CloudByteStream.chunkSize)
            copy.append(part); at += part.count
        }
        #expect(copy == bytes)
        #expect(stream.counter.value >= Int64(size))
        // Seeks back and forth, including a read that starts just before a chunk boundary.
        for offset in [size - 7, 3, CloudByteStream.chunkSize - 2, CloudByteStream.chunkSize * 3 + 99] {
            let part = try await stream.read(at: offset, count: 64)
            #expect(part == bytes[offset..<min(size, offset + 64, (offset / CloudByteStream.chunkSize + 1) * CloudByteStream.chunkSize)])
        }
        await stream.clear()
    }

    /// A bundle's proxy downloads each request with its own threads, so its stream reads ahead on one connection.
    @Test func aSingleConnectionStreamReadsAheadOneChunk() async throws {
        let size = CloudByteStream.chunkSize * 10
        let (url, _) = try await served("single.mp4", size: size)
        let stream = CloudByteStream(source: .init(url: url, headers: [:], length: size, name: "single.mp4"), session: RangeServer.session, parallel: 1) { nil }
        _ = try await stream.read(at: 0, count: 64)
        try await Task.sleep(for: .milliseconds(300))
        #expect(RangeServer.requests("single.mp4") == 2)
        await stream.clear()
    }

    /// A file whose audio sits far from its video is read in two places at once. Neither reader
    /// may cancel the other's chunks (the sound dropped out on Apple TV when they did).
    @Test func twoDistantReadersBothFinish() async throws {
        let chunk = CloudByteStream.chunkSize
        let size = chunk * 30
        let (url, bytes) = try await served("interleaved.mp4", size: size)
        let stream = CloudByteStream(source: .init(url: url, headers: [:], length: size, name: "interleaved.mp4"), session: RangeServer.session) { nil }
        func sequential(from start: Int, chunks: Int) async throws -> Data {
            var at = start, copy = Data()
            while at < start + chunks * chunk { let part = try await stream.read(at: at, count: start + chunks * chunk - at); copy.append(part); at += part.count }
            return copy
        }
        async let video = sequential(from: 0, chunks: 12)
        async let audio = sequential(from: chunk * 18, chunks: 12)
        #expect(try await video == bytes[0..<chunk * 12])
        #expect(try await audio == bytes[chunk * 18..<chunk * 30])
        await stream.clear()
    }

    /// AVPlayer opens and plays a real movie through the resource loader. Set TVBOX_CLOUD_MEDIA to
    /// an MP4 (for example one whose moov comes after a large mdat, as on cloud drives).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TVBOX_CLOUD_MEDIA"] != nil))
    func avPlayerPlaysThroughTheLoader() async throws {
        let media = try Data(contentsOf: URL(fileURLWithPath: ProcessInfo.processInfo.environment["TVBOX_CLOUD_MEDIA"]!))
        let size = media.count
        let served = RangeServer.add("movie-\(UUID().uuidString).mp3", media)
        for round in 1...3 {
            let url = CloudStreams.register(.init(url: served, headers: [:], length: size, name: "movie.mp3"), session: RangeServer.session) { nil }
            let asset = try #require(CloudStreams.asset(for: url))
            let (duration, tracks) = try await asset.load(.duration, .tracks)
            #expect(duration.seconds > 5, "round \(round)")
            #expect(tracks.contains { $0.mediaType == .video } && tracks.contains { $0.mediaType == .audio }, "round \(round)")
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            player.play()
            var waited = 0
            while player.currentTime().seconds < 4, item.status != .failed, waited < 200 { try await Task.sleep(for: .milliseconds(100)); waited += 1 }
            #expect(item.status != .failed, "round \(round): \(String(describing: item.error))")
            #expect(player.currentTime().seconds >= 4, "round \(round): stuck at \(player.currentTime().seconds)")
            // A seek near the end, then back to the start, as a viewer would.
            await player.seek(to: CMTime(seconds: duration.seconds - 6, preferredTimescale: 600))
            await player.seek(to: CMTime(seconds: 1, preferredTimescale: 600))
            #expect(item.status != .failed, "round \(round) after seeks: \(String(describing: item.error))")
            player.pause()
            CloudStreams.stop(url)
        }
    }

    /// Reports from 2026-10: a drive answered a range 2.5 GB into an episode with 206 and no bytes, which stopped it.
    @Test func aRangeAnsweredWithNoBytesIsAskedAgain() async throws {
        let size = CloudByteStream.chunkSize * 2 + 77
        var bytes = Data(count: size)
        bytes.withUnsafeMutableBytes { raw in for i in 0..<size { raw[i] = UInt8(truncatingIfNeeded: i &* 7 &+ i >> 11) } }
        let name = "empty-\(UUID().uuidString).mkv"
        let url = RangeServer.add(name, bytes, empty: 2)
        let stream = CloudByteStream(source: .init(url: url, headers: [:], length: size, name: name), session: RangeServer.session, parallel: 1) { nil }
        // The last chunk, so nothing is read ahead.
        #expect(try await stream.read(at: size - 16, count: 16) == bytes.suffix(16))
        #expect(RangeServer.requests(name) == 3)
        await stream.clear()
    }

    @Test func aDriveThatSendsPartOfARangeIsAskedForTheRest() async throws {
        let size = CloudByteStream.chunkSize + 999
        var bytes = Data(count: size)
        bytes.withUnsafeMutableBytes { raw in for i in 0..<size { raw[i] = UInt8(truncatingIfNeeded: i &* 13 &+ i >> 7) } }
        let name = "capped-\(UUID().uuidString).mkv"
        let url = RangeServer.add(name, bytes, cap: 700_000)
        let stream = CloudByteStream(source: .init(url: url, headers: [:], length: size, name: name), session: RangeServer.session, parallel: 1) { nil }
        let chunk = try await stream.read(at: 0, count: CloudByteStream.chunkSize)
        #expect(chunk == bytes.prefix(CloudByteStream.chunkSize))
        #expect(try await stream.read(at: size - 10, count: 10) == bytes.suffix(10))
        await stream.clear()
    }

    /// A refresh that failed isn't reported as a new address to the other chunks refused with it.
    @Test func aFailedRefreshIsNotRetriedAtOnce() async throws {
        let size = CloudByteStream.chunkSize * 3
        let (url, _) = try await served("gone.mp4", size: size)
        let expired = url.deletingLastPathComponent().appending(path: "gone-expired.mp4")
        let calls = CloudCounter()
        let stream = CloudByteStream(source: .init(url: expired, headers: [:], length: size, name: "gone.mp4"), session: RangeServer.session, parallel: 1) {
            calls.add(1)
            return nil
        }
        await #expect(throws: (any Error).self) { try await stream.read(at: 0, count: 4) }
        await #expect(throws: (any Error).self) { try await stream.read(at: CloudByteStream.chunkSize * 2, count: 4) }
        #expect(calls.value == 1)
        // One request for each chunk: no retry after the refresh failed.
        #expect(RangeServer.requests("gone-expired.mp4") == 2)
        await stream.clear()
    }

    @Test func anExpiredAddressIsResolvedAgain() async throws {
        let size = CloudByteStream.chunkSize + 10
        let (url, bytes) = try await served("a.mp4", size: size)
        let expired = url.deletingLastPathComponent().appending(path: "expired.mp4")
        let calls = CloudCounter()
        let stream = CloudByteStream(source: .init(url: expired, headers: [:], length: size, name: "a.mp4"), session: RangeServer.session) {
            calls.add(1)
            return .init(url: url, headers: [:], length: size, name: "a.mp4")
        }
        #expect(try await stream.read(at: size - 4, count: 4) == bytes[(size - 4)...])
        #expect(calls.value == 1)
        await stream.clear()
    }
}

/// Serves registered bytes for https://cloud.test/<name> with HTTP Range, in memory, so these
/// tests share no server or port with other suites. Unknown names answer 404 (an expired link).
final class RangeServer: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var files: [String: Data] = [:]
    nonisolated(unsafe) private static var restOfFile: Set<String> = []
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    /// Answers a drive gives now and then: `empty` ranges with no bytes, then at most `cap` bytes per range.
    nonisolated(unsafe) private static var faults: [String: (empty: Int, cap: Int?)] = [:]
    static let configuration: URLSessionConfiguration = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeServer.self]
        return configuration
    }()
    static let session = URLSession(configuration: configuration)
    /// `restOfFile` answers every range with everything from its start, as a plugin's drive proxy does.
    static func add(_ name: String, _ data: Data, restOfFile: Bool = false, empty: Int = 0, cap: Int? = nil) -> URL {
        lock.withLock {
            files[name] = data
            if restOfFile { Self.restOfFile.insert(name) }
            if empty > 0 || cap != nil { faults[name] = (empty, cap) }
        }
        return URL(string: "https://cloud.test/\(name)")!
    }
    /// How many requests a file was asked for.
    static func requests(_ name: String) -> Int { lock.withLock { counts[name, default: 0] } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == "cloud.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let client else { return }
        let name = url.lastPathComponent
        let (file, toEnd, fault) = Self.lock.withLock {
            Self.counts[name, default: 0] += 1
            let fault = Self.faults[name]
            if let fault, fault.empty > 0 { Self.faults[name]?.empty -= 1 }
            return (Self.files[name], Self.restOfFile.contains(name), fault)
        }
        guard let data = file else {
            client.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
            client.urlProtocolDidFinishLoading(self); return
        }
        var range = 0..<data.count, status = 200
        if let header = request.value(forHTTPHeaderField: "Range"), let match = header.firstMatch(of: /^bytes=(\d+)-(\d*)$/),
           let first = Int(match.1), first < data.count {
            let last = toEnd ? data.count - 1 : Int(match.2) ?? data.count - 1
            range = first..<min(data.count, last + 1, fault?.cap.map { first + $0 } ?? Int.max); status = 206
        }
        if status == 206, let fault, fault.empty > 0 {
            let headers = ["Content-Length": "0", "Content-Range": "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(data.count)"]
            client.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client.urlProtocolDidFinishLoading(self); return
        }
        var headers = ["Content-Length": "\(range.count)", "Content-Type": "application/octet-stream"]
        if status == 206 { headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(data.count)" }
        client.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: data.subdata(in: range))
        client.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

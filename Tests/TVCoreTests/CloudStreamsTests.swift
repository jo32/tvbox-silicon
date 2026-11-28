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

    /// Dolby's packager writes `hev1` entries whose hvcC lists no parameter sets (they are in the stream). Tagged
    /// `hvc1`, AVPlayer fails at once with CoreMedia error -4; left `hev1`, the player repackages the file (#769, #1644).
    @Test func hevcWhoseSettingsAreOnlyInTheStreamStaysHev1() {
        func be(_ value: Int) -> Data { Data([UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)]) }
        func entry(_ tag: String, arrays: [UInt8]) -> Data {
            let record = Data([1] + Array(repeating: 0, count: 20) + [0x0f] + arrays)
            let hvcC = be(8 + record.count) + Data("hvcC".utf8) + record
            return be(86 + hvcC.count) + Data(tag.utf8) + Data(repeating: 0, count: 6) + Data([0, 1]) + Data(repeating: 0, count: 70) + hvcC
        }
        let none: [UInt8] = [0]
        let vpsOnly: [UInt8] = [1, 0xa0, 0, 1, 0, 2, 0x40, 0x01]
        let complete: [UInt8] = [2, 0xa1, 0, 1, 0, 2, 0x42, 0x01, 0xa2, 0, 1, 0, 2, 0x44, 0x01]
        for arrays in [none, vpsOnly] {
            #expect(CloudStreams.playableSampleEntries(entry("hev1", arrays: arrays)) == entry("hev1", arrays: arrays))
            #expect(CloudStreams.playableSampleEntries(entry("dvhe", arrays: arrays)) == entry("dvhe", arrays: arrays))
        }
        #expect(CloudStreams.playableSampleEntries(entry("hev1", arrays: complete)) == entry("hvc1", arrays: complete))
        #expect(CloudStreams.playableSampleEntries(entry("dvhe", arrays: complete)) == entry("dvh1", arrays: complete))
    }

    @Test func containerComesFromTheBytesNotTheName() throws {
        let mp4 = Data([0, 0, 0, 0x20, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D])
        #expect(try CloudStreams.contentType(mp4, name: "4KXIN 192.mp3") == AVFileType.mp4.rawValue)
        let quickTime = Data([0, 0, 0, 0x14, 0x66, 0x74, 0x79, 0x70, 0x71, 0x74, 0x20, 0x20])
        #expect(try CloudStreams.contentType(quickTime, name: "a.mp4") == AVFileType.mov.rawValue)
        #expect(throws: TVError.self) { try CloudStreams.contentType(Data([0x1A, 0x45, 0xDF, 0xA3, 0, 0, 0, 0]), name: "a.mp4") }
        // A drive CDN's verification page or JSON error body is not a video (#2728).
        #expect(throws: TVError.self) { try CloudStreams.contentType(Data("<!doctype html><html>".utf8), name: "a.mp4") }
        #expect(throws: TVError.self) { try CloudStreams.contentType(Data("<html><body>verify</body>".utf8), name: "a.mp4") }
        #expect(throws: TVError.self) { try CloudStreams.contentType(Data("{\"error\": \"not found\"}".utf8), name: "a.mp4") }
        #expect(throws: TVError.self) { try CloudStreams.contentType(Data([0xEF, 0xBB, 0xBF] + Array("<head>".utf8)), name: "a.mp4") }
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

    /// Issue #433: on the iPhone AVPlayer reads a video on two overlapping requests, the newer starting a few chunks
    /// behind where the older got to, while another request reads its sound further back. The newer one counted as a
    /// third reader, a seek, which cancelled the chunks the others were reading ahead: a bundle's proxy then fetched them
    /// again and again, and a 4K episode stalled once the speed fell below its bitrate.
    @Test func overlappingRequestsDoNotFetchChunksAgain() async throws {
        let chunk = CloudByteStream.chunkSize
        let size = chunk * 48
        var bytes = Data(count: size)
        bytes.withUnsafeMutableBytes { raw in for i in 0..<size { raw[i] = UInt8(truncatingIfNeeded: i &* 11 &+ i >> 13) } }
        let name = "overlap-\(UUID().uuidString).mp4"
        // Answered a little later, so the chunks read ahead are still on their way when the next read comes.
        let url = RangeServer.add(name, bytes, connections: 64)
        let stream = CloudByteStream(source: .init(url: url, headers: [:], length: size, name: name), session: RangeServer.session, parallel: 2) { nil }
        for step in 0..<16 {
            // The sound, the video, and the video's newer request three chunks behind it.
            for index in [step, 14 + step, 11 + step] {
                let at = index * chunk + 5
                #expect(try await stream.read(at: at, count: 16) == bytes[at..<at + 16])
            }
        }
        // None was dropped on its way, and chunks 0 to 29 plus at most 8 read ahead were each fetched once.
        #expect(RangeServer.cancels(name) == 0)
        #expect(RangeServer.requests(name) <= 38)
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

    /// Once the player knows the duration, reads get a chunk's bytes as they arrive, even when a connection breaks off
    /// halfway through one and the rest is asked for again.
    @Test func aPlayingStreamHandsOverBytesAsTheyArrive() async throws {
        let size = CloudByteStream.chunkSize * 4 + 4321
        var bytes = Data(count: size)
        bytes.withUnsafeMutableBytes { raw in for i in 0..<size { raw[i] = UInt8(truncatingIfNeeded: i &* 29 &+ i >> 10) } }
        let name = "trickle-\(UUID().uuidString).mkv"
        let url = RangeServer.add(name, bytes, trickle: true, breaks: 2)
        let stream = CloudByteStream(source: .init(url: url, headers: [:], length: size, name: name), session: RangeServer.session) { nil }
        await stream.setDuration(60)
        var at = 0, copy = Data(), pieces = 0
        while at < size {
            let part = try await stream.read(at: at, count: size - at)
            #expect(!part.isEmpty)
            copy.append(part); at += part.count; pieces += 1
        }
        #expect(copy == bytes)
        // Not one piece per chunk: the first bytes of each came before the rest.
        #expect(pieces > 5)
        for offset in [size - 7, 3, CloudByteStream.chunkSize - 2, CloudByteStream.chunkSize * 3 + 99] {
            let part = try await stream.read(at: offset, count: 64)
            #expect(!part.isEmpty && part == bytes[offset..<offset + part.count])
        }
        #expect(RangeServer.requests(name) >= 7)
        await stream.clear()
    }

    /// At the start and after a jump, the chunk the player waits for comes in pieces on several connections at once
    /// (`burst`); its bytes still reach the reader in order. A stream held to fewer connections never does this.
    @Test func aJumpReadsTheChunkThereInPieces() async throws {
        let chunk = CloudByteStream.chunkSize
        let size = chunk * 12 + 333
        var bytes = Data(count: size)
        bytes.withUnsafeMutableBytes { raw in for i in 0..<size { raw[i] = UInt8(truncatingIfNeeded: i &* 17 &+ i >> 12) } }
        for parallel in [CloudByteStream.parallel, 2] {
            let name = "burst-\(parallel)-\(UUID().uuidString).mp4"
            let url = RangeServer.add(name, bytes)
            let stream = CloudByteStream(source: .init(url: url, headers: [:], length: size, name: name), session: RangeServer.session, parallel: parallel) { nil }
            #expect(try await stream.read(at: 0, count: 4) == bytes.prefix(4))
            // The chunks read ahead from the start are in: the jump has connections to spare.
            try await Task.sleep(for: .milliseconds(300))
            var at = chunk * 9 + 10, copy = Data()
            while at < chunk * 10 { let part = try await stream.read(at: at, count: chunk * 10 - at); copy.append(part); at += part.count }
            #expect(copy == bytes[chunk * 9 + 10..<chunk * 10])
            let inside = RangeServer.starts(name).filter { $0 > chunk * 9 && $0 < chunk * 10 }
            if parallel == CloudByteStream.parallel { #expect(inside.count >= 2) } else { #expect(inside.isEmpty) }
            // The last chunk, short, in pieces too.
            #expect(try await stream.read(at: size - 5, count: 5) == bytes.suffix(5))
            await stream.clear()
        }
    }

    @Test func theIndexIsFoundFromTheFirstBoxes() {
        func box(_ type: String, _ size: Int, large: Bool = false) -> Data {
            var data = Data()
            func put(_ value: Int, _ count: Int) { for shift in stride(from: (count - 1) * 8, through: 0, by: -8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) } }
            put(large ? 1 : size, 4); data.append(contentsOf: Array(type.utf8))
            if large { put(size, 8) }
            return data
        }
        var head = box("ftyp", 32); head.append(Data(count: 24))
        #expect(CloudStreams.indexRange(head + box("mdat", 3_000_000_000, large: true), length: 3_000_100_000) == 3_000_000_032..<3_000_100_000)
        #expect(CloudStreams.indexRange(head + box("free", 8) + box("mdat", 900_000), length: 1_000_000) == 900_040..<1_000_000)
        #expect(CloudStreams.indexRange(head + box("moov", 5000), length: 1_000_000) == 32..<5032)
        // A size past the file's end: not an MP4 the index can be found in.
        #expect(CloudStreams.indexRange(head + box("mdat", 2_000_000), length: 1_000_000) == nil)
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

    /// Issue #312: 115 answers 403 to connections past a few at once on a link it is serving. The reads wait for a
    /// connection instead of failing, and the stream reads ahead on fewer.
    @Test func aDriveThatCapsConnectionsIsReadOnFewer() async throws {
        let chunk = CloudByteStream.chunkSize
        let size = chunk * 24
        var bytes = Data(count: size)
        bytes.withUnsafeMutableBytes { raw in for i in 0..<size { raw[i] = UInt8(truncatingIfNeeded: i &* 7 &+ i >> 11) } }
        let url = RangeServer.add("capped.mkv", bytes, connections: 2)
        let stream = CloudByteStream(source: .init(url: url, headers: [:], length: size, name: "capped.mkv"), session: RangeServer.session) { nil }
        func sequential(from start: Int, chunks: Int) async throws -> Data {
            var at = start, copy = Data()
            while at < start + chunks * chunk { let part = try await stream.read(at: at, count: start + chunks * chunk - at); copy.append(part); at += part.count }
            return copy
        }
        #expect(try await stream.read(at: 0, count: 4) == bytes.prefix(4))
        // FFmpeg reads an MKV's index at the end while the start is still being read ahead.
        async let video = sequential(from: 0, chunks: 16)
        async let index = sequential(from: chunk * 20, chunks: 4)
        #expect(try await video == bytes[0..<chunk * 16])
        #expect(try await index == bytes[chunk * 20..<size])
        #expect(RangeServer.refusals("capped.mkv") > 0)
        await stream.clear()
    }

    /// A link refused before it sent anything is not waited on: it failed, as an expired one does.
    @Test func aLinkRefusedFromTheStartFails() async throws {
        let url = RangeServer.add("refused.mkv", Data(count: 64), connections: 0)
        let stream = CloudByteStream(source: .init(url: url, headers: [:], length: 64, name: "refused.mkv"), session: RangeServer.session) { nil }
        await #expect(throws: (any Error).self) { try await stream.read(at: 0, count: 4) }
        #expect(RangeServer.requests("refused.mkv") == 1)
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

    /// Issue #485: iOS took back the suspended app's sockets, so a bundle's proxy refuses connections on its old port.
    /// The stream asks where the proxy listens now and reads on from there, instead of failing every read.
    @Test func aRefusedLoopbackProxyMovesToItsNewPort() async throws {
        let size = CloudByteStream.chunkSize + 10
        let (url, bytes) = try await served("moved.mp4", size: size)
        // Nothing listens on the discard port here, so connecting is refused (NSURLErrorCannotConnectToHost).
        let stale = URL(string: "http://127.0.0.1:9/spider/wogg/3/proxy/quark/moved.mp4")!
        let calls = CloudCounter()
        let stream = CloudByteStream(source: .init(url: stale, headers: [:], length: size, name: "moved.mp4"), session: RangeServer.session, parallel: 1) {
            calls.add(1)
            return .init(url: url, headers: [:], length: size, name: "moved.mp4")
        }
        #expect(try await stream.read(at: size - 4, count: 4) == bytes[(size - 4)...])
        #expect(calls.value == 1)
        #expect(RangeServer.requests("moved.mp4") == 1)
        await stream.clear()
    }

    /// The 9280.kstore.vip bundle's drive sites put the drive link and its headers in their proxy addresses (#530).
    @Test func aBundleProxyRevealsItsDriveLink() throws {
        let fields = #"{"url":"https://drive.test/file.mp4?sign=a%2Bb~","headers":{"Cookie":"__puus=1","User-Agent":"quark","X-Count":2},"threads":16,"chunkKB":256,"createdAt":1}"#
        let pst = Data(fields.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let proxy = try #require(URL(string: "http://127.0.0.1:61981/spider/huban/3/proxy/quark/c4f07934-2ea1?pst=\(pst)"))
        let link = try #require(CatPawOpen.revealedLink(proxy))
        #expect(link.url.absoluteString == "https://drive.test/file.mp4?sign=a%2Bb~")
        #expect(link.headers == ["Cookie": "__puus=1", "User-Agent": "quark", "X-Count": "2"])
        #expect(CatPawOpen.revealedLink(try #require(URL(string: "http://127.0.0.1:61981/spider/huban/3/proxy/quark/c4f07934-2ea1"))) == nil)
        #expect(CatPawOpen.revealedLink(try #require(URL(string: "http://127.0.0.1:61981/spider/huban/3/proxy/quark/1?pst=e30"))) == nil)
        #expect(CatPawOpen.revealedLink(try #require(URL(string: "https://example.com/spider/huban/3/proxy/quark/1?pst=\(pst)"))) == nil)
    }

    /// The app reads a drive file itself only when its link serves what the bundle's proxy does.
    @Test func aDriveLinkStandsInForItsProxyOnlyWhenItServesTheSameFile() async throws {
        let size = 5000
        let (link, bytes) = try await served("direct-link.mp4", size: size)
        let proxied = CloudStreams.Source(url: RangeServer.add("direct-proxy.mp4", bytes), headers: [:], length: size, name: "c4f07934")
        let direct = try #require(await CatPawOpen.sameFile(proxied, at: link, headers: ["Cookie": "a"], session: RangeServer.session))
        #expect(direct.url == link && direct.length == size && direct.headers == ["Cookie": "a"] && direct.name == "c4f07934")
        // A link to a file under a disguise the proxy strips is longer; one the proxy changes has other bytes.
        let disguised = RangeServer.add("direct-disguised.mp4", Data(repeating: 0x89, count: 100) + bytes)
        #expect(await CatPawOpen.sameFile(proxied, at: disguised, headers: [:], session: RangeServer.session) == nil)
        var changed = bytes
        changed[3] ^= 0xff
        #expect(await CatPawOpen.sameFile(proxied, at: RangeServer.add("direct-changed.mp4", changed), headers: [:], session: RangeServer.session) == nil)
        // An expired link.
        #expect(await CatPawOpen.sameFile(proxied, at: try #require(URL(string: "https://cloud.test/direct-expired.mp4")), headers: [:], session: RangeServer.session) == nil)
    }

    /// Issue #2175: the stream reports how many seconds of cached bytes it already holds ahead of AVPlayer's reads.
    @Test func reportsSecondsCachedAheadOfReads() async throws {
        let size = CloudByteStream.chunkSize * 10
        let (url, _) = try await served("ahead-\(UUID().uuidString).mp4", size: size)
        let stream = CloudByteStream(source: .init(url: url, headers: [:], length: size, name: "ahead.mp4"), session: RangeServer.session) { nil }
        // Before the duration is known, nothing is reported.
        #expect(stream.bufferedAhead.withLock { $0 } == 0)
        // 10 chunks over 100 s = 10 s per chunk.
        await stream.setDuration(100)
        _ = try await stream.read(at: 0, count: 64)
        // Wait briefly for prefetched chunks to land in cache.
        for _ in 0..<40 {
            if stream.bufferedAhead.withLock({ $0 }) >= 30 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(stream.bufferedAhead.withLock { $0 } >= 30)
        await stream.clear()
        #expect(stream.bufferedAhead.withLock { $0 } == 0)
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
    /// Files whose bytes come in small pieces, a little apart, and how many of their connections still break off halfway.
    nonisolated(unsafe) private static var trickles: [String: Int] = [:]
    /// Files that answer at most this many requests at once, each a little later, and refuse the rest with 403 (115's CDN).
    nonisolated(unsafe) private static var limits: [String: Int] = [:]
    nonisolated(unsafe) private static var active: [String: Int] = [:]
    nonisolated(unsafe) private static var refused: [String: Int] = [:]
    nonisolated(unsafe) private static var cancelled: [String: Int] = [:]
    nonisolated(unsafe) private static var rangeStarts: [String: [Int]] = [:]
    /// Whether this request was answered, so a stop before that is a cancel.
    private var answered = false
    static let configuration: URLSessionConfiguration = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeServer.self]
        return configuration
    }()
    static let session = URLSession(configuration: configuration)
    /// `restOfFile` answers every range with everything from its start, as a plugin's drive proxy does.
    static func add(_ name: String, _ data: Data, restOfFile: Bool = false, empty: Int = 0, cap: Int? = nil, connections: Int? = nil,
                    trickle: Bool = false, breaks: Int = 0) -> URL {
        lock.withLock {
            if trickle { trickles[name] = breaks }
            files[name] = data
            if restOfFile { Self.restOfFile.insert(name) }
            if empty > 0 || cap != nil { faults[name] = (empty, cap) }
            if let connections { limits[name] = connections }
        }
        return URL(string: "https://cloud.test/\(name)")!
    }
    /// Where each range asked of a file began.
    static func starts(_ name: String) -> [Int] { lock.withLock { rangeStarts[name, default: []] } }
    /// How many requests a file was asked for.
    static func requests(_ name: String) -> Int { lock.withLock { counts[name, default: 0] } }
    /// How many requests a file with a connection limit refused.
    static func refusals(_ name: String) -> Int { lock.withLock { refused[name, default: 0] } }
    /// How many requests to a file with a connection limit were cancelled before their answer.
    static func cancels(_ name: String) -> Int { lock.withLock { cancelled[name, default: 0] } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == "cloud.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let client else { return }
        let name = url.lastPathComponent
        let (file, toEnd, fault, limited, refuse) = Self.lock.withLock {
            Self.counts[name, default: 0] += 1
            let fault = Self.faults[name]
            if let fault, fault.empty > 0 { Self.faults[name]?.empty -= 1 }
            let limit = Self.limits[name]
            let refuse = limit.map { Self.active[name, default: 0] >= $0 } ?? false
            if refuse { Self.refused[name, default: 0] += 1 } else if limit != nil { Self.active[name, default: 0] += 1 }
            return (Self.files[name], Self.restOfFile.contains(name), fault, limit != nil, refuse)
        }
        if refuse {
            let body = Data("{\"state\":false,\"msg\":\"too many connections\"}".utf8)
            client.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "\(body.count)"])!, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: body)
            client.urlProtocolDidFinishLoading(self); return
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
            Self.lock.withLock { Self.rangeStarts[name, default: []].append(first) }
        }
        if status == 206, let fault, fault.empty > 0 {
            let headers = ["Content-Length": "0", "Content-Range": "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(data.count)"]
            client.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client.urlProtocolDidFinishLoading(self); return
        }
        var headers = ["Content-Length": "\(range.count)", "Content-Type": "application/octet-stream"]
        if status == 206 { headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(data.count)" }
        let breaks = Self.lock.withLock {
            guard let left = Self.trickles[name] else { return Int?.none }
            if left > 0 { Self.trickles[name] = left - 1 }
            return left
        }
        if let breaks {
            client.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            let body = data.subdata(in: range), piece = 128 * 1024
            let end = breaks > 0 ? body.count / 2 : body.count
            func send(_ at: Int) {
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(3)) { [self] in
                    guard let client = self.client else { return }
                    if at >= end {
                        if breaks > 0 { client.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)) }
                        else { client.urlProtocolDidFinishLoading(self) }
                        return
                    }
                    client.urlProtocol(self, didLoad: body.subdata(in: at..<min(end, at + piece)))
                    send(at + piece)
                }
            }
            send(0); return
        }
        guard limited else {
            client.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: data.subdata(in: range))
            client.urlProtocolDidFinishLoading(self); return
        }
        // Held open for a while, so the stream's other connections overlap it.
        let body = data.subdata(in: range)
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(40)) { [self, status, headers] in
            RangeServer.lock.withLock { self.answered = true }
            if let client = self.client {
                client.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
                client.urlProtocol(self, didLoad: body)
                client.urlProtocolDidFinishLoading(self)
            }
            RangeServer.lock.withLock { RangeServer.active[name, default: 1] -= 1 }
        }
    }
    override func stopLoading() {
        guard let name = request.url?.lastPathComponent else { return }
        Self.lock.withLock { if Self.limits[name] != nil, !answered { Self.cancelled[name, default: 0] += 1 } }
    }
}

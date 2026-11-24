import Foundation
import Testing
@testable import TVCore

/// Playing a download before it has finished (#1264).
@Suite(.serialized) struct DownloadStreamTests {
    private static let chunk = Int(Transfer.chunk)

    private static func bytes(_ count: Int, seed: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ seed &+ ($0 >> 9)) })
    }

    /// A download's folder under a root of its own, with `parts/` in it.
    private static func folder() throws -> URL {
        let folder = URL.temporaryDirectory.appending(path: "download-stream-\(UUID().uuidString)").appending(path: "item")
        try FileManager.default.createDirectory(at: folder.appending(path: "parts"), withIntermediateDirectories: true)
        return folder
    }

    private static func save(_ plan: TransferPlan, in folder: URL) throws {
        try JSONEncoder().encode(plan).write(to: folder.appending(path: "plan.json"))
    }

    /// A stopped file download of two chunks and a bit, with only its first chunk on disk.
    private static func stoppedFile() throws -> (folder: URL, name: String, data: Data) {
        DownloadStream.session = RangeServer.session
        let data = bytes(chunk * 2 + 1000, seed: 1)
        let name = "stopped-\(UUID().uuidString).mp4"
        let url = RangeServer.add(name, data)
        let folder = try folder()
        var part = Data(count: data.count)
        part.replaceSubrange(0..<chunk, with: data.prefix(chunk))
        try part.write(to: folder.appending(path: "parts/media.part"))
        let file = TransferPlan.RemoteFile(urls: [url], name: "media.part", length: Int64(data.count), ranged: true, done: [0])
        try save(TransferPlan(kind: .file, headers: [:], files: [file], fileExtension: "mp4"), in: folder)
        return (folder, name, data)
    }

    @Test func aStoppedFilePlaysFromDiskAndFromItsSource() async throws {
        let (folder, name, data) = try Self.stoppedFile()
        let file = try #require(DownloadStream.file(folder.appending(path: "play.mp4")))
        #expect(file.length == Int64(data.count))
        #expect(file.fileExtension == "mp4")
        // What is on disk comes from disk.
        let saved = try await file.read(100...199)
        #expect(saved == Data(data[100..<200]))
        #expect(RangeServer.starts(name).isEmpty)
        // One read ends with its chunk.
        let edge = try await file.read(Int64(Self.chunk - 10)...Int64(Self.chunk + 10))
        #expect(edge == Data(data[(Self.chunk - 10)..<Self.chunk]))
        // What isn't comes from the source: the chunk once, however many reads it takes.
        let start = Self.chunk * 2
        let tail = try await file.read(Int64(start + 5)...Int64(data.count + 50))
        #expect(tail == Data(data[(start + 5)...]))
        let head = try await file.read(Int64(start)...Int64(start + 4))
        #expect(head == Data(data[start..<(start + 5)]))
        #expect(RangeServer.starts(name) == [start])
        #expect(DownloadStream.isPlaying(folder))
    }

    @Test func thePlayersFirstReadDoesNotSitThroughAChunkTheDownloadIsFetching() async throws {
        let (folder, name, data) = try Self.stoppedFile()
        // As a download in the middle of the second chunk, on a slow host.
        let piece = folder.appending(path: "parts/media.part").path + "#1"
        let download = Task { try await DownloadStream.exclusive(piece) { try await Task.sleep(for: .seconds(5)) } }
        try await Task.sleep(for: .milliseconds(100))
        let file = try #require(DownloadStream.file(folder.appending(path: "play.mp4")))
        let began = ContinuousClock.now
        let read = try await file.read(Int64(Self.chunk)...Int64(Self.chunk + 9))
        #expect(read == Data(data[Self.chunk..<(Self.chunk + 10)]))
        let waited = began.duration(to: .now)
        #expect(waited >= DownloadStream.patience && waited < .seconds(4))
        #expect(RangeServer.starts(name).count == 4)
        download.cancel()
    }

    @Test func theLoopbackServerSendsAnUnfinishedFileAcrossItsChunks() async throws {
        let (folder, name, data) = try Self.stoppedFile()
        let address = try await LocalMediaServer().address(of: folder.appending(path: "play.mp4"), root: folder.deletingLastPathComponent())
        // As a player asks: everything from somewhere in the saved chunk on.
        let from = Self.chunk - 1000
        var request = URLRequest(url: address)
        request.setValue("bytes=\(from)-", forHTTPHeaderField: "Range")
        let (body, response) = try await URLSession.shared.data(for: request)
        let answer = try #require(response as? HTTPURLResponse)
        #expect(answer.statusCode == 206)
        #expect(answer.value(forHTTPHeaderField: "Content-Range") == "bytes \(from)-\(data.count - 1)/\(data.count)")
        #expect(answer.value(forHTTPHeaderField: "Content-Type") == "video/mp4")
        #expect(body == Data(data[from...]))
        // The whole chunk in between came in four shares at once; the short last one in one piece.
        #expect(RangeServer.starts(name).sorted() == (0..<4).map { Self.chunk + $0 * Self.chunk / 4 } + [Self.chunk * 2])
        // Its length alone, without a byte fetched.
        var probe = URLRequest(url: address)
        probe.httpMethod = "HEAD"
        let (_, top) = try await URLSession.shared.data(for: probe)
        #expect((top as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length") == "\(data.count)")
        #expect(RangeServer.starts(name).count == 5)
    }

    @Test func aRunningDownloadKeepsWhatThePlayerFetchedAndFetchesNothingTwice() async throws {
        DownloadStream.session = RangeServer.session
        // Eleven chunks, the last one short, from a server that sends them in small pieces.
        let data = Self.bytes(Self.chunk * 10 + 77, seed: 2)
        let name = "running-\(UUID().uuidString).mp4"
        let url = RangeServer.add(name, data, trickle: true)
        let folder = try Self.folder()
        let meter = DownloadMeter()
        let transfer = Transfer(folder: folder, meter: meter, session: RangeServer.session, resolve: { Channel(name: "Test", url: url) }, note: { _ in })
        let run = Task { try await transfer.run() }
        var playing: PendingFile?
        for _ in 0..<1000 where playing == nil {
            playing = DownloadStream.file(folder.appending(path: "play.mp4"))
            if playing == nil { try await Task.sleep(for: .milliseconds(2)) }
        }
        let file = try #require(playing)
        // The player jumps near the end while the download is still at the start.
        let from = Self.chunk * 9
        let jumped = try await file.read(Int64(from)...Int64(data.count - 1))
        #expect(jumped == Data(data[from..<(Self.chunk * 10)]))
        #expect(try await run.value == "media.mp4")
        #expect(try Data(contentsOf: folder.appending(path: "media.mp4")) == data)
        // Every chunk was asked of the server once, whoever asked (the first also by the look at the link); the one
        // fetched for the player may have come in shares.
        let starts = RangeServer.starts(name).filter { $0 > 0 }
        #expect(Set(starts).count == starts.count)
        #expect(Set(starts).isSuperset(of: (1...10).map { $0 * Self.chunk }))
        #expect(starts.allSatisfy { $0 % Self.chunk == 0 || $0 / Self.chunk == 9 })
        #expect(meter.snapshot.parts == 11)
        #expect(meter.received == Int64(data.count))
        // Finished under the player: what it reads next is the finished file.
        let after = try await file.read(5...9)
        #expect(after == Data(data[5..<10]))
    }

    @Test func anUnfinishedPlaylistPlaysAndThePiecesFetchedForItAreKept() async throws {
        DownloadStream.session = RangeServer.session
        let id = UUID().uuidString
        let segments = (0..<4).map { Self.bytes(5000 + $0, seed: $0) }
        let names = (0..<4).map { "segment\($0)-\(id).m4s" }
        let parts = (0..<4).map {
            TransferPlan.Part(url: RangeServer.add(names[$0], segments[$0]), range: nil, name: String(format: "parts/%05d.m4s", $0), transportStream: false)
        }
        let playlist = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n" + parts.map { "#EXTINF:6.0,\n\($0.name)\n" }.joined() + "#EXT-X-ENDLIST\n"
        let folder = try Self.folder()
        try Self.save(TransferPlan(kind: .hls, headers: [:], parts: parts, playlist: playlist), in: folder)
        try segments[0].write(to: folder.appending(path: "parts/00000.m4s"))
        // The whole playlist, though only the first piece is here.
        let listed = await DownloadStream.missing(folder.appending(path: "index.m3u8"))
        #expect(listed == Data(playlist.utf8))
        // A piece the player jumps to is fetched and kept.
        let piece = await DownloadStream.missing(folder.appending(path: "parts/00002.m4s"))
        #expect(piece == segments[2])
        #expect(try Data(contentsOf: folder.appending(path: "parts/00002.m4s")) == segments[2])
        let unknown = await DownloadStream.missing(folder.appending(path: "parts/00009.m4s"))
        #expect(unknown == nil)
        // The download then fetches only what is still missing.
        let meter = DownloadMeter()
        let transfer = Transfer(folder: folder, meter: meter, session: RangeServer.session, resolve: { throw CancellationError() }, note: { _ in })
        #expect(try await transfer.run() == "index.m3u8")
        #expect(names.map { RangeServer.requests($0) } == [0, 1, 1, 1])
        #expect(meter.snapshot.parts == 4)
        #expect((0..<4).allSatisfy { (try? Data(contentsOf: folder.appending(path: parts[$0].name))) == segments[$0] })
    }

    @Test func aDownloadGoesOnFromWhereThePlayerIs() {
        let queue = WorkQueue(Array(0..<10))
        #expect(queue.next() == 0)
        queue.advance(to: 6) { $0 }
        #expect((0..<4).map { _ in queue.next() } == [6, 7, 8, 9])
        // Back before what it skipped: the lowest left at or past it, then the rest in their order.
        queue.advance(to: 3) { $0 }
        #expect((0..<6).map { _ in queue.next() } == [3, 4, 5, 1, 2, nil])
    }

    @Test func onlyRangedFilesAndPlaylistsPlayBeforeTheyAreWhole() {
        let ranged = TransferPlan.RemoteFile(urls: [], name: "media.part", length: 100, ranged: true)
        let whole = TransferPlan.RemoteFile(urls: [], name: "media.part", length: 100, ranged: false)
        #expect(TransferPlan(kind: .file, headers: [:], files: [ranged]).streams)
        #expect(!TransferPlan(kind: .file, headers: [:], files: [whole]).streams)
        #expect(!TransferPlan(kind: .dash, headers: [:], files: [ranged, ranged]).streams)
        #expect(TransferPlan(kind: .hls, headers: [:], playlist: "#EXTM3U\n").streams)
    }

    @Test func rangeHeadersNameTheBytesAsked() throws {
        let all = try #require(LocalMediaServer.span(nil, size: 100))
        #expect(all.range == 0...99 && all.status == 200)
        let rest = try #require(LocalMediaServer.span("Range: bytes=10-", size: 100))
        #expect(rest.range == 10...99 && rest.status == 206)
        let some = try #require(LocalMediaServer.span("range: bytes=10-19", size: 100))
        #expect(some.range == 10...19)
        let last = try #require(LocalMediaServer.span("Range: bytes=-20", size: 100))
        #expect(last.range == 80...99)
        #expect(LocalMediaServer.span("Range: bytes=100-", size: 100) == nil)
    }
}

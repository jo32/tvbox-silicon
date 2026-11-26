import Foundation
import Network
import os
import Testing
@testable import TVCore

struct FLVLiveTests {
    private typealias Tag = FLVTagReader.Tag

    private static let avcConfig = Data([0x17, 0x00, 0, 0, 0, 1, 2, 3])
    private static let aacConfig = Data([0xAF, 0x00, 0x12, 0x10])
    private static func video(_ time: UInt32, key: Bool) -> Tag { Tag(type: 9, time: time, body: Data([key ? 0x17 : 0x27, 0x01, 0, 0, 0, 9, 9])) }
    private static func audio(_ time: UInt32) -> Tag { Tag(type: 8, time: time, body: Data([0xAF, 0x01, 7, 7])) }

    private static func file(_ tags: [Tag]) -> Data {
        var data = Data([0x46, 0x4C, 0x56, 0x01, 0x05, 0, 0, 0, 9, 0, 0, 0, 0])
        for tag in tags { FLVSegmenter.write(tag, to: &data) }
        return data
    }

    @Test func tagsAreReadAcrossArbitraryChunks() throws {
        let tags = [Tag(type: 9, time: 0, body: Self.avcConfig), Self.video(0, key: true), Self.audio(23), Self.video(0x0123_4567, key: false)]
        let data = Self.file(tags)
        var reader = FLVTagReader()
        var read: [Tag] = []
        var offset = 0
        for size in [1, 5, 9, 2, 30, 7, 1000] where offset < data.count {
            let end = min(data.count, offset + size)
            read += try reader.append(data[offset..<end])
            offset = end
        }
        #expect(read == tags)
        // Times above 24 bits keep their extension byte.
        #expect(read.last?.time == 0x0123_4567)
    }

    @Test func notFLVIsRefused() {
        var reader = FLVTagReader()
        #expect(throws: FLVTagReader.Failure.self) { try reader.append(Data("#EXTM3U\n#EXT-X-VERSION:3\n".utf8)) }
    }

    @Test func aPlainVideoFileIsReportedAsNotFLV() async throws {
        // A plugin labelled an MP4 file "flv" (AngelLive's Hongguo episodes, #1047): it says so, so the caller can play it as it is.
        // The session is started directly: the shared store keeps three, and parallel tests would close it.
        let file = FileManager.default.temporaryDirectory.appending(path: "flv-\(UUID().uuidString).mp4")
        try (Data([0, 0, 0, 0x20]) + Data("ftypisom".utf8) + Data(count: 4096)).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let session = FLVLiveSession(url: file, headers: [:], device: RemuxSession.device())
        defer { session.close() }
        await #expect(throws: FLVLive.NotFLV.self) { try await session.start() }
    }

    @Test func pluginVideoFilesLabelledFLVAreNotFLV() {
        let reply: JSONValue = .array([.object(["cdn": .string("选集"), "qualitys": .array([
            .object(["title": .string("第1集"), "liveCodeType": .string("flv"),
                     "url": .string("https://v11-hgweb.qznovelvod.com/abc/6af2/video/tos/cn/tos-cn-v-6fcc8e/6d09/?a=8662&mime_type=video_mp4&qs=0")]),
            .object(["title": .string("原画"), "liveCodeType": .string("flv"),
                     "url": .string("https://tx-flv-web.yy.com/live/abc?wsSecret=1")]),
        ])])])
        #expect(LivePluginCatalog.options(reply).map(\.flv) == [false, true])
    }

    @Test func runsBeginAtKeyframesAfterTheMinimum() throws {
        var segmenter = FLVSegmenter()
        var runs: [FLVSegmenter.Run] = []
        let tags: [Tag] = [Self.video(0, key: false), // before any configuration or keyframe: dropped
                           Tag(type: 9, time: 0, body: Self.avcConfig), Tag(type: 8, time: 0, body: Self.aacConfig),
                           Self.video(40, key: false), // still before the first keyframe: dropped
                           Self.video(1000, key: true), Self.audio(1010), Self.video(2000, key: true), // 1 s: too short to cut
                           Self.video(3000, key: true), Self.audio(3010), Self.video(4500, key: false), Self.video(5000, key: true)]
        for tag in tags { if let run = segmenter.add(tag) { runs.append(run) } }
        #expect(runs.count == 2)
        #expect(runs.map(\.start) == [1000, 3000])
        #expect(runs.map(\.duration) == [2, 2])
        #expect(runs.allSatisfy { !$0.discontinuity })
        // Each run is a playable file: configurations first, then its own tags.
        var reader = FLVTagReader()
        let first = try reader.append(runs[0].file)
        #expect(first.map(\.type) == [9, 8, 9, 8, 9])
        #expect(first[0].body == Self.avcConfig && first[1].body == Self.aacConfig)
        #expect(first.map(\.time) == [1000, 1000, 1000, 1010, 2000])
    }

    @Test func jumpsAndNewConfigurationsBeginDiscontinuities() {
        var segmenter = FLVSegmenter()
        var runs: [FLVSegmenter.Run] = []
        let tags: [Tag] = [Tag(type: 9, time: 0, body: Self.avcConfig), Self.video(0, key: true), Self.video(2000, key: true),
                           // The source reconnected: times begin again.
                           Self.video(100, key: true), Self.video(2200, key: true),
                           // Another picture size.
                           Tag(type: 9, time: 2300, body: Data([0x17, 0x00, 0, 0, 0, 4, 5, 6])), Self.video(2300, key: true), Self.video(4400, key: true)]
        for tag in tags { if let run = segmenter.add(tag) { runs.append(run) } }
        #expect(runs.map(\.start) == [0, 2000, 100, 2200, 2300])
        #expect(runs.map(\.discontinuity) == [false, false, true, false, true])
        // The run cut by the new configuration lasts until it.
        #expect(runs[3].duration == 0.1)
    }

    @Test func legacyHEVCBecomesEnhancedRTMP() {
        // Codec id 12: SequenceStart with composition time 0, then the record.
        let config = FLVSegmenter.enhanced(Tag(type: 9, time: 0, body: Data([0x1C, 0x00, 0, 0, 0, 0xAA, 0xBB])))
        #expect(config.body == Data([0x90, 0x68, 0x76, 0x63, 0x31, 0xAA, 0xBB]))
        #expect(FLVSegmenter.isVideoConfig(config.body))
        let frame = FLVSegmenter.enhanced(Tag(type: 9, time: 40, body: Data([0x2C, 0x01, 0, 0, 0x21, 0xCC])))
        #expect(frame.body == Data([0xA1, 0x68, 0x76, 0x63, 0x31, 0, 0, 0x21, 0xCC]))
        #expect(!FLVSegmenter.isKeyframe(frame.body))
        // H.264 is left as it is.
        let avc = Self.video(0, key: true)
        #expect(FLVSegmenter.enhanced(avc) == avc)
    }
}

// MARK: Going on from a fresh address

extension FLVLiveTests {
    @Test func aResumedStreamSkipsPicturesAlreadyPlayed() throws {
        var first = FLVSegmenter()
        _ = first.add(Tag(type: 9, time: 0, body: Self.avcConfig))
        for time: UInt32 in [0, 2000, 4000] { _ = first.add(Self.video(time, key: true)) }
        _ = first.add(Self.video(4040, key: false))
        // The connection ended: the run under way is kept.
        let finished = first.finish()
        let tail = try #require(finished)
        #expect(tail.start == 4000 && abs(tail.duration - 0.041) < 0.0001 && !tail.discontinuity)
        #expect(first.lastEnd == 4041)
        // The new connection begins at pictures the server still had.
        var resumed = FLVSegmenter.resuming(after: first.lastEnd)
        _ = resumed.add(Tag(type: 9, time: 0, body: Self.avcConfig))
        for time: UInt32 in [2000, 4000, 6000] {
            let closed = resumed.add(Self.video(time, key: true))
            #expect(closed == nil)
        }
        let closed = resumed.add(Self.video(8000, key: true))
        let run = try #require(closed)
        #expect(run.start == 6000 && run.duration == 2 && run.discontinuity)
        // A clock that began again plays on.
        var reset = FLVSegmenter.resuming(after: 200_000)
        _ = reset.add(Tag(type: 9, time: 0, body: Self.avcConfig))
        _ = reset.add(Self.video(0, key: true))
        let restarted = reset.add(Self.video(2000, key: true))
        let again = try #require(restarted)
        #expect(again.start == 0 && again.discontinuity)
        var empty = FLVSegmenter()
        let nothing = empty.finish()
        #expect(nothing == nil)
    }

    @Test func aStreamWhoseConnectionEndsGoesOnFromAFreshAddress() async throws {
        let stream = try Data(contentsOf: try #require(Bundle.module.url(forResource: "live-h264-aac", withExtension: "flv", subdirectory: "Fixtures")))
        // The first address stops halfway, as one that expired does; the fresh one gives the stream from its start
        // again, as a CDN begins at a picture it still has. After that there is no fresh address, and the stream ends.
        let server = try await LiveServer.start(["/first.flv": stream.prefix(stream.count / 2), "/fresh.flv": stream])
        defer { server.stop() }
        let port = server.port
        let asked = OSAllocatedUnfairLock(initialState: 0)
        let session = FLVLiveSession(url: URL(string: "http://127.0.0.1:\(port)/first.flv")!, headers: [:], device: RemuxSession.device()) {
            let count = asked.withLock { $0 += 1; return $0 }
            return count == 1 ? (URL(string: "http://127.0.0.1:\(port)/fresh.flv")!, ["X-Renewed": "1"]) : nil
        }
        defer { session.close() }
        try await session.start()
        var playlist = ""
        for _ in 0..<80 where !playlist.contains("#EXT-X-ENDLIST") {
            playlist = await session.playlist(0) ?? ""
            if !playlist.contains("#EXT-X-ENDLIST") { try await Task.sleep(for: .milliseconds(250)) }
        }
        #expect(playlist.contains("#EXT-X-ENDLIST"))
        #expect(asked.withLock { $0 } == 2)
        #expect(server.headers("/fresh.flv")["x-renewed"] == "1")
        let lines = playlist.components(separatedBy: "\n")
        // One playlist throughout: the fresh connection's runs follow a discontinuity, and nothing plays twice (the
        // stream lasts 6 s; a little at the cut may be lost, never repeated).
        #expect(lines.filter { $0 == "#EXT-X-DISCONTINUITY" }.count == 1)
        let total = lines.filter { $0.hasPrefix("#EXTINF:") }.compactMap { Double($0.dropFirst(8).dropLast()) }.reduce(0, +)
        #expect(total > 4.5 && total < 6.3, "listed \(total) s")
        for name in lines where name.hasSuffix(".m4s") {
            let index = try #require(Int(name.dropFirst(2).dropLast(4)))
            let media = try await session.segment(track: 0, index: index)
            #expect(!media.isEmpty)
        }
    }
}

/// A live stream's server: each address gives its bytes and then ends the connection, as one that expired does.
private final class LiveServer: @unchecked Sendable {
    let port: UInt16
    private let listener: NWListener
    private let requests: OSAllocatedUnfairLock<[String: [String: String]]>

    private init(listener: NWListener, port: UInt16, requests: OSAllocatedUnfairLock<[String: [String: String]]>) {
        self.listener = listener; self.port = port; self.requests = requests
    }

    static func start(_ bodies: [String: Data]) async throws -> LiveServer {
        let listener = try NWListener(using: .tcp)
        let queue = DispatchQueue(label: "live.server")
        let requests = OSAllocatedUnfairLock<[String: [String: String]]>(initialState: [:])
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
                let asked = headers
                requests.withLock { $0[path] = asked }
                guard let body = bodies[path] else {
                    return connection.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), isComplete: true,
                                           completion: .contentProcessed { _ in connection.cancel() })
                }
                // No length: the stream lasts until the server ends it.
                let header = "HTTP/1.1 200 OK\r\nContent-Type: video/x-flv\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(header.utf8) + body, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            final class Flag: @unchecked Sendable { var done = false }
            let resumed = Flag()
            listener.stateUpdateHandler = { state in
                guard !resumed.done else { return }
                if case .ready = state, let port = listener.port?.rawValue { resumed.done = true; continuation.resume(returning: port) }
                if case .failed(let error) = state { resumed.done = true; continuation.resume(throwing: error) }
            }
            listener.start(queue: queue)
        }
        return LiveServer(listener: listener, port: port, requests: requests)
    }

    /// The headers the last request for `path` came with.
    func headers(_ path: String) -> [String: String] { requests.withLock { $0[path] ?? [:] } }

    func stop() { listener.cancel() }
}

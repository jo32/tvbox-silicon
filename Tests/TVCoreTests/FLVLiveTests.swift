import Foundation
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

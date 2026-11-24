import Foundation
import Testing
@testable import TVCore

@Test func aStreamsPreviewFramesAreSpreadOverTheVideo() {
    // A two-hour film: a frame every 10 seconds at most; a ten-minute clip: every 2.5; a short one: every 2.
    #expect(ScrubPreview.step(duration: 7200) == 10)
    #expect(ScrubPreview.step(duration: 600) == 2.5)
    #expect(ScrubPreview.step(duration: 90) == 2)
    #expect(ScrubPreview.step(duration: 0) == 2)
    #expect(ScrubPreview.step(duration: .nan) == 2)
}

@Test func aFingerThatBarelyMovesAsksForTheSameFrame() {
    #expect(ScrubPreview.snapped(1234, duration: 7200) == 1230)
    #expect(ScrubPreview.snapped(1236, duration: 7200) == 1240)
    #expect(ScrubPreview.snapped(1231, duration: 7200) == ScrubPreview.snapped(1234.9, duration: 7200))
    // Never past the end, before the start, or anywhere odd.
    #expect(ScrubPreview.snapped(7199, duration: 7195) == 7195)
    #expect(ScrubPreview.snapped(-3, duration: 600) == 0)
    #expect(ScrubPreview.snapped(.nan, duration: 600) == 0)
}

@Test func aSecondReaderOpensOnlyStreamsThatTakeOne() throws {
    #expect(ScrubPreview.reads(try #require(URL(string: "https://example.com/a/index.m3u8")), repackaged: false))
    #expect(ScrubPreview.reads(try #require(URL(string: "http://127.0.0.1:8123/download/1/index.m3u8")), repackaged: false))
    #expect(ScrubPreview.reads(try #require(URL(string: "\(DashStreams.scheme)://x/master.m3u8")), repackaged: false))
    // The repackager makes each part for the playing video; a drive's and a decrypted file read ahead for it.
    #expect(!ScrubPreview.reads(try #require(URL(string: "http://127.0.0.1:8123/remux/1/index.m3u8")), repackaged: true))
    #expect(!ScrubPreview.reads(try #require(URL(string: "\(CloudStreams.scheme)://x/file.mkv")), repackaged: false))
    #expect(!ScrubPreview.reads(try #require(URL(string: "\(CENCStreams.scheme)://x/file.mp4")), repackaged: false))
    #expect(!ScrubPreview.reads(try #require(URL(string: "\(LiveRepair.scheme)://x/live.m3u8")), repackaged: false))
    #expect(!ScrubPreview.reads(URL(fileURLWithPath: "/tmp/a.m3u8"), repackaged: false))
}

@Test func theHandleTicksAtChaptersAndAtEitherEnd() {
    let marks = [0.0, 90, 600, 1500]
    // Across a chapter's start, either way; not while sliding inside one.
    #expect(ScrubPreview.ticks(from: 80, to: 95, marks: marks, duration: 1500))
    #expect(ScrubPreview.ticks(from: 95, to: 80, marks: marks, duration: 1500))
    #expect(ScrubPreview.ticks(from: 85, to: 90, marks: marks, duration: 1500))
    #expect(!ScrubPreview.ticks(from: 100, to: 400, marks: marks, duration: 1500))
    #expect(!ScrubPreview.ticks(from: 90, to: 95, marks: marks, duration: 1500))
    // Reaching the start or the end once, not again while held there; marks at the ends add no second tick.
    #expect(ScrubPreview.ticks(from: 4, to: 0, marks: [], duration: 1500))
    #expect(!ScrubPreview.ticks(from: 0, to: 0, marks: marks, duration: 1500))
    #expect(ScrubPreview.ticks(from: 1490, to: 1500, marks: [], duration: 1500))
    #expect(!ScrubPreview.ticks(from: 1500, to: 1500, marks: marks, duration: 1500))
    #expect(!ScrubPreview.ticks(from: 0, to: 5, marks: marks, duration: 1500))
    // No length known: nothing to tick against.
    #expect(!ScrubPreview.ticks(from: 1, to: 2, marks: [1.5], duration: 0))
    #expect(!ScrubPreview.ticks(from: .nan, to: 2, marks: [1.5], duration: 10))
}

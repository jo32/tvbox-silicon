import Foundation
import Testing
@testable import TVCore

struct DanmakuTests {
    private func varint(_ value: UInt64) -> [UInt8] {
        var value = value, bytes: [UInt8] = []
        repeat { var byte = UInt8(value & 0x7F); value >>= 7; if value > 0 { byte |= 0x80 }; bytes.append(byte) } while value > 0
        return bytes
    }
    private func element(ms: UInt64, mode: UInt64, color: UInt64, text: String) -> [UInt8] {
        let body = [0x10] + varint(ms) + [0x18] + varint(mode) + [0x20] + varint(25) + [0x28] + varint(color)
            + [0x32, 2, 0x61, 0x62] + [0x3A] + varint(UInt64(text.utf8.count)) + Array(text.utf8) + [0x49] + Array(repeating: 0, count: 8)
        return [0x0A] + varint(UInt64(body.count)) + body
    }

    @Test func segmentsParseIntoTimedComments() {
        let data = Data(element(ms: 61_500, mode: 1, color: 0xFF0000, text: "前方高能") + element(ms: 2_000, mode: 5, color: 0xFFFFFF, text: "top")
                        + element(ms: 3_000, mode: 7, color: 0xFFFFFF, text: "[positioned]") + element(ms: 4_000, mode: 4, color: 0, text: "  "))
        let comments = BilibiliDanmaku.parse(data)
        #expect(comments.map(\.text) == ["前方高能", "top"])
        #expect(comments[0].time == 61.5 && comments[0].position == .scroll && comments[0].color == 0xFF0000)
        #expect(comments[1].position == .top)
    }

    @Test func layoutKeepsCommentsApartAndDropsWhatDoesNotFit() {
        var layout = DanmakuLayout(width: 1000, height: 400, laneHeight: 50, scrollArea: 0.5, scrollDuration: 10)
        #expect(layout.scrollLanes == 4 && layout.fixedLanes == 2)
        let comment = Danmaku(time: 0, position: .scroll, text: "x")
        // Four at once take four lanes; a fifth has none.
        let lanes = (0..<5).map { _ in layout.place(comment, width: 200, at: 0)?.lane }
        #expect(lanes == [0, 1, 2, 3, nil])
        // Once the first has fully entered with a gap, its lane is free again.
        #expect(layout.place(comment, width: 200, at: 3)?.lane == 0)
        // A much longer (faster) comment must not catch the one ahead, so it waits for another lane.
        #expect(layout.place(comment, width: 3000, at: 3.2) == nil)
        // Pinned comments stack in their own rows (on an empty screen, so no scrolling comment is in the way).
        layout = DanmakuLayout(width: 1000, height: 400, laneHeight: 50, scrollArea: 0.5, scrollDuration: 10)
        let fixed = Danmaku(time: 0, position: .top, text: "t")
        #expect(layout.place(fixed, width: 100, at: 0)?.lane == 0)
        #expect(layout.place(fixed, width: 100, at: 1)?.lane == 1)
        #expect(layout.place(fixed, width: 100, at: 4.5)?.lane == 0)
    }

    @Test func areaLimitsHowMuchOfThePictureCommentsUse() {
        // A quarter of a 1000-point picture holds five 50-point rows, and top comments stay inside it too.
        let quarter = DanmakuLayout(width: 1000, height: 1000, laneHeight: 50, scrollArea: DanmakuArea.quarter.share)
        #expect(quarter.scrollLanes == 5 && quarter.fixedLanes == 5)
        let whole = DanmakuLayout(width: 1000, height: 1000, laneHeight: 50, scrollArea: DanmakuArea.full.share)
        #expect(whole.scrollLanes == 20 && whole.fixedLanes == 6)
        #expect(DanmakuArea.standard.share == 0.75 && DanmakuArea(rawValue: 50) == .half)
        #expect(DanmakuArea.allCases.map(\.next) == [.half, .threeQuarters, .full, .quarter])
    }

    @Test func topCommentsAndScrollingCommentsDoNotOverlap() {
        var layout = DanmakuLayout(width: 1000, height: 400, laneHeight: 50, scrollArea: 0.5, scrollDuration: 10)
        let moving = Danmaku(time: 0, position: .scroll, text: "x")
        let pinned = Danmaku(time: 0, position: .top, text: "t")
        // Lane 0 has a comment that crosses the centre within the next four seconds, so the top comment takes row 1.
        #expect(layout.place(moving, width: 200, at: 0)?.lane == 0)
        #expect(layout.place(pinned, width: 300, at: 1)?.lane == 1)
        // Row 0 is still busy and row 1 holds a pinned comment this one would reach before it goes, so it takes row 2.
        #expect(layout.place(moving, width: 200, at: 1.5)?.lane == 2)
        // Once the first comment is past the centre, row 0 is clear for a top comment again.
        var later = DanmakuLayout(width: 1000, height: 400, laneHeight: 50, scrollArea: 0.5, scrollDuration: 10)
        _ = later.place(moving, width: 200, at: 0)
        #expect(later.place(pinned, width: 300, at: 7.5)?.lane == 0)
    }
}

struct CastMediaDanmakuTests {
    @Test func castMp4AddressesNameTheirPart() {
        let cast = URL(string: "http://14.17.92.11/upgcxcode/88/70/42500557088/42500557088-1-192.mp4?e=x&ua=tvproj")!
        #expect(DanmakuSource.registerBilibiliMedia(cast) && DanmakuSource.has(cast))
        #expect(!DanmakuSource.registerBilibiliMedia(URL(string: "https://example.com/video.mp4")!))
    }
}

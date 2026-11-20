import Foundation
import Testing
import CoreGraphics
@testable import TVCore

/// Tiling rules for the dock: tiles must not overlap, must stay on screen,
/// must keep the video aspect ratio, and offsets must align to bottom-right.
@Suite("DockLayout")
struct DockLayoutTests {

    private let screen = CGSize(width: 466, height: 678)

    @Test func tilesNeverOverlap() {
        for n in 2...8 {
            let tiles = DockLayout.tiles(count: n, in: screen, aspect: 0.5625)
            #expect(tiles.count == n)
            for i in 0..<tiles.count {
                for j in (i + 1)..<tiles.count {
                    let a = CGRect(origin: tiles[i].origin, size: tiles[i].size)
                    let b = CGRect(origin: tiles[j].origin, size: tiles[j].size)
                    #expect(!a.intersects(b), "overlap at n=\(n) i=\(i) j=\(j)")
                }
            }
        }
    }

    @Test func everyTileStaysInsideTheContainer() {
        for n in 1...8 {
            let tiles = DockLayout.tiles(count: n, in: screen, aspect: 0.5625)
            for (i, t) in tiles.enumerated() {
                let right = t.origin.x + t.size.width
                let bottom = t.origin.y + t.size.height
                #expect(t.origin.x >= -0.5, "left edge out at n=\(n) i=\(i)")
                #expect(t.origin.y >= -0.5, "top edge out at n=\(n) i=\(i)")
                #expect(right <= screen.width + 0.5, "right edge out at n=\(n) i=\(i)")
                #expect(bottom <= screen.height + 0.5, "bottom edge out at n=\(n) i=\(i)")
            }
        }
    }

    @Test func tilesKeepTheAspectRatio() {
        let aspect: CGFloat = 0.5625
        for n in 1...8 {
            for t in DockLayout.tiles(count: n, in: screen, aspect: aspect) {
                let got = t.size.width / max(t.size.height, 0.001)
                #expect(abs(got - aspect) < 0.02, "aspect \(got) drifted at n=\(n)")
            }
        }
    }

    /// The offset must be the exact vector from container bottom-right to the
    /// tile's bottom-right corner: adding it back must land on the tile corner.
    ///
    /// Note this does NOT claim the tile corner equals the container corner --
    /// tiling centres the grid, so tiles generally sit away from the edges.
    @Test func offsetConversionIsReversible() {
        let tiles = DockLayout.tiles(count: 4, in: screen, aspect: 0.5625)
        for t in tiles {
            let o = DockLayout.offset(for: t, in: screen)
            // Where the tile lands if anchored at container bottom-right.
            let landedX = screen.width + o.width
            let landedY = screen.height + o.height
            #expect(abs(landedX - (t.origin.x + t.size.width)) < 0.001)
            #expect(abs(landedY - (t.origin.y + t.size.height)) < 0.001)
        }
    }

    @Test func degenerateInputsReturnNothing() {
        #expect(DockLayout.tiles(count: 0, in: screen, aspect: 0.5625).isEmpty)
        #expect(DockLayout.tiles(count: 3, in: .zero, aspect: 0.5625).isEmpty)
        #expect(DockLayout.tiles(count: 3, in: CGSize(width: 1, height: 1), aspect: 0.5625).isEmpty)
    }

    @Test func singleTileUsesTheSpace() {
        let t = DockLayout.tiles(count: 1, in: screen, aspect: 0.5625)
        #expect(t.count == 1)
        #expect(t[0].size.width > screen.width * 0.5)
    }
}

/// 「整理一次 / 锁定整理」用的网格：统一视窗宽、逐行排开、互不重叠。
///
/// 用户 2026-11-17：「整理要根据平铺来，而不是图层互相折叠了（允许调整成固定大小整理）」
/// 「锁定整理得把视窗统一」。这两条在这里被钉成断言。
@Suite("DockLayout packing")
struct DockLayoutPackTests {

    private let screen = CGSize(width: 466, height: 678)
    private let chrome: CGFloat = 34

    /// 整理后任意两张卡都不许相交。
    ///
    /// ⛔ 这条正是「折叠」的守卫：卡片高度 = 画面 + 标题栏，
    ///    格子只按画面算的话每张都高一截，上下两排必然叠在一起。
    @Test func packedTilesNeverOverlap() {
        let aspects: [CGFloat] = [0.5625, 1.777, 2.35, 0.5625, 1.0, 0.75, 1.333, 0.4]
        for n in 1...aspects.count {
            let tiles = DockLayout.packedTiles(count: n, aspects: Array(aspects.prefix(n)),
                                               cardWidth: 240, chrome: chrome, in: screen)
            #expect(tiles.count == n)
            for i in 0..<tiles.count {
                for j in (i + 1)..<tiles.count {
                    let a = CGRect(origin: tiles[i].origin, size: tiles[i].size)
                    let b = CGRect(origin: tiles[j].origin, size: tiles[j].size)
                    #expect(!a.intersects(b), "overlap at n=\(n) i=\(i) j=\(j)")
                }
            }
        }
    }

    /// 统一视窗：每一张的宽度都相同。
    @Test func packedTilesShareOneWidth() {
        let aspects: [CGFloat] = [0.5625, 1.777, 2.35, 1.0]
        let tiles = DockLayout.packedTiles(count: 4, aspects: aspects,
                                           cardWidth: 240, chrome: chrome, in: screen)
        let widths = Set(tiles.map { Int(($0.size.width * 100).rounded()) })
        #expect(widths.count == 1, "宽度不统一：\(widths)")
    }

    /// 整组留在容器里（不出屏）。
    @Test func packedTilesStayInsideTheContainer() {
        let aspects: [CGFloat] = [1.777, 1.777, 1.777, 1.777, 1.777, 1.777]
        for n in 1...aspects.count {
            for t in DockLayout.packedTiles(count: n, aspects: Array(aspects.prefix(n)),
                                            cardWidth: 240, chrome: chrome, in: screen) {
                #expect(t.origin.x >= -0.5)
                #expect(t.origin.y >= -0.5)
                #expect(t.origin.x + t.size.width <= screen.width + 0.5)
                #expect(t.origin.y + t.size.height <= screen.height + 0.5)
            }
        }
    }

    /// 标题栏必须算进格子高度 —— 否则每张卡都比自己的格子高一截。
    @Test func chromeIsCountedInTheHeight() {
        let aspect: CGFloat = 16.0 / 9.0
        let t = DockLayout.packedTiles(count: 1, aspects: [aspect], cardWidth: 200,
                                       chrome: chrome, in: screen)
        #expect(abs(t[0].size.height - (200 / aspect + chrome)) < 0.01)
    }

    /// 排不下时整体缩小，而不是溢出屏幕。
    @Test func tooManyCardsShrinkInsteadOfOverflowing() {
        let aspects = Array(repeating: CGFloat(0.5625), count: 8)
        let tiles = DockLayout.packedTiles(count: 8, aspects: aspects,
                                           cardWidth: 240, chrome: chrome, in: screen)
        #expect(tiles.count == 8)
        #expect(tiles.allSatisfy { $0.size.width <= 240 + 0.01 })
        #expect(tiles.allSatisfy { $0.origin.y + $0.size.height <= screen.height + 0.5 })
    }
}

import Foundation
import Testing
import CoreGraphics
@testable import TVCore

/// 坞卡片拖动进度的判据。
///
/// 用户 2026-11-17 的实测：拖底部细线或**拖标题栏**都不改变进度、画面不移动、
/// 没有调整样式、不显示「已播 / 总长」。其中「读数与映射」这一半的正确性全落在
/// `DockScrub` 上，所以这里把它钉死。
@Suite("DockScrub")
struct DockScrubTests {

    // MARK: - x → 进度

    @Test func fractionFollowsTheTrackNotTheWholeWidth() {
        let inset = DockScrub.inset
        let width: CGFloat = 200
        let usable = width - inset * 2

        // 轨道两端（内缩之后）就是 0 与 1，不是控件两端。
        #expect(DockScrub.fraction(x: inset, width: width) == 0)
        #expect(DockScrub.fraction(x: width - inset, width: width) == 1)
        // 中点对中点。
        #expect(abs(DockScrub.fraction(x: width / 2, width: width) - 0.5) < 1e-9)
        // 内缩段内的 x 线性映射。
        let quarter = DockScrub.fraction(x: inset + usable * 0.25, width: width)
        #expect(abs(quarter - 0.25) < 1e-9)
    }

    @Test func fractionClampsOutsideTheTrack() {
        let width: CGFloat = 200
        // 手指滑出控件（拖到卡片外）时按到端点，不能出现负数或 >1 的进度。
        #expect(DockScrub.fraction(x: -50, width: width) == 0)
        #expect(DockScrub.fraction(x: width + 80, width: width) == 1)
        #expect(DockScrub.fraction(x: 0, width: width) == 0)
        #expect(DockScrub.fraction(x: width, width: width) == 1)
    }

    @Test func fractionIsSafeBeforeTheFirstLayoutPass() {
        // 首帧宽度是 0：不能返回 NaN，否则会一路污染到 seek 目标与读数。
        #expect(DockScrub.fraction(x: 10, width: 0) == 0)
        #expect(DockScrub.fraction(x: 10, width: -3) == 0)
        #expect(DockScrub.fraction(x: .infinity, width: 200).isFinite)
    }

    // MARK: - 进度 → 秒

    @Test func secondsNeedAKnownDuration() {
        // 直播 / 时长还没就绪：不该凭空算一个位置去 seek。
        #expect(DockScrub.seconds(fraction: 0.5, duration: 0) == nil)
        #expect(DockScrub.seconds(fraction: 0.5, duration: .infinity) == nil)
        #expect(DockScrub.seconds(fraction: .nan, duration: 90) == nil)
        #expect(DockScrub.seconds(fraction: 0.5, duration: 90) == 45)
        #expect(DockScrub.seconds(fraction: 0, duration: 90) == 0)
        #expect(DockScrub.seconds(fraction: 1, duration: 90) == 90)
        // 越界也要夹住。
        #expect(DockScrub.seconds(fraction: -0.4, duration: 90) == 0)
        #expect(DockScrub.seconds(fraction: 1.4, duration: 90) == 90)
    }

    // MARK: - 读数

    @Test func clockFormatsMinutesAndHours() {
        #expect(DockScrub.clock(0) == "0:00")
        #expect(DockScrub.clock(9) == "0:09")
        #expect(DockScrub.clock(65) == "1:05")
        #expect(DockScrub.clock(3600) == "1:00:00")
        #expect(DockScrub.clock(3725) == "1:02:05")
        // 非法值给出占位，不是 "0:00"（那会让人以为片子只有开头）。
        #expect(DockScrub.clock(.nan) == "--:--")
        #expect(DockScrub.clock(.infinity) == "--:--")
        // 负值（seek 之前 currentTime 偶尔为负）按 0 处理。
        #expect(DockScrub.clock(-5) == "0:00")
    }

    @Test func readoutShowsPositionAndTotalDuration() {
        // 用户要的那一行：拖到 1:05 / 全长 45:00。
        #expect(DockScrub.readout(fraction: 65.0 / 2700, duration: 2700) == "1:05 / 45:00")
        // 两端。
        #expect(DockScrub.readout(fraction: 0, duration: 2700) == "0:00 / 45:00")
        #expect(DockScrub.readout(fraction: 1, duration: 2700) == "45:00 / 45:00")
        // 总时长未知时退化为百分比 —— **不编时间**。
        #expect(DockScrub.readout(fraction: 0.42, duration: 0) == "42%")
        #expect(DockScrub.readout(fraction: .nan, duration: 0) == "0%")
        // 越界不产生 "50:00 / 45:00" 这种自相矛盾的读数。
        #expect(DockScrub.readout(fraction: 1.5, duration: 2700) == "45:00 / 45:00")
    }

    // MARK: - 预览节流

    @Test func throttleLetsTheFirstFrameThroughAndThenWaits() {
        var throttle = DockScrubThrottle(interval: 0.12)
        let t0 = Date(timeIntervalSince1970: 1_000)

        // ⛔ `#expect` 的宏展开会把被调用的表达式装进闭包，`mutating` 方法在里面不可用，
        //    所以每一拍先算到局部变量再断言。判据本身一字不改。
        //
        // 按下第一帧必须立刻预览：否则「按住不动」时画面一帧都不动。
        let first = throttle.due(now: t0)
        #expect(first)
        // 间隔内全部丢掉 —— 这正是「不排队积压」的依据。
        let early1 = throttle.due(now: t0.addingTimeInterval(0.02))
        let early2 = throttle.due(now: t0.addingTimeInterval(0.11))
        #expect(!early1)
        #expect(!early2)
        // 到点放行。
        let atInterval = throttle.due(now: t0.addingTimeInterval(0.12))
        #expect(atInterval)
        // 放行之后重新开始计时。
        let afterAllow = throttle.due(now: t0.addingTimeInterval(0.20))
        let nextWindow = throttle.due(now: t0.addingTimeInterval(0.25))
        #expect(!afterAllow)
        #expect(nextWindow)
    }

    @Test func resetMakesTheNextTouchImmediate() {
        var throttle = DockScrubThrottle(interval: 0.5)
        let t0 = Date(timeIntervalSince1970: 2_000)
        let first = throttle.due(now: t0)
        let suppressed = throttle.due(now: t0.addingTimeInterval(0.01))
        #expect(first)
        #expect(!suppressed)
        // 松手清一次，下一次按下必须立刻有预览（用户新的一次拖动不能被上一轮拖累）。
        throttle.reset()
        let afterReset = throttle.due(now: t0.addingTimeInterval(0.02))
        #expect(afterReset)
    }
}

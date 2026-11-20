import Foundation
import Testing
@testable import TVCore

// MARK: - 坞入口的停靠位

/// 锁住三条：吸附到最近的角、钳位不出界、几何退化时不崩。
@Suite("DockHandleAnchor")
struct DockHandleAnchorTests {

    private let screen = CGSize(width: 466, height: 678)
    private let button = CGSize(width: 44, height: 44)

    /// 四个象限各归到对应的角 —— 判据是「相对中心」，不是距离。
    @Test func eachQuadrantSnapsToItsCorner() {
        let mid = CGPoint(x: screen.width / 2, y: screen.height / 2)
        #expect(DockHandleAnchor.nearest(to: CGPoint(x: 10, y: 10), in: screen) == .topLeading)
        #expect(DockHandleAnchor.nearest(to: CGPoint(x: 456, y: 10), in: screen) == .topTrailing)
        #expect(DockHandleAnchor.nearest(to: CGPoint(x: 10, y: 668), in: screen) == .bottomLeading)
        #expect(DockHandleAnchor.nearest(to: CGPoint(x: 456, y: 668), in: screen) == .bottomTrailing)
        // 正中偏一像素也要有确定答案，不能来回跳。
        #expect(DockHandleAnchor.nearest(to: CGPoint(x: mid.x - 1, y: mid.y - 1), in: screen) == .topLeading)
        #expect(DockHandleAnchor.nearest(to: CGPoint(x: mid.x + 1, y: mid.y + 1), in: screen) == .bottomTrailing)
    }

    /// 极窄/极扁容器：判据必须仍给确定答案。
    ///
    /// ⚠️ 这条**不是**用来区分「相对中心」与「距离平方」的 —— 实测两者在
    /// 466×678 / 951×669 / 669×951 三种尺寸上逐点一致（0 个反例）。
    /// 它守的是另一件事：容器退化时**不许崩、不许给出随机的角**。
    @Test func degenerateContainersStillAnswerSensibly() {
        let thin = CGSize(width: 100, height: 4)
        #expect(DockHandleAnchor.nearest(to: CGPoint(x: 10, y: 1), in: thin) == .topLeading)
        #expect(DockHandleAnchor.nearest(to: CGPoint(x: 90, y: 3), in: thin) == .bottomTrailing)

        let sliver = CGSize(width: 4, height: 100)
        #expect(DockHandleAnchor.nearest(to: CGPoint(x: 1, y: 10), in: sliver) == .topLeading)
        #expect(DockHandleAnchor.nearest(to: CGPoint(x: 3, y: 90), in: sliver) == .bottomTrailing)
    }

    /// 钳位：拖出屏幕的点必须被拉回可视区（按钮完整可见 + 预留 inset）。
    @Test func aPointDraggedOffscreenComesBack() {
        let inset: CGFloat = 12
        for p in [CGPoint(x: -500, y: -500), CGPoint(x: 5000, y: 5000),
                  CGPoint(x: 0, y: 0), CGPoint(x: 466, y: 678)] {
            let c = DockHandleAnchor.clampedCenter(p, in: screen, button: button, inset: inset)
            #expect(c.x >= button.width / 2 + inset - 0.001)
            #expect(c.x <= screen.width - button.width / 2 - inset + 0.001)
            #expect(c.y >= button.height / 2 + inset - 0.001)
            #expect(c.y <= screen.height - button.height / 2 - inset + 0.001)
        }
    }

    /// 容器比按钮还小时不能产出「反区间」。
    ///
    /// `min > max` 时 `min(max(x,min),max)` 的结果随实现摆动 —— 实测这类写法
    /// 会让按钮在极小的中间态容器里瞬移到左上。这里要求退回容器中心。
    @Test func aContainerSmallerThanTheButtonFallsBackToItsCentre() {
        let tiny = CGSize(width: 20, height: 20)
        let c = DockHandleAnchor.clampedCenter(CGPoint(x: 999, y: 999), in: tiny, button: button, inset: 12)
        #expect(abs(c.x - tiny.width / 2) < 0.001)
        #expect(abs(c.y - tiny.height / 2) < 0.001)
    }

    /// 四个角的停靠中心必须两两不同，且各自贴对边。
    @Test func eachAnchorSitsAgainstItsOwnEdges() {
        let inset: CGFloat = 12
        let centers = DockHandleAnchor.allCases.map {
            DockHandleAnchor.center(of: $0, in: screen, button: button, inset: inset)
        }
        #expect(Set(centers.map { "\($0.x),\($0.y)" }).count == 4, "四个角的停靠点必须互不相同")
        for (i, a) in DockHandleAnchor.allCases.enumerated() {
            let c = centers[i]
            if a.isLeading { #expect(c.x < screen.width / 2) } else { #expect(c.x > screen.width / 2) }
            if a.isTop { #expect(c.y < screen.height / 2) } else { #expect(c.y > screen.height / 2) }
        }
    }
}

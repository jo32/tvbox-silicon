import Foundation
import Testing
@testable import TVCore

// MARK: - 坞的可见性

/// 这组判据锁住一条不变式：**只要有任务，管理入口就必须在**。
///
/// 用户报的缺陷是「进入播放页迷你小窗就消失了，误触也没了」——
/// 卡片让位是对的（两层视频叠一起穿帮），但让位之后屏幕上不能什么都没有。
@Suite("DockVisibility")
struct DockVisibilityTests {

    private func state(_ count: Int, covered: Bool = false, collapsed: Bool = false) -> DockVisibility.State {
        .init(taskCount: count, coveredByForeground: covered, collapsed: collapsed)
    }

    /// ⛔ 核心不变式：任何「有任务」的组合下，入口都必须画。
    ///
    /// 这条覆盖 2×2×N 的所有组合，而不是挑几个例子 ——
    /// 「被前台盖住」与「用户收起」是最容易把入口一起关掉的两条路径。
    @Test func theHandleSurvivesEveryWayTheCardsCanHide() {
        for count in 1...4 {
            for covered in [false, true] {
                for collapsed in [false, true] {
                    let s = state(count, covered: covered, collapsed: collapsed)
                    #expect(DockVisibility.showsHandle(s),
                            "count=\(count) covered=\(covered) collapsed=\(collapsed) 时入口必须还在")
                }
            }
        }
    }

    /// 反过来：坞空的时候入口不该画（一颗点了没东西的按钮是噪音）。
    @Test func anEmptyDockHasNoHandle() {
        for covered in [false, true] {
            for collapsed in [false, true] {
                #expect(!DockVisibility.showsHandle(state(0, covered: covered, collapsed: collapsed)))
            }
        }
    }

    /// 卡片只在「有任务 + 没被盖住 + 没收起」时才画。
    @Test func cardsNeedAllThreeConditions() {
        #expect(DockVisibility.showsCards(state(1)))
        #expect(!DockVisibility.showsCards(state(0)))
        #expect(!DockVisibility.showsCards(state(1, covered: true)))
        #expect(!DockVisibility.showsCards(state(1, collapsed: true)))
        #expect(!DockVisibility.showsCards(state(1, covered: true, collapsed: true)))
    }

    /// 入口必须**比卡片更常出现** —— 这是两条判定之间的序关系，
    /// 写反了（例如入口也跟着 hidden）就会退回用户报的那个缺陷。
    @Test func theHandleIsNeverStricterThanTheCards() {
        for count in 0...4 {
            for covered in [false, true] {
                for collapsed in [false, true] {
                    let s = state(count, covered: covered, collapsed: collapsed)
                    if DockVisibility.showsCards(s) {
                        #expect(DockVisibility.showsHandle(s),
                                "卡片画出来了，入口却没有 —— 两者序关系写反了")
                    }
                }
            }
        }
    }

    /// 角标：单集不显示数字（多余），多集才显示。
    @Test func theBadgeCountsOnlyWhenThereIsMoreThanOne() {
        #expect(DockVisibility.badge(state(0)) == nil)
        #expect(DockVisibility.badge(state(1)) == nil)
        #expect(DockVisibility.badge(state(2)) == "2")
        #expect(DockVisibility.badge(state(4)) == "4")
    }

    /// 入口图标要能表达「里面有东西被藏起来了」。
    @Test func theHandleSignalsHiddenContent() {
        #expect(!DockVisibility.handleShowsHiddenContent(state(2)))
        #expect(DockVisibility.handleShowsHiddenContent(state(2, covered: true)))
        #expect(DockVisibility.handleShowsHiddenContent(state(2, collapsed: true)))
        #expect(!DockVisibility.handleShowsHiddenContent(state(0, covered: true)))
    }
}

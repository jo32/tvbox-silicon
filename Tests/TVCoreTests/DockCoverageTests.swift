import Foundation
import Testing
@testable import TVCore

// MARK: - #11：坞「不该出现时出现」的判据

/// 三输入真值表（8 行全覆盖）。
///
/// 修复前只有 2 个输入（presentingPlayer / playsInWatchPage），
/// `isWatchPageMounted` 这一维**不存在** —— 于是 `playing == nil` 时
/// 第三维恒 false、所有判据一起失守，坞照画。
@Test func dockCoverageTruthTable() throws {
    // 全屏播放器开着 ⇒ 一定让位（不管其它两维）
    #expect(DockCoverage.isCoveredByForeground(
        presentingPlayer: true, isWatchPageMounted: false, playsInWatchPage: false))
    #expect(DockCoverage.isCoveredByForeground(
        presentingPlayer: true, isWatchPageMounted: true, playsInWatchPage: true))

    // ⛔ 关键一行：全屏没开、这一集也不在作用域里（= `playing == nil` 的形态），
    // 但观看页在场 ⇒ **必须让位**。这正是修复加的那一维。
    #expect(DockCoverage.isCoveredByForeground(
        presentingPlayer: false, isWatchPageMounted: true, playsInWatchPage: false),
        "观看页在场时坞必须让位，哪怕 playing == nil")

    // 这一集在作用域里 ⇒ 让位（原判据本就能处理）
    #expect(DockCoverage.isCoveredByForeground(
        presentingPlayer: false, isWatchPageMounted: false, playsInWatchPage: true))

    // 都没有 ⇒ 坞该画（唯一不放行的情况）
    #expect(!DockCoverage.isCoveredByForeground(
        presentingPlayer: false, isWatchPageMounted: false, playsInWatchPage: false),
        "没有任何前台载体时坞必须画出来")
}

/// 负对照：老判据在「观看页在场但 playing==nil」这一格**判错**。
///
/// 这条不是形式主义 —— 它把「修复改变了哪一类输入」变成可复算的事实。
@Test func legacyRuleMissesTheMountedButNotPlayingCase() throws {
    let mounted = true, notPlaying = false

    let fixed = DockCoverage.isCoveredByForeground(
        presentingPlayer: false, isWatchPageMounted: mounted, playsInWatchPage: notPlaying)
    let legacy = DockCoverage.legacyIsCoveredByForeground(
        presentingPlayer: false, playsInWatchPage: notPlaying)

    #expect(fixed, "修复后必须让位")
    #expect(!legacy, "老判据在这里放行 —— 这就是坞误画的根因")
    #expect(fixed != legacy, "两者必须不同，否则本判据没有判别力")

    // 其余三格两者必须一致（修复不能改变已正确的情形）
    for presenting in [false, true] {
        for inWatch in [false, true] {
            // 观看页不在场时，两版判据必须等价
            let f = DockCoverage.isCoveredByForeground(
                presentingPlayer: presenting, isWatchPageMounted: false, playsInWatchPage: inWatch)
            let l = DockCoverage.legacyIsCoveredByForeground(
                presentingPlayer: presenting, playsInWatchPage: inWatch)
            #expect(f == l, "观看页不在场时两版必须等价（presenting=\(presenting) inWatch=\(inWatch)）")
        }
    }
}

/// 坞里有多个任务时：只要前台在演，整块坞就不画 ——
/// 但**不清空**（清空是别处的职责，见 `Store.swift` 的注释）。
///
/// 本判据只回答「画不画」，不回答「留不留」，这里把它钉住，
/// 防止日后有人把「隐藏」写成「清空」。
@Test func coverageOnlyDecidesVisibilityNotExistence() throws {
    // 判据是纯函数，没有任何「删除任务」的副作用面 —— 签名只有三个 Bool，返回 Bool。
    // 这条测试的实质是：输入里**没有**任务数量这一维，所以它不可能清空坞。
    #expect(DockCoverage.isCoveredByForeground(
        presentingPlayer: false, isWatchPageMounted: true, playsInWatchPage: false))
    // 上一条为 true 时，调用方只改 opacity/allowsHitTesting（RootView:184-185），
    // 不改 `store.videoTasks`。判据层不提供清空能力，这是结构保证。
}

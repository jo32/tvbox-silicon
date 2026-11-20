import Foundation

/// 坞（迷你播放器）此刻该不该**让位**给前台画面。
///
/// ## 为什么是一条独立判据
///
/// 坞表达的是「我正在看、但没占着屏幕」。一旦前台真的在演，它必须让位，
/// 否则两层视频叠在同一块区域上各播各的（用户报的「两个嵌套视频」）。
///
/// ## 为什么不能只看「这一集在不在观看页作用域里」
///
/// 最初的判据只有 `playsInWatchPage(playing)` 一条。它对 `playing == nil`
/// **恒为 false**（`Store+Playback.swift`:
/// `guard let scope = channel?.historyContext?.id else { return false }`）。
///
/// 于是下面这几种时刻，所有判据一起为 false、坞照画：
///   · 用户按退出键关掉前台这一集 → `playing = nil`，但页面可能还没消失
///   · 换一集起播的间隙
///   · 坞里挂着别的集、而当前这一集没挂到 `playing`
///
/// 用户看到的就是「坞在不该出现时出现」。原报告把它记成
/// 「`playing=nil` 的场景判不出」—— 判据缺失，不是绘制问题。
///
/// ## 缺失的那一条
///
/// `isWatchPageMounted` 就是为这一帧造的：由观看页 `onAppear` / `onDisappear`
/// **同步**维护，不受 scope 内容影响，所以页面刚推入、`onAppear` 还没跑那一帧也可靠。
/// `Store` 在决定「要不要弹全屏播放器」时早就用了它
/// （`playing != nil, !playsInWatchPage(playing), !isWatchPageMounted`）——
/// 同一份判断在两处分叉，坞这边漏了。
///
/// 抽成纯函数是为了让判据可复跑：三个输入都是 Bool，不需要 App 层状态。
public enum DockCoverage {
    /// 坞是否该让位（= 不画）。
    ///
    /// - Parameters:
    ///   - presentingPlayer: 全屏播放器是否开着。
    ///   - isWatchPageMounted: 是否有任何观看页在场（同步维护，不看 scope 内容）。
    ///   - playsInWatchPage: **当前这一集**是否属于屏幕上某个观看页作用域。
    /// - Returns: true = 让位（不画坞）。
    public static func isCoveredByForeground(
        presentingPlayer: Bool,
        isWatchPageMounted: Bool,
        playsInWatchPage: Bool
    ) -> Bool {
        if presentingPlayer { return true }
        // 观看页在场就让位 —— 这条不依赖 `playing` 是否为 nil。
        if isWatchPageMounted { return true }
        return playsInWatchPage
    }

    /// 修复前的判据，**只用于判据的负对照**，不参与运行。
    ///
    /// 保留它是有意的：它让「修复到底改变了哪一类输入」成为可复算的事实，
    /// 而不是一句「我修好了」。
    public static func legacyIsCoveredByForeground(
        presentingPlayer: Bool,
        playsInWatchPage: Bool
    ) -> Bool {
        if presentingPlayer { return true }
        return playsInWatchPage
    }
}

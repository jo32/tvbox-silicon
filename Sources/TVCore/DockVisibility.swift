import Foundation

// MARK: - 坞的可见性（纯数据，可测）

/// 「坞现在该不该把卡片画出来」这件事的唯一判定。
///
/// ## 为什么需要单独一层
///
/// 坞有**三种**互不相同、以前混在视图里判的状态：
///
/// 1. **被前台盖住**（进观看页/全屏播放器）：两层视频叠在一起会穿帮，卡片必须不画。
/// 2. **用户手动收起**：坞占屏幕，看列表/选集时想让它躲开。
/// 3. **坞里根本没有任务**：什么都不该出现。
///
/// 前两个都是「不画卡片」，但**都不能等于「坞不存在」**：
/// 只要还有任务，用户就必须随时能找回来 —— 这正是用户报的
/// 「进入播放页迷你小窗就消失了，误触也没了」：卡片被隐藏之后，
/// 屏幕上再没有任何东西提示「这里还有几集在播」，也没有任何入口把它们叫回来。
///
/// 所以判定分成两件事：
///   - `showsCards`：画不画卡片本身（被盖住或收起时为 false）
///   - `showsHandle`：画不画「坞管理入口」（**只要有任务就为 true**，与被盖住/收起无关）
///
/// ## 与旧实现的差别
///
/// 旧实现只有一个 `coveredByForeground`，它同时决定了 opacity 与命中测试。
/// 于是「被盖住」和「坞没有任务」在屏幕上长得一模一样 —— 用户分不出是哪种，
/// 也就不知道该去哪儿找回。
public enum DockVisibility {

    /// 判定所需的全部输入。没有视图对象，可以直接断言。
    public struct State: Equatable, Sendable {
        /// 坞里有几集在播。
        public var taskCount: Int
        /// 前台正盖着（观看页在场 / 全屏播放器在演）。
        public var coveredByForeground: Bool
        /// 用户手动收起了坞。
        public var collapsed: Bool

        public init(taskCount: Int, coveredByForeground: Bool, collapsed: Bool) {
            self.taskCount = taskCount
            self.coveredByForeground = coveredByForeground
            self.collapsed = collapsed
        }
    }

    /// 坞里到底有没有东西。
    public static func hasTasks(_ s: State) -> Bool { s.taskCount > 0 }

    /// 画不画卡片本身。
    ///
    /// 没有任务时当然不画；被前台盖住、或被用户收起时也不画（但下面的 handle 仍会画）。
    public static func showsCards(_ s: State) -> Bool {
        hasTasks(s) && !s.coveredByForeground && !s.collapsed
    }

    /// 画不画「坞管理入口」。
    ///
    /// ⛔ **只要有任务就画**，与「被盖住」「用户收起」都无关。
    ///
    /// 这是本条需求的全部要害：入口消失的那一帧，屏幕上就没有任何东西能证明
    /// 「这里还有几集在播」。用户于是只能猜——而猜不到就等于丢了。
    public static func showsHandle(_ s: State) -> Bool {
        hasTasks(s)
    }

    /// 入口上显示的数字（几集在播）。
    public static func badge(_ s: State) -> String? {
        guard hasTasks(s) else { return nil }
        return s.taskCount > 1 ? "\(s.taskCount)" : nil
    }

    /// 入口该不该提示「有内容被藏起来了」——收起或被盖住时为真。
    ///
    /// 入口的图标据此变一下（从「展开」变成「有东西在里面」），
    /// 否则用户看不出「现在按一下会发生什么」。
    public static func handleShowsHiddenContent(_ s: State) -> Bool {
        hasTasks(s) && (s.collapsed || s.coveredByForeground)
    }
}

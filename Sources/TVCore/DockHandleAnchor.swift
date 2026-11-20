import Foundation
import CoreGraphics

// MARK: - 坞管理入口的停靠位

/// 「坞管理入口」这颗常驻小按钮停在哪。
///
/// ## 为什么需要它
///
/// 这颗按钮原来**写死在右下角**。问题很实际：
///   · 右下角是坞卡片自己的默认落点，卡片展开时按钮叠在卡片上；
///   · 有的页面右下角有工具栏 / 主页条 / 输入框，正好压住它；
///   · 用户的手势习惯不同（左手、右手），固定一角总有一半人别扭。
///
/// 所以它是**可拖动 + 吸附到四角**的浮件，位置也持久化 ——
/// 下次进来还在用户放开手的那个角。
///
/// ## 为什么按「角」而不是任意坐标
///
/// 任意坐标在旋转、折叠/展开、换页面时都得重算边界，稍有偏差就跑到屏幕外
/// （坞卡片那一套 `perCardOffset` 就是这样，每次形态变化都要重新钳一遍）。
/// 四角是**与尺寸无关的不变量**：换了屏宽屏高，角还是那个角。
/// 拖动过程中的自由位置只用于跟手，**松手一律吸附到最近的角**。
public enum DockHandleAnchor: String, CaseIterable, Sendable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    /// 吸附：拖到哪就归到最近的角。
    ///
    /// 判据用**相对中心的位置**（左右 / 上下各一半）。
    ///
    /// ⚠️ 订正一条我先前写错的理由：注释原来说「距离平方在极扁/极窄容器里会偏向某个角」
    /// —— **穷举验证否定了它**。对三种真机尺寸（466×678 / 951×669 / 669×951）
    /// 以 17pt 步长遍历全屏，两种算法结论**逐点一致，0 个反例**。
    ///
    /// 所以保留相对中心，理由是**写法更简单、没有浮点乘方、判定只依赖两个比较**，
    /// 而不是「距离法会错」。两者等价就别留一个站不住的论证——
    /// 后人照那句错误理由去「修」距离法，反而可能真引入偏差。
    public static func nearest(to point: CGPoint, in size: CGSize) -> DockHandleAnchor {
        let isLeft = point.x < size.width / 2
        let isTop = point.y < size.height / 2
        if isTop { return isLeft ? .topLeading : .topTrailing }
        return isLeft ? .bottomLeading : .bottomTrailing
    }

    /// 这颗按钮在某个角上的对齐方式（SwiftUI 的 `Alignment` 语义，用纯枚举表达，TVCore 不依赖 SwiftUI）。
    public var isTop: Bool { self == .topLeading || self == .topTrailing }
    public var isLeading: Bool { self == .topLeading || self == .bottomLeading }

    /// 把「自由拖动的位置」钳进可视区。
    ///
    /// `inset` 是安全边距（避开圆角与主页条）；`button` 是按钮尺寸。
    /// 返回按钮**中心点**应该在的位置。
    public static func clampedCenter(_ point: CGPoint,
                                     in size: CGSize,
                                     button: CGSize,
                                     inset: CGFloat) -> CGPoint {
        let halfW = button.width / 2 + inset
        let halfH = button.height / 2 + inset
        // 容器比按钮还小时不能返回负数区间（那会让 min > max，钳位结果随实现摆动）。
        let minX = min(halfW, size.width / 2)
        let maxX = max(size.width - halfW, size.width / 2)
        let minY = min(halfH, size.height / 2)
        let maxY = max(size.height - halfH, size.height / 2)
        return CGPoint(x: min(max(point.x, minX), maxX),
                       y: min(max(point.y, minY), maxY))
    }

    /// 某个角对应的**中心点**（用于不拖动时的固定停靠）。
    public static func center(of anchor: DockHandleAnchor,
                              in size: CGSize,
                              button: CGSize,
                              inset: CGFloat) -> CGPoint {
        let x = anchor.isLeading ? button.width / 2 + inset : size.width - button.width / 2 - inset
        let y = anchor.isTop ? button.height / 2 + inset : size.height - button.height / 2 - inset
        return CGPoint(x: x, y: y)
    }
}

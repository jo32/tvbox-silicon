import Foundation
import CoreGraphics

/// 坞卡片「拖进度」的纯计算：手指的 x → 0…1、秒数 → `12:34`、「已播 / 总长」拼成一行。
///
/// ## 为什么这些函数在 TVCore 里，而不是写在视图里
///
/// 拖动是否跟手，判据全在这几条小函数上：端点有没有夹紧、左右留边口径是否与实际轨道一致、
/// 总时长未知时会不会编一个时间出来。写在视图里就只能靠真机肉眼看，
/// 而这台机器上坞的真机取证要连设备 —— 放这里能单测，且改口径时测试会红。
///
/// ## 留边与轨道必须同一个口径
///
/// 小窗卡片的四角是 12pt 圆角，轨道两端那一段按下去落在圆角外（视觉上有线、摸不到）。
/// 所以可拖区间是 `[inset, width - inset]`，映射也跟着这条区间算 ——
/// 底边进度条与下方标题栏**共用这一个函数**，两处才不会一处拖得满、一处拖不到头。
public enum DockScrub {

    /// 轨道两端各留多少 pt 不可拖（避开圆角）。
    public static let inset: CGFloat = 10

    /// 手指 x → 进度 0…1。
    ///
    /// - Parameters:
    ///   - x: 手指在**控件自身坐标系**里的横坐标（`DragGesture` 的 `.local`）。
    ///   - width: 控件宽度。
    ///   - inset: 两端留边；默认与轨道绘制共用 `DockScrub.inset`。
    public static func fraction(x: CGFloat, width: CGFloat, inset: CGFloat = inset) -> Double {
        // 宽度还没量出来（首帧 0）时给 0，别返回 NaN 污染后续计算。
        guard width.isFinite, width > 1 else { return 0 }
        let usable = max(width - inset * 2, 1)
        let raw = (x - inset) / usable
        guard raw.isFinite else { return 0 }
        return min(max(Double(raw), 0), 1)
    }

    /// 进度 → 目标秒数。总时长未知（直播、时长还没就绪）时返回 nil：
    /// 那种情况下**不该**凭空算一个位置去 seek。
    public static func seconds(fraction: Double, duration: Double) -> Double? {
        guard duration.isFinite, duration > 0, fraction.isFinite else { return nil }
        return min(max(fraction, 0), 1) * duration
    }

    /// 秒数 → `12:34` / `1:02:03`。
    public static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// 拖动时的读数：`12:34 / 45:00`；总时长未知时退化为百分比。
    ///
    /// 用户要求「拖移时要显示出进度条标点和进度条具体信息」——
    /// 只有百分比在拖的时候没有意义（他不知道拖到的是第几分钟），
    /// 所以只要能算出秒数就一定给「已播 / 总长」。
    public static func readout(fraction: Double, duration: Double) -> String {
        let f = min(max(fraction.isFinite ? fraction : 0, 0), 1)
        guard let at = seconds(fraction: f, duration: duration) else {
            return "\(Int((f * 100).rounded()))%"
        }
        return clock(at) + " / " + clock(duration)
    }
}

/// 拖动中「该不该现在发一次预览 seek」的节流器。
///
/// ## 为什么必须有节流
///
/// 拖动时 `onChanged` 每秒能来几十次。每次都向 AVPlayer 要一次 seek，
/// 请求会排队积压，画面反而**越来越落后**（用户报的「拖了没用、松手才跳」）。
/// 预览只要「大致跟到手指位置」就够，松手那一刻再做一次精确 seek。
///
/// ## 为什么把时间注入进来
///
/// 时间敏感阈值不能用 `sleep` 在测试里挪边界（机器一忙就红）。
/// 这里由调用方给 `now`，测试可以给定任意时间序列，判据是确定的。
public struct DockScrubThrottle {

    /// 两次预览之间的最小间隔（秒）。
    public let interval: TimeInterval
    private var last: Date?

    public init(interval: TimeInterval = 0.12) {
        self.interval = interval
    }

    /// 现在该发预览了吗？返回 true 时内部会记下这次的时间。
    public mutating func due(now: Date) -> Bool {
        if let last, now.timeIntervalSince(last) < interval { return false }
        last = now
        return true
    }

    /// 一次拖动结束时清零，下一次按下立刻就有预览（不必等间隔）。
    public mutating func reset() { last = nil }
}

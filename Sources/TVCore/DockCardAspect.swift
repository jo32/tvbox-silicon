import CoreGraphics

/// 坞卡片的画面比例（宽÷高）。
///
/// ## 为什么不是「读一次 presentationSize 就完事」
///
/// 卡片高度 = `卡片宽 / aspectRatio`。比例一旦取错，画面按 `resizeAspect`
/// 居中缩放，多出来的地方就是用户看到的**留白**。
///
/// 缺陷本体：视图里直接读 `AVPlayerItem.presentationSize` —— 那是**普通属性**，
/// 不是 SwiftUI 可观察源。源比例就绪后它变了，但**没有任何东西通知视图重算**，
/// 于是卡片一直按回退值 16/9 排版。竖屏源（9:16）因此被排成扁条，
/// 左右各留一条 —— 正是「竖屏源小窗缩到最小右侧有白边」。
///
/// 修法：`PlaybackSession` 每采样 tick 把 `presentationSize` **镜像**成
/// 一个可观察属性（`presentationAspect`），卡片读镜像。本函数负责把
/// 「镜像值 → 可用比例」这一步的判据收成一处，供两侧共用、并被单测覆盖。
public enum DockCardAspect {
    /// 16:9，缺省与兜底。
    public static let fallback: CGFloat = 16.0 / 9.0

    /// 接受的比例范围。超出即认为「还没就绪 / 读到了脏值」，回退到 16:9。
    ///
    /// 下界 0.2 ≈ 1:5（极窄竖片），上界 6 ≈ 6:1（极宽横幅）。
    /// 与项目其它两处（`VideoTask.aspectRatio`、`AVPlayer` 相关的既有闸门）取值一致。
    public static let minimum: CGFloat = 0.2
    public static let maximum: CGFloat = 6.0

    /// 把镜像来的比例规整成可用值。
    ///
    /// - Parameter mirrored: `PlaybackSession.presentationAspect` 的值。
    /// - Returns: 落在 `[minimum, maximum]` 内且有限的就原样返回，否则 `fallback`。
    public static func resolved(_ mirrored: CGFloat) -> CGFloat {
        guard mirrored.isFinite, mirrored > minimum, mirrored < maximum else { return fallback }
        return mirrored
    }

    /// 由 `presentationSize` 算出可用于镜像的比例；未就绪返回 nil（**不要**在这里回退）。
    ///
    /// 返回 nil 让调用方保留上一次的好值 —— 换集瞬间 `presentationSize` 会是 `.zero`，
    /// 若此时回退到 16:9，卡片会在换集那一帧突然从竖条跳成扁条再跳回来。
    public static func from(presentationSize size: CGSize) -> CGFloat? {
        guard size.width > 0, size.height > 0 else { return nil }
        let ratio = size.width / size.height
        guard ratio.isFinite, ratio > minimum, ratio < maximum else { return nil }
        return ratio
    }
}

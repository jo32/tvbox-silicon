import Foundation
import CoreGraphics

// MARK: - 坞卡片的解码分辨率

/// 「这张这么小的卡片，该按多高的分辨率去解」。
///
/// ## 为什么必须限
///
/// 坞卡片只有 120–320pt 宽（约 240–640 物理像素 @2x）。但 `AVPlayer` 默认按**源分辨率**
/// 解码：一个 4K 源在小窗里也解 4K 全帧。单路看不出问题，8 路一起解就是
/// 「解码器抢 GPU、内存翻数倍、画面一起卡」。
///
/// 用户要求「就要同时解码」，那就必须把**单路解码量**压下来，否则 8 路必然不能同时跑。
/// 这不是可选优化，是让「同时解码」成立的前提。
///
/// ## 判据
///
/// 按卡片宽度 × 屏幕缩放取「够用的最高档」，向上取到常见档位：
///   ≤ 480px → 480p，≤ 720px → 720p，≤ 1080px → 1080p，其余不限（跟随源）。
///
/// ⛔ **只对坞卡片生效**，前台/全屏不受影响 —— 那里要的是画质，不是路数。
public enum DockDecodeResolution {

    /// 一档解码上限（短边像素）。`nil` 表示不限制（跟随源）。
    public static func cap(forCardWidth width: CGFloat, scale: CGFloat) -> CGFloat? {
        let pixels = width * max(scale, 1)
        if pixels <= 480 { return 480 }
        if pixels <= 720 { return 720 }
        if pixels <= 1080 { return 1080 }
        return nil
    }

    /// AVFoundation 的 `AVPlayerItem.preferredMaximumResolution` 语义：
    /// 传 `.zero` 表示不限。这里把上面的档位换成它要的形式。
    public static func preferredMaximumResolution(forCardWidth width: CGFloat,
                                                  scale: CGFloat) -> CGSize {
        guard let cap = cap(forCardWidth: width, scale: scale) else { return .zero }
        // 传正方形上限：让 AVF 按「短边不超过 cap」处理，不强行改宽高比。
        return CGSize(width: cap, height: cap)
    }

    /// 探针用：这一档的可读名字。
    public static func name(forCardWidth width: CGFloat, scale: CGFloat) -> String {
        guard let cap = cap(forCardWidth: width, scale: scale) else { return "source" }
        return "\(Int(cap))p"
    }
}

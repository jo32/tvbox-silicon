import Foundation
import Testing
@testable import TVCore

// MARK: - #16：竖屏源小窗右侧白边（卡片比例读不到可观察源）

/// 核心判据：竖屏源必须算出竖的比例，而不是回退 16:9。
///
/// 缺陷本体：`VideoTask.aspectRatio` 直读 `AVPlayerItem.presentationSize`，
/// 那是普通属性、不是 SwiftUI 可观察源 ⇒ 源就绪后卡片不重算，一直 16:9。
/// 竖片被排成扁条，画面 `resizeAspect` 居中 ⇒ 左右留白。
@Test func portraitSourceResolvesToPortraitNotFallback() throws {
    // 1080×1920 竖片
    let portrait = CGSize(width: 1080, height: 1920)
    let ratio = try #require(DockCardAspect.from(presentationSize: portrait))
    #expect(abs(ratio - 0.5625) < 0.001, "竖片比例应为 0.5625，实得 \(ratio)")

    // 关键：经 resolved 后仍是竖比例，**不能**被拍回 16:9
    let resolved = DockCardAspect.resolved(ratio)
    #expect(abs(resolved - 0.5625) < 0.001)
    #expect(resolved != DockCardAspect.fallback, "竖片绝不能落回 16:9 —— 那就是白边的成因")

    // 负对照：若卡片仍按回退值排版，画面上下会溢出/左右留白。
    // 这里用「比例差」把它量化：0.5625 vs 1.7778 差 3 倍以上。
    #expect(DockCardAspect.fallback / resolved > 3,
            "回退值与真实竖比例的差距必须显著，否则该缺陷不会显现")
}

/// `.zero` / 未就绪时必须返回 nil，**不能**回退 16:9。
///
/// 换集瞬间 `presentationSize` 是 `.zero`。若此时回退，卡片会
/// 「竖条 → 扁条 → 竖条」抖一下。
@Test func notReadyReturnsNilSoPreviousValueIsKept() throws {
    #expect(DockCardAspect.from(presentationSize: .zero) == nil)
    #expect(DockCardAspect.from(presentationSize: CGSize(width: 0, height: 1080)) == nil)
    #expect(DockCardAspect.from(presentationSize: CGSize(width: 1080, height: 0)) == nil)

    // 这是与「直接回退」的关键区别：调用方据此保留上一次的好值。
    // 负对照：如果实现写成 `?? fallback`，换集会有一次跳变 —— 上面三个 nil 就是证据。
    #expect(DockCardAspect.from(presentationSize: .zero) != DockCardAspect.fallback)
}

/// 脏值必须被闸门挡住。
@Test func dirtyRatioFallsBack() throws {
    // 小于下界（极窄）→ 视为未就绪
    #expect(DockCardAspect.from(presentationSize: CGSize(width: 100, height: 1000)) == nil)
    // 大于上界（极宽）→ 同上
    #expect(DockCardAspect.from(presentationSize: CGSize(width: 1000, height: 100)) == nil)
    // 非有限
    #expect(!DockCardAspect.resolved(.infinity).isFinite == false)
    #expect(DockCardAspect.resolved(.nan) == DockCardAspect.fallback)
    #expect(DockCardAspect.resolved(0) == DockCardAspect.fallback)
    #expect(DockCardAspect.resolved(-1) == DockCardAspect.fallback)
}

/// 常见分辨率都要算对（含横竖两种）。
@Test func commonResolutionsResolveCorrectly() throws {
    let cases: [(CGSize, CGFloat)] = [
        (CGSize(width: 1920, height: 1080), 16.0 / 9.0),   // 横 1080p
        (CGSize(width: 1080, height: 1920), 9.0 / 16.0),   // 竖 1080p
        (CGSize(width: 1280, height: 720), 16.0 / 9.0),
        (CGSize(width: 720, height: 1280), 9.0 / 16.0),
        (CGSize(width: 640, height: 480), 4.0 / 3.0),
        (CGSize(width: 3840, height: 1600), 2.4),          // 宽银幕
    ]
    for (size, expected) in cases {
        let ratio = try #require(DockCardAspect.from(presentationSize: size),
                                 "\(Int(size.width))x\(Int(size.height)) 应可用")
        #expect(abs(ratio - expected) < 0.001,
                "\(Int(size.width))x\(Int(size.height)) 期望 \(expected)，实得 \(ratio)")
        #expect(abs(DockCardAspect.resolved(ratio) - expected) < 0.001)
    }
}

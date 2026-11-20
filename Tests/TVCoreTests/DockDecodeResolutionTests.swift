import Foundation
import Testing
@testable import TVCore

/// 「8 路同时解码」能成立的前提：单路解码量必须压到小窗够用的档位。
///
/// 没有这一层，8 路各解 1080p/4K 会把解码器拖死 —— 那时「同时解码」只是个开关，
/// 实际画面会一起卡。
@Suite("DockDecodeResolution")
struct DockDecodeResolutionTests {

    /// 坞卡片的真实宽度区间（120–320pt）在 @2x/@3x 下都不该要超过 1080p。
    @Test func dockCardsNeverNeedMoreThanTheirPixels() {
        for width in [CGFloat(120), 160, 240, 320] {
            for scale in [CGFloat(2), 3] {
                let cap = DockDecodeResolution.cap(forCardWidth: width, scale: scale)
                if let cap {
                    #expect(cap <= 1080, "\(width)pt@\(scale)x 不应要求超过 1080p")
                }
            }
        }
    }

    /// 档位单调：卡片越宽，允许的解码档不会变小。
    @Test func aWiderCardNeverGetsALowerCap() {
        let widths: [CGFloat] = [100, 200, 300, 400, 600, 900]
        var previous: CGFloat = 0
        for w in widths {
            guard let cap = DockDecodeResolution.cap(forCardWidth: w, scale: 2) else { continue }
            #expect(cap >= previous, "\(w)pt 的档位 \(cap) 低于更窄卡片的 \(previous)")
            previous = cap
        }
    }

    /// 极小卡片必须给最低档，而不是 nil（nil = 跟随源，会去解 4K）。
    ///
    /// ⛔ 这是本类型最容易写错的一处：小窗越小越该压解码，
    ///    如果小到某处返回 nil，反而变成「不限制」——完全反了。
    @Test func aTinyCardStillGetsALowCapNotUnlimited() {
        let cap = DockDecodeResolution.cap(forCardWidth: 120, scale: 2)
        #expect(cap != nil, "极小卡片不能返回 nil（nil = 不限制，会按源分辨率全解）")
        #expect(cap == 480)
    }

    /// 超过 1080p 的宽度才允许跟随源（无上限）。
    @Test func onlyLargeSurfacesFollowTheSource() {
        #expect(DockDecodeResolution.cap(forCardWidth: 800, scale: 2) == nil)
        #expect(DockDecodeResolution.preferredMaximumResolution(forCardWidth: 800, scale: 2) == .zero)
    }

    /// 档位名可读，便于真机日志判读。
    @Test func theCapIsNameable() {
        #expect(DockDecodeResolution.name(forCardWidth: 120, scale: 2) == "480p")
        #expect(DockDecodeResolution.name(forCardWidth: 240, scale: 2) == "480p" || DockDecodeResolution.name(forCardWidth: 240, scale: 2) == "720p")
        #expect(DockDecodeResolution.name(forCardWidth: 800, scale: 2) == "source")
    }
}

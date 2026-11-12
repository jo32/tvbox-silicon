import Foundation

/// What this device turned out too slow for while making in-between frames (Smooth Motion), so the next video of
/// that size doesn't stutter through the same attempts. An Apple TV 4K dropped frames for about half a minute at
/// the start of every 4K episode: a 720p copy, too slow; a 540p copy, too slow; off. Then the same again for the
/// next episode (#866).
public struct SmoothingLimits: Sendable {
    /// The most pixels interpolated per frame, and the fewer tried when that is too slow.
    public static let full = 1280 * 720, reduced = 960 * 540
    /// How long a finding stands, in seconds. A device that was hot or busy gets another try later.
    public var lifetime = 1800.0
    private var reducedFrom: Finding?
    private var offFrom: Finding?
    private struct Finding: Sendable { var pixels: Int; var at: Double }

    public init() {}

    /// The most pixels to interpolate at for a picture `pixels` big, or nil when even the reduced size was too slow
    /// for a picture that big.
    public func budget(pixels: Int, now: Double) -> Int? {
        if let offFrom = standing(offFrom, now), pixels >= offFrom.pixels { return nil }
        if let reducedFrom = standing(reducedFrom, now), pixels >= reducedFrom.pixels { return Self.reduced }
        return Self.full
    }

    /// A picture `pixels` big was too slow to interpolate within `budget`. Bigger pictures cost more, so they share the finding.
    public mutating func tooSlow(pixels: Int, budget: Int, now: Double) {
        if budget > Self.reduced {
            reducedFrom = Finding(pixels: min(pixels, standing(reducedFrom, now)?.pixels ?? .max), at: now)
        } else {
            offFrom = Finding(pixels: min(pixels, standing(offFrom, now)?.pixels ?? .max), at: now)
        }
    }

    private func standing(_ finding: Finding?, _ now: Double) -> Finding? {
        guard let finding, now - finding.at < lifetime else { return nil }
        return finding
    }
}

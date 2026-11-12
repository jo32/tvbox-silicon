import Testing
@testable import TVCore

@Suite struct SmoothingLimitsTests {
    private let uhd = 3840 * 1632, fullHD = 1920 * 1080

    @Test func aDeviceNotSeenStrugglingGetsTheFullSize() {
        #expect(SmoothingLimits().budget(pixels: uhd, now: 0) == SmoothingLimits.full)
    }

    /// The Apple TV 4K of #866: 4K was too slow from a 720p copy, then from a 540p copy.
    @Test func theNextVideoOfThatSizeSkipsWhatWasTooSlow() {
        var limits = SmoothingLimits()
        limits.tooSlow(pixels: uhd, budget: SmoothingLimits.full, now: 10)
        #expect(limits.budget(pixels: uhd, now: 20) == SmoothingLimits.reduced)
        limits.tooSlow(pixels: uhd, budget: SmoothingLimits.reduced, now: 30)
        #expect(limits.budget(pixels: uhd, now: 40) == nil)
        // A bigger picture costs more; a smaller one, which the same device keeps up with, is left alone.
        #expect(limits.budget(pixels: 3840 * 2160, now: 40) == nil)
        #expect(limits.budget(pixels: fullHD, now: 40) == SmoothingLimits.full)
    }

    @Test func aSmallerPictureThatStrugglesLowersTheBar() {
        var limits = SmoothingLimits()
        limits.tooSlow(pixels: uhd, budget: SmoothingLimits.reduced, now: 0)
        limits.tooSlow(pixels: fullHD, budget: SmoothingLimits.reduced, now: 5)
        #expect(limits.budget(pixels: fullHD, now: 6) == nil)
        // A bigger one struggling later doesn't raise it again.
        limits.tooSlow(pixels: uhd, budget: SmoothingLimits.reduced, now: 7)
        #expect(limits.budget(pixels: fullHD, now: 8) == nil)
    }

    /// A device that was hot or busy is tried again later.
    @Test func aFindingLapses() {
        var limits = SmoothingLimits()
        limits.lifetime = 100
        limits.tooSlow(pixels: uhd, budget: SmoothingLimits.full, now: 0)
        limits.tooSlow(pixels: uhd, budget: SmoothingLimits.reduced, now: 50)
        #expect(limits.budget(pixels: uhd, now: 99) == nil)
        #expect(limits.budget(pixels: uhd, now: 120) == nil)
        #expect(limits.budget(pixels: uhd, now: 150) == SmoothingLimits.full)
        // A lapsed finding doesn't hold a new one down to its size.
        limits.tooSlow(pixels: 3840 * 2160, budget: SmoothingLimits.reduced, now: 200)
        #expect(limits.budget(pixels: uhd, now: 201) == SmoothingLimits.full)
        #expect(limits.budget(pixels: 3840 * 2160, now: 201) == nil)
    }
}

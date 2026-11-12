import Testing
@testable import TVCore

@Test func macPlayerScrollKeepsSidewaysSwipesForScrubbing() {
    // A mouse wheel: each notch on its own. Up and down is the volume, a sideways wheel is not.
    var wheel = ScrollAxisLock()
    #expect(wheel.axis(dx: 0, dy: 3, starts: false, tracked: false) == .vertical)
    #expect(wheel.axis(dx: 2, dy: 0, starts: false, tracked: false) == .horizontal)
    #expect(wheel.axis(dx: 0, dy: -1, starts: false, tracked: false) == .vertical)

    // A trackpad swipe to the side that drifts down stays a swipe (#874), through its momentum.
    var pad = ScrollAxisLock()
    #expect(pad.axis(dx: 0, dy: 0, starts: true, tracked: true) == nil)
    #expect(pad.axis(dx: 4, dy: 1, starts: false, tracked: true) == .horizontal)
    #expect(pad.axis(dx: 1, dy: 6, starts: false, tracked: true) == .horizontal)
    #expect(pad.axis(dx: 0, dy: 0, starts: false, tracked: true) == .horizontal)
    #expect(pad.axis(dx: 0, dy: 2, starts: false, tracked: true) == .horizontal)

    // The next gesture chooses again: up and down is the volume, even when it wanders sideways.
    #expect(pad.axis(dx: 1, dy: -5, starts: true, tracked: true) == .vertical)
    #expect(pad.axis(dx: 7, dy: 0, starts: false, tracked: true) == .vertical)
    // A straight diagonal counts as up and down, as before.
    #expect(pad.axis(dx: 2, dy: 2, starts: true, tracked: true) == .vertical)
}

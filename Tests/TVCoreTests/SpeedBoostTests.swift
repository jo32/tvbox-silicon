import Testing
@testable import TVCore

@Test func holdingThePictureStepsThroughSpeedsSideways() {
    var boost = SpeedBoost(rate: 2)
    #expect(boost.rate == 2 && !boost.locked)
    boost.moved(x: 49, y: 20)
    #expect(boost.rate == 2)
    boost.moved(x: 50, y: 0)
    #expect(boost.rate == 2.5)
    boost.moved(x: 100, y: 0)
    #expect(boost.rate == 3)
    boost.moved(x: 500, y: 0)
    #expect(boost.rate == 4)
    boost.moved(x: -60, y: 0)
    #expect(boost.rate == 1.5)
    boost.moved(x: -100, y: 0)
    #expect(boost.rate == 1)
    boost.moved(x: -500, y: 0)
    #expect(boost.rate == 0.5)
    boost.moved(x: .nan, y: .infinity)
    #expect(boost.rate == 0.5 && !boost.locked)
}

@Test func slidingDownKeepsTheSpeedAfterLettingGo() {
    var boost = SpeedBoost(rate: 3)
    boost.moved(x: -50, y: 79)
    #expect(!boost.locked)
    boost.moved(x: -50, y: 80)
    #expect(boost.locked && boost.rate == 2.5)
    // Moving back up doesn't let it go again; tapping its label does.
    boost.moved(x: 0, y: 0)
    #expect(boost.locked && boost.rate == 3)
}

@Test func holdSpeedStartsAtTheNearestRate() {
    #expect(SpeedBoost(rate: 3).rate == 3)
    #expect(SpeedBoost(rate: 4).rate == 4)
    #expect(SpeedBoost(rate: 7).rate == 4)
    #expect(SpeedBoost(rate: 0.5).rate == 0.5)
    #expect(SpeedBoost(rate: 0.1).rate == 0.5)
    #expect(SpeedBoost(rate: .nan).rate == SpeedBoost.standard)
}

@Test func holdsStartSlowerOrFasterButNotAtNormalSpeed() {
    #expect(SpeedBoost.startRates == [0.5, 1.5, 2, 2.5, 3, 4])
    #expect(SpeedBoost.startRates.contains(SpeedBoost.standard))
}

@Test func aHoldSlowsDownBeforeTheBufferRunsOut() {
    var throttle = SpeedBoost.Throttle(wanted: 4)
    #expect(throttle.rate == 4 && !throttle.limited)
    throttle.update(ahead: 60, waiting: false)
    #expect(throttle.rate == 4)
    // 15 s of video lasts under 4 s at 4×: one step at a time, down to normal speed at the slowest.
    throttle.update(ahead: 15, waiting: false)
    #expect(throttle.rate == 3 && throttle.limited)
    throttle.update(ahead: 11, waiting: false)
    #expect(throttle.rate == 2.5)
    throttle.update(ahead: 9, waiting: true)
    #expect(throttle.rate == 2)
    for _ in 0..<5 { throttle.update(ahead: 0, waiting: true) }
    #expect(throttle.rate == 1)
}

@Test func aHoldSpeedsUpAgainWhileTheDownloadKeepsUp() {
    var throttle = SpeedBoost.Throttle(wanted: 3)
    throttle.update(ahead: 8, waiting: false)
    throttle.update(ahead: 6, waiting: false)
    #expect(throttle.rate == 2)
    // The buffer has to hold up for a few seconds, and leave room at the next speed.
    for ahead in [10.0, 11, 12, 13, 14] { throttle.update(ahead: ahead, waiting: false) }
    #expect(throttle.rate == 2)
    throttle.update(ahead: 16, waiting: false)
    #expect(throttle.rate == 2.5)
    // Shrinking at 2.5×: it stays there, and steps down before running out.
    for ahead in [15.0, 14.5, 14, 13.5, 13, 12.5] { throttle.update(ahead: ahead, waiting: false) }
    #expect(throttle.rate == 2.5)
    throttle.update(ahead: 9, waiting: false)
    #expect(throttle.rate == 2)
    // Never past the speed asked for.
    for _ in 0..<30 { throttle.update(ahead: 120, waiting: false) }
    #expect(throttle.rate == 3 && !throttle.limited)
}

@Test func slowerHoldsAreLeftAlone() {
    var slow = SpeedBoost.Throttle(wanted: 0.5)
    slow.update(ahead: 0, waiting: true)
    #expect(slow.rate == 0.5)
    var fast = SpeedBoost.Throttle(wanted: 2)
    fast.update(ahead: .nan, waiting: false)
    #expect(fast.rate == 2)
}

@Test func slidingOnKeepsTheSpeedTheConnectionHeld() {
    var throttle = SpeedBoost.Throttle(wanted: 4)
    throttle.update(ahead: 2, waiting: false)
    throttle.update(ahead: 2, waiting: false)
    #expect(throttle.rate == 2.5)
    #expect(SpeedBoost.Throttle(wanted: 3, after: throttle).rate == 2.5)
    #expect(SpeedBoost.Throttle(wanted: 2, after: throttle).rate == 2)
    #expect(SpeedBoost.Throttle(wanted: 3, after: SpeedBoost.Throttle(wanted: 4)).rate == 3)
}

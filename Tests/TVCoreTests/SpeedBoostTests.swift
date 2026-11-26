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

@Test func holdSpeedCanBeOff() {
    #expect(!SpeedBoost.isOn(SpeedBoost.off))
    #expect(!SpeedBoost.isOn(.nan))
    #expect(SpeedBoost.isOn(SpeedBoost.standard) && SpeedBoost.isOn(0.5))
    #expect(!SpeedBoost.startRates.contains(SpeedBoost.off))
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
    // 11 s of video lasts under 3 s at 4×: one step at a time, down to normal speed at the slowest.
    throttle.update(ahead: 13, waiting: false)
    #expect(throttle.rate == 4)
    throttle.update(ahead: 11, waiting: false)
    #expect(throttle.rate == 3 && throttle.limited)
    throttle.update(ahead: 8, waiting: false)
    #expect(throttle.rate == 2.5)
    throttle.update(ahead: 9, waiting: true)
    #expect(throttle.rate == 2)
    for _ in 0..<5 { throttle.update(ahead: 0, waiting: true) }
    #expect(throttle.rate == 1)
}

@Test func aHoldSpeedsUpAgainWhileTheDownloadKeepsUp() {
    var throttle = SpeedBoost.Throttle(wanted: 3)
    throttle.update(ahead: 10, waiting: false)
    throttle.update(ahead: 8, waiting: false)
    throttle.update(ahead: 6, waiting: false)
    throttle.update(ahead: 4, waiting: false)
    #expect(throttle.rate == 2)
    // The buffer has to hold up for a few seconds, and leave room at the next speed.
    for ahead in [10.0, 11, 12, 13, 14] { throttle.update(ahead: ahead, waiting: false) }
    #expect(throttle.rate == 2)
    throttle.update(ahead: 16, waiting: false)
    #expect(throttle.rate == 2.5)
    // Shrinking at 2.5×: it stays there, and steps down before running out.
    for ahead in [15.0, 14.5, 14, 13.5, 13, 12.5] { throttle.update(ahead: ahead, waiting: false) }
    #expect(throttle.rate == 2.5)
    throttle.update(ahead: 7, waiting: false)
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
    throttle.update(ahead: 14, waiting: false)
    throttle.update(ahead: 11, waiting: false)
    throttle.update(ahead: 8, waiting: false)
    throttle.update(ahead: 5, waiting: false)
    #expect(throttle.rate == 2.5)
    #expect(SpeedBoost.Throttle(wanted: 3, after: throttle).rate == 2.5)
    #expect(SpeedBoost.Throttle(wanted: 2, after: throttle).rate == 2)
    #expect(SpeedBoost.Throttle(wanted: 3, after: SpeedBoost.Throttle(wanted: 4)).rate == 3)
}

@Test func aSteadyOrGrowingSmallBufferDoesNotSlowDown() {
    // Issue #2175: a fast connection where AVPlayer only reports a few seconds ahead (or after a seek) keeps up.
    var steady = SpeedBoost.Throttle(wanted: 2)
    for ahead in [4.0, 4.0, 3.85, 4.1, 4.0, 4.0] { steady.update(ahead: ahead, waiting: false) }
    #expect(steady.rate == 2 && !steady.limited)
    // Growing after a seek, with a one-tick dip and small jitter as chunks arrive.
    var afterSeek = SpeedBoost.Throttle(wanted: 2)
    for ahead in [3.8, 2.8, 4.4, 4.2, 5.6, 6.9] { afterSeek.update(ahead: ahead, waiting: false) }
    #expect(afterSeek.rate == 2 && !afterSeek.limited)
    // Chunk-by-chunk sawtooth at a steady cap never drains for two samples in a row.
    var sawtooth = SpeedBoost.Throttle(wanted: 2)
    for ahead in [5.0, 3.0, 5.0, 3.0, 5.0, 3.0] { sawtooth.update(ahead: ahead, waiting: false) }
    #expect(sawtooth.rate == 2 && !sawtooth.limited)
}

@Test func anUnreportedBufferDoesNotSlowDownUnlessStalled() {
    // Issue #2175: empty or missing loadedTimeRanges while playing smoothly is not a slow connection.
    var throttle = SpeedBoost.Throttle(wanted: 2)
    for _ in 0..<10 { throttle.update(ahead: nil, waiting: false) }
    #expect(throttle.rate == 2 && !throttle.limited)
    // A real stall still steps down, and clean playback recovers toward the wanted speed.
    throttle.update(ahead: nil, waiting: true)
    #expect(throttle.rate == 1.5 && throttle.limited)
    for _ in 0..<SpeedBoost.Throttle.settle { throttle.update(ahead: nil, waiting: false) }
    #expect(throttle.rate == 2 && !throttle.limited)
}

@Test func reachingTheEndOfTheVideoDoesNotSlowDown() {
    var throttle = SpeedBoost.Throttle(wanted: 2)
    for remaining in [5.0, 3.0, 1.0] {
        throttle.update(ahead: remaining, waiting: false, remaining: remaining)
    }
    #expect(throttle.rate == 2 && !throttle.limited)
}

@Test func bufferedAheadReadsLoadedRangesAroundPlayhead() {
    // Empty or stale ranges report nil rather than 0 s.
    #expect(SpeedBoost.bufferedAhead(ranges: [], at: 100) == nil)
    #expect(SpeedBoost.bufferedAhead(ranges: [(0, 50)], at: 100) == nil)
    #expect(SpeedBoost.bufferedAhead(ranges: [(0, 50)], at: .nan) == nil)
    // Normal range, small start offset, and contiguous ranges with a tiny gap.
    #expect(SpeedBoost.bufferedAhead(ranges: [(10, 40)], at: 15) == 25)
    #expect(SpeedBoost.bufferedAhead(ranges: [(10.2, 40)], at: 10) == 30)
    #expect(SpeedBoost.bufferedAhead(ranges: [(10, 20), (20.1, 35)], at: 15) == 20)
    // A large gap is not bridged.
    #expect(SpeedBoost.bufferedAhead(ranges: [(10, 20), (30, 50)], at: 15) == 5)
}

@Test func aTappedKeySkipsAndAHeldOnePlaysFaster() {
    var key = KeyHold()
    // A tap: let go before the wait is over.
    let pressed = key.press(repeated: false)
    #expect(pressed && key.isDown)
    let tapped = key.release()
    #expect(tapped == .tap && !key.isDown)
    // The wait of a press that is over starts nothing.
    let late = key.wait()
    #expect(!late)
    // A hold: the key repeat changes nothing, and it ends as a hold, not as a skip.
    let again = key.press(repeated: false), repeated = key.press(repeated: true), began = key.wait()
    #expect(again && !repeated && began)
    let repeatedHeld = key.press(repeated: true), beganTwice = key.wait()
    #expect(!repeatedHeld && !beganTwice)
    let held = key.release()
    #expect(held == .held)
    // A key that was down before its events came here (another window had them) does nothing.
    let stale = key.press(repeated: true)
    #expect(!stale && !key.isDown)
    let stray = key.release()
    #expect(stray == .stray)
}

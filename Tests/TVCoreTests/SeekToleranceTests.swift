import Testing
@testable import TVCore

@Test func aLetGoSeekLandsWithinWhatTheFingerCouldPick() {
    // A 45-minute episode across a 390-point bar: about 7 s a point, so the widest window.
    #expect(SeekTolerance.release(secondsPerPoint: 2700.0 / 390) == SeekTolerance.widest)
    // Fine scrubbing at a tenth of the speed on an 800-point bar: 0.34 s a point, about 3.4 s.
    let fine = SeekTolerance.release(secondsPerPoint: 2700.0 / 800 * 0.1)
    #expect(fine > 3.3 && fine < 3.4)
    // A slide across the picture moves at most 3 minutes over its width: never closer than the narrowest window.
    #expect(SeekTolerance.release(secondsPerPoint: PictureSeek.secondsPerPoint(width: 1000, duration: 2700)) == SeekTolerance.narrowest)
    // Nothing known about the drag (a tap with no width yet): exact, as before.
    #expect(SeekTolerance.release(secondsPerPoint: 0) == 0)
    #expect(SeekTolerance.release(secondsPerPoint: .nan) == 0)
}

@Test func aSkipAlwaysMovesMostOfTheWayItsDirection() {
    #expect(SeekTolerance.skip(10) == 2.5)
    #expect(SeekTolerance.skip(-10) == 2.5)
    #expect(SeekTolerance.skip(60) == SeekTolerance.widest)
    #expect(SeekTolerance.skip(.infinity) == 0)
}

@Test func aSlideCoversAtMostThreeMinutes() {
    #expect(PictureSeek.secondsPerPoint(width: 900, duration: 2700) == 0.2)
    #expect(PictureSeek.secondsPerPoint(width: 600, duration: 60) == 0.1)
    #expect(PictureSeek.secondsPerPoint(width: 0, duration: 60) == 0)
}

@Test func aJumpPlaysAgainOnceThreeSecondsAreIn() {
    #expect(!SeekResume.shouldPlay(ahead: 0, remaining: 600))
    #expect(!SeekResume.shouldPlay(ahead: 2.9, remaining: 600))
    #expect(SeekResume.shouldPlay(ahead: 3, remaining: 600))
    // Near the end, all that is left is enough.
    #expect(SeekResume.shouldPlay(ahead: 1.9, remaining: 2))
    #expect(!SeekResume.shouldPlay(ahead: .nan, remaining: 2))
    #expect(!SeekResume.shouldPlay(ahead: 1, remaining: .nan))
}

@Test func aRateChangeIsNoJumpButASeekIs() {
    let clock = SeekResume.Clock(seconds: 100, at: 50, rate: 1)
    // Two seconds later at normal speed: about 102, a play or a hold at 2x posts the notice there.
    #expect(!clock.jumped(to: 102.1, at: 52))
    #expect(clock.jumped(to: 140, at: 52))
    #expect(clock.jumped(to: 92, at: 52))
    // Paused or waiting, the clock stands still.
    let still = SeekResume.Clock(seconds: 100, at: 50, rate: 0)
    #expect(!still.jumped(to: 100, at: 80))
    #expect(still.jumped(to: 110, at: 80))
    #expect(!still.jumped(to: .nan, at: 80))
}

import Testing
@testable import TVCore

@Test func aTapTogglesTheControlsAndTwoOnASideSkip() {
    var taps = PictureTaps()
    #expect(taps.tap(at: 0, in: .forward) == .toggleControls)
    #expect(taps.tap(at: 0.2, in: .forward) == .skip(seconds: 10, total: 10, first: true))
    // Each further tap soon after skips 10 more.
    #expect(taps.tap(at: 0.8, in: .forward) == .skip(seconds: 10, total: 20, first: false))
    #expect(taps.tap(at: 1.4, in: .forward) == .skip(seconds: 10, total: 30, first: false))
    // Too late: a plain tap again.
    #expect(taps.tap(at: 2.2, in: .forward) == .toggleControls)
    #expect(taps.tap(at: 2.4, in: .back) == .toggleControls)
    #expect(taps.tap(at: 2.6, in: .back) == .skip(seconds: -10, total: 10, first: true))
    // The other side ends the run.
    #expect(taps.tap(at: 2.8, in: .forward) == .toggleControls)
    #expect(taps.tap(at: 3.5, in: .forward) == .toggleControls)
    #expect(taps.tap(at: 3.9, in: .forward) == .toggleControls)
}

@Test func twoTapsInTheMiddlePlayOrPauseOnce() {
    var taps = PictureTaps()
    #expect(taps.tap(at: 0, in: .middle) == .toggleControls)
    #expect(taps.tap(at: 0.25, in: .middle) == .togglePlayback)
    #expect(taps.tap(at: 0.4, in: .middle) == .toggleControls)
    #expect(taps.tap(at: 0.6, in: .middle) == .togglePlayback)
    // A side tap and then a middle one are two single taps.
    #expect(taps.tap(at: 5, in: .back) == .toggleControls)
    #expect(taps.tap(at: 5.1, in: .middle) == .toggleControls)
}

@Test func pictureZonesAreThirdsWhenThereIsATimeline() {
    #expect(PictureTaps.zone(x: 10, width: 900, seekable: true) == .back)
    #expect(PictureTaps.zone(x: 450, width: 900, seekable: true) == .middle)
    #expect(PictureTaps.zone(x: 890, width: 900, seekable: true) == .forward)
    #expect(PictureTaps.zone(x: 890, width: 900, seekable: false) == .middle)
    #expect(PictureTaps.zone(x: 10, width: 0, seekable: true) == .middle)
}

@Test func slidingAcrossThePictureMovesUpToThreeMinutes() {
    #expect(PictureSeek.target(from: 600, moved: 450, width: 900, duration: 2700) == 690)
    #expect(PictureSeek.target(from: 600, moved: -900, width: 900, duration: 2700) == 420)
    // A short video: the width is the whole video.
    #expect(PictureSeek.target(from: 30, moved: 450, width: 900, duration: 120) == 90)
    #expect(PictureSeek.target(from: 30, moved: -900, width: 900, duration: 120) == 0)
    #expect(PictureSeek.target(from: 100, moved: 900, width: 900, duration: 120) == 120)
    #expect(PictureSeek.target(from: 100, moved: .nan, width: 900, duration: 120) == 100)
    #expect(PictureSeek.target(from: 100, moved: 10, width: 0, duration: 120) == 100)
}

@Test func slidingUpOrDownSetsALevelAwayFromTheEdges() {
    #expect(PictureLevel.value(from: 0.5, moved: -300, height: 800) == 1)
    #expect(PictureLevel.value(from: 0.5, moved: 150, height: 800) == 0.25)
    #expect(PictureLevel.value(from: 0.2, moved: 600, height: 800) == 0)
    #expect(PictureLevel.value(from: 0.4, moved: .nan, height: 800) == 0.4)
    #expect(PictureLevel.value(from: 0.4, moved: 10, height: 0) == 0.4)
    #expect(!PictureLevel.slides(fromY: 20, height: 800))
    #expect(PictureLevel.slides(fromY: 400, height: 800))
    #expect(!PictureLevel.slides(fromY: 780, height: 800))
}

@Test func doubleTapsSkipTheChosenInterval() {
    var taps = PictureTaps()
    #expect(taps.tap(at: 0, in: .back, step: 30) == .toggleControls)
    #expect(taps.tap(at: 0.2, in: .back, step: 30) == .skip(seconds: -30, total: 30, first: true))
    #expect(taps.tap(at: 0.7, in: .back, step: 30) == .skip(seconds: -30, total: 60, first: false))
    // The skip buttons' symbols exist for each choice; anything else stored skips 10 seconds.
    #expect(SkipInterval.seconds(45) == 45)
    #expect(SkipInterval.seconds(7) == 10)
    #expect(SkipInterval.symbol(forward: true, seconds: 5) == "goforward.5")
    #expect(SkipInterval.symbol(forward: false, seconds: 0) == "gobackward.10")
}

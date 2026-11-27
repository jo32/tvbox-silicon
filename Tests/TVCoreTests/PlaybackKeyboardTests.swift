import Testing
@testable import TVCore

@Test func playbackKeysDoNotRepeatToggles() {
    for (key, action) in [(PlaybackKeyboard.Key.space, PlaybackKeyboard.Action.playPause), (.mute, .mute)] {
        var keyboard = PlaybackKeyboard()
        #expect(keyboard.handle(key, phase: .down) == [action])
        #expect(keyboard.handle(key, phase: .repeated).isEmpty)
        #expect(keyboard.handle(key, phase: .down).isEmpty)
        #expect(keyboard.handle(key, phase: .up).isEmpty)
        #expect(keyboard.handle(key, phase: .down) == [action])
    }
}

@Test func playbackArrowTapAndHoldAreDifferentActions() {
    var keyboard = PlaybackKeyboard()
    #expect(keyboard.handle(.right, phase: .down) == [.waitForHold])
    #expect(keyboard.handle(.right, phase: .up) == [.seek(10)])
    #expect(keyboard.held().isEmpty)
    #expect(keyboard.handle(.right, phase: .down) == [.waitForHold])
    #expect(keyboard.held() == [.beginBoost])
    #expect(keyboard.handle(.right, phase: .repeated).isEmpty)
    #expect(keyboard.held().isEmpty)
    #expect(keyboard.handle(.right, phase: .up, shift: true) == [.endBoost])
}

@Test func playbackShiftArrowsAndVolumeRepeat() {
    for (key, shift, action) in [(PlaybackKeyboard.Key.left, false, PlaybackKeyboard.Action.seek(-10)),
                                (.left, true, .seek(-60)), (.right, true, .seek(60)),
                                (.up, false, .volume(0.05)), (.down, false, .volume(-0.05))] {
        var keyboard = PlaybackKeyboard()
        #expect(keyboard.handle(key, phase: .down, shift: shift) == [action])
        #expect(keyboard.handle(key, phase: .repeated, shift: shift) == [action])
        #expect(keyboard.held().isEmpty)
        #expect(keyboard.handle(key, phase: .up).isEmpty)
    }
}

@Test func interruptedPlaybackKeysNeverSeekOrLeaveABoostRunning() {
    for held in [false, true] {
        var keyboard = PlaybackKeyboard()
        _ = keyboard.handle(.right, phase: .down)
        if held { _ = keyboard.held() }
        #expect(keyboard.cancel() == (held ? [.endBoost] : []))
        #expect(keyboard.cancel().isEmpty)
        #expect(keyboard.held().isEmpty)
        #expect(keyboard.handle(.right, phase: .repeated).isEmpty)
        #expect(keyboard.handle(.right, phase: .up).isEmpty)
        #expect(keyboard.handle(.right, phase: .down) == [.waitForHold])
    }
}

@Test func macArrowKeysDoNotWakePlayerChrome() {
    // Left, right, down and up arrows stay quiet (#2557).
    for keyCode: UInt16 in [123, 124, 125, 126] {
        #expect(!PlaybackKeyboard.wakesMacChrome(keyCode: keyCode))
    }
    // Space, Escape and letter keys still wake the controls.
    for keyCode: UInt16 in [49, 53, 3, 46] {
        #expect(PlaybackKeyboard.wakesMacChrome(keyCode: keyCode))
    }
}

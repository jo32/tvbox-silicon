import Foundation
import Testing
@testable import TVCore

@Test func subtitleDelayKeepsItsRange() {
    #expect(SubtitleDelay.clamped(-2) == 0)
    #expect(SubtitleDelay.clamped(4.5) == 4.5)
    #expect(SubtitleDelay.clamped(99) == 30)
    #expect(SubtitleDelay.clamped(.nan) == 0)
    #expect(SubtitleDelay.clamped(.infinity) == 0)
    #expect(SubtitleDelay.title(0) == L10n.text("In sync"))
    #expect(SubtitleDelay.title(2.5) == "+2.5 s")
}

@Test func aDelayedLineWaitsBeforeItShows() {
    var schedule = SubtitleSchedule(delay: 2)
    schedule.enqueue(["第一句"], at: 10)
    #expect(schedule.lines(at: 11.9) == nil)
    #expect(schedule.lines(at: 12) == ["第一句"])
    // Taken once: the next call only reports a later change.
    #expect(schedule.lines(at: 12.5) == nil)
}

@Test func aCueEndWaitsLikeItsStart() {
    var schedule = SubtitleSchedule(delay: 1.5)
    schedule.enqueue(["第一句"], at: 10)
    schedule.enqueue([], at: 12)
    #expect(schedule.lines(at: 11.5) == ["第一句"])
    #expect(schedule.lines(at: 13.5) == [])
}

@Test func aRepeatedCueReplacesTheEarlierOne() {
    var schedule = SubtitleSchedule(delay: 1)
    schedule.enqueue(["old"], at: 5)
    schedule.enqueue(["new"], at: 5)
    #expect(schedule.lines(at: 6) == ["new"])
    #expect(schedule.pending.isEmpty)
}

@Test func aSeekDropsTheLineUpAndWhatWaitedForTheOldPlace() {
    var schedule = SubtitleSchedule(delay: 2)
    schedule.enqueue(["old"], at: 100)
    #expect(schedule.lines(at: 101) == nil)
    // Forward: AVPlayer hands over the new place's line before the clock reports the jump. The old line goes at once,
    // and the new one still waits its delay.
    schedule.enqueue(["new"], at: 200)
    #expect(schedule.lines(at: 200) == [])
    #expect(schedule.lines(at: 202) == ["new"])
    // Back: the lines waiting ahead of the new place go too; AVPlayer hands them over again when their time comes.
    schedule.enqueue(["later"], at: 205)
    #expect(schedule.lines(at: 202.25) == nil)
    #expect(schedule.lines(at: 50) == [])
    #expect(schedule.pending.isEmpty)
    // Playback moving on is no seek: nothing to clear.
    #expect(schedule.lines(at: 50.25) == nil)
}

@Test func resetForgetsWhatWasWaiting() {
    var schedule = SubtitleSchedule(delay: 3)
    schedule.enqueue(["第一句"], at: 10)
    schedule.reset()
    #expect(schedule.lines(at: 100) == nil)
}

@Test func turningTheDelayOffShowsWhatTheClockSaysNow() {
    var schedule = SubtitleSchedule(delay: 10)
    schedule.enqueue(["第一句"], at: 5)
    schedule.enqueue([], at: 8)
    // Still waiting at 9.5 with the delay on: neither line has come due.
    #expect(schedule.lines(at: 9.5) == nil)
    // With the delay off, the clock decides what is up: the line ended at 8, so nothing shows.
    schedule.delay = 0
    #expect(schedule.lines(at: 9.5) == [])
}

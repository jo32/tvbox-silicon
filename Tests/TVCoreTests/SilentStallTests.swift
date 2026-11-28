import Foundation
import Testing
@testable import TVCore

struct SilentStallTests {
    /// The seconds in `range` at which `stall` says the wait has gone on too long.
    private func fired(_ stall: inout SilentStall, _ range: ClosedRange<Int>, waiting: Bool = true,
                       received: (Int) -> Int64) -> [Int] {
        range.filter { stall.update(waiting: waiting, received: received($0), now: Double($0)) }
    }

    /// Issue #2109: a drive file waited at 1,601,194,434 bytes from 17:04:52 until the viewer gave up a minute later.
    @Test func waitingWithNoBytesReopensOnce() {
        var stall = SilentStall()
        // Once after `limit` seconds, then the count starts again.
        #expect(fired(&stall, 0...60) { _ in 1_601_194_434 } == [25, 51])
    }

    @Test func bytesComingInOrNotWaitingKeepItQuiet() {
        var stall = SilentStall()
        // A slow drive still brings bytes: no stall.
        #expect(fired(&stall, 0...120) { Int64($0) * 100_000 }.isEmpty)
        // Paused (or playing): not waiting, so no count however long nothing arrives.
        #expect(fired(&stall, 121...240, waiting: false) { _ in 0 }.isEmpty)
        // The wait counts from when it began, not from the pause before it.
        #expect(fired(&stall, 241...266) { _ in 0 } == [266])
    }

    @Test func realProgressResetsTheCountAndATrickleDoesNot() {
        var stall = SilentStall()
        #expect(fired(&stall, 0...24) { _ in 10 }.isEmpty)
        // 64 KB more at 24 s: the 25 s count starts there.
        #expect(fired(&stall, 24...48) { _ in 10 + SilentStall.progress }.isEmpty)
        #expect(fired(&stall, 49...49) { _ in 10 + SilentStall.progress } == [49])
        // A byte every eight seconds keeps a connection from timing out, and is still a stall.
        var trickle = SilentStall()
        #expect(fired(&trickle, 0...30) { Int64($0 / 8) } == [25])
    }

    @Test func stallsCountWithDrops() {
        var recovery = PlaybackDropRecovery()
        var delays: [Duration?] = []
        delays.append(recovery.delayAfterStall(position: 600))
        delays.append(recovery.delay(after: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut), position: 600))
        delays.append(recovery.delayAfterStall(position: 600))
        delays.append(recovery.delayAfterStall(position: 600))
        // Playing on a minute or more past the last reopening starts the count again.
        delays.append(recovery.delayAfterStall(position: 700))
        delays.append(recovery.delayAfterStall(position: .nan))
        #expect(delays == [.seconds(1), .seconds(3), .seconds(8), nil, .seconds(1), nil])
    }
}

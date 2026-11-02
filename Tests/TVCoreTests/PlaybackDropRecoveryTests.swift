import Foundation
import Testing
@testable import TVCore

struct PlaybackDropRecoveryTests {
    func error(_ domain: String, _ code: Int, underlying: NSError? = nil) -> NSError {
        NSError(domain: domain, code: code, userInfo: underlying.map { [NSUnderlyingErrorKey: $0] } ?? [:])
    }

    /// Issue #331: the failures an iPhone logged when its Wi-Fi dropped 42 minutes into an episode.
    @Test func droppedAndStalledConnectionsCount() {
        #expect(PlaybackDropRecovery.isDrop(error("CoreMediaErrorDomain", -15628)))
        #expect(PlaybackDropRecovery.isDrop(error(NSURLErrorDomain, NSURLErrorNetworkConnectionLost)))
        #expect(PlaybackDropRecovery.isDrop(error(NSURLErrorDomain, NSURLErrorSecureConnectionFailed,
                                                  underlying: error(NSURLErrorDomain, NSURLErrorSecureConnectionFailed))))
        #expect(PlaybackDropRecovery.isDrop(error(NSURLErrorDomain, NSURLErrorTimedOut)))
        #expect(PlaybackDropRecovery.isDrop(error("CoreMediaErrorDomain", -15628, underlying: error(NSURLErrorDomain, NSURLErrorNotConnectedToInternet))))
    }

    @Test func refusedLinksAndUnreadableMediaDoNot() {
        // An expired link: 404 and 403, as AVPlayer reports them.
        #expect(!PlaybackDropRecovery.isDrop(error(NSURLErrorDomain, NSURLErrorFileDoesNotExist, underlying: error("CoreMediaErrorDomain", -12938))))
        #expect(!PlaybackDropRecovery.isDrop(error(NSURLErrorDomain, NSURLErrorNoPermissionsToReadFile, underlying: error("CoreMediaErrorDomain", -12660))))
        #expect(!PlaybackDropRecovery.isDrop(error(NSURLErrorDomain, NSURLErrorResourceUnavailable, underlying: error("CoreMediaErrorDomain", -12884))))
        #expect(!PlaybackDropRecovery.isDrop(error("CoreMediaErrorDomain", -15628, underlying: error("CoreMediaErrorDomain", -12938))))
        #expect(!PlaybackDropRecovery.isDrop(error("AVFoundationErrorDomain", -11828)))
        #expect(!PlaybackDropRecovery.isDrop(nil))
    }

    @Test func reopensAFewTimesThenGivesUp() {
        var recovery = PlaybackDropRecovery()
        let drop = error(NSURLErrorDomain, NSURLErrorNetworkConnectionLost)
        #expect(recovery.delay(after: drop, position: 2521) == .seconds(1))
        // The reopenings that can't connect yet fail where the episode stopped.
        #expect(recovery.delay(after: drop, position: 2521) == .seconds(3))
        #expect(recovery.delay(after: drop, position: 2521) == .seconds(8))
        #expect(recovery.delay(after: drop, position: 2521) == nil)
        #expect(recovery.attempts == 3)
    }

    @Test func aConnectionThatCameBackStartsTheCountAgain() {
        var recovery = PlaybackDropRecovery()
        let stall = error("CoreMediaErrorDomain", -15628)
        #expect(recovery.delay(after: stall, position: 600) == .seconds(1))
        #expect(recovery.delay(after: stall, position: 630) == .seconds(3))
        #expect(recovery.delay(after: stall, position: 700) == .seconds(1))
        #expect(recovery.attempts == 1)
    }

    @Test func otherFailuresDontUseAnAttempt() {
        var recovery = PlaybackDropRecovery()
        #expect(recovery.delay(after: error(NSURLErrorDomain, NSURLErrorFileDoesNotExist), position: 10) == nil)
        #expect(recovery.delay(after: error(NSURLErrorDomain, NSURLErrorNetworkConnectionLost), position: .nan) == nil)
        #expect(recovery.attempts == 0)
    }
}

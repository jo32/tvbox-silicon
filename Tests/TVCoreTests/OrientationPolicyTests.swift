import Testing
import TVCore

@Suite("Player orientation policy")
struct OrientationPolicyTests {
    @Test func watchPageHoldsPortraitAndReleasesWithoutForcingPortrait() {
        var policy = OrientationPolicy()
        #expect(policy.allowed == .allButUpsideDown)

        let enter = policy.holdPortrait(true)
        #expect(enter == .portrait)
        #expect(policy.allowed == .portrait)

        let landscape = policy.set(landscape: true)
        #expect(landscape == .landscape)
        #expect(policy.allowed == .landscape)

        let exitFullScreen = policy.set(landscape: false)
        #expect(exitFullScreen == .portrait)
        #expect(policy.allowed == .portrait)

        let leave = policy.holdPortrait(false)
        #expect(leave == .refresh)
        #expect(policy.allowed == .allButUpsideDown)
    }

    @Test func nestedWatchPagesKeepPortraitHoldUntilAllLeave() {
        var policy = OrientationPolicy()
        let first = policy.holdPortrait(true)
        #expect(first == .portrait)
        let second = policy.holdPortrait(true)
        #expect(second == nil)
        #expect(policy.allowed == .portrait)

        let firstLeft = policy.holdPortrait(false)
        #expect(firstLeft == nil)
        #expect(policy.allowed == .portrait)

        let secondLeft = policy.holdPortrait(false)
        #expect(secondLeft == .refresh)
        #expect(policy.allowed == .allButUpsideDown)
    }

    @Test func unfoldingDuoReleasesLandscapeWithoutLockingPortrait() {
        var policy = OrientationPolicy()
        _ = policy.holdPortrait(true)
        _ = policy.set(landscape: true)
        #expect(policy.allowed == .landscape)

        // Unfolding drops the landscape lock without requesting portrait, then watchBody releases its hold
        // and the standalone full-screen player takes over on the inner display.
        let released = policy.release(forcePortrait: false)
        #expect(released == .refresh)
        let releasedHold = policy.holdPortrait(false)
        #expect(releasedHold == .refresh)
        let standalone = policy.setStandalonePlayer(true)
        #expect(standalone == nil)
        #expect(policy.allowed == .allButUpsideDown)
    }

    @Test func foldingDuoUnderStandalonePlayerDoesNotLockPortrait() {
        var policy = OrientationPolicy()
        let opened = policy.setStandalonePlayer(true)
        #expect(opened == nil)
        #expect(policy.allowed == .allButUpsideDown)

        // Folding mounts watchBody underneath the full-screen cover; its portrait hold must not lock the player.
        let held = policy.holdPortrait(true)
        #expect(held == nil)
        #expect(policy.allowed == .allButUpsideDown)

        // Once the viewer closes the full-screen cover, the watch page underneath regains its portrait hold.
        let closed = policy.setStandalonePlayer(false)
        #expect(closed == .portrait)
        #expect(policy.allowed == .portrait)
    }

    @Test func closingLandscapePlayerOnPhoneRequestsPortrait() {
        var policy = OrientationPolicy()
        _ = policy.set(landscape: true)
        let released = policy.release(forcePortrait: true)
        #expect(released == .portrait)
        #expect(policy.allowed == .allButUpsideDown)
    }
}

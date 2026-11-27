import Testing
@testable import TVCore

struct PictureReadinessTests {
    @Test func revealsImmediatelyWhenFirstVideoFrameIsReady() {
        var readiness = PictureReadiness()
        readiness.displayChanged(false)
        #expect(!readiness.shouldReveal(itemReady: true, pendingResume: false, checkingPicture: false, repackagingSegments: false))
        readiness.displayChanged(true)
        // Even before timeControlStatus reaches .playing, a ready display frame dismisses the poster backdrop (#2636, #1629).
        #expect(readiness.shouldReveal(itemReady: true, pendingResume: false, checkingPicture: false, repackagingSegments: false))
        // Held back while the item is still opening, restoring a saved place, or repackaging.
        #expect(!readiness.shouldReveal(itemReady: false, pendingResume: false, checkingPicture: false, repackagingSegments: false))
        #expect(!readiness.shouldReveal(itemReady: true, pendingResume: true, checkingPicture: false, repackagingSegments: false))
        #expect(!readiness.shouldReveal(itemReady: true, pendingResume: false, checkingPicture: true, repackagingSegments: false))
        #expect(!readiness.shouldReveal(itemReady: true, pendingResume: false, checkingPicture: false, repackagingSegments: true))
    }

    @Test func ignoresStaleReadyFlagUntilPreviousEpisodeClears() {
        var readiness = PictureReadiness()
        readiness.displayChanged(true)
        // Next episode starts while the layer still reports true from the previous item (#1956).
        readiness.reset()
        #expect(readiness.stale)
        #expect(!readiness.shouldReveal(itemReady: true, pendingResume: false, checkingPicture: false, repackagingSegments: false))
        // Once the previous item clears and the new episode decodes a frame, reveal immediately.
        readiness.displayChanged(false)
        #expect(!readiness.stale)
        readiness.displayChanged(true)
        #expect(readiness.shouldReveal(itemReady: true, pendingResume: false, checkingPicture: false, repackagingSegments: false))
    }

    @Test func frameRateRevealsEvenIfReadyFlagNeverCleared() {
        var readiness = PictureReadiness()
        readiness.displayChanged(true)
        readiness.reset()
        #expect(readiness.shouldReveal(itemReady: true, pendingResume: false, checkingPicture: false, repackagingSegments: false, hasVideoFrameRate: true))
    }

    @Test func keepsBackdropWhileCheckingPicturelessHLSAndAllowsAudioOnly() {
        var readiness = PictureReadiness()
        readiness.displayChanged(false)
        // Playing sound with no display frame yet while HLS segment check is active: keep the waiting screen (#2032, #1680, #2454).
        #expect(!readiness.shouldRevealWithoutFrame(itemReady: true, playing: true, pendingResume: false, checkingPicture: false,
                                                    checkingSegments: true, repackagingSegments: false))
        // Once the segment check finishes without repackaging (audio-only stream), reveal playback controls.
        #expect(readiness.shouldRevealWithoutFrame(itemReady: true, playing: true, pendingResume: false, checkingPicture: false,
                                                   checkingSegments: false, repackagingSegments: false))
        // Headless sessions with no display observer still fall back to playing status.
        let headless = PictureReadiness()
        #expect(headless.shouldRevealWithoutFrame(itemReady: true, playing: true, pendingResume: false, checkingPicture: false,
                                                  checkingSegments: true, repackagingSegments: false))
    }
}

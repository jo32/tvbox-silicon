import Testing
import TVCore

@Suite("Mobile Picture in Picture state")
struct MobilePiPStateTests {
    @Test func automaticBackgroundPiPKeepsPlayerOpenAndReturnsOnAppActive() {
        var state = MobilePiPState()
        state.willStart()
        state.didStart()
        #expect(state.active)
        #expect(!state.startedManually)
        #expect(!state.floating)

        // Switching back to Yingxia via the home bar stops automatic PiP once.
        let first = state.shouldStopOnAppActive()
        #expect(first)
        let second = state.shouldStopOnAppActive()
        #expect(!second)

        state.didStop()
        #expect(!state.active)
        #expect(!state.stopping)
    }

    @Test func automaticPiPReturnButtonAlreadyStoppingDoesNotStopTwice() {
        var state = MobilePiPState()
        state.willStart()
        state.didStart()
        state.willStop()
        let shouldStop = state.shouldStopOnAppActive()
        #expect(!shouldStop)
        state.didStop()
        #expect(!state.active)
    }

    @Test func manualPiPFloatsOverAppAndStaysFloatingOnAppActive() {
        var state = MobilePiPState()
        state.beginManualStart()
        state.willStart()
        state.didStart()
        #expect(state.active)
        #expect(state.startedManually)
        #expect(state.floating)

        // Returning to Yingxia while browsing under manual PiP leaves it floating.
        let shouldStop = state.shouldStopOnAppActive()
        #expect(!shouldStop)

        state.didStop()
        #expect(!state.active)
        #expect(!state.floating)
        #expect(!state.startedManually)
    }

    @Test func failedManualStartClearsManualFlagForLaterAutomaticPiP() {
        var state = MobilePiPState()
        state.beginManualStart()
        state.didFailToStart()
        #expect(!state.startedManually)
        #expect(!state.active)

        state.willStart()
        state.didStart()
        #expect(!state.floating)
        let shouldStop = state.shouldStopOnAppActive()
        #expect(shouldStop)
    }
}

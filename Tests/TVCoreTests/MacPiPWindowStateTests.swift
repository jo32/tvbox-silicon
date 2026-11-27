import Testing
import TVCore

@Suite("Mac Picture in Picture window state")
struct MacPiPWindowStateTests {
    @Test func hidesWindowWhenPiPStartsAndRestoresOnReturn() {
        var state = MacPiPWindowState()
        #expect(state.didStart(windowIsFullScreen: false) == .hideWindow)
        #expect(state.active)
        #expect(state.windowHidden)

        #expect(state.willRestore() == .restoreWindow)
        #expect(!state.windowHidden)
        #expect(state.didStop() == .none)
        #expect(!state.active)
    }

    @Test func closingPiPWindowClosesHiddenPlayerWindow() {
        var state = MacPiPWindowState()
        #expect(state.didStart(windowIsFullScreen: false) == .hideWindow)
        #expect(state.didStop() == .closeWindow)
        #expect(!state.active)
        #expect(!state.windowHidden)
    }

    @Test func fullScreenWindowExitsFullScreenBeforeHiding() {
        var state = MacPiPWindowState()
        #expect(state.didStart(windowIsFullScreen: true) == .exitFullScreenThenHide)
        #expect(!state.windowHidden)
        #expect(state.awaitingFullScreenExit)

        #expect(state.didExitFullScreen() == .hideWindow)
        #expect(state.windowHidden)
        #expect(!state.awaitingFullScreenExit)
    }

    @Test func exitingFullScreenAfterPiPStoppedDoesNotHideWindow() {
        var state = MacPiPWindowState()
        #expect(state.didStart(windowIsFullScreen: true) == .exitFullScreenThenHide)
        #expect(state.didStop() == .none)
        #expect(state.didExitFullScreen() == .none)
        #expect(!state.windowHidden)
    }

    @Test func autoAdvanceStaysHiddenWhileNewTitleStopsPiPAndShowsWindow() {
        var state = MacPiPWindowState()
        #expect(state.didStart(windowIsFullScreen: false) == .hideWindow)

        #expect(state.willPresent(continuing: true) == .none)
        #expect(state.windowHidden)

        #expect(state.willPresent(continuing: false) == .stopPiPAndShowWindow)
        #expect(!state.windowHidden)
        // Stopping PiP triggered by opening another video must not close the window.
        #expect(state.didStop() == .none)
    }

    @Test func normalPresentationShowsWindow() {
        var state = MacPiPWindowState()
        #expect(state.willPresent(continuing: false) == .restoreWindow)
        #expect(state.willPresent(continuing: true) == .restoreWindow)
    }
}

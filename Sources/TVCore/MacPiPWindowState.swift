import Foundation

/// Tracks the macOS player window's visibility across Picture in Picture so the large window hides instead of staying
/// open as a black frame (#2533, #2318), stays hidden when an episode auto-advances (#1847), returns when the PiP
/// window's return button is clicked, and closes playback when the PiP window itself is closed.
public struct MacPiPWindowState: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case none
        case hideWindow
        case exitFullScreenThenHide
        case restoreWindow
        case closeWindow
        case stopPiPAndShowWindow
    }

    public private(set) var active = false
    public private(set) var windowHidden = false
    public private(set) var awaitingFullScreenExit = false
    public private(set) var restoring = false

    public init() {}

    /// Picture in Picture finished entering its floating window.
    public mutating func didStart(windowIsFullScreen: Bool) -> Action {
        active = true
        restoring = false
        if windowIsFullScreen {
            awaitingFullScreenExit = true
            return .exitFullScreenThenHide
        }
        windowHidden = true
        return .hideWindow
    }

    /// The player window finished leaving macOS Full Screen after Picture in Picture started.
    public mutating func didExitFullScreen() -> Action {
        guard awaitingFullScreenExit else { return .none }
        awaitingFullScreenExit = false
        guard active else { return .none }
        windowHidden = true
        return .hideWindow
    }

    /// The viewer clicked the PiP window's return-to-window button.
    public mutating func willRestore() -> Action {
        restoring = true
        awaitingFullScreenExit = false
        let wasHidden = windowHidden
        windowHidden = false
        return wasHidden ? .restoreWindow : .none
    }

    /// Picture in Picture stopped, either after a restore or because the viewer closed the floating window.
    public mutating func didStop() -> Action {
        active = false
        awaitingFullScreenExit = false
        let shouldClose = windowHidden && !restoring
        windowHidden = false
        restoring = false
        return shouldClose ? .closeWindow : .none
    }

    /// A channel is about to be presented in the player window.
    /// `continuing`: true when advancing within the same series or folder while PiP is running.
    public mutating func willPresent(continuing: Bool) -> Action {
        if !active && !windowHidden { return .restoreWindow }
        if continuing { return .none }
        restoring = true
        windowHidden = false
        awaitingFullScreenExit = false
        return .stopPiPAndShowWindow
    }

    /// The player window closed.
    public mutating func windowClosed() {
        active = false
        windowHidden = false
        awaitingFullScreenExit = false
        restoring = false
    }
}

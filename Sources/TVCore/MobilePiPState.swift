import Foundation

/// Tracks whether iOS Picture in Picture was started by the viewer inside the app or automatically by iOS on leaving
/// the app.
///
/// Manual PiP dismisses the player screen so the viewer can browse Yingxia under the floating window, remembering
/// whether the player was in landscape so returning restores it (#2483). Automatic PiP keeps the player screen open in
/// its orientation and returns straight into it when the viewer switches back to Yingxia via the home bar (#2441) or
/// taps the PiP window's return button (#2483).
public struct MobilePiPState: Sendable, Equatable {
    public private(set) var active = false
    /// True once manual in-app PiP is up and the player screen should dismiss so the video floats over the app.
    public private(set) var floating = false
    public private(set) var startedManually = false
    public private(set) var stopping = false

    public init() {}

    /// Viewer tapped the player's Picture in Picture button to enter PiP.
    public mutating func beginManualStart() {
        startedManually = true
    }

    public mutating func willStart() {
        active = true
        stopping = false
    }

    /// Picture in Picture is now floating. Sets `floating` only for manual in-app PiP so automatic background PiP
    /// leaves the player screen (and its landscape orientation) intact.
    public mutating func didStart() {
        active = true
        if startedManually { floating = true }
    }

    public mutating func willStop() {
        stopping = true
    }

    public mutating func didStop() {
        active = false
        floating = false
        startedManually = false
        stopping = false
    }

    public mutating func didFailToStart() {
        active = false
        floating = false
        startedManually = false
        stopping = false
    }

    /// True when returning the app to the foreground should stop automatic PiP so playback lands straight back in
    /// the open player screen (#2441).
    public mutating func shouldStopOnAppActive() -> Bool {
        guard active, !startedManually, !stopping else { return false }
        stopping = true
        return true
    }
}

import Foundation

/// Decides which interface orientations the iPhone app allows and whether a state change should request an explicit
/// geometry update from UIKit.
///
/// Extracted from `PlayerOrientation` so watch-page portrait holds, standalone full-screen covers, and iPhone Duo
/// fold/unfold transitions (#1967, #1528, #2103) stay balanced and unit-tested.
public struct OrientationPolicy: Sendable, Equatable {
    public enum Allowed: Sendable, Equatable {
        case allButUpsideDown
        case landscape
        case portrait
    }

    public enum Request: Sendable, Equatable {
        /// Re-query `supportedInterfaceOrientations` without forcing the scene to portrait.
        case refresh
        case landscape
        case portrait
    }

    public private(set) var lockedLandscape = false
    public private(set) var portraitHoldCount = 0
    public private(set) var standalonePlayerCount = 0

    public init() {}

    public var allowed: Allowed {
        if lockedLandscape { return .landscape }
        if portraitHoldCount > 0 && standalonePlayerCount == 0 { return .portrait }
        return .allButUpsideDown
    }

    /// Explicit rotate button, watch-page Full Screen toggle, or Start in Full Screen.
    public mutating func set(landscape: Bool) -> Request {
        lockedLandscape = landscape
        return landscape ? .landscape : .portrait
    }

    /// Drops a landscape lock when closing the player or unfolding iPhone Duo to its inner display.
    /// `forcePortrait`: true when closing a landscape-locked player on a compact phone screen; false when unfolding
    /// to a large display so the inner screen isn't forced into portrait (#1967, #1528).
    public mutating func release(forcePortrait: Bool = true) -> Request? {
        guard lockedLandscape else { return nil }
        lockedLandscape = false
        return forcePortrait ? .portrait : .refresh
    }

    /// Reference-counted portrait hold while a watch page is on screen. Releasing it never forces portrait, and
    /// acquiring it does not override a standalone full-screen player presented above it (for example after folding
    /// iPhone Duo from its inner display to its outer display, #1967, #1528, #2103).
    public mutating func holdPortrait(_ hold: Bool) -> Request? {
        let before = allowed
        if hold { portraitHoldCount += 1 }
        else { portraitHoldCount = max(0, portraitHoldCount - 1) }
        let after = allowed
        guard before != after else { return nil }
        return after == .portrait ? .portrait : .refresh
    }

    /// Marks a standalone full-screen player cover as presented or dismissed. While active, any watch page underneath
    /// cannot lock the screen to portrait; once dismissed, the watch page's portrait hold takes effect again.
    public mutating func setStandalonePlayer(_ active: Bool) -> Request? {
        let before = allowed
        if active { standalonePlayerCount += 1 }
        else { standalonePlayerCount = max(0, standalonePlayerCount - 1) }
        let after = allowed
        guard before != after else { return nil }
        return after == .portrait ? .portrait : .refresh
    }
}

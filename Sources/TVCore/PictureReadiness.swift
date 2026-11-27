import Foundation

/// Decides when the player's waiting backdrop gives way to the video picture (#2636, #1629, #1956) and keeps it up
/// while a stream plays sound without a picture yet (#2032, #1680, #2454).
///
/// Watching `AVPlayerLayer.isReadyForDisplay` (or `AVPlayerViewController.isReadyForDisplay` on Apple TV) lets the
/// backdrop vanish on the frame the picture lands instead of waiting for `timeControlStatus == .playing` plus a fixed
/// delay, and keeps the backdrop in place while a pictureless stream is checked or repackaged. Because
/// `removeAllItems()` clears `isReadyForDisplay` asynchronously on the next tick, a new episode started while the
/// previous one's frame was still marked ready ignores that stale `true` until it clears or a video track reports
/// drawn frames.
public struct PictureReadiness: Sendable, Equatable {
    public private(set) var hasObserver = false
    public private(set) var displayReady = false
    /// `displayReady` was still `true` from the previous item when a new episode or repackaged copy opened.
    public private(set) var stale = false

    public init() {}

    /// A new episode or repackaged stream is opening; any `displayReady` still held belongs to the previous item.
    public mutating func reset() {
        stale = displayReady
    }

    /// Updates `isReadyForDisplay` from the player layer or controller.
    public mutating func displayChanged(_ ready: Bool) {
        hasObserver = true
        displayReady = ready
        if !ready { stale = false }
    }

    /// Whether a fresh video frame of the current item is ready to display.
    public var hasFreshFrame: Bool { displayReady && !stale }

    /// Whether the backdrop should step aside immediately because a video frame of the current item is ready.
    public func shouldReveal(itemReady: Bool, pendingResume: Bool, checkingPicture: Bool,
                             repackagingSegments: Bool, hasVideoFrameRate: Bool = false) -> Bool {
        guard itemReady, !pendingResume, !checkingPicture, !repackagingSegments else { return false }
        return hasFreshFrame || hasVideoFrameRate
    }

    /// Whether a playing item with no video frame yet should still reveal the player: for headless sessions without a
    /// display layer, or once any picture / HLS-segment check has ruled out a missing picture (an audio-only stream).
    public func shouldRevealWithoutFrame(itemReady: Bool, playing: Bool, pendingResume: Bool, checkingPicture: Bool,
                                         checkingSegments: Bool, repackagingSegments: Bool) -> Bool {
        guard itemReady, playing, !pendingResume, !checkingPicture, !repackagingSegments else { return false }
        if !hasObserver { return true }
        return !checkingSegments
    }
}

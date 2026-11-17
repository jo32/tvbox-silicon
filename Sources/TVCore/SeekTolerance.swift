import Foundation

/// How far from the time asked for a seek may land, so the player can start from a keyframe near it (#1213, #1224).
///
/// An exact seek first reads and decodes every frame from the keyframe before the target up to it. On a 4K60 file with
/// keyframes four seconds apart that is about 15 MB to fetch before the picture moves, which takes seconds from a cloud
/// drive, and more the higher the frame rate and bitrate. Other players land on a keyframe: KSPlayer by default
/// (`isAccurateSeek = false`), mpv's seek bar while it is dragged and its relative seeks, and AVPlayer's own
/// `seek(to:)`, which the ±10 skips already use.
public enum SeekTolerance {
    /// The most a seek may land from its target either way: half of the ten seconds between keyframes that x264 and
    /// x265 leave by default in a 24 or 25 fps film, so there is always one in reach.
    public static let widest = 5.0
    /// The least, so a keyframe four seconds apart (250 frames at 60 fps) is often within reach.
    public static let narrowest = 2.0

    /// A seek bar or a slide across the picture let go: within about ten points' worth of the finger, which can't pick
    /// a time any finer, between `narrowest` and `widest`.
    /// - Parameter secondsPerPoint: how much time one point of the drag moves, at the scrubbing speed used.
    public static func release(secondsPerPoint: Double) -> Double {
        guard secondsPerPoint.isFinite, secondsPerPoint > 0 else { return 0 }
        return min(widest, max(narrowest, secondsPerPoint * 10))
    }

    /// A skip of `seconds`: up to a quarter of it either way, so it always moves at least three quarters of the way
    /// and never back the other way.
    public static func skip(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        return min(widest, abs(seconds) / 4)
    }
}

/// After a jump, playing again once a few seconds are in, rather than when AVPlayer predicts the download will keep up
/// (#1213). On a link only a little faster than the video, that prediction took 4 to 24 s after a skip whose picture
/// was there within a second. KSPlayer starts with 3 s loaded (`preferredForwardBufferDuration`); mpv resumes after
/// 1 s (`cache-pause-wait`).
public enum SeekResume {
    /// Seconds loaded past the playhead that are enough to play again.
    public static let ahead = 3.0
    /// How long after a jump this holds; later waits are left to AVPlayer.
    public static let window = 15.0

    /// Where the clock was, and how fast it ran: AVPlayer posts the same jump notice for a rate change (a play, a hold
    /// at 2×) as for a seek, so a jump is a clock more than a second from where this says it should be.
    public struct Clock: Equatable, Sendable {
        public var seconds: Double
        public var at: TimeInterval
        /// The rate it was playing at, 0 while paused or waiting.
        public var rate: Double
        public init(seconds: Double, at: TimeInterval, rate: Double) { self.seconds = seconds; self.at = at; self.rate = rate }

        public func jumped(to seconds: Double, at time: TimeInterval) -> Bool {
            guard seconds.isFinite, self.seconds.isFinite else { return false }
            return abs(seconds - (self.seconds + max(0, time - at) * rate)) > 1
        }
    }

    /// Whether a player waiting for its buffer should play now.
    /// - Parameters:
    ///   - ahead: seconds loaded past the playhead.
    ///   - remaining: seconds left in the video; what's left of a video near its end is enough when it is all in.
    public static func shouldPlay(ahead: Double, remaining: Double) -> Bool {
        guard ahead.isFinite, ahead > 0 else { return false }
        return ahead >= Self.ahead || (remaining.isFinite && ahead >= remaining - 0.25)
    }
}

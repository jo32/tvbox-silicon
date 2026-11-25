import Foundation

/// Touch and hold the picture to play faster, as in Douyin, YouTube, X and Telegram. The hold starts at the speed
/// chosen in Settings; sliding sideways steps through `rates` (Telegram), down to half speed on the left, and sliding
/// down keeps the speed after the finger lifts (X), until its label is tapped.
public struct SpeedBoost: Equatable, Sendable {
    public static let key = "player.holdSpeed"
    public static let rates: [Double] = [0.5, 1, 1.5, 2, 2.5, 3, 4]
    /// The speeds a hold can start at: normal speed only on the way between slower and faster.
    public static let startRates = rates.filter { $0 != 1 }
    public static let standard = 2.0
    /// The setting's Off (#1149): touching and holding the picture does nothing, for those who'd rather it didn't.
    public static let off = 0.0
    /// Whether a hold plays faster at the speed chosen in Settings.
    public static func isOn(_ rate: Double) -> Bool { rate.isFinite && rate > 0 }
    /// Sideways distance, in points, from one rate to the next.
    public static let step = 50.0
    /// Downward distance, in points, that keeps the speed.
    public static let lockDistance = 80.0

    private let start: Int
    public private(set) var rate: Double
    public private(set) var locked = false

    /// Starts at the rate in `rates` nearest to `rate`.
    public init(rate: Double) {
        let wanted = rate.isFinite ? rate : Self.standard
        start = Self.rates.indices.min { abs(Self.rates[$0] - wanted) < abs(Self.rates[$1] - wanted) } ?? 1
        self.rate = Self.rates[start]
    }

    /// The finger is `x` points right of and `y` points below where the hold began.
    public mutating func moved(x: Double, y: Double) {
        guard x.isFinite, y.isFinite else { return }
        if y >= Self.lockDistance { locked = true }
        let steps = Int((x / Self.step).rounded(.towardZero))
        rate = Self.rates[min(max(0, start + steps), Self.rates.count - 1)]
    }
}

extension SpeedBoost {
    /// Seconds of video buffered past `now` from `AVPlayerItem.loadedTimeRanges` (`(start, end)` in seconds).
    /// Nil when no loaded range covers or closely follows `now`, so an empty or stale range list isn't mistaken for
    /// an exhausted buffer (#2175).
    public static func bufferedAhead(ranges: [(start: Double, end: Double)], at now: Double) -> Double? {
        guard now.isFinite else { return nil }
        let tolerance = 0.5
        let valid = ranges
            .filter { $0.start.isFinite && $0.end.isFinite && $0.end >= $0.start }
            .sorted { $0.start < $1.start }
        guard let first = valid.firstIndex(where: { $0.start <= now + tolerance && $0.end >= now }) else { return nil }
        var end = valid[first].end
        for next in valid[(first + 1)...] {
            guard next.start <= end + tolerance else { break }
            end = max(end, next.end)
        }
        return max(0, end - now)
    }

    /// A hold faster than the connection delivers keeps stopping to buffer (issue #364): a 4K episode at 4× needs four
    /// times its bitrate. While a hold plays faster than normal speed, the speed steps down through `rates` before the
    /// buffered video runs out, and back up toward the speed asked for while the download keeps up, so it plays at
    /// about the fastest speed the connection sustains instead of the one that stalls. It is fed the seconds of video
    /// buffered ahead of the playhead once a second; the measured download speed alone can't tell, as the player
    /// stops downloading whenever its buffer is full.
    public struct Throttle: Equatable, Sendable {
        /// The speed the hold asked for.
        public let wanted: Double
        /// The speed to play at now.
        public private(set) var rate: Double
        /// The buffer ahead when the current speed was last judged, and the samples since.
        private var mark: Double?
        private var samples = 0
        /// The buffer ahead at the previous sample, and how many samples in a row it shrank.
        private var previous: Double?
        private var draining = 0

        /// Slower when the buffer would last fewer seconds than this at the current speed: the buffered video is used
        /// up first, rather than the speed given up early (#796).
        public static let low = 3.0
        /// Faster only when it would last half as long again at the next speed.
        public static let roomy = 6.0
        /// Seconds the buffer has to hold up at one speed before the next one is tried.
        public static let settle = 5
        /// A drop smaller than this is sampling jitter rather than the buffer draining.
        public static let drainStep = 0.25
        /// Consecutive shrinking samples before stepping down without a stall: a steady or growing small buffer
        /// (after a seek, or a player that only keeps a few seconds in `loadedTimeRanges`) is keeping up (#2175).
        public static let drainSamples = 2

        /// A hold that slides on from a speed the connection already held lower starts at that lower speed.
        public init(wanted: Double, after previous: Throttle? = nil) {
            self.wanted = wanted
            if let previous, previous.rate < previous.wanted { rate = min(wanted, previous.rate) } else { rate = wanted }
        }

        public var limited: Bool { rate < wanted }

        /// `ahead`: seconds of video buffered past the playhead, or nil when unreported; `waiting`: playback stopped
        /// because the buffer ran out, not the moment AVPlayer takes to judge a new speed, which said nothing about
        /// the connection (#796); `remaining`: seconds left in the video.
        public mutating func update(ahead: Double?, waiting: Bool, remaining: Double = .infinity) {
            guard wanted > 1 else { return }
            let known = ahead.flatMap { $0.isFinite ? max(0, $0) : nil }
            let steps = SpeedBoost.rates.filter { $0 >= 1 && $0 <= wanted }
            guard let index = steps.firstIndex(of: rate) else { return }
            let atEnd = known.map { remaining.isFinite && $0 >= remaining - 0.5 } ?? false
            if let known, !atEnd {
                if let last = previous {
                    if known < last - Self.drainStep { draining += 1 } else { draining = 0 }
                } else {
                    draining = 0
                }
                previous = known
            } else {
                previous = nil
                draining = 0
            }
            let lowAndDraining = known.map { !atEnd && draining >= Self.drainSamples && $0 / rate < Self.low } ?? false
            if waiting || lowAndDraining {
                if index > 0 { rate = steps[index - 1] }
                mark = nil; samples = 0
                return
            }
            if let known {
                guard let start = mark else { mark = known; samples = 0; return }
                samples += 1
                guard samples >= Self.settle else { return }
                // The buffer didn't shrink at this speed: the download keeps up (or the buffer is full), so try the next.
                if index + 1 < steps.count, atEnd || (known >= start && known / steps[index + 1] >= Self.roomy) { rate = steps[index + 1] }
                mark = known; samples = 0
            } else {
                // Unreported buffer, playing without stalling: after `settle` clean seconds, try the next speed again.
                samples += 1
                guard samples >= Self.settle else { return }
                if index + 1 < steps.count { rate = steps[index + 1] }
                samples = 0
            }
        }
    }
}

/// The right arrow key on the Mac: a tap skips ahead, and held past `delay` it plays faster until it is let go, as
/// in Bilibili (issue #871). It follows the key itself and not the key repeat, which can be slow or switched off.
public struct KeyHold: Equatable, Sendable {
    /// Seconds a key stays down before it counts as held.
    public static let delay = 0.35
    public enum Release: Equatable, Sendable {
        /// Let go before `delay`, after it, or without its press having been seen.
        case tap, held, stray
    }
    public private(set) var isDown = false
    private var isHeld = false

    public init() {}

    /// A key-down event. True for the press itself, which starts the wait; the repeats that follow change nothing,
    /// and neither do those of a key that was already down before its events came here.
    public mutating func press(repeated: Bool) -> Bool {
        guard !isDown, !repeated else { return false }
        isDown = true; isHeld = false
        return true
    }

    /// `delay` after the press. True when the key is still down, so the hold begins.
    public mutating func wait() -> Bool {
        guard isDown, !isHeld else { return false }
        isHeld = true
        return true
    }

    public mutating func release() -> Release {
        defer { isDown = false; isHeld = false }
        return isHeld ? .held : isDown ? .tap : .stray
    }
}

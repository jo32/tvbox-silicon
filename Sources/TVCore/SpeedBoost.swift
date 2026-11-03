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

        /// Slower when the buffer would last fewer seconds than this at the current speed.
        public static let low = 4.0
        /// Faster only when it would last half as long again at the next speed.
        public static let roomy = 6.0
        /// Seconds the buffer has to hold up at one speed before the next one is tried.
        public static let settle = 5

        /// A hold that slides on from a speed the connection already held lower starts at that lower speed.
        public init(wanted: Double, after previous: Throttle? = nil) {
            self.wanted = wanted
            if let previous, previous.rate < previous.wanted { rate = min(wanted, previous.rate) } else { rate = wanted }
        }

        public var limited: Bool { rate < wanted }

        /// `ahead`: seconds of video buffered past the playhead; `waiting`: playback stopped to buffer.
        public mutating func update(ahead: Double, waiting: Bool) {
            guard wanted > 1, ahead.isFinite else { return }
            let steps = SpeedBoost.rates.filter { $0 >= 1 && $0 <= wanted }
            guard let index = steps.firstIndex(of: rate) else { return }
            if waiting || ahead / rate < Self.low {
                if index > 0 { rate = steps[index - 1] }
                mark = nil
                return
            }
            guard let start = mark else { mark = ahead; samples = 0; return }
            samples += 1
            guard samples >= Self.settle else { return }
            // The buffer didn't shrink at this speed: the download keeps up (or the buffer is full), so try the next.
            if index + 1 < steps.count, ahead >= start, ahead / steps[index + 1] >= Self.roomy { rate = steps[index + 1] }
            mark = ahead; samples = 0
        }
    }
}

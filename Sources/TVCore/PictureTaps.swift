import Foundation

/// Taps on the picture, as in YouTube: one shows or hides the controls at once; a second soon after, on a side, skips
/// 10 seconds with the controls hidden, and each further tap on that side skips 10 more. Two in the middle play or pause.
public struct PictureTaps: Sendable {
    public enum Zone: Sendable { case back, middle, forward }

    public enum Action: Equatable, Sendable {
        case toggleControls
        /// The second tap of two in the middle: undo the first one's toggle, then play or pause.
        case togglePlayback
        /// Skip `seconds`; `total` is the run so far, for its label. `first` is the second tap of the double tap.
        case skip(seconds: Double, total: Double, first: Bool)
    }

    /// Between the two taps of a double tap.
    public static let interval = 0.3
    /// Between further taps that keep skipping.
    public static let streak = 0.7
    public static let seconds = 10.0

    private var last: (time: Double, zone: Zone)?
    private var skipping: (zone: Zone, total: Double)?

    public init() {}

    /// The outer thirds skip; without a timeline to skip on, the whole picture is the middle.
    public static func zone(x: Double, width: Double, seekable: Bool) -> Zone {
        guard seekable, width > 0, x.isFinite else { return .middle }
        return x < width / 3 ? .back : x > width * 2 / 3 ? .forward : .middle
    }

    /// A tap at `time` seconds (any steady clock).
    public mutating func tap(at time: Double, in zone: Zone) -> Action {
        let previous = last
        last = (time, zone)
        let seconds = zone == .back ? -Self.seconds : Self.seconds
        if let run = skipping, run.zone == zone, let previous, time - previous.time <= Self.streak {
            skipping = (zone, run.total + Self.seconds)
            return .skip(seconds: seconds, total: run.total + Self.seconds, first: false)
        }
        skipping = nil
        guard let previous, previous.zone == zone, time - previous.time <= Self.interval else { return .toggleControls }
        if zone == .middle {
            // A third tap starts over rather than pausing again.
            last = nil
            return .togglePlayback
        }
        skipping = (zone, Self.seconds)
        return .skip(seconds: seconds, total: Self.seconds, first: true)
    }
}

/// Whether two taps on a side skip (the default) or, with this off, play or pause as two taps in the middle do.
public enum PictureDoubleTap {
    public static let key = "player.doubleTapSkips"
}

/// Sliding sideways across the picture moves through the video (Bilibili, Tencent Video): the picture's width is up
/// to three minutes, or the whole video when it is shorter.
public enum PictureSeek {
    public static let span = 180.0

    public static func target(from start: Double, moved x: Double, width: Double, duration: Double) -> Double {
        guard width > 0, duration > 0, duration.isFinite, start.isFinite, x.isFinite else { return start }
        return min(max(0, start + x / width * min(duration, span)), duration)
    }
}

/// Sliding up or down the picture sets the screen's brightness on its left half and the volume on its right (Bilibili,
/// Tencent Video): three quarters of the picture's height is the whole range.
public enum PictureLevel {
    public static let key = "player.slidesLevels"
    /// Slides that start this close to the top or bottom are left to Notification Center, Control Center and the
    /// Home indicator.
    public static let edge = 44.0

    public static func slides(fromY y: Double, height: Double) -> Bool { y >= edge && y <= height - edge }

    public static func value(from start: Double, moved y: Double, height: Double) -> Double {
        guard height > 0, start.isFinite, y.isFinite else { return start }
        return min(max(0, start - y / (height * 0.75)), 1)
    }
}

import Foundation

/// Taps on the picture: one waits `interval` for a second before showing or hiding the controls, so a double tap
/// doesn't flash them (#2148). Two in the middle play or pause; two on a side skip 10 seconds with the controls hidden,
/// and each further tap on that side skips 10 more right away.
public struct PictureTaps: Sendable {
    public enum Zone: Sendable { case back, middle, forward }

    public enum Action: Equatable, Sendable {
        /// A first tap that could still become a double tap: wait `interval`, then call `settle()`.
        case wait
        /// Two taps in the middle: play or pause without touching the controls.
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
    private var pending = false

    public init() {}

    /// The outer thirds skip; without a timeline to skip on, the whole picture is the middle.
    public static func zone(x: Double, width: Double, seekable: Bool) -> Zone {
        guard seekable, width > 0, x.isFinite else { return .middle }
        return x < width / 3 ? .back : x > width * 2 / 3 ? .forward : .middle
    }

    /// A tap at `time` seconds (any steady clock); a skip moves `step` seconds (`SkipInterval`).
    public mutating func tap(at time: Double, in zone: Zone, step: Double = Self.seconds) -> Action {
        let previous = last
        last = (time, zone)
        let seconds = zone == .back ? -step : step
        if let run = skipping, run.zone == zone, let previous, time - previous.time <= Self.streak {
            pending = false
            skipping = (zone, run.total + step)
            return .skip(seconds: seconds, total: run.total + step, first: false)
        }
        skipping = nil
        guard let previous, previous.zone == zone, time - previous.time <= Self.interval else {
            pending = true
            return .wait
        }
        pending = false
        if zone == .middle {
            // A third tap starts over rather than pausing again.
            last = nil
            return .togglePlayback
        }
        skipping = (zone, step)
        return .skip(seconds: seconds, total: step, first: true)
    }

    /// Called once `interval` has passed after `.wait` without another tap: finishes the single tap and returns `true`
    /// if the controls should toggle.
    public mutating func settle() -> Bool {
        guard pending else { return false }
        pending = false
        last = nil
        return true
    }

    /// Drops any waiting single tap or skip run when another gesture or control takes over.
    public mutating func cancel() {
        pending = false
        last = nil
        skipping = nil
    }
}

/// How far the skip buttons and a double tap on a side move (#929): 10 seconds unless chosen otherwise, from the
/// steps the system's skip symbols are drawn for.
public enum SkipInterval {
    public static let key = "player.skipSeconds"
    public static let standard = 10.0
    public static let choices: [Double] = [5, 10, 15, 30, 45, 60, 75, 90]

    /// A stored value that isn't one of the choices skips the standard 10 seconds.
    public static func seconds(_ stored: Double) -> Double { choices.contains(stored) ? stored : standard }

    public static func symbol(forward: Bool, seconds: Double) -> String {
        (forward ? "goforward." : "gobackward.") + String(Int(Self.seconds(seconds)))
    }
}

/// How the picture meets the screen (#952, #1111), as in Infuse and VLC: whole inside it, filling it and cropped, or
/// stretched to its shape. Pinching moves between Fit and Fill; the choice stays for the next video.
public enum VideoFill: String, CaseIterable, Sendable {
    case fit, fill, stretch
    public static let key = "player.videoFill"
}

/// Whether two taps on a side skip or, with this off, play or pause as two taps in the middle do. Off unless turned
/// on: skipping by accident was the commoner complaint (#1745).
public enum PictureDoubleTap {
    public static let key = "player.doubleTapSkips"
    public static let standard = false
}

/// The edge the full-screen lock button sits on: the left, as in Bilibili, or the right, for the thumb of a hand that
/// holds the phone there (#1922).
public enum LockButtonSide: String, CaseIterable, Sendable {
    case left, right
    public static let key = "player.lockSide"

    /// A stored value that isn't a side is the left.
    public static func side(_ stored: String) -> LockButtonSide { LockButtonSide(rawValue: stored) ?? .left }
}

/// Picture in Picture on iPhone and iPad (#1731): off, the player has no button for it and leaving the app while a
/// video plays doesn't start it.
public enum PictureInPicturePreference {
    public static let key = "player.pictureInPicture"

    public static func isOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
    }
}

/// The video's tags over the seek bar in full screen (HW, H265, 4K…): shown unless turned off (#1534).
public enum PlaybackTags {
    public static let key = "player.showsTags"
}

/// The battery in the player's status as a number instead of the gauge (#1743). iOS tells apps the level in steps of
/// 5%, so the number is the nearest step: it can read 60% beside the system's 62%.
public enum BatteryPercentage {
    public static let key = "player.batteryPercentage"

    /// 0 to 100 from a level of 0 to 1, whatever the device reports.
    public static func percent(_ level: Double) -> Int {
        guard level.isFinite else { return 0 }
        return Int((min(max(level, 0), 1) * 100).rounded())
    }
}

/// Sliding sideways across the picture moves through the video (Bilibili, Tencent Video): the picture's width is up
/// to three minutes, or the whole video when it is shorter.
public enum PictureSeek {
    public static let span = 180.0

    public static func target(from start: Double, moved x: Double, width: Double, duration: Double) -> Double {
        guard width > 0, duration > 0, duration.isFinite, start.isFinite, x.isFinite else { return start }
        return min(max(0, start + x / width * min(duration, span)), duration)
    }

    /// How much time one point of the slide moves.
    public static func secondsPerPoint(width: Double, duration: Double) -> Double {
        guard width > 0, duration > 0, duration.isFinite else { return 0 }
        return min(duration, span) / width
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

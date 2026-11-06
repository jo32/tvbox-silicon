import Foundation

/// How late subtitles show, in seconds (#599). A source's subtitle file can sit ahead of its picture, and the
/// player has no other way to pull it back: the delay waits before a line AVPlayer hands over is drawn. Zero
/// keeps AVPlayer's own timing, so a viewer who never sets it sees no change.
public enum SubtitleDelay {
    public static let key = "subtitleDelay"
    /// Posted on the main thread when `save` stores a new delay, so a video playing takes it at once.
    public static let changed = Notification.Name("SubtitleDelayChanged")
    /// A subtitle running far ahead of the picture is a mismatched file, not a timing to correct by a minute.
    public static let range: ClosedRange<Double> = 0...30
    public static let step: Double = 0.5

    public static func load(_ defaults: UserDefaults = .standard) -> Double {
        clamped(defaults.double(forKey: key))
    }

    public static func save(_ seconds: Double, _ defaults: UserDefaults = .standard) {
        defaults.set(clamped(seconds), forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// A delay the player can wait: a number in `range`, and 0 for anything that isn't one.
    public static func clamped(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        return min(max(seconds, range.lowerBound), range.upperBound)
    }

    /// How the delay reads in Settings and in the player's menu.
    public static func title(_ seconds: Double) -> String {
        clamped(seconds) == 0 ? L10n.text("In sync") : String(format: "%+.1f s", clamped(seconds))
    }
}

import Foundation

/// The playback speed a new title starts at (Settings › Playback on iPhone and
/// iPad). It survives relaunching the app. The next episodes of a title keep the
/// speed picked in the player; live channels and music are unaffected.
///
/// The value lives in `UserDefaults` under `key`, validated against the speeds
/// offered by the player menus, and defaults to `standard` (1×) when absent or
/// invalid.
public enum PlaybackSpeed {
    public static let key = "player.playbackSpeed"
    public static let standard: Float = 1.0

    /// The speeds offered by the in-player menus, the only legal values.
    public static let speeds: [Float] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4]

    /// The speed a new player should start at.
    public static func load(defaults: UserDefaults = .standard) -> Float {
        let value = defaults.float(forKey: key)
        return speeds.contains(value) ? value : standard
    }

    /// The speed set in Settings › Playback, or nil when none was ever set (videos then keep the player's speed).
    public static func chosen(defaults: UserDefaults = .standard) -> Float? {
        guard defaults.object(forKey: key) != nil else { return nil }
        let value = defaults.float(forKey: key)
        return speeds.contains(value) ? value : nil
    }

    /// Records the speed a new player should start at.
    public static func save(_ speed: Float, defaults: UserDefaults = .standard) {
        guard speeds.contains(speed) else { return }
        defaults.set(speed, forKey: key)
    }

    /// A short label for a speed, matching the player menu ("1×", "1.5×", …).
    public static func speedLabel(_ speed: Float) -> String {
        speed == 1 ? "1×" : String(format: "%g×", speed)
    }
}

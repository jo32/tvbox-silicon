import Foundation

public struct EpisodeSkipSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var introEnd: Double
    /// Store the distance from the end so episodes with different lengths remain usable.
    public var outroLength: Double

    public init(enabled: Bool = false, introEnd: Double = 0, outroLength: Double = 0) {
        self.enabled = enabled; self.introEnd = introEnd; self.outroLength = outroLength
    }

    public static func introLimit(_ duration: Double) -> Double { min(300, duration / 4) }
    public static func outroLimit(_ duration: Double) -> Double { min(600, duration / 4) }

    public func validationError(duration: Double) -> String? {
        guard duration.isFinite, duration > 0 else { return L10n.text("Wait for the video duration. Live streams cannot use skipping.") }
        guard duration >= 120 else { return L10n.text("Skipping is available for videos at least two minutes long.") }
        guard introEnd.isFinite, outroLength.isFinite, introEnd >= 0, outroLength >= 0 else { return L10n.text("Enter a valid time such as 01:30.") }
        guard introEnd <= Self.introLimit(duration) else { return L10n.text("The intro cannot exceed five minutes or a quarter of the video.") }
        guard outroLength <= Self.outroLimit(duration) else { return L10n.text("The outro cannot exceed ten minutes or a quarter of the video.") }
        guard duration - introEnd - outroLength >= max(60, duration * 0.6) else { return L10n.text("Keep at least 60% of the video as main content.") }
        return nil
    }

    /// These settings with the intro ending, or the outro starting, at `position`, and switched on: what Apple TV's
    /// "Intro Ends Here" saves, where there is no keyboard for a time (#808). Nil where the rules above refuse it.
    public func marking(intro: Bool, at position: Double, duration: Double) -> Self? {
        guard position.isFinite, duration.isFinite, position >= 0, position <= duration else { return nil }
        var value = self
        value.enabled = true
        if intro { value.introEnd = position.rounded(.down) } else { value.outroLength = (duration - position).rounded(.up) }
        return value.validationError(duration: duration) == nil ? value : nil
    }

    public static func parseTime(_ text: String) -> Double? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0
        for (index, part) in parts.enumerated() {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(part), number <= 86_400,
                  index == 0 || number < 60 else { return nil }
            total = total * 60 + number
            guard total <= 86_400 else { return nil }
        }
        return Double(total)
    }

    public static func formatTime(_ time: Double) -> String {
        guard time.isFinite, (0...86_400).contains(time) else { return "00:00" }
        let seconds = Int(time.rounded(.down))
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    public static func scope(origin: URL, source: String, video: String) -> String {
        // JSON encoding avoids collisions between identifiers containing delimiters.
        String(data: try! JSONEncoder().encode([origin.absoluteString, source, video]), encoding: .utf8)!
    }

    public static func load(scope: String, defaults: UserDefaults = .standard) -> Self {
        // Do not migrate a global time into every work: it belongs to an unknown previous film.
        var value = defaults.data(forKey: "episodeSkip.v1." + scope).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
        value.enabled = defaults.object(forKey: "episodeSkip.auto.v2") as? Bool ?? loadGlobal(defaults: defaults).enabled
        return value
    }

    public static func loadGlobal(defaults: UserDefaults = .standard) -> Self {
        defaults.data(forKey: "episodeSkip.global.v1").flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
    }

    public func saveGlobal(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: "episodeSkip.global.v1")
    }

    public func save(scope: String, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: "episodeSkip.v1." + scope)
        defaults.set(enabled, forKey: "episodeSkip.auto.v2")
    }
    public static func remove(scope: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: "episodeSkip.v1." + scope)
    }
}

/// Each segment is skipped once per play-through. Rewinding manually never traps the viewer
/// in an automatic seek loop; restarting playback or applying new settings starts a new pass.
public struct EpisodeSkipPass: Sendable {
    private var introHandled = false
    private var outroHandled = false
    public init() {}

    public mutating func target(time: Double, duration: Double, playing: Bool, settings: EpisodeSkipSettings) -> Double? {
        guard playing, time.isFinite, time >= 0, time <= duration, settings.enabled,
              settings.validationError(duration: duration) == nil else { return nil }
        if !introHandled {
            introHandled = true
            if settings.introEnd > 0, time < settings.introEnd { return settings.introEnd }
        }
        if !outroHandled, settings.outroLength > 0, time >= duration - settings.outroLength {
            outroHandled = true
            return max(time, duration - 0.05)
        }
        return nil
    }
}

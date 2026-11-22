import Foundation

public struct EpisodeSkipSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var introEnd: Double
    /// Store the distance from the end so episodes with different lengths remain usable.
    public var outroLength: Double

    public init(enabled: Bool = false, introEnd: Double = 0, outroLength: Double = 0) {
        self.enabled = enabled; self.introEnd = introEnd; self.outroLength = outroLength
    }

    /// Any times the video has room for, as long as the intro ends before the outro starts. Limits on their length
    /// (five minutes, a quarter of the video, 60% left between) refused the right times for short episodes, such as
    /// an anime's 90-second opening in a 12-minute episode (#1003).
    public func validationError(duration: Double) -> String? {
        guard duration.isFinite, duration > 0 else { return L10n.text("Wait for the video duration. Live streams cannot use skipping.") }
        guard introEnd.isFinite, outroLength.isFinite, introEnd >= 0, outroLength >= 0 else { return L10n.text("Enter a valid time such as 01:30.") }
        guard introEnd + outroLength < duration else { return L10n.text("The intro must end before the outro starts.") }
        return nil
    }

    /// Whether this title has an intro or an outro to skip. Switched on without either, nothing is skipped (#1405).
    public var hasTimes: Bool { introEnd > 0 || outroLength > 0 }

    /// What the players' menus say beside Skip Intro / Outro (#1488): Off, Not Set, or the times, the outro as the time
    /// left when it starts ("Intro 01:30 · Outro −02:00"), which holds for every episode.
    public var summary: String {
        guard enabled else { return L10n.text("Off") }
        guard hasTimes else { return L10n.text("Not set") }
        var parts: [String] = []
        if introEnd > 0 { parts.append(L10n.text("Intro %@", Self.formatTime(introEnd))) }
        if outroLength > 0 { parts.append(L10n.text("Outro %@", "−" + Self.formatTime(outroLength))) }
        return parts.joined(separator: " · ")
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
        value.enabled = isAutomatic(defaults: defaults)
        return value
    }

    /// The one switch for every title (Settings › Playback, and each title's sheet): on, the times saved for a title,
    /// and the credits a source marks, are skipped.
    public static func isAutomatic(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: "episodeSkip.auto.v2") as? Bool ?? loadGlobal(defaults: defaults).enabled
    }

    public static func setAutomatic(_ on: Bool, defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: "episodeSkip.auto.v2")
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

    /// `scope` under a subscription's new address when it was saved under `old`; nil when it belongs to another one.
    /// A subscription whose address the viewer changed (#982) keeps what was saved against its sources this way.
    public static func rescope(_ scope: String, from old: URL, to new: URL) -> String? {
        guard let parts = try? JSONDecoder().decode([String].self, from: Data(scope.utf8)), parts.count == 3,
              parts[0] == old.absoluteString else { return nil }
        return Self.scope(origin: new, source: parts[1], video: parts[2])
    }

    /// Saved scope keys with `old` moved to `new`, in their order, without repeats.
    static func rescope(_ scopes: [String], from old: URL, to new: URL) -> [String] {
        var seen = Set<String>()
        return scopes.map { rescope($0, from: old, to: new) ?? $0 }.filter { seen.insert($0).inserted }
    }

    /// Moves the intro and outro times saved for a subscription's videos to its new address. Times already saved
    /// under the new one stay.
    public static func moveOrigin(from old: URL, to new: URL, defaults: UserDefaults = .standard) {
        let prefix = "episodeSkip.v1."
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(prefix) {
            guard let scope = rescope(String(key.dropFirst(prefix.count)), from: old, to: new) else { continue }
            if defaults.object(forKey: prefix + scope) == nil { defaults.set(value, forKey: prefix + scope) }
            defaults.removeObject(forKey: key)
        }
    }
}

/// Each segment is skipped once per play-through. Rewinding manually never traps the viewer
/// in an automatic seek loop; restarting playback or applying new settings starts a new pass.
public struct EpisodeSkipPass: Sendable {
    /// How long before the outro the player counts down to skipping it, so the viewer can keep it (#1003).
    public static let outroWarning = 5.0
    private var introHandled = false
    private var outroHandled = false
    public init() {}

    /// Seconds until the outro is skipped, while that is `outroWarning` or less; nil before then, and once it is
    /// skipped or kept.
    public func outroCountdown(time: Double, duration: Double, settings: EpisodeSkipSettings) -> Double? {
        guard !outroHandled, settings.enabled, settings.outroLength > 0, time.isFinite,
              settings.validationError(duration: duration) == nil else { return nil }
        let left = duration - settings.outroLength - time
        return left > 0 && left <= Self.outroWarning ? left : nil
    }

    /// The viewer keeps this play-through's outro.
    public mutating func keepOutro() { outroHandled = true }

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

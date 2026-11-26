import Foundation

/// An explicit subtitle choice. Older records contain only AVPlayer's display name and language.
public struct SubtitleChoice: Equatable, Sendable, Codable {
    /// The title it was picked for (`Channel.skipScope`).
    public var scope: String
    public var name: String
    public var language: String?
    public var format: String?
    public var rendition: String?

    public init(scope: String, name: String, language: String?, format: String? = nil, rendition: String? = nil) {
        self.scope = scope; self.name = name; self.language = language; self.format = format; self.rendition = rendition
    }

    /// Which of an episode's tracks is the picked one: the track with its name and language, else the first in its
    /// language. Nil when the episode has none like it, and its subtitles stay as the system set them.
    public func index(among tracks: [(name: String, language: String?)]) -> Int? {
        index(among: tracks, in: scope)
    }

    public func index(among tracks: [(name: String, language: String?)], in other: String?) -> Int? {
        match(tracks.map { TrackLabel.Option(displayName: $0.name, language: $0.language, title: nil) }, in: other)
    }

    public func match(_ tracks: [TrackLabel.Option], in other: String?) -> Int? {
        let candidates = tracks.indices.filter { tracks[$0].language == language }
        if scope == other {
            let named = candidates.filter { (tracks[$0].title ?? tracks[$0].displayName) == name }
            let exact = named.filter { tracks[$0].format == format }
            if let rendition, let same = exact.first(where: { tracks[$0].rendition == rendition }) { return same }
            if let first = exact.first { return first }
            if let title = named.first { return title }
            if let format, let sameFormat = candidates.first(where: { tracks[$0].format == format }) { return sameFormat }
            // A pre-upgrade record may have AVPlayer's display name instead of the rendition title.
            if let legacy = candidates.first(where: { tracks[$0].displayName == name }) { return legacy }
        }
        return language == nil ? nil : candidates.first
    }

    public enum Preference: Equatable, Codable, Sendable {
        case off
        case track(SubtitleChoice)
    }

    private static func titleKey(_ scope: String) -> String { key + ".title." + scope }

    /// For a new series the last language still applies. Off belongs only to the series where it was picked.
    public static func preference(for scope: String?, in defaults: UserDefaults = .standard) -> Preference? {
        if let scope, let data = defaults.data(forKey: titleKey(scope)),
           let local = try? JSONDecoder().decode(Preference.self, from: data) { return local }
        return saved(in: defaults).map(Preference.track)
    }

    public static func remember(_ track: TrackLabel.Option?, for scope: String?, in defaults: UserDefaults = .standard) {
        // Preserve the old single-slot record for its series before replacing the last language.
        if let old = saved(in: defaults), !old.scope.isEmpty, defaults.object(forKey: titleKey(old.scope)) == nil {
            defaults.set(try? JSONEncoder().encode(Preference.track(old)), forKey: titleKey(old.scope))
        }
        let choice = track.map { SubtitleChoice(scope: scope ?? "", name: $0.title ?? $0.displayName, language: $0.language,
                                                format: $0.format, rendition: $0.rendition) }
        if let scope {
            defaults.set(try? JSONEncoder().encode(choice.map(Preference.track) ?? .off), forKey: titleKey(scope))
        }
        if choice?.language != nil || scope == nil { save(choice, in: defaults) }
    }

    public static let key = "player.subtitleChoice"

    /// The last choice made in the player's menu: a track, or nil for Off or none yet.
    public static func saved(in defaults: UserDefaults = .standard) -> SubtitleChoice? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(SubtitleChoice.self, from: $0) }
    }

    public static func save(_ choice: SubtitleChoice?, in defaults: UserDefaults = .standard) {
        if let data = choice.flatMap({ try? JSONEncoder().encode($0) }) { defaults.set(data, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }
}

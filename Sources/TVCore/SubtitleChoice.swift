import Foundation

/// The subtitle track a viewer picked in the player's menu, to pick again in the next episode of the same title,
/// and in this one when its stream is opened again (#779). It is kept across videos and launches (#1174): another
/// title starts with a track in the same language. Off, or no choice yet, leaves each item with the system's choice,
/// usually none.
public struct SubtitleChoice: Equatable, Sendable, Codable {
    /// The title it was picked for (`Channel.skipScope`).
    public var scope: String
    public var name: String
    public var language: String?

    public init(scope: String, name: String, language: String?) {
        self.scope = scope; self.name = name; self.language = language
    }

    /// Which of an episode's tracks is the picked one: the track with its name and language, else the first in its
    /// language. Nil when the episode has none like it, and its subtitles stay as the system set them.
    public func index(among tracks: [(name: String, language: String?)]) -> Int? {
        if let same = tracks.firstIndex(where: { $0.name == name && $0.language == language }) { return same }
        guard let language else { return nil }
        return tracks.firstIndex { $0.language == language }
    }

    /// The same, for a video of title `other`: in another title only a track in the picked language counts, since a
    /// name without one ("Track 3") says nothing about another file's tracks.
    public func index(among tracks: [(name: String, language: String?)], in other: String?) -> Int? {
        guard other == scope || language != nil else { return nil }
        return index(among: tracks)
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

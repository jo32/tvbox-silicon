import Foundation

/// The subtitle track a viewer picked in the player's menu, to pick again in the next episode of the same title,
/// and in this one when its stream is opened again (#779). Each item starts with the system's choice, usually none.
public struct SubtitleChoice: Equatable, Sendable {
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
}

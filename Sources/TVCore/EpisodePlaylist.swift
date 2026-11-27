import Foundation

/// Follow the source's ordering within the current line; never jump to another
/// line or wrap the final episode back to the beginning.
public struct EpisodePlaylist: Sendable {
    public let episodes: [Episode]
    public init(_ episodes: [Episode]) { self.episodes = episodes }
    public var flags: [String] {
        var seen = Set<String>()
        return episodes.map(\.flag).filter { seen.insert($0).inserted }
    }
    public func episodes(for flag: String) -> [Episode] { episodes.filter { $0.flag == flag } }
    public func next(after context: PlaybackHistoryContext) -> Episode? {
        let line = episodes(for: context.episodeFlag)
        guard let current = context.episode(in: line), let index = line.firstIndex(of: current),
              line.indices.contains(index + 1) else { return nil }
        return line[index + 1]
    }
    public func previous(before context: PlaybackHistoryContext) -> Episode? {
        let line = episodes(for: context.episodeFlag)
        guard let current = context.episode(in: line), let index = line.firstIndex(of: current),
              line.indices.contains(index - 1) else { return nil }
        return line[index - 1]
    }

    /// The same episode on the video's other lines, starting right after the current line and wrapping around.
    /// Matches by exact name, else by episode number, else a single-episode film on both lines — the same rules
    /// `PlaybackHistoryEntry.resumePosition(for:among:)` uses to carry progress across lines (#2560).
    public func alternates(for context: PlaybackHistoryContext) -> [Episode] {
        let allFlags = flags
        guard allFlags.count > 1 else { return [] }
        let orderedFlags: [String]
        if let currentIndex = allFlags.firstIndex(of: context.episodeFlag) {
            orderedFlags = (1..<allFlags.count).map { allFlags[(currentIndex + $0) % allFlags.count] }
        } else {
            orderedFlags = allFlags.filter { $0 != context.episodeFlag }
        }
        let currentCount = episodes(for: context.episodeFlag).count
        let currentNumber = CatalogDanmakuMatcher.episodeNumber(context.episodeName)
        return orderedFlags.compactMap { flag -> Episode? in
            let line = episodes(for: flag)
            let exact = line.filter { $0.name == context.episodeName }
            if exact.count == 1 { return exact.first }
            if let currentNumber {
                let numbered = line.filter { CatalogDanmakuMatcher.episodeNumber($0.name) == currentNumber }
                if numbered.count == 1 { return numbered.first }
            }
            if currentCount <= 1, line.count == 1 { return line.first }
            return nil
        }
    }
}

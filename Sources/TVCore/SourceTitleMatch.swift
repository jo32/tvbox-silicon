import Foundation

/// A Discover title among the answers to a search of every source: the results that are that work, best first.
/// Discover's title page shows the best one's episodes and lists the rest under Change Source.
public enum SourceTitleMatch {
    /// How a result's year sits with the work's. A year a year off counts as the same: a release in one country and a
    /// source's listing of it often differ by one.
    public enum Year: Int, Comparable, Sendable {
        case same, unknown, other
        public static func < (lhs: Year, rhs: Year) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// A result that is the work.
    public struct Candidate: Identifiable, Equatable, Sendable {
        public let site: Site
        public let video: Video
        /// The season the title names past the first (X 第二季); nil for the work itself, its first season, or a title
        /// that names none.
        public let laterSeason: Int?
        public let year: Year
        /// Its place among its source's results.
        public let position: Int
        public var id: String { site.key + "\u{1F}" + video.id }
        public static func == (lhs: Candidate, rhs: Candidate) -> Bool { lhs.id == rhs.id }

        /// The work itself in the year it came out: nothing better can turn up, so it can show at once.
        public var decisive: Bool { laterSeason == nil && year == .same }
    }

    /// The work's names (TMDB's and the original), normalized once for every result.
    public struct Wanted: Sendable {
        let names: Set<String>
        let year: Int?
        public init(names: [String], year: Int?) {
            var normalized = Set<String>()
            for name in names {
                for form in [name, SeasonTitles.parse(name).core] {
                    let value = TitleMatch.normalize(form)
                    if !value.isEmpty { normalized.insert(value) }
                }
            }
            self.names = normalized
            self.year = year
        }
    }

    /// One source's results that are the work, in the source's order: the title is one of the names once normalized
    /// (case, width, traditional or simplified, spaces and punctuation don't count), or is one with a season and
    /// bracketed notes (【4K】, [国语]) after it. Folders and plugin settings never are.
    public static func candidates(_ videos: [Video], site: Site, wanted: Wanted) -> [Candidate] {
        guard !wanted.names.isEmpty else { return [] }
        var found: [Candidate] = []
        var seen = Set<String>()
        for (position, video) in videos.enumerated() where video.action == nil && !video.isFolder && seen.insert(video.id).inserted {
            let laterSeason: Int?
            if wanted.names.contains(TitleMatch.normalize(video.name)) {
                laterSeason = nil
            } else {
                let parsed = SeasonTitles.parse(video.name)
                guard wanted.names.contains(TitleMatch.normalize(parsed.core)) else { continue }
                laterSeason = (parsed.season ?? 1) > 1 ? parsed.season : nil
            }
            found.append(Candidate(site: site, video: video, laterSeason: laterSeason, year: fit(video.year, wanted.year), position: position))
        }
        return found
    }

    /// Best first: the work itself before its later seasons (those in season order), then a matching year before none
    /// given before another year, then the sources in the viewer's Watch Now order (`sourceOrder`, by source key;
    /// unlisted ones last), then each source's own order.
    public static func ranked(_ candidates: [Candidate], sourceOrder: [String: Int]) -> [Candidate] {
        candidates.sorted { lhs, rhs in
            let left = (lhs.laterSeason ?? 0, lhs.year.rawValue, sourceOrder[lhs.site.key] ?? .max, lhs.position)
            let right = (rhs.laterSeason ?? 0, rhs.year.rawValue, sourceOrder[rhs.site.key] ?? .max, rhs.position)
            return left == right ? lhs.site.key < rhs.site.key : left < right
        }
    }

    /// The first four-digit year in a source's year field ("2008", "2008-01-20", "2008年").
    static func fit(_ text: String?, _ year: Int?) -> Year {
        guard let year, let text else { return .unknown }
        var run = 0, value = 0
        for character in text {
            if let digit = character.wholeNumberValue, character.isASCII {
                run += 1; value = value * 10 + digit
                if run == 4 { return abs(value - year) <= 1 ? .same : .other }
            } else {
                run = 0; value = 0
            }
        }
        return .unknown
    }
}

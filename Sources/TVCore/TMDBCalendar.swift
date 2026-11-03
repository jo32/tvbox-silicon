import Foundation

/// This week's airing calendar from our Worker (Services/tmdb-match, `GET /v1/calendar`): anime from Bangumi, series
/// from TMDB, each with fallbacks there (AniList, bangumi-data; TVmaze) and the last good copy when all fail.
/// Days run Monday to Sunday in China time (`timeZone`); `airsAt` is an exact time where the source knows it.
public enum TMDBCalendar {
    public enum Kind: String, Codable, CaseIterable, Hashable, Sendable { case anime, tv }

    /// Series by where they're made (the Worker's REGIONS).
    public enum Region: String, Codable, CaseIterable, Hashable, Sendable {
        case cn, hktw, us, jp, kr, gb
        /// The viewer's own, by the app's language.
        public static var preferred: Region {
            switch L10n.resolvedLanguage() {
            case "zh-Hans": .cn
            case "zh-Hant": .hktw
            case "ja": .jp
            default: .us
            }
        }
    }

    public struct Link: Codable, Hashable, Sendable {
        public let site: String
        public let name: String
        public let url: URL
    }

    public struct Work: Codable, Hashable, Sendable {
        public let type: TMDBMatch.MediaType
        public let id: Int
        public let season: Int?
    }

    public struct Item: Codable, Hashable, Sendable, Identifiable {
        public let title: String
        public let originalTitle: String
        public let cover: URL?
        /// ISO 8601 with milliseconds, as the Worker writes it; `airDate` parses it.
        public let airsAt: String?
        public let episode: Int?
        public let season: Int?
        public let rating: Double?
        public let network: String?
        /// The start of the synopsis (TV), when the source has one.
        public let overview: String?
        /// bgm.tv subject.
        public let bangumi: Int?
        /// The TMDB work, which the Discover detail page opens.
        public let tmdb: Work?
        public let links: [Link]

        public var airDate: Date? {
            airsAt.flatMap { try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse($0) }
        }
        /// Two Bangumi subjects can share a TMDB series (a dub, a split season), so Bangumi's ID comes first.
        public var id: String {
            if let bangumi { return "bgm:\(bangumi)" }
            if let tmdb { return "tmdb:\(tmdb.type.rawValue):\(tmdb.id)" }
            return "\(title)|\(airsAt ?? "")"
        }
        public var bangumiPage: URL? { bangumi.flatMap { URL(string: "https://bgm.tv/subject/\($0)") } }
    }

    public struct Day: Codable, Hashable, Sendable, Identifiable {
        /// YYYY-MM-DD in `Week.timeZone`.
        public let date: String
        /// 1 = Monday … 7 = Sunday.
        public let weekday: Int
        public let items: [Item]
        public var id: String { date }
    }

    public struct Credit: Codable, Hashable, Sendable {
        public let name: String
        public let url: URL
    }

    public struct Week: Codable, Sendable {
        public let kind: Kind
        /// Where the list came from: bangumi, anilist, bangumi-data, tmdb or tvmaze.
        public let source: String
        /// Not the kind's first choice.
        public let fallback: Bool
        /// Every source failed: this is an older copy moved onto this week.
        public let stale: Bool
        public let timeZone: String
        public let days: [Day]
        /// Shown with the calendar, as the sources' licenses ask.
        public let attribution: [Credit]

        /// Today's day of the week, in the calendar's time zone.
        public func today(_ now: Date = Date()) -> Day? {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: timeZone) ?? .current
            let parts = calendar.dateComponents([.year, .month, .day], from: now)
            let date = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            return days.first { $0.date == date }
        }
    }

    /// Debug builds can point the calendar alone at a local Worker: `-qaCalendar http://127.0.0.1:8799/v1/`.
    static var base: URL {
        #if DEBUG
        if let value = UserDefaults.standard.string(forKey: "qaCalendar"), let url = URL(string: value) { return url }
        #endif
        return TMDBMatch.base
    }

    /// `region` is for series; anime ignores it.
    public static func week(_ kind: Kind, region: Region = .preferred, language: String = TMDBMatch.language, session: URLSession = .shared) async throws -> Week {
        var parts = URLComponents(url: base.appending(path: "calendar"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "kind", value: kind.rawValue), URLQueryItem(name: "language", value: language)]
        if kind == .tv { parts.queryItems!.append(URLQueryItem(name: "region", value: region.rawValue)) }
        let (data, response) = try await session.data(for: URLRequest(url: parts.url!, timeoutInterval: 30))
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw TMDBMatch.Failure(code: "http", message: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        #if DEBUG
        // A Worker under `wrangler dev --remote` sees the production host, so the covers it serves name that host.
        if base != TMDBMatch.endpoint, let text = String(data: data, encoding: .utf8) {
            let local = text.replacingOccurrences(of: TMDBMatch.endpoint.absoluteString + "cover/", with: base.absoluteString + "cover/")
            return try JSONDecoder().decode(Week.self, from: Data(local.utf8))
        }
        #endif
        return try JSONDecoder().decode(Week.self, from: data)
    }
}

import Foundation

/// When a series' latest season airs, episode by episode (#1186). The dates are TMDB's: the original network's local
/// date, without a time. Chinese platforms often release two or more episodes a day, so a day holds a list.
public struct AirSchedule: Codable, Hashable, Sendable {
    public struct Episode: Codable, Hashable, Sendable {
        public let number: Int
        /// "yyyy-MM-dd", or nil while TMDB doesn't know it yet.
        public let airDate: String?
        public init(number: Int, airDate: String?) { self.number = number; self.airDate = airDate }
    }

    /// One day's episodes, in order.
    public struct Day: Hashable, Sendable, Identifiable {
        public let date: String
        public let episodes: [Int]
        public var id: String { date }
        /// "7", "7-8", or "7, 9" when they don't follow on.
        public var range: String { AirSchedule.range(episodes) }
    }

    public let showID: Int
    public let season: Int
    public let seasonName: String
    /// How many episodes TMDB lists for the season, dated or not.
    public let total: Int
    public let episodes: [Episode]
    public let networks: [String]
    public let status: String?
    public let fetched: Date
    /// TMDB's genres for the series ("剧情", "古装"), for the Following Calendar's cards; nil in schedules kept from before.
    public var genres: [String]?

    /// The season as the app's language says it ("第 1 季"): TMDB's name only when it is a real title, since its generic
    /// "Season 1" comes in whatever language the schedule was fetched in.
    public var seasonTitle: String { Self.seasonTitle(seasonName, number: season) }

    public static func seasonTitle(_ name: String, number: Int) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let generic = trimmed.isEmpty || trimmed.range(of: #"^(Season|第|シーズン)\s*\d+\s*(季)?$"#, options: [.regularExpression, .caseInsensitive]) != nil
        return generic ? L10n.text("Season %@", String(number)) : trimmed
    }

    public init(showID: Int, season: Int, seasonName: String, total: Int, episodes: [Episode], networks: [String], status: String?, fetched: Date) {
        self.showID = showID; self.season = season; self.seasonName = seasonName; self.total = max(total, episodes.count)
        self.episodes = episodes; self.networks = networks; self.status = status; self.fetched = fetched
    }

    /// The schedule in details fetched with their latest season; nil without one.
    public init?(details: TMDBMatch.Details, fetched: Date = Date()) {
        guard details.mediaType == .tv, let season = details.season else { return nil }
        let count = details.seasons.first { $0.number == season.number }?.episodeCount ?? 0
        self.init(showID: details.id, season: season.number, seasonName: season.name, total: count,
                  episodes: season.episodes.map { Episode(number: $0.number, airDate: $0.airDate) },
                  networks: details.networks, status: details.status, fetched: fetched)
        genres = details.genres
    }

    /// The days with episodes, earliest first.
    public var days: [Day] {
        var byDate: [String: [Int]] = [:]
        for episode in episodes { if let date = episode.airDate, Self.isDate(date) { byDate[date, default: []].append(episode.number) } }
        return byDate.keys.sorted().map { Day(date: $0, episodes: byDate[$0]!.sorted()) }
    }

    /// Episodes out by the end of `today`.
    public func aired(today: String) -> Int { days.filter { $0.date <= today }.reduce(0) { $0 + $1.episodes.count } }

    /// Today's episodes, else the next day's.
    public func next(today: String) -> Day? { days.first { $0.date >= today } }

    /// Worth a calendar: something airs from today on, or aired in the last two weeks.
    public func isAiring(today: String) -> Bool {
        guard let last = days.last else { return false }
        return last.date >= Self.day(Self.date(today).map { $0.addingTimeInterval(-14 * 86_400) } ?? .distantPast)
    }

    // MARK: Dates

    /// "7", "7-8", or "7, 9, 12-13".
    public static func range(_ numbers: [Int]) -> String {
        let sorted = Array(Set(numbers)).sorted()
        var parts: [String] = []
        var index = 0
        while index < sorted.count {
            var end = index
            while end + 1 < sorted.count, sorted[end + 1] == sorted[end] + 1 { end += 1 }
            parts.append(end == index ? String(sorted[index]) : "\(sorted[index])-\(sorted[end])")
            index = end + 1
        }
        return parts.joined(separator: ", ")
    }

    private static func formatter(_ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    /// The viewer's calendar day, as TMDB writes air dates.
    public static func day(_ date: Date, timeZone: TimeZone = .current) -> String { formatter(timeZone).string(from: date) }

    /// Noon of a "yyyy-MM-dd" day, so a day's arithmetic never crosses midnight.
    public static func date(_ day: String, timeZone: TimeZone = .current) -> Date? {
        formatter(timeZone).date(from: day).map { $0.addingTimeInterval(12 * 3600) }
    }

    static func isDate(_ value: String) -> Bool { value.count == 10 && date(value, timeZone: TimeZone(identifier: "UTC")!) != nil }

    /// The season to follow: the highest numbered one (season 0 holds the specials).
    public static func latestSeason(_ seasons: [TMDBMatch.SeasonSummary]) -> Int? {
        seasons.filter { $0.number > 0 }.map(\.number).max()
    }

    // MARK: Followed shows

    /// A followed show with its next episodes: today's, else the next day's; nil when nothing is coming.
    public struct Upcoming: Hashable, Sendable, Identifiable {
        public let show: FollowedShow
        public let schedule: AirSchedule?
        public let day: Day?
        public var id: Int { show.id }
        public init(show: FollowedShow, schedule: AirSchedule?, day: Day?) { self.show = show; self.schedule = schedule; self.day = day }
    }

    /// For the Discover shelf: shows with something coming, soonest first, then the others in the viewer's order.
    public static func upcoming(_ shows: [FollowedShow], schedules: [Int: AirSchedule], today: String) -> [Upcoming] {
        let items = shows.map { show in
            Upcoming(show: show, schedule: schedules[show.id], day: schedules[show.id]?.next(today: today))
        }
        let coming = items.filter { $0.day != nil }.enumerated().sorted { lhs, rhs in
            (lhs.element.day!.date, lhs.offset) < (rhs.element.day!.date, rhs.offset)
        }.map(\.element)
        return coming + items.filter { $0.day == nil }
    }

    /// One day of the agenda: every followed show with episodes that day.
    public struct AgendaDay: Hashable, Sendable, Identifiable {
        public let date: String
        public let entries: [Upcoming]
        public var id: String { date }
    }

    /// The followed shows' episodes from `today` (or from `first`, a day before it) for `days` days, by day.
    public static func agenda(_ shows: [FollowedShow], schedules: [Int: AirSchedule], today: String, from first: String? = nil,
                              days: Int = 28) -> [AgendaDay] {
        let from = first ?? today
        guard let start = date(from) else { return [] }
        let end = day(start.addingTimeInterval(Double(max(days, 1) - 1) * 86_400))
        var byDate: [String: [Upcoming]] = [:]
        for show in shows {
            guard let schedule = schedules[show.id] else { continue }
            for value in schedule.days where value.date >= from && value.date <= end {
                byDate[value.date, default: []].append(Upcoming(show: show, schedule: schedule, day: value))
            }
        }
        return byDate.keys.sorted().map { AgendaDay(date: $0, entries: byDate[$0]!) }
    }
}

/// Followed shows' schedules from the TMDB Worker: at most one refresh per show every 12 hours, kept in Caches so
/// Discover shows the last ones at once. Nothing runs until Discover or a title page asks.
public actor AirSchedules {
    public static let shared = AirSchedules()
    public typealias Fetch = @Sendable (_ id: Int, _ season: Int?) async throws -> TMDBMatch.Details

    private let file: URL?
    private let lifetime: TimeInterval
    private let fetch: Fetch
    private var cache: [Int: AirSchedule]?
    private var running: [Int: Task<AirSchedule?, Never>] = [:]

    public init(file: URL? = URL.cachesDirectory.appending(path: "com.tvbox.yingxia/air-schedules.json"), lifetime: TimeInterval = 12 * 3600,
                fetch: @escaping Fetch = { id, season in try await TMDBMatch.details(.tv, id: id, season: season) }) {
        self.file = file; self.lifetime = lifetime; self.fetch = fetch
    }

    /// What is kept, however old.
    public func cached(_ id: Int) -> AirSchedule? { loaded()[id] }
    public func cached(_ ids: [Int]) -> [Int: AirSchedule] { loaded().filter { ids.contains($0.key) } }

    /// The show's latest season schedule. `details` (from a title page) saves asking for the season list first.
    /// A failed refresh keeps the old schedule.
    public func schedule(_ id: Int, details: TMDBMatch.Details? = nil, now: Date = Date()) async -> AirSchedule? {
        let old = loaded()[id]
        if let old, now.timeIntervalSince(old.fetched) < lifetime, old.fetched <= now { return old }
        if let task = running[id] { return await task.value }
        let fetch = fetch
        let task = Task<AirSchedule?, Never> {
            do {
                var season = details.flatMap { AirSchedule.latestSeason($0.seasons) } ?? old?.season
                if season == nil { season = AirSchedule.latestSeason(try await fetch(id, nil).seasons) }
                guard let first = season else { return nil }
                var value = try await fetch(id, first)
                // A new season since the last look.
                if let latest = AirSchedule.latestSeason(value.seasons), latest > first { value = try await fetch(id, latest) }
                return AirSchedule(details: value, fetched: now)
            } catch {
                return nil
            }
        }
        running[id] = task
        let value = await task.value
        running[id] = nil
        guard let value else { return old }
        cache?[id] = value
        save()
        return value
    }

    /// Several shows' schedules, four requests at a time.
    public func schedules(_ ids: [Int], now: Date = Date()) async -> [Int: AirSchedule] {
        var result: [Int: AirSchedule] = [:]
        await withTaskGroup(of: (Int, AirSchedule?).self) { group in
            var pending = ids.makeIterator()
            for _ in 0..<4 {
                guard let id = pending.next() else { break }
                group.addTask { (id, await self.schedule(id, now: now)) }
            }
            while let (id, value) = await group.next() {
                if let value { result[id] = value }
                if let id = pending.next() { group.addTask { (id, await self.schedule(id, now: now)) } }
            }
        }
        return result
    }

    private func loaded() -> [Int: AirSchedule] {
        if let cache { return cache }
        let saved = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([Int: AirSchedule].self, from: $0) } ?? [:]
        cache = saved
        return saved
    }

    private func save() {
        guard let file, let cache, let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

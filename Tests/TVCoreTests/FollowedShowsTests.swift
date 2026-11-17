import Foundation
import Testing
@testable import TVCore

private func show(_ id: Int, _ name: String = "Show") -> TMDBCatalog.Item {
    TMDBCatalog.Item(id: id, mediaType: .tv, name: name, originalName: name, year: 2026, overview: "", poster: nil, backdrop: nil, rating: nil, genreIDs: [])
}

/// Details as the Worker sends them for `/details?season=`: only what the schedule reads is filled in.
private func details(_ id: Int, seasons: [(Int, Int)], season: Int?, dates: [String?], status: String = "Returning Series") throws -> TMDBMatch.Details {
    let episodes = dates.enumerated().map { index, date -> [String: Any] in
        ["number": index + 1, "name": "E\(index + 1)", "overview": "", "airDate": date as Any]
    }
    var json: [String: Any] = [
        "mediaType": "tv", "id": id, "name": "Show \(id)", "originalName": "", "tagline": "", "overview": "", "genres": [String](),
        "voteCount": 0, "countries": [String](), "status": status, "cast": [Any](), "crew": [Any](), "networks": ["Youku"],
        "seasons": seasons.map { ["number": $0.0, "name": "Season \($0.0)", "episodeCount": $0.1] }, "link": "https://www.themoviedb.org/tv/\(id)",
    ]
    if let season { json["season"] = ["number": season, "name": "Season \(season)", "overview": "", "episodes": episodes] }
    let data = try JSONSerialization.data(withJSONObject: json)
    return try JSONDecoder().decode(TMDBMatch.Details.self, from: data)
}

@Test func airScheduleGroupsEpisodesByDay() throws {
    // A Chinese drama: two a day after a four-episode premiere, the last ones not dated yet.
    let value = try #require(AirSchedule(details: try details(1, seasons: [(0, 2), (1, 30)], season: 1,
        dates: ["2026-11-14", "2026-11-14", "2026-11-14", "2026-11-14", "2026-11-15", "2026-11-15", "2026-11-16", "2026-11-16", "2026-11-17", nil, ""])))
    #expect(value.total == 30 && value.networks == ["Youku"])
    #expect(value.days.map(\.date) == ["2026-11-14", "2026-11-15", "2026-11-16", "2026-11-17"])
    #expect(value.days.map(\.range) == ["1-4", "5-6", "7-8", "9"])
    #expect(value.aired(today: "2026-11-16") == 8)
    #expect(value.next(today: "2026-11-16")?.range == "7-8")
    #expect(value.next(today: "2026-11-18") == nil)
    #expect(value.isAiring(today: "2026-11-20") && !value.isAiring(today: "2026-12-20"))
    #expect(AirSchedule.range([9, 7, 12, 8, 13]) == "7-9, 12-13" && AirSchedule.range([3]) == "3" && AirSchedule.range([]) == "")
    #expect(AirSchedule.latestSeason(try details(1, seasons: [(0, 2), (1, 10), (2, 8)], season: nil, dates: []).seasons) == 2)
}

@Test func followedShowsAgendaListsTheComingDays() throws {
    let a = FollowedShow(item: show(1, "A")), b = FollowedShow(item: show(2, "B")), c = FollowedShow(item: show(3, "C"))
    let schedules = [
        1: try #require(AirSchedule(details: try details(1, seasons: [(1, 4)], season: 1, dates: ["2026-11-15", "2026-11-18", "2026-11-18", "2026-12-30"]))),
        2: try #require(AirSchedule(details: try details(2, seasons: [(1, 2)], season: 1, dates: ["2026-11-16", "2026-11-17"]))),
        3: try #require(AirSchedule(details: try details(3, seasons: [(1, 1)], season: 1, dates: ["2026-10-01"], status: "Ended"))),
    ]
    let upcoming = AirSchedule.upcoming([c, a, b], schedules: schedules, today: "2026-11-16")
    #expect(upcoming.map(\.show.id) == [2, 1, 3])
    #expect(upcoming.map { $0.day?.range } == ["1", "2-3", nil])
    let agenda = AirSchedule.agenda([a, b, c], schedules: schedules, today: "2026-11-16", days: 14)
    #expect(agenda.map(\.date) == ["2026-11-16", "2026-11-17", "2026-11-18"])
    #expect(agenda.map { $0.entries.map(\.show.id) } == [[2], [2], [1]])
}

@MainActor @Test func followedShowsAreKeptOnceAndSynced() throws {
    let defaults = try #require(UserDefaults(suiteName: "followed-" + UUID().uuidString))
    let list = FollowedShows(defaults: defaults)
    var changes = 0
    list.onChange = { changes += 1 }
    list.follow(show(1, "A"))
    list.follow(show(2, "B"))
    list.follow(show(1, "A"))
    list.follow(TMDBCatalog.Item(id: 9, mediaType: .movie, name: "Film", originalName: "", year: nil, overview: "", poster: nil, backdrop: nil, rating: nil, genreIDs: []))
    #expect(list.shows.map(\.id) == [2, 1] && changes == 2)
    // Following again with a new name keeps its place.
    list.follow(show(1, "A2"))
    #expect(list.shows.map(\.name) == ["B", "A2"] && changes == 3)
    #expect(FollowedShows(defaults: defaults).shows.map(\.id) == [2, 1])
    list.toggle(show(2))
    #expect(list.shows.map(\.id) == [1] && !list.contains(2))
    #expect(Array(list.syncValues.keys) == ["tv:1"])
    let now = Date()
    list.adopt([CloudSyncItem(id: "tv:1", value: FollowedShow(item: show(1, "A2")), stamp: now),
                CloudSyncItem(id: "tv:5", value: FollowedShow(item: show(5, "E")), stamp: now.addingTimeInterval(5))])
    #expect(list.shows.map(\.id) == [5, 1] && changes == 4)
}

@Test func airSchedulesAreFetchedOnceAndFollowNewSeasons() async throws {
    actor Calls { var list: [String] = []; func add(_ value: String) { list.append(value) } }
    let calls = Calls()
    let file = FileManager.default.temporaryDirectory.appending(path: "air-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let seasons = LockedBox([(1, 2)])
    let store = AirSchedules(file: file, lifetime: 3600) { id, season in
        await calls.add("\(id):\(season.map(String.init) ?? "-")")
        let list = seasons.value
        return try details(id, seasons: list, season: season, dates: season == nil ? [] : ["2026-11-16", "2026-11-17"])
    }
    let start = Date()
    let first = await store.schedule(7, now: start)
    #expect(first?.season == 1 && first?.days.count == 2)
    _ = await store.schedule(7, now: start.addingTimeInterval(60))
    #expect(await calls.list == ["7:-", "7:1"])
    // Hours later season 2 is listed: the refresh asks for the old season, sees the new one and follows it.
    seasons.value = [(1, 2), (2, 10)]
    let later = await store.schedule(7, now: start.addingTimeInterval(7200))
    #expect(later?.season == 2 && later?.total == 10)
    #expect(await calls.list == ["7:-", "7:1", "7:1", "7:2"])
    // Kept on disk for the next launch.
    #expect(await AirSchedules(file: file).cached(7)?.season == 2)
}

private final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

@Test func airScheduleSeasonTitleKeepsOnlyRealNames() {
    let generic = L10n.text("Season %@", "1")
    #expect(AirSchedule.seasonTitle("Season 1", number: 1) == generic)
    #expect(AirSchedule.seasonTitle("第 1 季", number: 1) == generic)
    #expect(AirSchedule.seasonTitle("第1季", number: 1) == generic)
    #expect(AirSchedule.seasonTitle("シーズン1", number: 1) == generic)
    #expect(AirSchedule.seasonTitle("", number: 2) == L10n.text("Season %@", "2"))
    #expect(AirSchedule.seasonTitle("少年歌行 风花雪月篇", number: 3) == "少年歌行 风花雪月篇")
}

@Test func followedShowsAgendaCanStartBeforeToday() throws {
    let schedule = try #require(AirSchedule(details: details(1, seasons: [(1, 3)], season: 1, dates: ["2026-11-10", "2026-11-17", "2026-11-24"])))
    let shows = [FollowedShow(item: show(1))]
    #expect(AirSchedule.agenda(shows, schedules: [1: schedule], today: "2026-11-17", days: 14).map(\.date) == ["2026-11-17", "2026-11-24"])
    #expect(AirSchedule.agenda(shows, schedules: [1: schedule], today: "2026-11-17", from: "2026-11-09", days: 21).map(\.date)
        == ["2026-11-10", "2026-11-17", "2026-11-24"])
}

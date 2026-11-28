import Foundation
import Testing
@testable import TVCore

private func movie(_ id: Int, _ name: String = "Film") -> TMDBCatalog.Item {
    TMDBCatalog.Item(id: id, mediaType: .movie, name: name, originalName: name, year: 2026, overview: "", poster: nil, backdrop: nil, rating: nil, genreIDs: [])
}

private func series(_ id: Int, _ name: String = "Show") -> TMDBCatalog.Item {
    TMDBCatalog.Item(id: id, mediaType: .tv, name: name, originalName: name, year: 2026, overview: "", poster: nil, backdrop: nil, rating: nil, genreIDs: [])
}

@Test func followedTitlesTakeMoviesOnly() throws {
    let title = try #require(FollowedTitle(item: movie(11, "Arrival")))
    #expect(title.id == 11 && title.name == "Arrival" && title.year == 2026)
    #expect(title.key == "movie:11")
    #expect(FollowedTitle(item: series(11)) == nil)
    // A series and a movie with the same TMDB id are different titles, and their keys never meet.
    #expect(FollowedShow(item: series(11)).key != title.key)
}

@Test func followedTitlesCatalogItemRoundTrips() throws {
    let title = try #require(FollowedTitle(item: movie(7, "Heat")))
    let item = title.catalogItem
    #expect(item.id == 7 && item.name == "Heat" && item.year == 2026 && item.mediaType == .movie)
    #expect(FollowedTitle(item: item) == title)
}

@MainActor @Test func followedTitlesAreKeptOnceAndSynced() throws {
    let defaults = try #require(UserDefaults(suiteName: "followed-titles-" + UUID().uuidString))
    let list = FollowedTitles(defaults: defaults)
    var changes = 0
    list.onChange = { changes += 1 }
    list.favorite(movie(1, "A"))
    list.favorite(movie(2, "B"))
    list.favorite(movie(1, "A"))
    // A series never joins the movies' list.
    list.favorite(series(9, "Show"))
    #expect(list.titles.map(\.id) == [2, 1] && changes == 2)
    // Favoriting again with a new name keeps its place.
    list.favorite(movie(1, "A2"))
    #expect(list.titles.map(\.name) == ["B", "A2"] && changes == 3)
    #expect(FollowedTitles(defaults: defaults).titles.map(\.id) == [2, 1])
    #expect(list.contains(2) && !list.contains(9))
    list.toggle(movie(2))
    #expect(list.titles.map(\.id) == [1] && !list.contains(2))
    #expect(Array(list.syncValues.keys) == ["movie:1"])
    let now = Date()
    let one = try #require(FollowedTitle(item: movie(1, "A2")))
    let five = try #require(FollowedTitle(item: movie(5, "E")))
    list.adopt([CloudSyncItem(id: "movie:1", value: one, stamp: now),
                CloudSyncItem(id: "movie:5", value: five, stamp: now.addingTimeInterval(5))])
    // `adopt` takes another device's list without calling `onChange` (it would echo the change back), so the
    // count stays at four from the `toggle` above; the `unfavorite` below is the fifth.
    #expect(list.titles.map(\.id) == [5, 1] && changes == 4)
    list.unfavorite(5)
    #expect(list.titles.map(\.id) == [1])
}

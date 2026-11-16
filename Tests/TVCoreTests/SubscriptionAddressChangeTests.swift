import Foundation
import Testing
@testable import TVCore

// A subscription whose address the viewer changed (#982) keeps what was saved against its sources.
private let old = URL(string: "https://old.example/tv.json")!
private let new = URL(string: "https://mirror.example/tv.json")!
private let other = URL(string: "https://other.example/tv.json")!
private func source(_ key: String) -> Site {
    Site(key: key, name: key, type: 1, api: "https://api.example/" + key, raw: ["key": .string(key)])
}

@Test func scopesMoveOnlyFromTheOldAddress() {
    let scope = EpisodeSkipSettings.scope(origin: old, source: "a", video: "v|1")
    #expect(EpisodeSkipSettings.rescope(scope, from: old, to: new) == EpisodeSkipSettings.scope(origin: new, source: "a", video: "v|1"))
    #expect(EpisodeSkipSettings.rescope(EpisodeSkipSettings.scope(origin: other, source: "a", video: ""), from: old, to: new) == nil)
    #expect(EpisodeSkipSettings.rescope("not json", from: old, to: new) == nil)
}

@Test @MainActor func pinsHidesAndOrderFollowTheNewAddress() throws {
    let suite = "address." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let a = source("a"), b = source("b")
    let pinned = PinnedSources(defaults: defaults), hidden = HiddenSources(defaults: defaults), order = SourceOrder(defaults: defaults)
    var changes = 0
    pinned.onChange = { changes += 1 }
    pinned.toggle(a, origin: old); pinned.toggle(b, origin: other)
    hidden.toggle(b, origin: old)
    order.save([b, a], origin: old)
    pinned.moveOrigin(from: old, to: new); hidden.moveOrigin(from: old, to: new); order.moveOrigin(from: old, to: new)
    #expect(pinned.contains(a, origin: new) && !pinned.contains(a, origin: old))
    #expect(pinned.contains(b, origin: other))
    #expect(PinnedSources(defaults: defaults).contains(a, origin: new))
    #expect(hidden.contains(b, origin: new) && !hidden.contains(b, origin: old))
    #expect(order.arrange([a, b], origin: new).map(\.key) == ["b", "a"])
    #expect(changes == 3)
    pinned.moveOrigin(from: old, to: new)
    #expect(changes == 3)
}

@Test @MainActor func historyFavoritesAndSkipTimesFollowTheNewAddress() throws {
    let suite = "address.history." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let history = PlaybackHistory(file: directory.appending(path: "history.json"), defaults: defaults)
    var context = PlaybackHistoryContext(origin: old, sourceKey: "a", sourceName: "A", videoID: "v", videoName: "Video",
                                         episodeID: "1", episodeName: "Episode 1", episodeFlag: "line")
    context.year = "2026"
    history.record(context, position: 90, duration: 1800)
    EpisodeSkipSettings(enabled: true, introEnd: 85, outroLength: 60).save(scope: context.id, defaults: defaults)
    history.moveOrigin(from: old, to: new)
    EpisodeSkipSettings.moveOrigin(from: old, to: new, defaults: defaults)
    let moved = try #require(history.entries.first)
    #expect(moved.context.origin == new && moved.context.year == "2026" && moved.position == 90)
    #expect(EpisodeSkipSettings.load(scope: moved.id, defaults: defaults).introEnd == 85)
    #expect(defaults.data(forKey: "episodeSkip.v1." + context.id) == nil)

    let favorites = Favorites(defaults: defaults)
    let video = FavoriteVideo(origin: old, sourceKey: "a", sourceName: "A", videoID: "v", videoName: "Video", poster: nil, posterHeaders: [:], year: nil)
    favorites.toggle(.video(video))
    favorites.toggle(.episode(FavoriteEpisode(video: video, episodeFlag: "line", episodeName: "Episode 1", episodeID: "1")))
    favorites.moveOrigin(from: old, to: new)
    var expected = video
    expected.origin = new
    #expect(favorites.contains(.video(expected)))
    #expect(Favorites(defaults: defaults).items(.episode).count == 1)
    #expect(!favorites.contains(.video(video)))
}

@Test @MainActor func healthRecordsFollowTheNewAddress() {
    let health = SourceHealth(file: nil)
    let a = source("a")
    struct Failure: Error {}
    health.record(a, origin: old, seconds: 1, error: Failure())
    health.record(a, origin: old, seconds: 1, error: Failure())
    #expect(health.failedRepeatedly(a, origin: old))
    health.moveOrigin(from: old, to: new)
    #expect(health.failedRepeatedly(a, origin: new) && !health.failedRepeatedly(a, origin: old))
}

import Foundation
import Testing
@testable import TVCore

private func historyContext(video: String = "series", episode: String = "1", source: String = "source") -> PlaybackHistoryContext {
    PlaybackHistoryContext(origin: URL(string: "https://example.com/sub.json")!, sourceKey: source, sourceName: "Movies",
        videoID: video, videoName: "Series", episodeID: episode, episodeName: "Episode " + episode, episodeFlag: "line")
}

@Test @MainActor func playbackHistoryPersistsUpdatesAndDeletesWithoutStreamCredentials() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "history.json")
    let history = PlaybackHistory(file: file)
    history.record(historyContext(), position: 143.5, duration: 1800)
    #expect(history.persistenceError == nil)
    let restored = PlaybackHistory(file: file)
    #expect(restored.entries.first?.resumePosition == 143.5)
    #expect(restored.entries.first?.context.episodeName == "Episode 1")
    restored.record(historyContext(episode: "2"), position: 25, duration: 1800)
    #expect(restored.entries.count == 1)
    #expect(restored.entries.first?.context.episodeID == "2")
    restored.record(historyContext(source: "other"), position: 50, duration: 1800)
    #expect(restored.entries.count == 2)
    restored.remove(historyContext().id)
    #expect(PlaybackHistory(file: file).entries.count == 1)
    restored.clear()
    #expect(PlaybackHistory(file: file).entries.isEmpty)
}

@Test @MainActor func playbackHistoryRejectsInvalidProgressAndDoesNotOverwriteWithLoadingZero() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: file) }
    let history = PlaybackHistory(file: file)
    history.record(historyContext(), position: 90, duration: 1800)
    for position in [0.0, -1, .nan, .infinity] { history.record(historyContext(), position: position, duration: 1800) }
    for duration in [-1.0, .nan, .infinity] { history.record(historyContext(), position: 10, duration: duration) }
    #expect(history.entries.first?.position == 90)
    history.record(historyContext(), position: 1900, duration: 1800)
    #expect(history.entries.first?.position == 1800)
    #expect(history.entries.first?.completed == true)
    #expect(history.entries.first?.resumePosition == 0)
}

@Test func playbackHistoryFindsTheSameEpisodeAfterReorderingAndRejectsMissingEpisodes() {
    let context = historyContext()
    let next = Episode(id: "1", name: "Episode 2", address: "fresh-2", flag: "line")
    let original = Episode(id: "9", name: "Episode 1", address: "fresh-1", flag: "line")
    #expect(context.episode(in: [next, original])?.address == "fresh-1")
    #expect(context.episode(in: [next]) == nil)
    #expect(context.episode(in: [Episode(id: "1", name: "Episode 1", address: "different-line", flag: "other")]) == nil)
    #expect(context.episode(in: [original, Episode(id: "10", name: "Episode 1", address: "ambiguous", flag: "line")]) == nil)
    // The details page opens on the line watched last even when it isn't the first line (#362).
    let otherLine = Episode(id: "20", name: "Episode 1", address: "first-line", flag: "other")
    #expect(context.episode(in: [otherLine, next, original])?.flag == "line")
}

@Test @MainActor func playbackHistoryBoundsAndRecoversItsPersistentFile() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: file) }
    try Data("broken history".utf8).write(to: file)
    let history = PlaybackHistory(file: file)
    #expect(history.entries.isEmpty)
    for index in 0...PlaybackHistory.limit {
        history.record(historyContext(video: String(index)), position: 10, duration: 100,
                       now: Date(timeIntervalSince1970: Double(index)))
    }
    #expect(history.entries.count == PlaybackHistory.limit)
    #expect(history.entries.first?.context.videoID == String(PlaybackHistory.limit))
    #expect(history.entries.contains { $0.context.videoID == "0" } == false)
    #expect(PlaybackHistory(file: file).entries == history.entries)
}

@Test func historyResumeClampsChangedDurationsAndCoexistsWithSegmentSkipping() {
    #expect(PlaybackHistoryEntry.resumeTarget(143.5, duration: 1800) == 143.5)
    #expect(PlaybackHistoryEntry.resumeTarget(143.5, duration: 100) == 99.75)
    #expect(PlaybackHistoryEntry.resumeTarget(.nan, duration: 1800) == nil)
    #expect(PlaybackHistoryEntry.resumeTarget(10, duration: .infinity) == nil)
    var pass = EpisodeSkipPass()
    let settings = EpisodeSkipSettings(enabled: true, introEnd: 90, outroLength: 120)
    #expect(pass.target(time: 143.5, duration: 1800, playing: true, settings: settings) == nil)
    #expect(pass.target(time: 20, duration: 1800, playing: true, settings: settings) == nil)
    #expect(pass.target(time: 1680, duration: 1800, playing: true, settings: settings) == 1799.95)
}

@Test func historyChannelDecodesLegacyFavoritesAndDoesNotNeedAnOldStreamToResume() throws {
    let legacy = Data(#"{"name":"Live","group":"TV","url":"https://example.com/live.m3u8","headers":{}}"#.utf8)
    let channel = try JSONDecoder().decode(Channel.self, from: legacy)
    #expect(channel.historyContext == nil)
    #expect(channel.resumePosition == nil)
    let encoded = try JSONEncoder().encode(historyContext())
    let text = String(decoding: encoded, as: UTF8.self)
    #expect(!text.contains("headers"))
    #expect(!text.contains("address"))
}

@Test func detailsWithoutAPosterKeepTheListOrSavedOne() {
    let list = URL(string: "https://img.example.com/list.jpg")!, own = URL(string: "https://img.example.com/own.jpg")!
    let bare = Video(id: "1", name: "肖申克的救赎", year: "1994", episodes: [Episode(id: "0-0", name: "正片", address: "a", flag: "line")])
    let kept = bare.keepingPoster(list, headers: ["Referer": "https://example.com/"])
    #expect(kept.poster == list && kept.posterHeaders == ["Referer": "https://example.com/"])
    #expect(kept.name == bare.name && kept.year == "1994" && kept.episodes == bare.episodes)
    // A poster of its own wins, and no fallback leaves it as it was.
    let posted = Video(id: "1", name: "x", poster: own)
    #expect(posted.keepingPoster(list).poster == own)
    #expect(bare.keepingPoster(nil).poster == nil)
}

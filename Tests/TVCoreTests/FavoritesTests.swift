import Foundation
import Testing
@testable import TVCore

private let origin = URL(string: "https://one.example/a.json")!
private let other = URL(string: "https://two.example/b.json")!

private func channel(_ name: String, url: String = "https://example.com/a.m3u8") -> Channel {
    Channel(name: name, group: "TV", url: URL(string: url)!)
}

private func video(_ id: String, origin: URL) -> FavoriteVideo {
    FavoriteVideo(origin: origin, sourceKey: "src", sourceName: "Source", videoID: id, videoName: id, poster: nil, posterHeaders: [:], year: nil)
}

private func episode(_ id: String, flag: String, name: String, episodeID: String) -> FavoriteEpisode {
    FavoriteEpisode(video: video(id, origin: origin), episodeFlag: flag, episodeName: name, episodeID: episodeID)
}

@Test @MainActor func legacyChannelFavoritesKeepTheirOrderAsLiveItems() throws {
    let suite = "favorites." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let saved = [channel("First"), channel("Second")]
    defaults.set(try JSONEncoder().encode(saved), forKey: "favorites")
    let favorites = Favorites(defaults: defaults)
    #expect(favorites.liveChannels.map(\.name) == ["First", "Second"])
    let document = try JSONDecoder().decode(FavoriteDocument.self, from: try #require(defaults.data(forKey: "favorites")))
    #expect(document.version == 2)
    #expect(Favorites(defaults: defaults).liveChannels.map(\.name) == ["First", "Second"])
}

@Test @MainActor func togglingAFavoriteInsertsItFirstAndRemovesTheSameItem() throws {
    let suite = "favorites." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let favorites = Favorites(defaults: defaults)
    let film = FavoriteItem.video(video("show", origin: origin))
    let song = FavoriteItem.music(MusicTrack(platform: .qq, songID: "9", title: "Song", artists: ["A"]))
    favorites.toggle(film)
    favorites.toggle(song)
    #expect(favorites.items.map(\.key) == [song.key, film.key])
    favorites.toggle(FavoriteItem.video(video("show", origin: origin)))
    #expect(!favorites.contains(film))
    #expect(favorites.contains(song))
    #expect(!favorites.contains(FavoriteItem.video(video("show", origin: other))))
}

@Test @MainActor func videoAndEpisodeFavoritesStayIndependentAndIgnoreEpisodeIndex() {
    let favorites = Favorites(defaults: UserDefaults(suiteName: "favorites." + UUID().uuidString)!)
    let film = FavoriteItem.video(video("show", origin: origin))
    let first = FavoriteItem.episode(episode("show", flag: "m3u8", name: "第1集", episodeID: "0-0"))
    let renamedIndex = FavoriteItem.episode(episode("show", flag: "m3u8", name: "第1集", episodeID: "4-2"))
    let otherEpisode = FavoriteItem.episode(episode("show", flag: "m3u8", name: "第2集", episodeID: "0-1"))
    favorites.toggle(film)
    favorites.toggle(first)
    #expect(favorites.contains(film))
    #expect(favorites.contains(renamedIndex))
    #expect(!favorites.contains(otherEpisode))
    favorites.toggle(renamedIndex)
    #expect(favorites.contains(film))
    #expect(!favorites.contains(first))
}

@Test @MainActor func musicAndCloudFavoritesUseTheirOwnIdentity() {
    let favorites = Favorites(defaults: UserDefaults(suiteName: "favorites." + UUID().uuidString)!)
    let song = MusicTrack(platform: .qq, songID: "9", title: "Song", artists: ["A"])
    var retitled = song
    retitled.title = "Other title"
    favorites.toggle(.music(song))
    #expect(favorites.contains(.music(retitled)))
    let file = FavoriteCloudFile(driveKey: "quark", folderID: "folder", folderName: "Folder", fileID: "file", fileName: "a.mp4", size: 10)
    var resized = file
    resized.size = 99
    favorites.toggle(.cloud(file))
    #expect(favorites.contains(.cloud(resized)))
    var otherDrive = file
    otherDrive.driveKey = "uc"
    #expect(!favorites.contains(.cloud(otherDrive)))
}

@Test @MainActor func roomFavoritesMatchByAddress() {
    let favorites = Favorites(defaults: UserDefaults(suiteName: "favorites." + UUID().uuidString)!)
    let room = channel("Host", url: "bilibili-live://room/42")
    let renamed = Channel(name: "New title", group: "TV", url: URL(string: "bilibili-live://room/42")!)
    favorites.toggle(.live(room))
    #expect(favorites.contains(.live(renamed)))
}

@Test func historyFavoriteIsTheEpisodeOrTheCloudFile() {
    var context = PlaybackHistoryContext(origin: origin, sourceKey: "src", sourceName: "Source", videoID: "show", videoName: "Show", poster: nil, episodeID: "0-0", episodeName: "第1集", episodeFlag: "m3u8")
    let entry = PlaybackHistoryEntry(context: context, position: 12, duration: 0, updatedAt: Date())
    let item = entry.favoriteItem()
    #expect(item.matches(.episode(episode("show", flag: "m3u8", name: "第1集", episodeID: "9-9"))))
    context = PlaybackHistoryContext(origin: URL(string: "tvbox-files://quark")!, sourceKey: CloudFiles.sourceKey, sourceName: "Quark", videoID: "folder", videoName: "Folder", poster: nil, episodeID: "file", episodeName: "a.mp4", episodeFlag: "quark")
    let cloud = PlaybackHistoryEntry(context: context, position: 1, duration: 0, updatedAt: Date()).favoriteItem()
    #expect(cloud.kind == .cloud)
}

@Test func episodeResumeUsesOnlyTheMatchingHistoryEpisode() {
    let saved = episode("show", flag: "m3u8", name: "第1集", episodeID: "0-0")
    let matching = PlaybackHistoryEntry(context: saved.historyContext(), position: 40, duration: 100, updatedAt: Date())
    var otherContext = saved.historyContext()
    otherContext = PlaybackHistoryContext(origin: origin, sourceKey: "src", sourceName: "Source", videoID: "show", videoName: "Show", poster: nil, episodeID: "0-1", episodeName: "第2集", episodeFlag: "m3u8")
    let other = PlaybackHistoryEntry(context: otherContext, position: 80, duration: 100, updatedAt: Date())
    #expect(saved.resumePosition(in: [matching]) == 40)
    #expect(saved.resumePosition(in: [other]) == 0)
    let finished = PlaybackHistoryEntry(context: saved.historyContext(), position: 100, duration: 100, updatedAt: Date())
    #expect(saved.resumePosition(in: [finished]) == 0)
}

@Test @MainActor func likedSongsListNewestFirstAndSurviveAReload() throws {
    let suite = "favorites." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let favorites = Favorites(defaults: defaults)
    let first = MusicTrack(platform: .qq, songID: "1", title: "First", artists: ["A"])
    let second = MusicTrack(platform: .netease, songID: "2", title: "Second", artists: ["B"])
    favorites.toggle(.music(first))
    favorites.toggle(.music(second))
    #expect(favorites.musicTracks.map(\.title) == ["Second", "First"])
    #expect(Favorites(defaults: defaults).musicTracks.map(\.id) == [second.id, first.id])
    favorites.toggle(.music(second))
    #expect(favorites.musicTracks.map(\.title) == ["First"])
}

@Test @MainActor func emptyKindsStayEmptyUntilSomethingIsSaved() {
    let favorites = Favorites(defaults: UserDefaults(suiteName: "favorites." + UUID().uuidString)!)
    favorites.toggle(.video(video("show", origin: origin)))
    #expect(favorites.items(.video).count == 1)
    #expect(favorites.items(.episode).isEmpty)
    #expect(favorites.items(.music).isEmpty)
    #expect(favorites.items(.cloud).isEmpty)
    #expect(favorites.items(.live).isEmpty)
}

@Test @MainActor func filterKindsAreThoseSavedInSectionOrder() {
    let favorites = Favorites(defaults: UserDefaults(suiteName: "favorites." + UUID().uuidString)!)
    #expect(favorites.kinds.isEmpty)
    favorites.toggle(.music(MusicTrack(platform: .qq, songID: "9", title: "Song", artists: ["A"])))
    favorites.toggle(.video(video("show", origin: origin)))
    favorites.toggle(.live(channel("News")))
    favorites.toggle(.video(video("other", origin: origin)))
    #expect(favorites.kinds == [.live, .video, .music])
    favorites.toggle(.live(channel("News")))
    #expect(favorites.kinds == [.video, .music])
}

@Test func listingVideoKeepsPosterTransportHeaders() throws {
    let poster = URL(string: "https://img.example/art/@2x.jpg")!
    let headers = ["Referer": "https://cdn.example/", "User-Agent": "Example Agent", "Cookie": "id=1"]
    let saved = FavoriteVideo(origin: origin, sourceKey: "src", sourceName: "Source", videoID: "show", videoName: "Show", poster: poster, posterHeaders: headers, year: "2024")
    let listing = try #require(saved.listingVideo())
    let plain = try #require(PosterResource(address: poster.absoluteString, origin: origin))
    #expect(listing.poster == plain.url)
    #expect(listing.posterHeaders == headers)
    #expect(listing.id == "show")
    #expect(listing.name == "Show")
    #expect(listing.year == "2024")
    let bare = FavoriteVideo(origin: origin, sourceKey: "src", sourceName: "Source", videoID: "show", videoName: "Show", poster: poster, posterHeaders: [:], year: nil)
    let withoutHeaders = try #require(bare.listingVideo())
    #expect(withoutHeaders.poster == plain.url)
    #expect(withoutHeaders.posterHeaders.isEmpty)
}

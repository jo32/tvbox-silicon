import Foundation
import Testing
@testable import TVCore

private func json(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
private func song(_ title: String, _ id: String, duration: Double = 200) -> MusicTrack {
    MusicTrack(platform: .qq, songID: id, title: title, artists: ["A"], duration: duration)
}

// MARK: - Lyrics

@Test func lrcParsesStampsOffsetsAndTranslations() throws {
    let lrc = [
        "[ti:晴天]", "[ar:周杰伦]", "[offset:500]", "[00:00.00]晴天 - 周杰伦", "[00:03.37]词：周杰伦", "[00:15.00] 编曲 : 钟兴民", "[00:20.00]吉他：蔡科俊 Again",
        "[00:28.00]晴天的前奏",
        "[00:29.50][01:40.120]故事的小黄花", "[00:33.8]从出生那年就飘着", "[00:40:00]", "[00:41.00]", "[00:45.00]It's here",
    ].joined(separator: "\n")
    let lyrics = try #require(MusicLyrics.parse(lrc, translation: "[00:29.60]The little yellow flowers\n[00:33.80]//", platform: .qq))
    #expect(lyrics.synced)
    // The title and credits at the start are dropped; the first sung line leads.
    #expect(lyrics.lines.map(\.text) == ["晴天的前奏", "故事的小黄花", "从出生那年就飘着", "", "It's here", "故事的小黄花"])
    // [offset:500] shows lyrics half a second earlier.
    #expect(abs(lyrics.lines[1].time - 29.0) < 0.001 && abs(lyrics.lines[5].time - 99.62) < 0.001)
    #expect(abs(lyrics.lines[2].time - 33.3) < 0.001)
    #expect(lyrics.lines[1].translation == "The little yellow flowers")
    // "//" marks an untranslated line.
    #expect(lyrics.lines[2].translation == nil)
    #expect(lyrics.index(at: 10) == nil && lyrics.index(at: 28) == 0 && lyrics.index(at: 29.1) == 1 && lyrics.index(at: 39.6) == 3 && lyrics.index(at: 500) == 5)
    #expect(MusicLyrics.isCredit("作词 : Taylor Swift/Liz Rose") && !MusicLyrics.isCredit("故事的小黄花") && !MusicLyrics.isCredit("Love Story"))

    let plain = try #require(MusicLyrics.parse("第一句\n\n第二句", platform: .netease))
    #expect(!plain.synced && plain.lines.map(\.text) == ["第一句", "第二句"] && plain.index(at: 5) == nil)
    #expect(MusicLyrics.parse("[ti:x]\n[00:01.00]", platform: .qq) == nil)
}

@Test func catalogLyricsAnswersParse() throws {
    let qq = try #require(QQMusicCatalog.parseLyrics(try json(#"{"retcode":0,"code":0,"lyric":"[00:01.00]Don&apos;t stop","trans":""}"#)))
    #expect(qq.lines.first?.text == "Don't stop" && qq.platform == .qq)
    #expect(QQMusicCatalog.parseLyrics(try json(#"{"retcode":-1901,"code":-1901}"#)) == nil)
    let netease = try #require(NeteaseMusicCatalog.parseLyrics(try json(
        #"{"code":200,"lrc":{"lyric":"[00:16.24]We were both young"},"tlyric":{"lyric":"[00:16.240]我们都还很年轻"}}"#)))
    #expect(netease.lines.first?.translation == "我们都还很年轻")
    #expect(NeteaseMusicCatalog.parseLyrics(try json(#"{"code":200,"nolyric":true}"#)) == nil)
}

private struct FakeLyrics: MusicLyricsSource {
    let platform: MusicPlatform
    let answer: MusicLyrics?
    func lyrics(songID: String) async throws -> MusicLyrics? { answer }
}

@Test func lyricsComeFromThePlayingCatalogFirst() async throws {
    var track = song("江南", "q")
    track.ids[.netease] = "108914"
    let qq = MusicLyrics.parse("[00:01.00]qq", platform: .qq), netease = MusicLyrics.parse("[00:01.00]netease", platform: .netease)
    let loader = MusicLyricsLoader(sources: [FakeLyrics(platform: .qq, answer: qq), FakeLyrics(platform: .netease, answer: netease)])
    #expect(await loader.lyrics(for: track, playing: .netease)?.platform == .netease)
    #expect(await loader.lyrics(for: track, playing: .qq)?.platform == .qq)
    // Synced lyrics from the other catalog beat unsynced ones from the playing catalog.
    let unsynced = MusicLyrics.parse("only words", platform: .qq)
    let mixed = MusicLyricsLoader(sources: [FakeLyrics(platform: .qq, answer: unsynced), FakeLyrics(platform: .netease, answer: netease)])
    #expect(await mixed.lyrics(for: track, playing: .qq)?.platform == .netease)
    #expect(await loader.lyrics(for: song("x", "z"), playing: .netease)?.platform == .qq)
}

// MARK: - Albums and playlists

@Test func collectionAnswersParse() throws {
    let qqAlbums = QQMusicCatalog.parseCollections(try json(#"{"code":0,"req":{"code":0,"data":{"body":{"item_album":[{"albummid":"000MkMni19ClKG","name":"<em>叶惠美</em>","singer":"周杰伦","singer_list":[{"name":"周杰伦"}],"song_num":11,"publish_date":"2003-07-31"}]}}}}"#), kind: .album)
    #expect(qqAlbums.first == MusicCollection(kind: .album, platform: .qq, collectionID: "000MkMni19ClKG", title: "叶惠美", subtitle: "周杰伦",
                                              artwork: URL(string: "https://y.gtimg.cn/music/photo_new/T002R300x300M000000MkMni19ClKG.jpg"), trackCount: 11, year: "2003"))
    let qqLists = QQMusicCatalog.parseCollections(try json(#"{"req":{"code":0,"data":{"body":{"item_songlist":[{"dissid":"7039749142","dissname":"百听不厌的<em>周杰伦</em>","nickname":"今晚月色很美","songnum":99,"logo":"http://qpic.y.qq.com/a/300"}]}}}}"#), kind: .playlist)
    #expect(qqLists.first?.title == "百听不厌的周杰伦" && qqLists.first?.trackCount == 99 && qqLists.first?.subtitle == "今晚月色很美")
    let (albumSongs, total) = QQMusicCatalog.parseAlbum(try json(#"{"req":{"code":0,"data":{"totalNum":11,"songList":[{"songInfo":{"mid":"0039MnYb0qxYhV","title":"晴天","singer":[{"name":"周杰伦"}],"album":{"mid":"000MkMni19ClKG","name":"叶惠美"},"interval":269}}]}}}"#))
    #expect(albumSongs.map(\.id) == ["qq:0039MnYb0qxYhV"] && total == 11 && albumSongs[0].duration == 269)

    let neteaseAlbums = NeteaseMusicCatalog.parseCollections(try json(#"{"code":200,"result":{"albums":[{"id":10804,"name":"第二天堂","size":15,"picUrl":"https://p2.music.126.net/a.jpg","artist":{"name":"林俊杰"}}]}}"#), kind: .album)
    #expect(neteaseAlbums.first?.collectionID == "10804" && neteaseAlbums.first?.subtitle == "林俊杰" && neteaseAlbums.first?.trackCount == 15)
    let neteaseLists = NeteaseMusicCatalog.parseCollections(try json(#"{"code":200,"result":{"playlists":[{"id":7694176632,"name":"听·林俊杰","trackCount":40,"coverImgUrl":"http://p1.music.126.net/x.jpg?imageView=1&watermark","creator":{"nickname":"云音乐"}}]}}"#), kind: .playlist)
    #expect(neteaseLists.first?.artwork?.absoluteString == "http://p1.music.126.net/x.jpg?param=300y300")
    let track = try #require(NeteaseMusicCatalog.track(try json(#"{"id":108899,"name":"第二天堂","ar":[{"name":"林俊杰"}],"al":{"name":"第二天堂","picUrl":"https://p.jpg"},"dt":266031}"#)))
    #expect(track.duration == 266.031 && track.artists == ["林俊杰"] && track.album == "第二天堂")

    let ranked = MusicCollections.rank([neteaseLists[0], neteaseAlbums[0], qqAlbums[0]], query: "叶惠美 周杰伦")
    #expect(ranked.first?.title == "叶惠美")
}

// MARK: - Queue, history and resuming

@Test func queueMovesThroughTracksAndStopsAfterRepeatedFailures() {
    let tracks = (1...4).map { song("S\($0)", "\($0)") }
    var queue = MusicQueue(tracks: tracks, start: 1, source: "Album")
    #expect(queue.current?.title == "S2" && queue.hasPrevious && queue.hasNext)
    #expect(queue.advance()?.title == "S3")
    #expect(queue.advance()?.title == "S4" && !queue.hasNext)
    #expect(queue.advance() == nil && queue.current?.title == "S4")
    #expect(queue.back()?.title == "S3")
    #expect(queue.jump(to: 0)?.title == "S1" && queue.jump(to: 9) == nil)
    #expect(queue.skipsAfterFailure(consecutive: 1) && queue.skipsAfterFailure(consecutive: 2))
    #expect(!queue.skipsAfterFailure(consecutive: 3))
    _ = queue.jump(to: 3)
    #expect(!queue.skipsAfterFailure(consecutive: 0))
    let shuffled = MusicQueue.shuffled(tracks, first: tracks[2])
    #expect(shuffled.current == tracks[2] && Set(shuffled.tracks) == Set(tracks))
    #expect(MusicQueue(tracks: tracks, start: 99).current == tracks[3])
}

@MainActor @Test func historyAndResumePointSurviveRelaunch() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "music-library-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let library = MusicLibrary(file: file)
    let a = song("A", "a"), b = song("B", "b")
    library.recordPlay(a, at: Date(timeIntervalSince1970: 1))
    library.recordPlay(b, at: Date(timeIntervalSince1970: 2))
    library.recordPlay(a, at: Date(timeIntervalSince1970: 3))
    #expect(library.history.map(\.track?.title) == ["A", "B"])
    // An album played from its page is one entry, however many of its songs played.
    let album = MusicCollection(kind: .album, platform: .qq, collectionID: "x", title: "叶惠美")
    library.recordPlay(album); library.recordPlay(album)
    #expect(library.history.map(\.id) == [album.id, a.id, b.id] && library.history[0].track == nil)
    #expect(MusicQueue(tracks: [a], collection: album).source == "叶惠美")
    let point = MusicResumePoint(queue: MusicQueue(tracks: [a, b], start: 1, source: "Album"), position: 42.5, savedAt: Date(timeIntervalSince1970: 4))
    library.saveResumePoint(point)
    library.flush()
    let reopened = MusicLibrary(file: file)
    #expect(reopened.history.map(\.id) == [album.id, a.id, b.id] && reopened.history[0].collection == album)
    #expect(reopened.resumePoint == point && reopened.resumePoint?.queue.current == b)
    for index in 0..<(MusicLibrary.historyLimit + 5) { reopened.recordPlay(song("S\(index)", "s\(index)")) }
    #expect(reopened.history.count == MusicLibrary.historyLimit)
    reopened.clearHistory()
    #expect(reopened.history.isEmpty && reopened.resumePoint == point)
}

private struct FakeCollections: MusicCatalogSource, MusicCollectionSource {
    let platform: MusicPlatform
    let found: [MusicCollection]
    func search(_ query: String, page: Int) async throws -> [MusicTrack] { [] }
    func searchCollections(_ query: String, kind: MusicCollection.Kind, page: Int) async throws -> [MusicCollection] {
        found.filter { $0.kind == kind }
    }
    func tracks(of collection: MusicCollection) async throws -> [MusicTrack] { [] }
}

@MainActor @Test func searchFindsAlbumsAndPlaylists() async throws {
    let album = MusicCollection(kind: .album, platform: .qq, collectionID: "1", title: "叶惠美", subtitle: "周杰伦")
    let list = MusicCollection(kind: .playlist, platform: .netease, collectionID: "2", title: "叶惠美专辑重温")
    let model = MusicSearchModel(catalogs: [FakeCollections(platform: .qq, found: [album]), FakeCollections(platform: .netease, found: [list])],
                                 health: MusicHealth(file: nil))
    model.search("叶惠美", kind: .albums, immediately: true)
    try await settle(model)
    #expect(model.kind == .albums && model.collections == [album] && model.results.isEmpty && model.directHit == nil)
    model.search("叶惠美", kind: .playlists, immediately: true)
    try await settle(model)
    #expect(model.collections == [list] && !model.empty)
    #expect(model.source(for: .qq) != nil)
}

@MainActor @Test func topResultsFindSongsAlbumsAndPlaylistsTogether() async throws {
    let album = MusicCollection(kind: .album, platform: .qq, collectionID: "1", title: "叶惠美", subtitle: "周杰伦")
    let list = MusicCollection(kind: .playlist, platform: .netease, collectionID: "2", title: "叶惠美专辑重温")
    let model = MusicSearchModel(catalogs: [FakeCollections(platform: .qq, found: [album, list])], health: MusicHealth(file: nil))
    model.search("叶惠美", kind: .top, immediately: true)
    try await settle(model)
    // Each kind's answer keeps the other's: both are on the page at once.
    #expect(Set(model.collections) == [album, list])
    model.search("叶惠美", kind: .albums, immediately: true)
    try await settle(model)
    #expect(model.collections == [album])
    #expect(!MusicSearchKind.filters.contains(.top))
}

private struct FakeSongs: MusicCatalogSource {
    let platform: MusicPlatform
    let found: [MusicTrack]
    func search(_ query: String, page: Int) async throws -> [MusicTrack] { found }
}

@MainActor @Test func artistSearchKeepsTheArtistsSongs() async throws {
    func track(_ id: String, _ title: String, _ artists: [String]) -> MusicTrack {
        var track = song(title, id); track.artists = artists; return track
    }
    // A song named after the artist, by someone else, is no song of theirs; a duet is.
    let qing = track("1", "晴天", ["周杰伦"]), duet = track("2", "千里之外", ["周杰伦", "费玉清"])
    let tribute = track("3", "周杰伦", ["其他人"]), cover = track("4", "晴天（翻唱）", ["周杰伦的粉丝"])
    let model = MusicSearchModel(catalogs: [FakeSongs(platform: .qq, found: [tribute, qing, cover, duet])], health: MusicHealth(file: nil))
    model.search("周杰伦", kind: .artists, immediately: true)
    try await settle(model)
    #expect(model.kind == .artists && model.results == [qing, duet] && model.directHit == nil)
    #expect(MusicSearchKind.filters == [.songs, .artists, .albums, .playlists])
    // Part of a name, when no artist is the whole of it.
    #expect(MusicMatching.byArtist([tribute, qing, cover], query: "杰伦") == [qing, cover])
    #expect(MusicMatching.byArtist([qing], query: " ").isEmpty)
}

/// One page of songs per call, by page number.
private struct PagedSongs: MusicCatalogSource {
    let platform: MusicPlatform
    let pages: [[MusicTrack]]
    func search(_ query: String, page: Int) async throws -> [MusicTrack] { page <= pages.count ? pages[page - 1] : [] }
}

@MainActor @Test func searchFiltersNarrowByYearGenreAndLanguage() async throws {
    func track(_ id: String, _ title: String, _ year: Int?, _ genre: MusicGenre?, _ language: MusicLanguage?) -> MusicTrack {
        var track = song(title, id); track.year = year; track.genre = genre; track.language = language; return track
    }
    let qing = track("1", "晴天", 2003, .pop, .mandarin), fukua = track("2", "浮夸", 2005, .pop, .cantonese)
    let unlabelled = track("3", "无名", nil, nil, nil), shape = track("4", "Shape of You", 2017, .pop, .english)
    let model = MusicSearchModel(catalogs: [PagedSongs(platform: .qq, pages: [[qing, fukua, unlabelled], [shape]])], health: MusicHealth(file: nil))
    model.search("歌", kind: .songs, immediately: true)
    try await settle(model)
    #expect(model.results == [qing, fukua, unlabelled])
    // The first filter searches again with a second page; a song with no year is hidden.
    model.setFilter(MusicSearchFilter(decade: .d2000))
    try await settle(model)
    #expect(model.results == [qing, fukua] && model.filter.decade == .d2000)
    // Changing it only refilters what was found.
    model.setFilter(MusicSearchFilter(decade: .d2010))
    #expect(model.results == [shape] && !model.busy)
    model.setFilter(MusicSearchFilter(language: .cantonese))
    #expect(model.results == [fukua])
    model.setFilter(MusicSearchFilter(genre: .rock))
    #expect(model.results.isEmpty && model.filteredOut && !model.empty)
    model.setFilter(MusicSearchFilter())
    #expect(model.results == [qing, fukua, unlabelled, shape] && !model.filteredOut)
    // The filter stays for the next query.
    model.setFilter(MusicSearchFilter(genre: .pop, language: .english))
    model.search("歌曲", immediately: true)
    try await settle(model)
    #expect(model.results == [shape])

    // Albums by their year; playlists have none to filter by.
    let album = MusicCollection(kind: .album, platform: .qq, collectionID: "1", title: "叶惠美", year: "2003")
    let undated = MusicCollection(kind: .album, platform: .qq, collectionID: "2", title: "无名")
    let list = MusicCollection(kind: .playlist, platform: .qq, collectionID: "3", title: "歌单")
    let noughties = MusicSearchFilter(decade: .d2000, genre: .rock)
    #expect(noughties.admits(album) && !noughties.admits(undated) && noughties.admits(list))
    #expect(!MusicSearchFilter(decade: .d2010).admits(album))
    #expect(MusicSearchFilter.facets(for: .albums) == [.decade] && MusicSearchFilter.facets(for: .playlists).isEmpty)
    #expect(MusicSearchFilter.facets(for: .artists) == [.decade, .genre, .language])
    #expect(MusicDecade.earlier.contains(1974) && MusicDecade.d1980.contains(1989) && !MusicDecade.d1980.contains(1990))

    // Another catalog's copy of a song takes QQ's labels when the two merge.
    var copy = song("晴天", "9"); copy.ids = [.netease: "9"]; copy.id = "netease:9"
    let merged = MusicMatching.merge([[copy], [qing]])
    #expect(merged.count == 1 && merged[0].year == 2003 && merged[0].genre == .pop && merged[0].language == .mandarin)
}

@Test func queueTakesSongsNextAndLast() {
    let a = song("A", "a"), b = song("B", "b"), c = song("C", "c"), d = song("D", "d")
    var queue = MusicQueue(tracks: [a, b], start: 0)
    queue.insertNext([c])
    #expect(queue.tracks == [a, c, b] && queue.current == a)
    queue.append([d])
    #expect(queue.tracks == [a, c, b, d] && queue.index == 0)
}

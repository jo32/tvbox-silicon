import Foundation
import Testing
@testable import TVCore

private func json(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
private func list(_ platform: MusicPlatform, _ id: String) -> MusicCollection {
    MusicCollection(kind: .playlist, platform: platform, collectionID: id, title: id)
}

// Trimmed from QQ's and NetEase's answers on 2026-11-02.

@Test func qqBrowseAnswersBecomeShelves() throws {
    let charts = try json(#"{"code":0,"req":{"code":0,"data":{"group":[{"groupId":0,"groupName":"巅峰榜","toplist":[{"topId":62,"title":"飙升榜","totalNum":100,"mbFrontPicUrl":"https://y.gtimg.cn/music/photo_new/T002R300x300M000001.jpg","frontPicUrl":"http://y.gtimg.cn/a.png"},{"topId":26,"title":"热歌榜","totalNum":300,"mbFrontPicUrl":"","frontPicUrl":"http://y.gtimg.cn/b.jpg"}]},{"groupId":3,"groupName":"全球榜","toplist":[{"topId":108,"title":"美国公告牌榜","totalNum":100}]}]}}}"#)
    let plaza = try json(#"{"code":0,"req":{"code":0,"data":{"total":11616,"v_playlist":[{"tid":7707261125,"title":"甜度爆表 | 旋律说唱狙击少女心","cover_url_medium":"http://qpic.y.qq.com/music_cover/x/300?n=1","creator_info":{"nick":"我想要两颗西柚"},"song_ids":[1,2,3]},{"tid":0,"title":"broken"}]}}}"#)
    let albums = try json(#"{"code":0,"req":{"code":0,"data":{"albums":[{"id":106411950,"mid":"000JeCNB4QY93C","name":"挺好的","singers":[{"name":"洛天依"}],"release_time":"2026-11-02"}]}}}"#)
    let shelves = QQMusicCatalog.parseBrowse(charts: charts, playlists: plaza, albums: albums)
    #expect(shelves.map(\.id) == [MusicBrowse.charts, MusicBrowse.playlists, MusicBrowse.albums, MusicBrowse.moreCharts])
    let top = shelves[0].collections
    #expect(top.map(\.title) == ["飙升榜", "热歌榜"] && top[0].collectionID == "toplist:62" && top[0].trackCount == 100)
    // The square cover when there is one, otherwise the next picture.
    #expect(top[0].artwork?.absoluteString == "https://y.gtimg.cn/music/photo_new/T002R300x300M000001.jpg")
    #expect(top[1].artwork?.absoluteString == "http://y.gtimg.cn/b.jpg")
    #expect(QQMusicCatalog.chartID(top[1]) == 26 && QQMusicCatalog.chartID(shelves[1].collections[0]) == nil)
    #expect(shelves[1].collections == [MusicCollection(kind: .playlist, platform: .qq, collectionID: "7707261125", title: "甜度爆表 | 旋律说唱狙击少女心",
                                                       subtitle: "我想要两颗西柚", artwork: URL(string: "http://qpic.y.qq.com/music_cover/x/300?n=1"), trackCount: 3)])
    #expect(shelves[2].collections.first == MusicCollection(kind: .album, platform: .qq, collectionID: "000JeCNB4QY93C", title: "挺好的", subtitle: "洛天依",
                                                            artwork: URL(string: "https://y.gtimg.cn/music/photo_new/T002R300x300M000000JeCNB4QY93C.jpg"), year: "2026"))
    #expect(shelves[3].collections.map(\.title) == ["美国公告牌榜"])
    // A catalog part that failed only drops its shelf.
    #expect(QQMusicCatalog.parseBrowse(charts: nil, playlists: plaza, albums: nil).map(\.id) == [MusicBrowse.playlists])

    let chart = QQMusicCatalog.parseChart(try json(#"{"code":0,"req":{"code":0,"data":{"data":{"topId":26},"songInfoList":[{"id":1,"mid":"0039MnYb0qxYhV","name":"Hong Kong","title":"Hong Kong","singer":[{"name":"The Weeknd"}],"album":{"mid":"003h24VO1pTh6K","name":"Hong Kong"},"interval":215}]}}}"#))
    #expect(chart.map(\.id) == ["qq:0039MnYb0qxYhV"] && chart[0].duration == 215 && chart[0].artists == ["The Weeknd"])
}

@Test func neteaseBrowseAnswersBecomeShelves() throws {
    let charts = try json(#"{"code":200,"list":[{"id":19723756,"name":"飙升榜","ToplistType":"S","trackCount":100,"coverImgUrl":"https://p2.music.126.net/a.jpg","creator":null},{"id":71384707,"name":"网易云古典榜","ToplistType":null,"trackCount":100,"coverImgUrl":"https://p2.music.126.net/b.jpg"}]}"#)
    let lists = try json(#"{"hasTaste":false,"code":200,"result":[{"id":514947114,"type":0,"name":"华语民谣","picUrl":"https://p2.music.126.net/c.jpg","trackCount":287}]}"#)
    let albums = try json(#"{"total":500,"code":200,"albums":[{"id":407428221,"name":"BAILE FUNK MANDALA","size":1,"picUrl":"https://p2.music.126.net/d.jpg","publishTime":1793603245000,"artist":{"name":"圈圈菌"}}]}"#)
    let shelves = NeteaseMusicCatalog.parseBrowse(charts: charts, playlists: lists, albums: albums)
    #expect(shelves.map(\.id) == [MusicBrowse.charts, MusicBrowse.playlists, MusicBrowse.albums, MusicBrowse.moreCharts])
    #expect(shelves[0].collections == [MusicCollection(kind: .playlist, platform: .netease, collectionID: "19723756", title: "飙升榜",
                                                       artwork: URL(string: "https://p2.music.126.net/a.jpg?param=300y300"), trackCount: 100)])
    #expect(shelves[1].collections.first?.artwork?.absoluteString == "https://p2.music.126.net/c.jpg?param=300y300")
    #expect(shelves[2].collections.first?.subtitle == "圈圈菌" && shelves[2].collections.first?.kind == .album)
    #expect(shelves[3].collections.map(\.title) == ["网易云古典榜"])
}

@Test func browseShelvesFromSeveralCatalogsTakeTurns() {
    let qq = [MusicBrowseSection(id: "charts", title: "Top Charts", collections: [list(.qq, "1"), list(.qq, "2"), list(.qq, "3")]),
              MusicBrowseSection(id: "albums", title: "New Albums", collections: [list(.qq, "a")])]
    let netease = [MusicBrowseSection(id: "playlists", title: "Playlists", collections: [list(.netease, "p")]),
                   MusicBrowseSection(id: "charts", title: "Other", collections: [list(.netease, "1"), list(.qq, "2")]),
                   MusicBrowseSection(id: "empty", title: "Empty", collections: [])]
    let merged = MusicBrowse.merge([qq, netease])
    #expect(merged.map(\.id) == ["charts", "albums", "playlists"])
    #expect(merged[0].title == "Top Charts")
    // One from each in turn; the second catalog's copy of qq:2 is dropped.
    #expect(merged[0].collections.map(\.id) == ["qq:playlist:1", "netease:playlist:1", "qq:playlist:2", "qq:playlist:3"])
}

private final class FakeBrowse: MusicBrowseSource, @unchecked Sendable {
    let platform: MusicPlatform
    var fails: Bool
    var calls = 0
    init(_ platform: MusicPlatform, fails: Bool = false) { self.platform = platform; self.fails = fails }
    func browseSections() async throws -> [MusicBrowseSection] {
        calls += 1
        if fails { throw MusicProviderError.invalidResponse("down") }
        return [MusicBrowseSection(id: "charts", title: "Top Charts", collections: [list(platform, "\(calls)")])]
    }
}

@MainActor @Test func browseLoadsOnceAndAsksAFailedCatalogAgain() async {
    let qq = FakeBrowse(.qq), netease = FakeBrowse(.netease, fails: true)
    let model = MusicBrowseModel(sources: [qq, netease])
    let start = Date()
    await model.load(now: start)
    #expect(model.sections.first?.collections.map(\.id) == ["qq:playlist:1"] && model.incomplete && !model.loading)
    // Only the catalog that failed is asked again.
    netease.fails = false
    await model.load(now: start.addingTimeInterval(60))
    #expect(qq.calls == 1 && netease.calls == 2 && !model.incomplete)
    #expect(model.sections.first?.collections.map(\.id) == ["qq:playlist:1", "netease:playlist:2"])
    // Kept for the session, until the charts are hours old.
    await model.load(now: start.addingTimeInterval(3600))
    #expect(qq.calls == 1 && netease.calls == 2)
    await model.load(now: start.addingTimeInterval(MusicBrowseModel.lifetime + 1))
    #expect(qq.calls == 2 && netease.calls == 3)
}

import Foundation
import Testing
@testable import TVCore

private func automaticContext(episode: String = "第1集") -> PlaybackHistoryContext {
    var context = PlaybackHistoryContext(origin: URL(string: "https://example.com/config")!, sourceKey: "movies", sourceName: "Movies", videoID: "series", videoName: "测试剧",
        episodeID: episode, episodeName: episode, episodeFlag: "line")
    context.year = "2025"
    return context
}
private actor DanmakuTestTransport {
    var counts: [String: Int] = [:]
    var mode: String
    init(_ mode: String) { self.mode = mode }
    func send(_ request: URLRequest) async throws -> Data {
        let host = request.url!.host()!, path = request.url!.path
        counts[host + path, default: 0] += 1
        if host == "mesh.if.iqiyi.com" {
            let root: [String: Any] = ["data": ["templates": [["albumInfo": ["title": "测试剧", "qipuId": "123", "year": ["value": "2025"], "videos": [
                ["number":"探班日", "title":"花絮", "pageUrl":"https://www.iqiyi.com/v_trailer.html"],
                ["number":"1", "title":"测试剧第1集", "pageUrl":"https://www.iqiyi.com/v_episode1.html"],
                ["number":"2", "title":"测试剧第2集", "pageUrl":"https://www.iqiyi.com/v_episode2.html"]
            ]]]]]]
            return try JSONSerialization.data(withJSONObject: root)
        }
        if host == "pbaccess.video.qq.com" { return Data(#"{"ret":0,"data":{"areaBoxList":[]}}"#.utf8) }
        if host == "backup.test" {
            if mode != "backup" { throw TVError.http(404) }
            return Data(##"{"code":200,"count":2,"danmuku":[[1,5,"#4994c4","有2条弹幕正在赶来，请遵守弹幕礼仪，祝您观影愉快~","1"],[3,1,"#ffffff","备用解析","1721178153"],[8,5,"#f00","顶部","1721178153"]]}"##.utf8)
        }
        if host == "dmku.test" {
            if mode == "dandan" { throw TVError.http(503) }
            if mode == "backup" { return Data(#"{"code":23,"danmuku":[]}"#.utf8) }
            return Data(##"{"code":23,"danmuku":[[1.5,"right","#fff","32px","真实协议测试"],[4,"top","#f00","32px","顶部"]]}"##.utf8)
        }
        if host == "dandan.test" {
            if mode == "slow" { try await Task.sleep(for: .seconds(10)) }
            if mode != "dandan" { return Data(#"{"success":true,"animes":[]}"#.utf8) }
            if path.contains("search/anime") { return Data(#"{"animes":[{"animeId":123,"animeTitle":"测试剧"}]}"#.utf8) }
            if path.contains("bangumi") { return Data(#"{"bangumi":{"episodes":[{"episodeId":123001,"episodeTitle":"第1集"},{"episodeId":123002,"episodeTitle":"第2集"}]}}"#.utf8) }
            return Data(#"{"comments":[{"p":"2,1,16777215,user","m":"备用弹幕"}]}"#.utf8)
        }
        throw TVError.http(404)
    }
    func count(_ key: String) -> Int { counts[key] ?? 0 }
    func total() -> Int { counts.values.reduce(0, +) }
}

@Test func multiSourceDanmakuUsesOfficialMetadataCachesPerSeriesAndReusesAddressesForNextEpisode() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = DanmakuTestTransport("dmku")
    let http = DanmakuHTTP { try await transport.send($0) }
    let cache = MediaCache(root: root)
    let resolver = DanmakuResolver(cache: cache, http: http, dandanServer: "https://dandan.test", dmkuServer: URL(string: "https://dmku.test")!)
    let result = try await resolver.resolve(automaticContext())
    #expect(result.source == "dmku · iqiyi")
    #expect(result.comments.count == 2)
    #expect(result.comments.first?.color == 0xffffff)
    #expect(!result.cached)
    let requests = await transport.total()
    let cached = try await resolver.resolve(automaticContext())
    #expect(cached.cached)
    #expect(await transport.total() == requests)
    let next = try await resolver.resolve(automaticContext(episode: "第2集"))
    #expect(next.comments.count == 2)
    #expect(await transport.count("mesh.if.iqiyi.com/portal/lw/search/homePageV3") == 1)
    #expect(cache.summary().danmaku == 2)
    #expect(cache.summary().lookups == 1)
    cache.remove(scope: automaticContext().id)
    #expect(cache.summary().danmaku == 0)
    #expect(cache.summary().lookups == 1)
}

@Test func dandanplayIsPrimaryAndSlowPrimaryFallsBackWithinBoundedTime() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    for mode in ["slow", "dandan"] {
        let transport = DanmakuTestTransport(mode)
        let resolver = DanmakuResolver(cache: MediaCache(root: root.appending(path: mode)), http: DanmakuHTTP { try await transport.send($0) },
            dandanServer: "https://dandan.test", dmkuServer: URL(string: "https://dmku.test")!)
        let start = Date()
        let result = try await resolver.resolve(automaticContext())
        #expect(!result.comments.isEmpty)
        #expect(Date().timeIntervalSince(start) < 7)
        #expect(mode == "dandan" ? result.source == "Dandanplay" : result.source == "dmku · iqiyi")
        if mode == "dandan" {
            #expect(await transport.count("dmku.test/") == 0)
            #expect(await transport.count("mesh.if.iqiyi.com/portal/lw/search/homePageV3") == 0)
            #expect(await transport.count("pbaccess.video.qq.com/trpc.videosearch.search_cgi.http/load_playsource_list_info") == 0)
        }
    }
}

@Test func officialPagesFallBackToTheBackupParserWhenDmkuHasNoComments() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = DanmakuTestTransport("backup")
    let resolver = DanmakuResolver(cache: MediaCache(root: root), http: DanmakuHTTP { try await transport.send($0) },
        dandanServer: "https://dandan.test", dmkuServer: URL(string: "https://dmku.test")!, backupServer: URL(string: "https://backup.test/")!)
    let result = try await resolver.resolve(automaticContext())
    #expect(result.source == "backup.test · iqiyi")
    #expect(result.comments.map(\.text) == ["备用解析", "顶部"])
    #expect(result.comments.last?.mode == .top)
    #expect(result.comments.last?.color == 0xff0000)
    #expect(await transport.count("dmku.test") == 1)
}

@Test func officialMatchingRejectsRemakesWrongSeasonsTrailersAndCredentialURLs() throws {
    let context = automaticContext()
    let anime: [String: Any] = ["title":"测试剧", "qipuId":"1", "year":["value":"2024"], "videos":[]]
    #expect(OfficialDanmakuCatalog.parseIQiyi(["data":["templates":[["albumInfo":anime]]]], context: context) == nil)
    let mapping = DanmakuMapping(provider: "iqiyi", title: "测试剧第二季", year: "2025", tracks: [DanmakuTrack(number: 1, title: "第1集")])
    #expect(mapping.track(for: context) == nil)
    #expect(DanmakuMapping(provider: "iqiyi", title: "测试剧", year: "2025", tracks: [DanmakuTrack(number:1,title:"1"),DanmakuTrack(number:1,title:"preview")]).track(for: context) == nil)
    #expect(OfficialVideoPage.validated("https://user:secret@www.iqiyi.com/v_a.html") == nil)
    #expect(OfficialVideoPage.validated("https://www.iqiyi.com.evil.test/v_a.html") == nil)
    #expect(OfficialVideoPage.validated("https://cdn.example.com/video.m3u8?token=secret") == nil)
    #expect(OfficialVideoPage.validated("http://www.iqiyi.com/v_a.html?token=tracking")?.absoluteString == "https://www.iqiyi.com/v_a.html")
    #expect(CatalogDanmakuMatcher.normalized("葬送的芙莉蓮") == CatalogDanmakuMatcher.normalized("葬送的芙莉莲"))
}

@Test func dmkuParserRejectsErrorsAndTencentSkipsTrailersAndFindsExplicitNumbers() throws {
    #expect(throws: (any Error).self) { try CatalogDanmakuParser.parse(Data(#"{"code":0,"danmuku":[]}"#.utf8)) }
    let root: [String: Any] = ["data":["module_list_datas":[["module_datas":[["item_data_lists":["item_datas":[
        ["item_params":["vid":"real1","union_title":"第1集","is_trailer":"0"]],
        ["item_params":["vid":"trailer","union_title":"第1集","is_trailer":"1"]],
        ["item_params":["vid":"bonus","union_title":"花絮","is_trailer":"0"]]
    ]]]]]]]]
    let tracks = OfficialDanmakuCatalog.tencentTracks(root, cid: "cover1")
    #expect(tracks.count == 1)
    #expect(tracks.first?.page?.absoluteString == "https://v.qq.com/x/cover/cover1/real1.html")
}

@Test func serviceFailuresAreBrieflyCachedAndDeletionDuringLookupCannotRepopulateContent() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = MediaCache(root: root)
    let http = DanmakuHTTP { _ in try await Task.sleep(for: .milliseconds(100)); throw TVError.http(503) }
    let resolver = DanmakuResolver(cache: cache, http: http, dandanServer: "https://offline.test", officialLookup: false)
    let initial = try await resolver.resolve(automaticContext())
    #expect(initial.state == "unavailable")
    #expect(initial.comments.isEmpty)
    let cached = try await resolver.resolve(automaticContext())
    #expect(cached.cached)
    cache.clear()
    let pending = Task { try await resolver.resolve(automaticContext()) }
    try await Task.sleep(for: .milliseconds(30))
    cache.remove(scope: automaticContext().id)
    _ = try await pending.value
    #expect(cache.summary().danmaku == 0)
}

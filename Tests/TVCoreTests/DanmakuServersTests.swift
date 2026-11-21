import Foundation
import Testing
@testable import TVCore

// Danmaku servers added by hand (#1408) and finding comments by an episode link (#1089).

private func serversContext(_ episode: String = "第5集", page: String? = nil) -> PlaybackHistoryContext {
    var context = PlaybackHistoryContext(origin: URL(string: "https://example.com/subscription?token=private")!,
        sourceKey: "source", sourceName: "Source", videoID: "series", videoName: "测试剧",
        episodeID: "https://example.com/video.m3u8?secret=playback", episodeName: episode, episodeFlag: "line")
    context.year = "2023"
    context.officialPage = page.flatMap { URL(string: $0) }
    return context
}

private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appending(path: "danmaku-servers-" + UUID().uuidString) }

/// danmu_api-like servers, one per host, each answering as configured.
private actor ServersTransport {
    var requests: [URLRequest] = []
    /// Hosts whose search lists 测试剧, hosts that read official pages (`comment?url=`), and hosts refusing or down.
    var listed: Set<String> = [], pages: Set<String> = [], refused: Set<String> = [], down: Set<String> = []
    func configure(listed: Set<String> = [], pages: Set<String> = [], refused: Set<String> = [], down: Set<String> = []) {
        self.listed = listed; self.pages = pages; self.refused = refused; self.down = down
    }
    func send(_ request: URLRequest) throws -> Data {
        requests.append(request)
        let url = request.url!, host = url.host() ?? "", path = url.path
        #expect(!url.absoluteString.contains("m3u8") && !url.absoluteString.contains("subscription"))
        if refused.contains(host) { throw TVError.http(401) }
        if down.contains(host) { throw TVError.http(503) }
        if path.hasSuffix("/api/v2/comment") {
            guard pages.contains(host) else { throw TVError.http(404) }
            return Data(#"{"errorCode":0,"success":true,"count":1,"comments":[{"cid":1,"p":"2.00,1,16777215,[qq]","m":"页面弹幕","t":2}]}"#.utf8)
        }
        if path.hasSuffix("search/anime") {
            return Data((listed.contains(host)
                ? #"{"errorCode":0,"success":true,"animes":[{"animeId":7,"animeTitle":"测试剧(2023)【国产剧】from tencent","source":"tencent","startDate":"2023-01-01T00:00:00Z"}]}"#
                : #"{"errorCode":0,"success":true,"animes":[]}"#).utf8)
        }
        if path.hasSuffix("bangumi/7") {
            return Data(#"{"errorCode":0,"success":true,"bangumi":{"animeId":7,"episodes":[{"episodeId":75,"episodeTitle":"【qq】 测试剧 第5集","episodeNumber":"5"},{"episodeId":76,"episodeTitle":"【qq】 测试剧 第6集","episodeNumber":"6"}]}}"#.utf8)
        }
        if path.contains("/comment/") {
            return Data(#"{"count":1,"comments":[{"cid":1,"p":"1.00,1,16777215,[qq]","m":"\#(host)","t":1}]}"#.utf8)
        }
        throw TVError.http(404)
    }
    func log() -> [String] { requests.map { ($0.url?.host() ?? "") + ($0.url?.path ?? "") } }
    func pageQuery(_ index: Int) -> String? {
        URLComponents(url: requests[index].url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "url" }?.value
    }
}

@Test func danmakuServersStartFromTheOneAddressSavedBeforeTheList() throws {
    let defaults = try #require(UserDefaults(suiteName: "DanmakuServers-\(UUID().uuidString)"))
    #expect(DanmakuService.servers(defaults: defaults) == [CatalogDanmakuClient.defaultServer])
    defaults.set("https://A.example/tok/api/v2/", forKey: DanmakuService.serverKey)
    #expect(DanmakuService.servers(defaults: defaults) == ["https://a.example/tok"])
    try DanmakuService.save(servers: ["https://b.example/api/v2", "https://a.example/tok", "https://b.example"], defaults: defaults)
    #expect(DanmakuService.servers(defaults: defaults) == ["https://b.example", "https://a.example/tok"])
    #expect(defaults.string(forKey: DanmakuService.serverKey) == "https://b.example")
    try DanmakuService.move("https://a.example/tok", to: 0, defaults: defaults)
    #expect(DanmakuService.servers(defaults: defaults) == ["https://a.example/tok", "https://b.example"])
    #expect(defaults.string(forKey: DanmakuService.serverKey) == "https://a.example/tok")
    // The one-address save replaces the first entry, as it replaced the address before the list.
    try DanmakuService.save(server: "https://c.example", preferredSource: .automatic, automatic: true, defaults: defaults)
    #expect(DanmakuService.servers(defaults: defaults) == ["https://c.example", "https://b.example"])
    try DanmakuService.remove("https://c.example", defaults: defaults)
    try DanmakuService.remove("https://b.example", defaults: defaults)
    #expect(DanmakuService.servers(defaults: defaults) == [CatalogDanmakuClient.defaultServer])
    #expect(throws: (any Error).self) { try DanmakuService.save(servers: ["https://a.example/?q=1"], defaults: defaults) }
}

@Test func danmakuServerTitlesNeverShowATokenInTheirPath() {
    #expect(DanmakuService.title(for: "https://a.example/secret-token/api/v2") == "a.example/…")
    #expect(DanmakuService.title(for: "http://192.168.1.2:9321") == "192.168.1.2:9321")
    #expect(DanmakuService.title(for: CatalogDanmakuClient.defaultServer) == L10n.text("Built-in Danmaku Services"))
}

@Test func aDanmakuServerIsAskedBeforeItIsAdded() async throws {
    let transport = ServersTransport()
    await transport.configure(refused: ["b.example"])
    let http = DanmakuHTTP { try await transport.send($0) }
    #expect(try await DanmakuService.check(" https://a.example/tok/api/v2/ ", transport: http) == "https://a.example/tok")
    await #expect(throws: DanmakuAuthorizationRequired.self) { try await DanmakuService.check("https://b.example", transport: http) }
    await #expect(throws: (any Error).self) {
        try await DanmakuService.check("https://c.example", transport: DanmakuHTTP { _ in Data(#"{"hello":"world"}"#.utf8) })
    }
    // The official server isn't asked: its requests are few and shared by every install.
    #expect(try await DanmakuService.check(CatalogDanmakuClient.defaultServer, transport: http) == CatalogDanmakuClient.defaultServer)
    #expect(await transport.log() == ["a.example/tok/api/v2/search/anime", "b.example/api/v2/search/anime"])
}

@Test func aServerThatReadsPagesGetsTheSourcesOfficialPageBeforeATitleSearch() async throws {
    let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let transport = ServersTransport()
    await transport.configure(listed: ["a.example"], pages: ["a.example"])
    let resolver = DanmakuResolver(cache: MediaCache(root: root), http: .init { try await transport.send($0) }, dandanServer: "https://a.example/tok")
    let result = try await resolver.resolve(serversContext(page: "https://v.qq.com/x/cover/abc123/def456.html?ptag=share"))
    #expect(result.state == "loaded")
    #expect(result.comments.first?.text == "页面弹幕")
    #expect(result.source == DanmakuProvider.tencent.title)
    #expect(await transport.log() == ["a.example/tok/api/v2/comment"])
    #expect(await transport.pageQuery(0) == "https://v.qq.com/x/cover/abc123/def456.html")
    // A page that isn't an official episode page is never sent.
    let other = try await resolver.resolve(serversContext("第6集", page: "https://example.com/private-page"))
    #expect(other.comments.first?.text == "a.example")
    #expect(await transport.log().filter { $0.hasSuffix("/comment") }.count == 1)
}

@Test func aServerWithoutPageCommentsFallsBackToTheTitleSearch() async throws {
    let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let transport = ServersTransport()
    await transport.configure(listed: ["a.example"])
    let resolver = DanmakuResolver(cache: MediaCache(root: root), http: .init { try await transport.send($0) }, dandanServer: "https://a.example")
    let result = try await resolver.resolve(serversContext(page: "https://v.qq.com/x/cover/abc123/def456.html"))
    #expect(result.state == "loaded")
    #expect(result.comments.first?.text == "a.example")
    #expect(await transport.log() == ["a.example/api/v2/comment", "a.example/api/v2/search/anime", "a.example/api/v2/bangumi/7", "a.example/api/v2/comment/75"])
}

@Test func danmakuServersAreAskedInOrderAndAHandPickGoesFirst() async throws {
    let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let transport = ServersTransport()
    await transport.configure(listed: ["b.example"])
    let cache = MediaCache(root: root), http = DanmakuHTTP { try await transport.send($0) }
    let a = DanmakuResolver(cache: cache, http: http, dandanServer: "https://a.example")
    let b = DanmakuResolver(cache: cache, http: http, dandanServer: "https://b.example")
    let chain = DanmakuChain([a, b])
    let found = try await chain.resolve(serversContext())
    #expect(found.comments.first?.text == "b.example")
    #expect(await transport.log() == ["a.example/api/v2/search/anime", "b.example/api/v2/search/anime", "b.example/api/v2/bangumi/7", "b.example/api/v2/comment/75"])
    #expect(try await chain.resolve(serversContext("第9集")).state == "unmatched")

    // Picked by hand on the second server: its next episodes ask it first, and the first isn't asked.
    let picked = serversContext("第6集")
    b.remember(DanmakuMapping(provider: "tencent", title: "测试剧(2023)【国产剧】from tencent", year: "2023",
        tracks: [DanmakuTrack(number: 6, title: "【qq】 测试剧 第6集", id: "76", source: "tencent")], animeID: "7", source: "tencent"),
        for: picked, ticket: cache.ticket(), picked: true)
    #expect(chain.hasPick(for: picked))
    let before = await transport.log().count
    #expect(try await chain.resolve(picked).comments.first?.text == "b.example")
    #expect(Array(await transport.log().dropFirst(before)) == ["b.example/api/v2/comment/76"])

    // One server down and none with comments: unavailable, not "no match".
    await transport.configure(listed: ["b.example"], down: ["a.example"])
    #expect(try await chain.resolve(serversContext("第7集")).state == "unavailable")
    chain.forgetPick(picked)
    #expect(!chain.hasPick(for: picked))
}

@Test func aPastedEpisodeLinkGoesToTheChosenServer() async throws {
    let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let transport = ServersTransport()
    await transport.configure(pages: ["a.example"])
    let http = DanmakuHTTP { try await transport.send($0) }
    let custom = DanmakuResolver(cache: MediaCache(root: root), http: http, dandanServer: "https://a.example/tok")
    let result = try await custom.comments(page: " https://www.mgtv.com/b/123/456.html?cxid=x#top ")
    #expect(result.state == "loaded")
    #expect(result.source == DanmakuProvider.imgo.title)
    #expect(await transport.pageQuery(0) == "https://www.mgtv.com/b/123/456.html")
    // A server added by hand may read other sites' pages; a sign-in and fragment are dropped.
    _ = try await custom.comments(page: "https://user:pw@www.example.org/play/1?id=2#t")
    #expect(await transport.pageQuery(1) == "https://www.example.org/play/1?id=2")
    // The built-in services take official episode pages only, and refuse another before sending anything.
    let builtIn = DanmakuResolver(cache: MediaCache(root: root.appending(path: "built-in")), http: http)
    await #expect(throws: (any Error).self) { try await builtIn.comments(page: "https://example.org/watch/1") }
    await #expect(throws: (any Error).self) { try await custom.comments(page: "not a link") }
    #expect(await transport.requests.count == 2)
}

/// Against a real danmu_api (github.com/huangxd-/danmu_api) when `DANMU_API_E2E` names one, such as
/// `http://127.0.0.1:9321/<TOKEN>`. Its comments come from the platforms, so this needs the network.
@Test(.enabled(if: ProcessInfo.processInfo.environment["DANMU_API_E2E"] != nil))
func aRealDanmuAPIServerFindsCommentsByTitleAndByPage() async throws {
    let address = try #require(ProcessInfo.processInfo.environment["DANMU_API_E2E"])
    let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let server = try await DanmakuService.check(address)
    let resolver = DanmakuResolver(cache: MediaCache(root: root), dandanServer: server)
    var context = PlaybackHistoryContext(origin: URL(string: "https://example.com/subscription")!, sourceKey: "source", sourceName: "Source",
        videoID: "qyn2", videoName: "庆余年第二季", episodeID: "https://example.com/5.m3u8", episodeName: "第5集", episodeFlag: "line")
    context.year = "2024"
    let found = try await resolver.resolve(context)
    #expect(found.state == "loaded")
    #expect(found.comments.count > 1000)
    #expect(found.track.contains("第二季") && found.track.contains("第5集"))
    let page = try await resolver.comments(page: "https://v.qq.com/x/cover/mzc002002kqssyu/k4100m6fkxe.html")
    #expect(page.comments.count > 1000)
    #expect(page.source == DanmakuProvider.tencent.title)
}

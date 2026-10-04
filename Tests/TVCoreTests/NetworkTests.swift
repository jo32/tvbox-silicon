import Foundation
import Testing
@testable import TVCore

private final class MockProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let status: Int
        let body: String
        if path == "/failure" { status = 503; body = "Unavailable" }
        else if path == "/subscription" {
            status = 200
            body = request.value(forHTTPHeaderField: "User-Agent") == HTTPClient.subscriptionUserAgent
                ? #"{"sites":[{"key":"中文","type":4,"api":"./api"}]}"#
                : "<!doctype html><html>Landing page</html>"
        } else if path == "/headers" {
            status = request.value(forHTTPHeaderField: "User-Agent") == "Custom" ? 200 : 403
            body = "#EXTM3U\n#EXTINF:-1,Channel\nhttps://example.com/live.m3u8"
        } else if path == "/missing-id" {
            status = 200; body = #"{"list":[{"vod_play_from":"自动","vod_play_url":"1$opaque-episode"}]}"#
        } else if path == "/x/player/playurl" {
            status = 200
            body = #"{"code":0,"data":{"format":"mp4","durl":[{"url":"https://cdn.example.com/video.mp4"}]}}"#
        } else if path == "/login" {
            status = 200; body = #"{"parse":0,"url":"","errMsg":"未扫码登录无法观看"}"#
        } else if path == "/qualities" {
            status = 200; body = #"{"parse":0,"url":["480P","https://example.com/480.mp4","360P","https://example.com/360.mp4"]}"#
        } else if path == "/bili" {
            status = 200; body = #"{"parse":0,"url":["480P","http://127.0.0.1:-1/proxy?do=bili&aid=123&cid=456&qn=32&type=mpd"]}"#
        } else if query.contains(where: { $0.name == "play" }) {
            status = 200
            body = path == "/parse" ? #"{"parse":1,"url":"https://example.com/watch/1"}"# : #"{"parse":0,"url":"https://example.com/video.m3u8","header":"{\"Referer\":\"https://example.com/\"}"}"#
        } else { status = 200; body = #"{"class":[{"type_id":1,"type_name":"Movie"}],"list":[{"vod_id":12,"vod_name":"Test"}],"pagecount":"3"}"# }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private func client() -> HTTPClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockProtocol.self]
    return HTTPClient(session: URLSession(configuration: config))
}
@Test func httpErrorsSurfaceStatus() async {
    await #expect(throws: (any Error).self) { try await client().get(URL(string: "https://example.com/failure")!) }
}
@Test func subscriptionUserAgentIsSentToPlaylist() async throws {
    let source = LiveSource(name: "Live", url: URL(string: "https://example.com/headers")!, headers: ["User-Agent": "Custom"])
    let channels = try await client().channels(source)
    #expect(channels.count == 1)
    #expect(channels[0].headers["User-Agent"] == "Custom")
}
@Test func standardCatalogAndPlaybackContract() async throws {
    let base = URL(string: "https://example.com/config.json")!
    let sub = try Subscription.parse(Data(#"{"sites":[{"key":"a","type":4,"api":"/api","header":{"User-Agent":"SiteAgent"}},{"key":"b","type":4,"api":"/parse"}]}"#.utf8), origin: base)
    let api = CatalogClient(site: sub.sites[0], origin: base, http: client())
    let home = try await api.home()
    #expect(home.categories.first?.id == "1")
    #expect(home.videos.first?.id == "12")
    #expect(home.pageCount == 3)
    let episode = Episode(id: "1", name: "Episode", address: "opaque-value", flag: "A")
    let play = try await api.playback(episode)
    #expect(play.url.absoluteString == "https://example.com/video.m3u8")
    #expect(play.headers["Referer"] == "https://example.com/")
    #expect(play.headers["User-Agent"] == "SiteAgent")
    let parseAPI = CatalogClient(site: sub.sites[1], origin: base, http: client())
    await #expect(throws: (any Error).self) { try await parseAPI.playback(episode) }
}

@Test func pluginStyleDetailMayOmitRequestedID() async throws {
    let base = URL(string: "https://example.com/config.json")!
    let sub = try Subscription.parse(Data(#"{"sites":[{"key":"a","type":4,"api":"/missing-id"}]}"#.utf8), origin: base)
    let api = CatalogClient(site: sub.sites[0], origin: base, http: client())
    let detail = try await api.detail("requested-id")
    #expect(detail.id == "requested-id")
    #expect(detail.episodes.first?.address == "opaque-episode")
    #expect(detail.episodes.first?.videoID == "requested-id")
}

@Test func playbackSurfacesProviderLoginReason() async throws {
    let base = URL(string: "https://example.com/config.json")!
    let sub = try Subscription.parse(Data(#"{"sites":[{"key":"a","type":4,"api":"/login"}]}"#.utf8), origin: base)
    let api = CatalogClient(site: sub.sites[0], origin: base, http: client())
    do {
        _ = try await api.playback(Episode(id: "a", name: "Episode", address: "id", flag: ""))
        Issue.record("Expected the provider's login error")
    } catch { #expect(error.localizedDescription == "未扫码登录无法观看") }
}

@Test func qualitySelectionResolvesTheChosenEntry() async throws {
    let base = URL(string: "https://example.com/config.json")!
    let sub = try Subscription.parse(Data(#"{"sites":[{"key":"a","type":4,"api":"/qualities"}]}"#.utf8), origin: base)
    let api = CatalogClient(site: sub.sites[0], origin: base, http: client())
    let plan = try await api.preparePlayback(Episode(id: "a", name: "Episode", address: "id", flag: ""))
    #expect(plan.choices.map(\.name) == ["480P", "360P"])
    let channel = try await api.resolvePlayback(plan, choice: plan.choices[1])
    #expect(channel.url.absoluteString == "https://example.com/360.mp4")
}

@Test func biliDashProxyBecomesProgressiveMP4() async throws {
    let base = URL(string: "https://example.com/config.json")!
    let sub = try Subscription.parse(Data(#"{"sites":[{"key":"a","type":4,"api":"/bili"}]}"#.utf8), origin: base)
    let api = CatalogClient(site: sub.sites[0], origin: base, http: client())
    let channel = try await api.playback(Episode(id: "a", name: "Episode", address: "id", flag: ""))
    #expect(channel.url.absoluteString == "https://cdn.example.com/video.mp4")
    #expect(channel.headers["Referer"] == "https://www.bilibili.com/")
}

@Test func resolvedMediaWithStaleParseFlagCanPlay() async throws {
    let base = URL(string: "https://example.com/config.json")!
    let sub = try Subscription.parse(Data(#"{"sites":[{"key":"a","type":4,"api":"/api"}]}"#.utf8), origin: base)
    let api = CatalogClient(site: sub.sites[0], origin: base, http: client())
    let choice = PlaybackChoice(id: 0, name: "Video", address: "https://cdn.example.com/video.mp4?token=1")
    let plan = PlaybackPlan(choices: [choice], headers: [:], group: "", requiresWebDetection: true)
    let channel = try await api.resolvePlayback(plan, choice: choice)
    #expect(channel.url.absoluteString == choice.address)
    #expect(!CatalogClient.isDirectMedia("https://example.com/watch?url=video.mp4"))
}

@Test func screenplayActionMetadataDoesNotHideVideoDetails() throws {
    let origin = URL(string: "https://example.com/")!
    let data = Data(#"{"vod_id":"play/ch4lua32z","vod_name":"我不是大师","action":"编剧姓名","vod_play_from":"默认","vod_play_url":"第1集$https://example.com/1.mp4"}"#.utf8)
    let json = try JSONDecoder().decode([String: JSONValue].self, from: data)
    let video = try #require(Video(json: json, origin: origin))
    #expect(video.name == "我不是大师")
    #expect(video.episodes.count == 1)
}

private actor SearchCollector {
    var results: [SearchSourceResult] = []
    func append(_ result: SearchSourceResult) { results.append(result) }
}

@Test func globalSearchPreservesSourceIdentityAndIsolatesFailure() async throws {
    let base = URL(string: "https://example.com/config")!
    let sub = try Subscription.parse(Data(#"{"sites":[{"key":"first","type":1,"api":"/api"},{"key":"second","type":4,"api":"/api"},{"key":"broken","type":4,"api":"/failure"},{"key":"disabled","type":1,"api":"/api","searchable":0},{"key":"excluded","type":1,"api":"/api","searchable":2},{"key":"unsupported","type":0,"api":"/api"}]}"#.utf8), origin: base)
    let collector = SearchCollector()
    await GlobalSearch.search(sites: sub.sites, origin: base, jarURL: nil, query: "  movie  ", http: client(), concurrency: 2) {
        await collector.append($0)
    }
    let results = await collector.results
    #expect(Set(results.map(\.id)) == ["first", "second", "broken"])
    #expect(results.filter { $0.page?.videos.first?.id == "12" }.count == 2)
    #expect(results.first { $0.id == "broken" }?.error != nil)
    #expect(results.first { $0.id == "first" }?.page?.pageCount == 3)
}

@Test func blankAndCancelledSearchDoNotPublishResults() async throws {
    let base = URL(string: "https://example.com/config")!
    let sub = try Subscription.parse(Data(#"{"sites":[{"key":"a","type":4,"api":"/api"}]}"#.utf8), origin: base)
    let collector = SearchCollector()
    await GlobalSearch.search(sites: sub.sites, origin: base, jarURL: nil, query: " \n ", http: client()) { await collector.append($0) }
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        await GlobalSearch.search(sites: sub.sites, origin: base, jarURL: nil, query: "movie", http: client()) { await collector.append($0) }
    }
    await task.value
    #expect(await collector.results.isEmpty)
}

@Test @MainActor func searchSessionRetainsResultsAndReusesRecentSearch() async throws {
    let base = URL(string: "https://example.com/config")!
    let sub = try Subscription.parse(Data(#"{"sites":[{"key":"a","type":4,"api":"/api"}]}"#.utf8), origin: base)
    let model = SearchModel(http: client())
    model.search("first", config: sub)
    await model.task?.value
    #expect(model.videoCount == 1)
    #expect(!model.busy)
    model.search("second", config: sub)
    await model.task?.value
    model.search("first", config: sub)
    #expect(!model.busy) // Cached results are available synchronously.
    #expect(model.keyword == "first")
    #expect(model.videoCount == 1)
    #expect(model.completed == model.total)
    model.reset()
    #expect(model.results.isEmpty)
    #expect(model.keyword.isEmpty)
}

@Test @MainActor func replacingSearchDiscardsOldCompletion() async throws {
    let base = URL(string: "https://example.com/config")!
    let sub = try Subscription.parse(Data(#"{"sites":[{"key":"a","type":4,"api":"/api"},{"key":"b","type":4,"api":"/api"}]}"#.utf8), origin: base)
    let model = SearchModel(http: client())
    model.search("old", config: sub)
    let old = model.task
    model.search("new", config: sub)
    await old?.value
    await model.task?.value
    #expect(model.keyword == "new")
    #expect(model.results.count == 2)
    #expect(model.completed == 2)
    #expect(!model.busy)
}

@Test @MainActor func stoppedSearchResumesAndSubscriptionChangeInvalidatesCache() async throws {
    let base = URL(string: "https://example.com/config")!
    let json = Data(#"{"sites":[{"key":"a","type":4,"api":"/api"}]}"#.utf8)
    let sub = try Subscription.parse(json, origin: base)
    let model = SearchModel(http: client())
    model.search("first", config: sub)
    let stopped = model.task
    model.stop()
    await stopped?.value
    #expect(model.stopped)
    #expect(model.results.isEmpty)
    model.resume(config: sub)
    await model.task?.value
    #expect(model.videoCount == 1)
    let changed = try Subscription.parse(json, origin: URL(string: "https://other.example/config")!)
    model.search("first", config: changed)
    #expect(model.busy)
    await model.task?.value
    #expect(model.videoCount == 1)
}

@Test @MainActor func recommendationCacheSurvivesNavigationAndFailedRefresh() async throws {
    let base = URL(string: "https://example.com/config")!
    let sub = try Subscription.parse(Data(#"{"sites":[{"key":"a","type":4,"api":"/api","indexs":1}]}"#.utf8), origin: base)
    let http = client()
    let api = CatalogClient(site: sub.sites[0], origin: base, http: http)
    let model = RecommendationModel()
    await model.load(client: api, subscriptionDate: sub.importedAt)
    #expect(model.items.count == 1)
    #expect(model.items[0].destination == .search("Test"))
    let offlineConfig = URLSessionConfiguration.ephemeral
    offlineConfig.protocolClasses = [OfflineProtocol.self]
    let offline = CatalogClient(site: sub.sites[0], origin: base, http: HTTPClient(session: URLSession(configuration: offlineConfig)))
    await model.load(client: offline, subscriptionDate: sub.importedAt)
    #expect(model.items.count == 1)
    #expect(model.error == nil)
    #expect(!model.busy)
    await model.load(client: offline, subscriptionDate: sub.importedAt, force: true)
    #expect(model.error != nil)
    #expect(model.items.count == 1)
    #expect(!model.busy)
    model.reset()
    #expect(model.items.isEmpty)
}

private final class OfflineProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

@Test func subscriptionUsesTVBoxIdentityWithChineseDomain() async throws {
    let url = try WebAddress.resolve("http://肥猫.net/subscription")
    let config = try await client().subscription(url)
    #expect(config.sites.first?.key == "中文")
    #expect(config.origin.host == "xn--z7x900a.net")
    let (browserData, _) = try await client().get(url)
    #expect(String(decoding: browserData, as: UTF8.self).contains("Landing page"))
}

import Foundation
import Testing
@testable import TVCore

private func customContext(_ episode: String = "第1集", year: String? = "2023") -> PlaybackHistoryContext {
    var context = PlaybackHistoryContext(origin: URL(string: "https://example.com/subscription?token=private")!,
        sourceKey: "source", sourceName: "Source", videoID: "series", videoName: "测试剧",
        episodeID: "https://example.com/video.m3u8?secret=playback", episodeName: episode, episodeFlag: "line")
    context.year = year
    context.officialPage = URL(string: "https://example.com/private-page")
    context.posterHeaders = ["Authorization": "private-header"]
    return context
}

private actor CustomDanmakuTransport {
    var requests: [URLRequest] = []
    var stale = false
    var fail = false
    var replacementMissing = false
    var commentRequests = 0
    let source: String
    init(source: String = "tencent") { self.source = source }
    func set(stale: Bool = false, fail: Bool = false, replacementMissing: Bool = false) {
        self.stale = stale; self.fail = fail; self.replacementMissing = replacementMissing
    }
    func send(_ request: URLRequest) throws -> Data {
        requests.append(request)
        let url = request.url!, path = url.path
        #expect(url.host == "example.com")
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Referer") == nil)
        #expect(request.value(forHTTPHeaderField: "X-AppId") == nil)
        #expect(!url.absoluteString.contains("private-header"))
        #expect(!url.absoluteString.contains("subscription"))
        #expect(!url.absoluteString.contains("m3u8"))
        if fail { throw TVError.http(503) }
        if path.hasSuffix("search/anime") {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(query == [URLQueryItem(name: "keyword", value: "测试剧")])
            #expect(request.timeoutInterval >= 45)
            return Data(#"{"animes":[{"animeId":101,"bangumiId":"native_qq-A1","animeTitle":"测试剧(2023)【电视剧】from tencent","source":"tencent","type":"tvseries","typeDescription":"电视剧","startDate":"2023-01-01T00:00:00Z"},{"animeId":102,"bangumiId":"iq-A2","animeTitle":"测试剧(2023)【电视剧】from iqiyi","source":"iqiyi","startDate":"2023-01-01T00:00:00Z"},{"animeId":103,"animeTitle":"测试剧(2022)【电视剧】from tencent","source":"tencent","startDate":"2022-01-01T00:00:00Z"},{"animeId":104,"animeTitle":"测试剧 第二季(2023)【电视剧】from tencent","source":"tencent","startDate":"2023-01-01T00:00:00Z"}]}"#.utf8)
        }
        if path.hasSuffix("bangumi/101") || path.hasSuffix("bangumi/102") {
            let prefix = path.hasSuffix("101") ? "qq" : "iqiyi"
            let first = stale ? "new-1" : "old-1", second = stale ? "new-2" : "old-2"
            return try JSONSerialization.data(withJSONObject: ["bangumi": ["episodes": [
                ["episodeId": first, "episodeTitle": "【\(prefix)】 测试剧 第1集 正式播出", "episodeNumber": "1", "url": "https://example.com/platform/1"],
                ["episodeId": second, "episodeTitle": "【\(prefix)】 测试剧 第2集 正式播出", "episodeNumber": "2"],
                ["episodeId": "bonus", "episodeTitle": "【\(prefix)】 测试剧 彩蛋9", "episodeNumber": "39"],
                ["episodeId": "trailer", "episodeTitle": "【\(prefix)】 测试剧 首轮阵容官宣！概念海报发布", "episodeNumber": "3"]
            ]]])
        }
        if path.contains("/comment/") {
            commentRequests += 1
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            #expect(query.contains(.init(name: "format", value: "json")))
            if stale && path.contains("old-") || replacementMissing { throw TVError.http(404) }
            return Data(#"{"count":1,"comments":[{"p":"1.00,1,16718180,[qq]","m":"自定义弹幕","t":1}]}"#.utf8)
        }
        throw TVError.http(404)
    }
    func paths() -> [String] { requests.compactMap { $0.url?.path } }
    func count(_ suffix: String) -> Int { requests.filter { $0.url!.path.hasSuffix(suffix) }.count }
    func total() -> Int { requests.count }
}

@Test func customDanmakuClientRetainsNativeIdentifiersMetadataPrefixAndJSONFormat() async throws {
    let transport = CustomDanmakuTransport()
    let client = try CatalogDanmakuClient(address: "https://EXAMPLE.com:443/token%2Fpart%2Bsecret/api/v2/", transport: .init { try await transport.send($0) })
    #expect(client.server.absoluteString == "https://example.com/token%2Fpart%2Bsecret")
    let anime = try #require(try await client.search("测试剧", source: .tencent).first)
    #expect(anime.id == "101")
    #expect(anime.bangumiID == "native_qq-A1")
    #expect(anime.title == "测试剧(2023)【电视剧】from tencent")
    #expect(anime.source == "tencent")
    #expect(anime.year == "2023")
    #expect(anime.type == "电视剧")
    #expect(anime.typeCode == "tvseries")
    let episode = try #require(try await client.episodes(anime).first)
    #expect(episode.episodeNumber == 1)
    #expect(episode.provider == .tencent)
    #expect(episode.url?.host() == "example.com")
    let comments = try await client.comments(episode)
    #expect(comments.first?.time == 1)
    #expect(comments.first?.color == 16718180)
    let paths = await transport.paths()
    #expect(paths.allSatisfy { $0.hasPrefix("/token/part+secret/api/v2/") })
}

@Test func customDanmakuNativeIDFallbackIsPathSafeAndNeverRequestsReturnedPageURLs() async throws {
    let client = try CatalogDanmakuClient(address: "https://example.com/prefix", transport: .init { request in
        let path = request.url!.path
        if path.hasSuffix("search/anime") {
            return Data(#"{"animes":[{"bangumiId":"native-qq_abc","animeTitle":"测试剧（腾讯）"},{"animeId":"../escape","bangumiId":"bad/id","animeTitle":"无效"}]}"#.utf8)
        }
        #expect(path == "/prefix/api/v2/bangumi/native-qq_abc")
        return Data(#"{"bangumi":{"episodes":[{"episodeId":"ep_1","episodeTitle":"第1集","episodeNumber":"1","url":"177780001"}]}}"#.utf8)
    })
    let results = try await client.search("测试剧")
    #expect(results.count == 1)
    #expect(results.first?.provider == .tencent)
    let episodes = try await client.episodes(try #require(results.first))
    #expect(episodes.first?.episodeNumber == 1)
    await #expect(throws: (any Error).self) { try await client.comments(.init(id: "../escape", title: "1")) }
}

@Test func customDanmakuMetadataMatchesExactWorkYearAndSeasonWithoutLosingPlatforms() {
    let rows = [
        CatalogDanmakuAnime(id: "1", title: "测试剧(2023)【电视剧】from tencent"),
        CatalogDanmakuAnime(id: "2", title: "测试剧(2023)【国产剧】from iqiyi"),
        CatalogDanmakuAnime(id: "3", title: "测试剧(2022)【电视剧】from tencent"),
        CatalogDanmakuAnime(id: "4", title: "测试剧 第四季(2023)【动漫】from tencent")
    ]
    #expect(CatalogDanmakuMatcher.anime(title: "测试剧", year: "2023", source: .tencent, in: rows)?.id == "1")
    #expect(CatalogDanmakuMatcher.anime(title: "测试剧", year: "2023", source: .iqiyi, in: rows)?.id == "2")
    #expect(CatalogDanmakuMatcher.anime(title: "测试剧", source: .tencent, in: rows) == nil)
    #expect(CatalogDanmakuMatcher.anime(title: "测试剧 第二季", year: "2023", in: rows) == nil)
    #expect(CatalogDanmakuMatcher.anime(title: "测试剧", year: "2024", in: rows) == nil)
    #expect(CatalogDanmakuMatcher.anime(title: "测试剧(2022)", year: "2023", in: rows) == nil)
    let duplicate = rows + [CatalogDanmakuAnime(id: "5", title: rows[0].title)]
    #expect(CatalogDanmakuMatcher.anime(title: "测试剧", year: "2023", source: .tencent, in: duplicate) == nil)
}

@Test func customDanmakuEpisodeMatchingPrefersExplicitTitlesAndRejectsExtrasAndContradictions() {
    let episodes = [
        CatalogDanmakuEpisode(id: "1", title: "【qq】 测试剧 第1集 开始", episodeNumber: 99),
        CatalogDanmakuEpisode(id: "metadata", title: "【qq】 测试剧", episodeNumber: 1),
        CatalogDanmakuEpisode(id: "contradiction", title: "第2集", episodeNumber: 3),
        CatalogDanmakuEpisode(id: "bonus", title: "【qq】 测试剧 彩蛋9", episodeNumber: 39),
        CatalogDanmakuEpisode(id: "preview", title: "【qq】 测试剧 首轮阵容官宣！概念海报发布", episodeNumber: 4),
        CatalogDanmakuEpisode(id: "arbitrary", title: "幕后故事", episodeNumber: 5),
        CatalogDanmakuEpisode(id: "unnamed", title: "【bilibili1】", episodeNumber: 6)
    ]
    #expect(CatalogDanmakuMatcher.episode(name: "第1集", seriesTitle: "测试剧", in: episodes)?.id == "1")
    #expect(CatalogDanmakuMatcher.episode(name: "第2集", seriesTitle: "测试剧", in: episodes)?.id == "contradiction")
    for number in [3, 4, 5, 39, 99] {
        #expect(CatalogDanmakuMatcher.episode(name: "第\(number)集", seriesTitle: "测试剧", in: episodes) == nil)
    }
    #expect(CatalogDanmakuMatcher.episode(name: "第6集", seriesTitle: "测试剧", in: episodes)?.id == "unnamed")
    #expect(CatalogDanmakuMatcher.episode(name: "第1集 预告", seriesTitle: "测试剧", in: episodes) == nil)
    #expect(CatalogDanmakuMatcher.episode(name: "正片", in: [.init(id: "x", title: "第1集 预告")]) == nil)
    for title in ["【bilibili1】 第1话 意义之塔", "【migu】 《测试剧》第01集：开始", "【youku】 第1集 测试剧", "【dandan】 第1话"] {
        #expect(CatalogDanmakuMatcher.episode(name: "1", seriesTitle: "测试剧", in: [.init(id: "x", title: title)])?.id == "x")
    }
    for number in [1, 2] {
        #expect(CatalogDanmakuMatcher.episode(name: "第\(number)集", seriesTitle: "测试剧", in: [
            .init(id: "range", title: "第1集至第2集", episodeNumber: number), .init(id: "s02e01", title: "S02E01", episodeNumber: number)
        ]) == nil)
    }
}

@Test func customDanmakuDoesNotConfuseWorkNameDigitsOrEnglishSubstringsWithExtras() {
    for title in ["Road House", "Extraordinary Attorney Woo", "Special Ops", "彩蛋人生"] {
        #expect(CatalogDanmakuMatcher.anime(title: title, in: [.init(id: "1", title: title)])?.id == "1")
    }
    for title in ["三体", "1988", "Road House", "Extraordinary Attorney Woo"] {
        #expect(CatalogDanmakuMatcher.episode(name: "第2集", seriesTitle: title,
            in: [.init(id: "2", title: "【qq】 " + title, episodeNumber: 2)])?.id == "2")
    }
    for title in ["OAD1", "OVA 2", "第2集 Special", "第2集 Trailer", "Preview 2"] {
        #expect(CatalogDanmakuMatcher.episode(name: "第2集", seriesTitle: "测试剧",
            in: [.init(id: "2", title: title, episodeNumber: 2)]) == nil)
    }
}

@Test func customDanmakuResolutionIsExclusiveAndUsesSelectedPlatformAndYear() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    for provider in [DanmakuProvider.tencent, .iqiyi] {
        let transport = CustomDanmakuTransport()
        let resolver = DanmakuResolver(cache: MediaCache(root: root.appending(path: provider.rawValue)), http: .init { try await transport.send($0) },
            dandanServer: "https://example.com/token", preferredSource: provider)
        let result = try await resolver.resolve(customContext(), first: { _ in
            Issue.record("The source callback must not run with a custom service")
            return nil
        })
        #expect(result.state == "loaded")
        #expect(result.source == provider.title)
        #expect(result.comments.count == 1)
        #expect(await transport.count("bangumi/\(provider == .tencent ? 101 : 102)") == 1)
        #expect(await transport.total() == 3)
        let next = try await resolver.resolve(customContext("第2集"))
        #expect(next.state == "loaded")
        #expect(await transport.count("search/anime") == 1)
        #expect(await transport.total() == 4)
        #expect(try await resolver.resolve(customContext("第39集")).state == "unmatched")
    }
}

@Test func customDanmakuAutomaticPlatformSelectionIsDeterministicAndAggregatorCanProvidePreferredSource() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = CustomDanmakuTransport()
    let resolver = DanmakuResolver(cache: MediaCache(root: root), http: .init { try await transport.send($0) }, dandanServer: "https://example.com")
    #expect(try await resolver.resolve(customContext()).source == DanmakuProvider.iqiyi.title)
    let aggregatorHTTP = DanmakuHTTP { request in
        #expect(request.url?.host() == "example.com")
        if request.url!.path.hasSuffix("search/anime") {
            return Data(#"{"animes":[{"animeId":1,"animeTitle":"测试剧(2023)【电视剧】from 360","source":"360"}]}"#.utf8)
        }
        if request.url!.path.contains("bangumi") {
            return Data(#"{"bangumi":{"episodes":[{"episodeId":11,"episodeTitle":"【qq】 测试剧 第1集","episodeNumber":"1"},{"episodeId":12,"episodeTitle":"【bilibili1】 第1集","episodeNumber":"1"}]}}"#.utf8)
        }
        #expect(request.url!.path.hasSuffix("comment/11"))
        return Data(#"{"comments":[{"p":"1,1,16777215,user","m":"聚合平台"}]}"#.utf8)
    }
    let aggregate = DanmakuResolver(cache: MediaCache(root: root.appending(path: "aggregate")), http: aggregatorHTTP,
        dandanServer: "https://example.com/aggregate", preferredSource: .tencent)
    #expect(try await aggregate.resolve(customContext()).source == DanmakuProvider.tencent.title)
}

@Test func customDanmakuCacheAndManualMappingsAreIsolatedByCanonicalServerAndPreference() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = MediaCache(root: root), context = customContext()
    let transport = CustomDanmakuTransport()
    let http = DanmakuHTTP { try await transport.send($0) }
    let first = DanmakuResolver(cache: cache, http: http, dandanServer: "https://example.com/a", preferredSource: .tencent)
    let equivalent = DanmakuResolver(cache: cache, http: http, dandanServer: "https://EXAMPLE.com:443/a/api/v2/", preferredSource: .tencent)
    let otherServer = DanmakuResolver(cache: cache, http: http, dandanServer: "https://example.com/b", preferredSource: .tencent)
    let otherProvider = DanmakuResolver(cache: cache, http: http, dandanServer: "https://example.com/a", preferredSource: .iqiyi)
    #expect(first.cacheKey(context) == equivalent.cacheKey(context))
    #expect(first.cacheKey(context) != otherServer.cacheKey(context))
    #expect(first.cacheKey(context) != otherProvider.cacheKey(context))
    let result = try await first.resolve(context)
    #expect(try await equivalent.resolve(context).cached)
    #expect(!(try await otherServer.resolve(context)).cached)
    #expect(!(try await otherProvider.resolve(context)).cached)
    #expect(await transport.count("search/anime") == 3)
    first.forget(context)
    #expect(cache.data(for: first.cacheKey(context), kind: .danmaku, scope: context.id) == nil)
    #expect(try await otherProvider.resolve(context).cached)
    first.cache(result, for: context)
    #expect(try await first.resolve(context).cached)
    first.forget(context)
    #expect(cache.data(for: first.cacheKey(context), kind: .danmaku, scope: context.id) == nil)
    // Bare legacy cache entries cannot leak after configuring a service.
    cache.store(try JSONEncoder().encode(result), for: DanmakuResolver.episodeKey(context), kind: .danmaku, scope: context.id,
        ttl: 3600, ticket: cache.ticket())
    #expect(!(try await first.resolve(context)).cached)
    cache.remove(scope: context.id)
    #expect(cache.summary().danmaku == 0)
}

@Test func customDanmakuStaleSavedEpisodeRefreshesOnceAndTransientFailuresKeepMapping() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = MediaCache(root: root), transport = CustomDanmakuTransport()
    let resolver = DanmakuResolver(cache: cache, http: .init { try await transport.send($0) },
        dandanServer: "https://example.com/stale", preferredSource: .tencent)
    #expect(try await resolver.resolve(customContext()).state == "loaded")
    await transport.set(stale: true)
    #expect(try await resolver.resolve(customContext("第2集")).state == "loaded")
    #expect(await transport.count("comment/old-2") == 1)
    #expect(await transport.count("comment/new-2") == 1)
    #expect(await transport.count("bangumi/101") == 2)
    #expect(await transport.count("search/anime") == 1)
    resolver.forget(customContext("第2集"))
    await transport.set(stale: true, fail: true)
    #expect(try await resolver.resolve(customContext("第2集")).state == "unavailable")
    #expect(await transport.count("bangumi/101") == 2)
    resolver.forget(customContext("第2集"))
    await transport.set(stale: true)
    #expect(try await resolver.resolve(customContext("第2集")).state == "loaded")
    #expect(await transport.count("bangumi/101") == 2)
    resolver.forget(customContext("第2集"))
    await transport.set(stale: true, replacementMissing: true)
    #expect(try await resolver.resolve(customContext("第2集")).state == "unavailable")
    #expect(await transport.count("bangumi/101") == 3)
    #expect(await transport.count("search/anime") == 1)
}

@Test func customDanmakuManualMappingRetainsTheChosenPlatformAndRefreshesItsCatalog() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = MediaCache(root: root), transport = CustomDanmakuTransport()
    let resolver = DanmakuResolver(cache: cache, http: .init { try await transport.send($0) }, dandanServer: "https://example.com/manual")
    resolver.remember(DanmakuMapping(provider: "iqiyi", title: "测试剧", year: "2023", tracks: [
        DanmakuTrack(number: 1, title: "第1集", id: "previous", source: "iqiyi")
    ], animeID: "102", source: "iqiyi"), for: customContext(), ticket: cache.ticket())
    resolver.remember(DanmakuMapping(provider: "tencent", title: "测试剧", year: "2023", tracks: [
        DanmakuTrack(number: 1, title: "第1集", id: "expired", source: "tencent"),
        DanmakuTrack(number: 1, title: "第1集", id: "other-platform", source: "bilibili")
    ], animeID: "101", source: "tencent"), for: customContext(), ticket: cache.ticket())
    let result = try await resolver.resolve(customContext())
    // The manually chosen platform must be retained over automatic iQIYI.
    #expect(result.source == DanmakuProvider.tencent.title)
    #expect(await transport.count("search/anime") == 0)
    #expect(await transport.count("comment/expired") == 1)
}

@Test func customManualSelectionReplacesPrefetchedPlatformWithoutDeletingCatalogOrRestoringOldTickets() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = MediaCache(root: root), transport = CustomDanmakuTransport()
    let resolver = DanmakuResolver(cache: cache, http: .init { try await transport.send($0) }, dandanServer: "https://example.com/manual-cache")
    let context = customContext(), next = customContext("第2集")
    #expect(try await resolver.resolve(next).source == DanmakuProvider.iqiyi.title)
    let old = cache.ticket()
    cache.store(Data("detail".utf8), for: "detail", kind: .catalog, scope: context.id, ttl: 3600, ticket: old)
    let fresh = resolver.invalidateEpisodes(for: context)
    resolver.remember(DanmakuMapping(provider: "tencent", title: context.videoName, year: context.year, tracks: [
        .init(number: 1, title: "第1集", id: "manual-1", source: "tencent"),
        .init(number: 2, title: "第2集", id: "manual-2", source: "tencent")
    ], animeID: "101", source: "tencent"), for: context, ticket: fresh)
    resolver.cache(AutomaticDanmakuResult(comments: [], track: "manual", source: DanmakuProvider.tencent.title, state: "loaded"), for: context, ticket: fresh)
    resolver.cache(AutomaticDanmakuResult(comments: [], track: "old prefetch", source: DanmakuProvider.iqiyi.title, state: "loaded"), for: next, ticket: old)
    #expect(cache.data(for: "detail", kind: .catalog, scope: context.id) == Data("detail".utf8))
    #expect(cache.data(for: resolver.cacheKey(next), kind: .danmaku, scope: next.id) == nil)
    #expect(try await resolver.resolve(next).source == DanmakuProvider.tencent.title)
    #expect(await transport.count("comment/manual-2") == 1)
}

@Test func customDanmakuRejectsServiceRefusalsAndKeepsHTTP404Identity() async throws {
    for payload in [#"{"success":false,"animes":[]}"#, #"{"success":false,"comments":[]}"#] {
        let client = try CatalogDanmakuClient(address: "https://example.com", transport: .init { _ in Data(payload.utf8) })
        await #expect(throws: (any Error).self) { try await client.search("测试剧") }
        await #expect(throws: (any Error).self) { try await client.comments(.init(id: "1", title: "1")) }
    }
    let client = try CatalogDanmakuClient(address: "https://example.com", transport: .init { _ in throw TVError.http(404) })
    do {
        _ = try await client.comments(.init(id: "1", title: "1"))
        Issue.record("Expected HTTP 404")
    } catch TVError.http(404) {} catch { Issue.record("HTTP 404 was lost: \(error)") }
}

@Test func customDanmakuSettingsValidateBeforeSavingAndCanonicalizeIdentity() throws {
    let name = "CustomDanmakuTests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    #expect(DanmakuService.server(defaults: defaults) == CatalogDanmakuClient.defaultServer)
    #expect(DanmakuService.preferredSource(defaults: defaults) == .automatic)
    try DanmakuService.save(server: "https://EXAMPLE.com:443/token/api/v2/", preferredSource: .tencent, automatic: true, defaults: defaults)
    #expect(DanmakuService.server(defaults: defaults) == "https://example.com/token")
    #expect(DanmakuService.preferredSource(defaults: defaults) == .tencent)
    #expect(defaults.bool(forKey: DanmakuService.automaticKey))
    #expect(DanmakuService.isCustomServer(DanmakuService.server(defaults: defaults)))
    #expect(!DanmakuService.isCustomServer(CatalogDanmakuClient.defaultServer + ":443"))
    #expect(!DanmakuService.isCustomServer(CatalogDanmakuClient.defaultServer + "/api/v2/"))
    #expect(!DanmakuService.isCustomServer(CatalogDanmakuClient.legacyDefaultServer))
    #expect(DanmakuService.isCustomServer("bad address"))
    #expect(throws: (any Error).self) {
        try DanmakuService.save(server: "https://example.com?token=invalid", preferredSource: .iqiyi, automatic: false, defaults: defaults)
    }
    #expect(DanmakuService.preferredSource(defaults: defaults) == .tencent)
    #expect(DanmakuService.cacheIdentity(server: "https://example.com/token", preferredSource: .tencent)
        == DanmakuService.cacheIdentity(server: "https://EXAMPLE.com:443/token/api/v2/", preferredSource: .tencent))
    #expect(DanmakuProvider(source: "qq") == .tencent)
    #expect(DanmakuProvider(source: "mgtv") == .imgo)
    #expect(DanmakuProvider.allCases.allSatisfy { !$0.title.isEmpty })
}

@Test func customDanmakuKeepsAHandPickFromAnotherPlatform() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = MediaCache(root: root), transport = CustomDanmakuTransport()
    let resolver = DanmakuResolver(cache: cache, http: .init { try await transport.send($0) }, dandanServer: "https://example.com/other-platform",
                                   preferredSource: .tencent)
    let context = customContext(), next = customContext("第2集")
    // Tencent preferred, but the viewer picked the Bilibili entry by hand: the next episode keeps using it.
    resolver.remember(DanmakuMapping(provider: "bilibili", title: context.videoName, year: context.year, tracks: [
        .init(number: 1, title: "第1集", id: "pick-1", source: "bilibili"),
        .init(number: 2, title: "第2集", id: "pick-2", source: "bilibili")
    ], animeID: "201", source: "bilibili"), for: context, ticket: cache.ticket())
    #expect(try await resolver.resolve(next).source == DanmakuProvider.bilibili.title)
    #expect(await transport.count("comment/pick-2") == 1)
    #expect(await transport.count("search/anime") == 0)
}

@Test func customDanmakuSaysWhenTheServerNeedsAuthorization() async throws {
    for status in [401, 403] {
        let client = try CatalogDanmakuClient(address: "https://example.com", transport: .init { _ in throw TVError.http(status) })
        await #expect(throws: DanmakuAuthorizationRequired.self) { try await client.search("测试剧") }
    }
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let resolver = DanmakuResolver(cache: MediaCache(root: root), http: .init { _ in throw TVError.http(401) },
                                   dandanServer: "https://example.com/expired-token")
    #expect(try await resolver.resolve(customContext()).state == "unavailable")
}

@Test func customDanmakuReadsFromAsASourceOnlyInServiceTags() {
    // Different films, not one title from two sources.
    for title in ["Escape from Alcatraz", "Escape from Tomorrow"] {
        let metadata = CatalogDanmakuMatcher.titleMetadata(title)
        #expect(metadata.title == title && metadata.source == nil)
    }
    #expect(CatalogDanmakuMatcher.titleMetadata("测试剧(2023)【电视剧】from 360").source == "360")
    #expect(CatalogDanmakuMatcher.titleMetadata("测试剧 from bilibili") == ("测试剧", nil, "bilibili", nil))
}

@Test func officialServerMatchesAsAutomaticForAPlatformItCannotFollow() {
    let context = customContext()
    #expect(DanmakuResolver(preferredSource: .bilibili).officialPreference(context) == .automatic)
    #expect(DanmakuResolver(preferredSource: .migu).officialPreference(context) == .automatic)
    #expect(DanmakuResolver(preferredSource: .tencent).officialPreference(context) == .tencent)
    #expect(DanmakuResolver(preferredSource: .dandan).officialPreference(context) == .dandan)
    #expect(DanmakuResolver(officialLookup: false, preferredSource: .iqiyi).officialPreference(context) == .automatic)
    var bilibili = context
    bilibili.officialPage = URL(string: "https://www.bilibili.com/bangumi/play/ep123456")
    #expect(DanmakuResolver(preferredSource: .bilibili).officialPreference(bilibili) == .bilibili)
}

@Test func aShowPickedByHandFollowsWithAutomaticMatchingOffAndSearchesNothing() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = MediaCache(root: root), transport = CustomDanmakuTransport()
    let resolver = DanmakuResolver(cache: cache, http: .init { try await transport.send($0) }, dandanServer: "https://example.com/picked")
    let context = customContext(), next = customContext("第2集")
    // Nothing picked: with matching off nothing is asked.
    #expect(!resolver.hasPick(for: next))
    #expect(try await resolver.resolve(next, savedOnly: true).comments.isEmpty)
    #expect(await transport.total() == 0)
    resolver.remember(DanmakuMapping(provider: "tencent", title: context.videoName, year: context.year, tracks: [
        .init(number: 1, title: "第1集", id: "manual-1", source: "tencent"),
        .init(number: 2, title: "第2集", id: "manual-2", source: "tencent")
    ], animeID: "101", source: "tencent"), for: context, ticket: cache.ticket(), picked: true)
    #expect(resolver.hasPick(for: next))
    #expect(try await resolver.resolve(next, savedOnly: true).source == DanmakuProvider.tencent.title)
    #expect(await transport.count("comment/manual-2") == 1)
    #expect(await transport.total() == 1)
    resolver.forgetPick(context)
    #expect(!resolver.hasPick(for: next))
}

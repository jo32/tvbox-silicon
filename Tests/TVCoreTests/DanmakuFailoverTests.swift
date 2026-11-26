import Foundation
import Testing
@testable import TVCore

private actor FailoverTransport {
    let mode: String
    var paths: [String] = []
    init(_ mode: String) { self.mode = mode }
    func send(_ request: URLRequest) async throws -> Data {
        let path = request.url!.path
        paths.append(path)
        if mode == "page-url-cancel", path.hasSuffix("/comment") { throw URLError(.cancelled) }
        if path.hasSuffix("search/anime") {
            if mode == "search-url-cancel" { throw URLError(.cancelled) }
            if mode == "cancel-empty-search" {
                withUnsafeCurrentTask { $0?.cancel() }
                return Data(#"{"animes":[]}"#.utf8)
            }
            var rows: [[String: Any]] = [
                ["animeId": "iq", "animeTitle": "测试剧(2023)【电视剧】from iqiyi", "source": "iqiyi"],
                ["animeId": "qq", "animeTitle": "测试剧(2023)【电视剧】from tencent", "source": "tencent"]]
            if mode == "ambiguous" { rows.append(["animeId": "qq2", "animeTitle": "测试剧(2023)【电视剧】from tencent", "source": "tencent"]) }
            if mode == "later-batch" {
                rows += ["bilibili", "youku", "migu"].map { ["animeId": $0, "animeTitle": "测试剧", "source": $0] }
            }
            if mode == "aliases" { rows = [rows[1], ["animeId": "qq2", "animeTitle": "测试剧", "source": "qq"]] }
            if mode == "aggregate" { rows = [["animeId": "combined", "animeTitle": "测试剧", "source": "360"]] }
            return try JSONSerialization.data(withJSONObject: ["animes": rows])
        }
        if path.contains("bangumi/") {
            let id = request.url!.lastPathComponent
            if mode == "later-batch", id == "migu" { throw TVError.http(429) }
            if id == "combined" {
                return Data(#"{"bangumi":{"episodes":[{"episodeId":"iq-1","episodeTitle":"第1集","source":"iqiyi"},{"episodeId":"qq-1","episodeTitle":"第1集","source":"tencent"}]}}"#.utf8)
            }
            if id == "qq", mode == "mixed" { throw URLError(.timedOut) }
            if id == "iq" {
                if mode == "list-failure" || mode == "all-fail" || mode == "ambiguous" { throw URLError(.timedOut) }
                if mode == "list-auth" { throw TVError.http(403) }
                if mode == "list-cancel" { throw CancellationError() }
            }
            return Data("{\"bangumi\":{\"episodes\":[{\"episodeId\":\"\(id)-1\",\"episodeTitle\":\"第1集\",\"source\":\"\(id == "iq" ? "iqiyi" : "tencent")\"}]}}".utf8)
        }
        if path.contains("comment/") {
            if path.hasSuffix("iq-1") {
                if mode == "feed-url-cancel" || mode == "saved-url-cancel" { throw URLError(.cancelled) }
                if ["aggregate", "mixed", "all-empty"].contains(mode) { return Data(#"{"comments":[]}"#.utf8) }
                if mode == "feed-failure" || mode == "all-fail" { throw URLError(.timedOut) }
                if mode == "empty" { return Data(#"{"comments":[]}"#.utf8) }
                if mode == "feed-auth" { throw TVError.http(401) }
                if mode == "feed-limit" { throw TVError.http(429) }
                if mode == "feed-cancel" { throw CancellationError() }
            }
            if mode == "all-fail" { throw URLError(.timedOut) }
            if mode == "all-empty" { return Data(#"{"comments":[]}"#.utf8) }
            return Data(#"{"comments":[{"p":"1,1,16777215,user","m":"next platform"}]}"#.utf8)
        }
        throw TVError.http(404)
    }
}

private func failoverContext() -> PlaybackHistoryContext {
    var context = PlaybackHistoryContext(origin: URL(string: "https://example.invalid/catalog")!, sourceKey: "source", sourceName: "Source", videoID: "show", videoName: "测试剧", episodeID: "1", episodeName: "第1集", episodeFlag: "line")
    context.year = "2023"
    return context
}

@Test(arguments: ["list-failure", "empty", "feed-failure", "aggregate"])
func automaticDanmakuContinuesAfterCandidateFailure(_ mode: String) async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = FailoverTransport(mode)
    let resolver = DanmakuResolver(cache: MediaCache(root: root), http: .init { try await transport.send($0) }, dandanServer: "https://failover.example/" + mode)
    let result = try await resolver.resolve(failoverContext())
    #expect(result.state == "loaded")
    #expect(result.source == DanmakuProvider.tencent.title)
    #expect(result.comments.first?.text == "next platform")
    let before = await transport.paths
    #expect(before.last?.hasSuffix("comment/qq-1") == true)
    resolver.forget(failoverContext())
    #expect(try await resolver.resolve(failoverContext()).source == DanmakuProvider.tencent.title)
    let after = await transport.paths
    #expect(after.count == before.count + 1 && after.last?.hasSuffix("comment/qq-1") == true)
}

@Test(arguments: ["list-auth", "feed-auth", "feed-limit", "all-fail", "ambiguous", "mixed", "all-empty", "aliases"])
func automaticDanmakuKeepsGlobalFailuresAndAmbiguityBounded(_ mode: String) async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = FailoverTransport(mode)
    let resolver = DanmakuResolver(cache: MediaCache(root: root), http: .init { try await transport.send($0) }, dandanServer: "https://failover.example/" + mode)
    let result = try await resolver.resolve(failoverContext())
    #expect(result.comments.isEmpty)
    let paths = await transport.paths
    #expect(result.state == (["all-empty", "aliases"].contains(mode) ? "unmatched" : "unavailable"))
    if !["all-fail", "all-empty"].contains(mode) { #expect(!paths.contains { $0.hasSuffix("comment/qq-1") }) }
    if mode == "aliases" { #expect(paths.count == 1) }
    if mode == "all-empty" { #expect(paths.filter { $0.contains("comment/") }.count == 2) }
    let count = paths.count
    _ = try await resolver.resolve(failoverContext())
    #expect(await transport.paths.count == count, "short failure cache must stop immediate retries")
}

@Test(arguments: ["list-cancel", "feed-cancel", "search-url-cancel", "feed-url-cancel", "page-url-cancel", "saved-url-cancel", "cancel-empty-search"])
func automaticDanmakuCancellationDoesNotFallThrough(_ mode: String) async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = FailoverTransport(mode)
    let resolver = DanmakuResolver(cache: MediaCache(root: root), http: .init { try await transport.send($0) }, dandanServer: "https://failover.example/" + mode)
    var context = failoverContext()
    if mode == "page-url-cancel" { context.officialPage = URL(string: "https://v.qq.com/x/page/abc.html") }
    if mode == "saved-url-cancel" {
        resolver.remember(.init(provider: "iqiyi", title: context.videoName, year: context.year,
            tracks: [.init(number: 1, title: "第1集", id: "iq-1", source: "iqiyi")]), for: context, ticket: resolver.cache.ticket(), picked: true)
    }
    let task = Task { [context] in try await resolver.resolve(context) }
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(await !transport.paths.contains { $0.hasSuffix("comment/qq-1") })
    if ["search-url-cancel", "page-url-cancel", "saved-url-cancel"].contains(mode) { #expect(await transport.paths.count == 1) }
    #expect(resolver.cache.data(for: resolver.cacheKey(context), kind: .danmaku, scope: context.id) == nil)
}

@Test func successfulDanmakuDoesNotRequestLowerPriorityBatches() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = FailoverTransport("later-batch")
    let resolver = DanmakuResolver(cache: MediaCache(root: root), http: .init { try await transport.send($0) }, dandanServer: "https://failover.example/later")
    #expect(try await resolver.resolve(failoverContext()).source == DanmakuProvider.iqiyi.title)
    #expect(await !transport.paths.contains { $0.hasSuffix("bangumi/migu") })
}

@Test func batchedListsCannotMultiplyTheAutomaticFeedBudget() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    actor Requests {
        var feeds: [String] = []
        func send(_ request: URLRequest) throws -> Data {
            let url = try #require(request.url)
            let platforms = ["iqiyi", "tencent", "bilibili", "youku", "imgo", "migu", "dandan"]
            if url.path.hasSuffix("search/anime") {
                let rows = ["desk", "box", "shelf"].map { ["animeId": $0, "animeTitle": "测试剧", "source": $0] }
                return try JSONSerialization.data(withJSONObject: ["animes": rows])
            }
            if url.path.contains("/bangumi/") {
                let rows = platforms.map { source in
                    ["episodeId": source == "iqiyi" ? "shared" : url.lastPathComponent + source,
                     "episodeTitle": "第1集", "source": source]
                }
                return try JSONSerialization.data(withJSONObject: ["bangumi": ["episodes": rows]])
            }
            feeds.append(url.lastPathComponent)
            return Data(#"{"comments":[]}"#.utf8)
        }
    }
    let requests = Requests()
    let resolver = DanmakuResolver(cache: MediaCache(root: root), http: .init { try await requests.send($0) }, dandanServer: "https://feeds.invalid")
    #expect(try await resolver.resolve(failoverContext()).state == "unmatched")
    let feeds = await requests.feeds
    #expect(feeds.count == 12 && Set(feeds).count == 12)
}

@Test func refreshingAnUnrecognizedPickedPlatformCannotSwitchToAKnownOne() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = MediaCache(root: root), context = failoverContext()
    let resolver = DanmakuResolver(cache: cache, http: .init { request in
        let url = try #require(request.url)
        if url.path.hasSuffix("/stale") { throw TVError.http(404) }
        if url.path.hasSuffix("bangumi/catalog") {
            return Data(#"{"bangumi":{"episodes":[{"episodeId":"wrong","episodeTitle":"第1集","source":"tencent"},{"episodeId":"fresh","episodeTitle":"第1集","source":"studio"}]}}"#.utf8)
        }
        return Data("{\"comments\":[{\"p\":\"1,1,16777215,user\",\"m\":\"\(url.lastPathComponent)\"}]}".utf8)
    }, dandanServer: "https://saved.invalid")
    resolver.remember(.init(provider: "studio", title: context.videoName, year: context.year,
        tracks: [.init(number: 1, title: "第1集", id: "stale", source: "studio")], animeID: "catalog", source: "studio"),
        for: context, ticket: cache.ticket(), picked: true)
    let result = try await resolver.resolve(context)
    #expect(result.source == "studio" && result.comments.first?.text == "fresh")
}

@Test func manuallyPickedDanmakuDoesNotSwitchPlatformsOnEmptyComments() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = MediaCache(root: root), transport = FailoverTransport("empty")
    let resolver = DanmakuResolver(cache: cache, http: .init { try await transport.send($0) }, dandanServer: "https://failover.example/manual")
    resolver.remember(.init(provider: "iqiyi", title: "测试剧", year: "2023", tracks: [.init(number: 1, title: "第1集", id: "iq-1", source: "iqiyi")], animeID: "iq", source: "iqiyi"), for: failoverContext(), ticket: cache.ticket(), picked: true)
    #expect(try await resolver.resolve(failoverContext()).comments.isEmpty)
    #expect(await transport.paths.count == 1)
}

@Test func manuallyPickedDanmakuWithMissingEpisodeDoesNotStartAutomaticSearch() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = MediaCache(root: root), transport = FailoverTransport("empty")
    let resolver = DanmakuResolver(cache: cache, http: .init { try await transport.send($0) }, dandanServer: "https://failover.example/manual-missing")
    resolver.remember(.init(provider: "iqiyi", title: "测试剧", year: "2023", tracks: [.init(number: 2, title: "第2集", id: "iq-2", source: "iqiyi")], animeID: "iq", source: "iqiyi"), for: failoverContext(), ticket: cache.ticket(), picked: true)
    #expect(try await resolver.resolve(failoverContext()).comments.isEmpty)
    #expect(await transport.paths.isEmpty)
}

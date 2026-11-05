import Foundation
import Testing
@testable import TVCore

private func catPawContext(episode: String = "第3集") -> PlaybackHistoryContext {
    PlaybackHistoryContext(origin: URL(string: "https://example.com/cat/index.js")!, sourceKey: "muou", sourceName: "木偶", videoID: "v1",
        videoName: "测试剧", episodeID: episode, episodeName: episode, episodeFlag: "线路1")
}
private let catPawXML = Data(#"<?xml version="1.0" encoding="UTF-8"?><i><d p="1.5,1,25,16777215,0,0,0,0">第一条</d><d p="3,5,25,16711680,0,0,0,0">顶部</d></i>"#.utf8)
private actor CatPawAsks {
    var params: [[String: String]] = []
    var answers: [[String: JSONValue]]
    init(_ answers: [[String: JSONValue]]) { self.answers = answers }
    func ask(_ params: [String: String]) -> [String: JSONValue] {
        self.params.append(params)
        return answers.count > 1 ? answers.removeFirst() : answers[0]
    }
}

@Test func catPawDanmakuWaitsForTheBundlesAddressAndReadsItsXML() async throws {
    let pushed = "http://127.0.0.1:4100/danmu/auto?name=%E6%B5%8B%E8%AF%95%E5%89%A7&episode=3"
    let asks = CatPawAsks([["url": .string("http://127.0.0.1:4100/danmu/auto?name=x"), "pending": .bool(true)],
                           ["url": .string(pushed), "pushed": .bool(true), "pending": .bool(false)]])
    let http = DanmakuHTTP { request in
        #expect(request.url?.absoluteString == pushed)
        #expect(request.value(forHTTPHeaderField: "x-yingxia-host") == "1")
        return catPawXML
    }
    let result = await CatPawDanmaku.comments(for: catPawContext(), source: "木偶", http: http) { await asks.ask($0) }
    #expect(result?.comments.map(\.text) == ["第一条", "顶部"])
    #expect(result?.source == "木偶" && result?.state == "loaded" && result?.track == "测试剧 · 第3集")
    let params = await asks.params
    #expect(params.count == 2)
    #expect(params.first == ["catDanmaku": "1", "name": "测试剧", "episode": "第3集"])
}

@Test func catPawBundlesWithoutDanmakuLeaveItToTheOtherProviders() async throws {
    let asks = CatPawAsks([["url": .string("http://127.0.0.1:4100/danmu/auto?name=x"), "pending": .bool(false)]])
    // No /danmu/auto route: Fastify's 404.
    let missing = DanmakuHTTP { _ in throw TVError.http(404) }
    #expect(await CatPawDanmaku.comments(for: catPawContext(), source: "s", http: missing) { await asks.ask($0) } == nil)
    // A page that isn't comments, and an address off this device, are no comments either.
    let page = DanmakuHTTP { _ in Data("<html>hello</html>".utf8) }
    #expect(await CatPawDanmaku.comments(for: catPawContext(), source: "s", http: page) { await asks.ask($0) } == nil)
    let remote = CatPawAsks([["url": .string("https://example.com/danmu")]])
    let never = DanmakuHTTP { _ in Issue.record("asked a remote address"); return catPawXML }
    #expect(await CatPawDanmaku.comments(for: catPawContext(), source: "s", http: never) { await remote.ask($0) } == nil)
    // A host that fails the call (an older host, or tvOS) is none too.
    #expect(await CatPawDanmaku.comments(for: catPawContext(), source: "s", http: never) { _ in throw TVError.invalidConfiguration } == nil)
}

@Test func resolverAsksTheSourcesOwnDanmakuFirstAndCachesIt() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let servers = DanmakuHTTP { request in Issue.record("asked \(request.url?.absoluteString ?? "")"); throw TVError.http(404) }
    let resolver = DanmakuResolver(cache: MediaCache(root: root), http: servers, dandanServer: "https://dandan.test",
                                   dmkuServer: URL(string: "https://dmku.test")!, backupServer: nil, officialLookup: false)
    let context = catPawContext()
    let own = AutomaticDanmakuResult(comments: try CatalogDanmakuParser.parse(catPawXML), track: "测试剧 · 第3集", source: "木偶", state: "loaded")
    let first = try await resolver.resolve(context, first: { _ in own })
    #expect(first.comments.count == 2 && first.source == "木偶" && !first.cached)
    let again = try await resolver.resolve(context, first: { _ in Issue.record("asked again"); return nil })
    #expect(again.cached && again.comments.count == 2)
}

import Foundation
import Testing
@testable import TVCore

private func site(_ id: String, oversized: Bool = false) -> Site {
    var raw: [String: JSONValue] = ["key": .string("same")]
    if oversized { raw["ext"] = .string(String(repeating: "s", count: 33 << 20)) }
    return Site(key: id, name: id, type: 1, api: "/catalog", raw: raw)
}

private actor CatalogReplies {
    private(set) var requests: [String] = []
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func releaseOther() {
        released = true
        waiter?.resume(); waiter = nil
    }
    func page(_ site: Site, query: String, page: Int) async -> CatalogPage {
        requests.append("\(site.id):\(page)")
        if query == "both", site.id == "same@other", !released {
            await withCheckedContinuation { waiter = $0 }
        }
        return CatalogPage(json: ["list": .array([.object(["vod_id": .string("\(page)"), "vod_name": .string(query)])]),
                                  "pagecount": .number(2)], origin: URL(string: "https://fixture.invalid")!)
    }
}

@MainActor @Test(arguments: [false, true]) func finalOmissionSettlesTheTitlePageWithoutPublishingAResult(disconnectProgress: Bool) async throws {
    let store = Store(subscription: Subscription(sites: [site("same@last", oversized: true)]))
    let title = DiscoverSources.of(.init(key: UUID().uuidString, name: "Example"))
    title.start(store)
    if disconnectProgress { title.search.onProgress = nil }
    let run = try #require(title.search.task)
    #expect(!title.finished)
    await run.value
    #expect(title.search.completed == 1 && title.search.total == 1)
    #expect(title.search.results.isEmpty && title.matches.isEmpty && title.chosen == nil)
    #expect(title.finished == !disconnectProgress && title.search.resultLimitMessage != nil)
}

@MainActor @Test func resumeKeepsOmittedIdentityAndDoesNotPublishStaleProgress() async throws {
    let replies = CatalogReplies()
    var http = HTTPClient()
    http.reply = { await replies.page($0, query: $1, page: $2) }
    let model = SearchModel(http: http)
    let config = Subscription(sites: [site("same", oversized: true), site("same@other")])
    model.search("first", config: config) { $0.id == "same@other" }
    let first = try #require(model.task)
    var progress: [Int] = [], delivered: [String] = []
    model.onProgress = { progress.append(model.completed) }
    model.onResult = { delivered.append($0.id) }
    await first.value
    #expect(model.completed == 1 && model.results.isEmpty && delivered.isEmpty)

    progress = []
    model.onProgress = {
        progress.append(model.completed)
        if model.completed == 1 {
            model.suspend()
            Task { await replies.releaseOther() }
        }
    }
    model.search("both", config: config)
    let interrupted = try #require(model.task)
    await interrupted.value
    #expect(model.suspended && progress == [1])
    #expect(delivered.isEmpty)
    let before = await replies.requests
    model.onProgress = { progress.append(model.completed) }
    model.resumeSuspended(config: config)
    #expect(model.completed == 1)
    await model.task?.value
    let resumed = Array((await replies.requests).dropFirst(before.count))
    #expect(resumed == ["same@other:1"])
    #expect(progress == [1, 2] && model.completed == model.total)
    #expect(delivered == ["same@other"] && model.results.map(\.id) == ["same@other"])
}

@MainActor @Test func cachedPayloadsOnlyAnswerTheCurrentlyEligibleSourceIdentities() async throws {
    let replies = CatalogReplies()
    var http = HTTPClient()
    http.reply = { await replies.page($0, query: $1, page: $2) }
    let model = SearchModel(http: http)
    let config = Subscription(sites: [site("same"), site("same@other")])
    model.search("cached", config: config) { $0.id == "same@other" }
    await model.task?.value
    #expect(model.results.map(\.id) == ["same"])
    model.search("cached", config: config) { $0.id == "same" }
    await model.task?.value
    #expect(model.results.map(\.id) == ["same@other"] && model.completed == 1)
    model.search("cached", config: config)
    await model.task?.value
    #expect(Set(model.results.map(\.id)) == ["same", "same@other"])
    #expect(model.completed == 2 && model.total == 2 && !model.busy)
    let requests = await replies.requests
    model.search("cached", config: config)
    #expect(!model.busy && model.task == nil)
    #expect(await replies.requests == requests)
}

@MainActor @Test func replacingSearchFromAResultCannotSendProgressToTheNextRun() async throws {
    let model = SearchModel(), config = Subscription(sites: [site("one")])
    var progress: [Int] = []
    model.onResult = { _ in
        if model.keyword == "first" { model.search("second", config: config) }
    }
    model.onProgress = { progress.append(model.completed) }
    model.search("first", config: config)
    let first = try #require(model.task)
    await first.value
    await model.task?.value
    #expect(model.keyword == "second" && model.results.map(\.id) == ["one"])
    #expect(progress == [1])
}

@MainActor @Test func cacheAdmissionIncludesTheKeywordAsWellAsItsResults() async {
    let query = String(repeating: "summer ", count: 40) + "catalog"
    var source = site("one")
    source.raw["notes"] = .string("")
    let cost = SearchPayloadBudget.cost(SearchSourceResult(site: source, page: nil, error: nil))
    source.raw["notes"] = .string(String(repeating: "n", count: (12 << 20) - cost.bytes - 16))
    let model = SearchModel(), config = Subscription(sites: [source])
    model.search(query, config: config)
    await model.task?.value
    #expect(model.results.map(\.id) == ["one"] && model.resultLimitMessage == nil)
    model.search(query, config: config)
    #expect(model.busy)
    await model.task?.value
}

@MainActor @Test func overflowingLaterPageStopsOnlyItsSourceAndKeepsItsCards() async {
    var http = HTTPClient()
    http.reply = { site, query, page in
        let rows: [JSONValue]
        if site.id == "same", page == 2 {
            rows = (0..<24_000).map { .object(["vod_id": .string("next-\($0)")]) }
        } else {
            rows = [.object(["vod_id": .string("page-\(page)"), "vod_name": .string(query)])]
        }
        return CatalogPage(json: ["list": .array(rows), "pagecount": .number(2)], origin: URL(string: "https://fixture.invalid")!)
    }
    let model = SearchModel(http: http), config = Subscription(sites: [site("same"), site("same@other")])
    model.search("catalog", config: config)
    await model.task?.value
    model.loadMore("same", config: config)
    await model.moreTask?.value
    #expect(!model.canLoadMore("same") && model.canLoadMore("same@other"))
    #expect(model.videos(for: "same").map(\.id) == ["page-1"])
    #expect(model.batches.isEmpty && model.resultLimitMessage != nil)
    model.loadMore("same@other", config: config)
    await model.moreTask?.value
    #expect(model.videos(for: "same@other").map(\.id) == ["page-1", "page-2"])
}

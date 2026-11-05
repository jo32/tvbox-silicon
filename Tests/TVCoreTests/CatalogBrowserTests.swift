import Foundation
import Testing
@testable import TVCore

private func page(_ name: String) -> CatalogPage {
    CatalogPage(json: ["list": .array([.object(["vod_id": .string(name), "vod_name": .string(name)])])], origin: URL(string: "https://example.com")!)
}

private func page(_ names: [String], pageCount: Int) -> CatalogPage {
    CatalogPage(json: ["pagecount": .number(Double(pageCount)),
                       "list": .array(names.map { .object(["vod_id": .string($0), "vod_name": .string($0)]) })],
                origin: URL(string: "https://example.com")!)
}

@MainActor @Test func newestCatalogRequestWins() async {
    let model = CatalogBrowser()
    let older = Task {
        await model.load(.list(category: nil, query: "old", page: 1)) { _ in
            try await Task.sleep(for: .milliseconds(100))
            return page("old")
        }
    }
    while !model.busy { await Task.yield() }
    await model.load(.list(category: nil, query: "new", page: 1)) { _ in page("new") }
    await older.value
    #expect(model.query == "new")
    #expect(model.videos.first?.name == "new")
    #expect(!model.busy)
}

@MainActor @Test func catalogFailureKeepsExactRetryRequest() async {
    let model = CatalogBrowser()
    let request = CatalogBrowser.Request.list(category: nil, query: "query", page: 2)
    await model.load(request) { _ in throw URLError(.timedOut) }
    #expect(model.request == request)
    #expect(model.error != nil)
    await model.load(model.request) { requested in
        #expect(requested == request)
        return page("recovered")
    }
    #expect(model.error == nil)
    #expect(model.page == 2)
    #expect(model.videos.first?.name == "recovered")
}

/// Issue #513: scrolling past the last cover appends the category's next page instead of stopping at a pager.
@MainActor @Test func catalogLoadMoreAppendsPagesUntilTheSourceRunsOut() async {
    let model = CatalogBrowser()
    await model.load(.list(category: "movies", query: "q", page: 1, filters: ["year": "2024"])) { _ in
        page(["a"], pageCount: 4)
    }
    #expect(model.hasMore)
    await model.loadMore { request in
        #expect(request == .list(category: "movies", query: "q", page: 2, filters: ["year": "2024"]))
        return page(["b", "a"], pageCount: 4)
    }
    #expect(model.videos.map(\.id) == ["a", "b"])
    #expect(model.page == 2)
    #expect(model.hasMore)
    await model.loadMore { _ in page([], pageCount: 4) }
    #expect(model.page == 3)
    #expect(!model.hasMore)
    #expect(model.videos.map(\.id) == ["a", "b"])
}

/// A source that sends `pagecount` only with the first page keeps appending: page 2's missing count (read as 1)
/// doesn't end the list.
@MainActor @Test func catalogLoadMoreKeepsTheFirstPageCount() async {
    let model = CatalogBrowser()
    await model.load(.list(category: "movies", query: "", page: 1)) { _ in page(["a"], pageCount: 4) }
    await model.loadMore { _ in page("b") }
    #expect(model.page == 2)
    #expect(model.pageCount == 4)
    #expect(model.hasMore)
    await model.loadMore { _ in page("c") }
    #expect(model.videos.map(\.id) == ["a", "b", "c"])
}

@MainActor @Test func aNewCatalogRequestCancelsLoadingMore() async {
    let model = CatalogBrowser()
    await model.load(.list(category: "movies", query: "", page: 1)) { _ in page(["a"], pageCount: 5) }
    let probe = FetchCancellationProbe()
    let older = Task {
        await model.loadMore { _ in
            await probe.start()
            do { try await Task.sleep(for: .seconds(10)) }
            catch { await probe.cancel(); throw error }
            return page(["b"], pageCount: 5)
        }
    }
    while !(await probe.started) { await Task.yield() }
    await model.load(.list(category: "other", query: "", page: 1)) { _ in page(["c"], pageCount: 5) }
    await older.value
    #expect(await probe.cancelled)
    #expect(!model.loadingMore)
    #expect(model.videos.map(\.id) == ["c"])
}

@MainActor @Test func catalogHomeClearsSearchAndLoadsFirstCategory() async {
    let model = CatalogBrowser()
    await model.load(.list(category: nil, query: "query", page: 1)) { _ in page("search") }
    await model.load(.home) { request in
        if request == .home {
            return CatalogPage(json: ["class": .array([.object(["type_id": .string("movies"), "type_name": .string("Movies")])])], origin: URL(string: "https://example.com")!)
        }
        #expect(request == .list(category: "movies", query: "", page: 1))
        return page("browse")
    }
    #expect(model.query.isEmpty)
    #expect(model.category == "movies")
    #expect(model.videos.first?.name == "browse")
}

private actor FetchCancellationProbe {
    var started = false
    var cancelled = false
    func start() { started = true }
    func cancel() { cancelled = true }
}

@MainActor @Test func supersededCatalogRequestCancelsItsFetch() async throws {
    let model = CatalogBrowser()
    let probe = FetchCancellationProbe()
    let older = Task {
        await model.load(.list(category: nil, query: "old", page: 1)) { _ in
            await probe.start()
            do { try await Task.sleep(for: .seconds(10)) }
            catch { await probe.cancel(); throw error }
            return page("old")
        }
    }
    while !(await probe.started) { await Task.yield() }
    let started = ContinuousClock.now
    await model.load(.list(category: nil, query: "new", page: 1)) { _ in page("new") }
    await older.value
    #expect(await probe.cancelled)
    #expect(started.duration(to: .now) < .seconds(1))
    #expect(model.videos.first?.name == "new")
    #expect(model.error == nil)
}

@MainActor @Test func leavingCatalogPageCancelsUnstructuredRequestAndAllowsReturn() async {
    let model = CatalogBrowser()
    let probe = FetchCancellationProbe()
    let request = CatalogBrowser.Request.list(category: "movies", query: "", page: 2)
    let old = Task {
        await model.load(request) { _ in
            await probe.start()
            do { try await Task.sleep(for: .seconds(10)) }
            catch { await probe.cancel(); throw error }
            return page("old")
        }
    }
    while !(await probe.started) { await Task.yield() }
    model.cancel()
    await old.value
    #expect(await probe.cancelled)
    #expect(!model.busy && !model.loaded && model.error == nil)
    #expect(model.videos.isEmpty && model.request == request)
    await model.load(model.request) { _ in page("returned") }
    model.cancel()
    #expect(model.loaded && model.videos.first?.name == "returned")
}

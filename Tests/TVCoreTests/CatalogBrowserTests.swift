import Foundation
import Testing
@testable import TVCore

private func page(_ name: String) -> CatalogPage {
    CatalogPage(json: ["list": .array([.object(["vod_id": .string(name), "vod_name": .string(name)])])], origin: URL(string: "https://example.com")!)
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

import Foundation
import Testing
@testable import TVCore

@MainActor @Test func eligibleSearchUsesFirstEligibleSourceForEachIdentity() {
    let first = Site(key: "same", name: "first", type: 1, api: "https://one.invalid", raw: [:])
    let duplicate = Site(key: "same", name: "second", type: 1, api: "https://two.invalid", raw: [:])
    let namespaced = Site(key: "other:same", name: "other subscription", type: 1, api: "https://three.invalid", raw: [:])
    let result = SearchModel.eligible([first, duplicate, namespaced], jarURL: nil, excluding: { _ in false })
    #expect(result.map(\.name) == ["first", "other subscription"])
    let filtered = SearchModel.eligible([first, duplicate], jarURL: nil, excluding: { $0.name == "first" })
    #expect(filtered.map(\.name) == ["second"])
}

@MainActor @Test func duplicateVideosKeepFirstCardInSourceOrder() {
    let site = Site(key: "one", name: "one", type: 1, api: "https://one.invalid", raw: [:])
    let model = SearchModel()
    let page = CatalogPage(json: ["list": .array([
        .object(["vod_id": .string("a"), "vod_name": .string("first")]),
        .object(["vod_id": .string("a"), "vod_name": .string("duplicate")]),
        .object(["vod_id": .string("b"), "vod_name": .string("last")])
    ])], origin: URL(string: "https://one.invalid")!)
    model.results = [SearchSourceResult(site: site, page: page, error: nil)]
    #expect(model.videos(for: site.id).map(\.name) == ["first", "last"])
}

@MainActor @Test func repeatedAnswerDoesNotIncrementProgressOrNotifyTwice() {
    let model = SearchModel()
    let site = Site(key: "one", name: "one", type: 1, api: "https://one.invalid", raw: [:])
    var callbacks = 0
    model.onResult = { _ in callbacks += 1 }
    model.total = 1
    model.record(SearchSourceResult(site: site, page: nil, error: "first"))
    model.record(SearchSourceResult(site: site, page: nil, error: "duplicate"))
    #expect(model.completed == model.total)
    #expect(model.results.count == 1)
    #expect(model.results.first?.error == "first")
    #expect(callbacks == 1)
    model.results = [] // An explicit retry removes the failure before dispatching it again.
    model.completed = 0
    model.record(SearchSourceResult(site: site, page: nil, error: nil))
    #expect(model.completed == 1)
    #expect(model.results.first?.error == nil)
}

private final class IdentityCatalogProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"list\":[]}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private actor IdentityAnswers {
    var ids: [String] = []
    func record(_ result: SearchSourceResult) { ids.append(result.id) }
}
@Test func directGlobalSearchDispatchesEachNamespacedIdentityOnce() async {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [IdentityCatalogProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let one = Site(key: "same", name: "first", type: 1, api: "https://one.invalid", raw: [:])
    let other = Site(key: "other:same", name: "second subscription", type: 1, api: "https://one.invalid", raw: [:])
    let answers = IdentityAnswers()
    await GlobalSearch.search(sites: [one, one, other], origin: URL(string: "https://one.invalid")!, jarURL: nil,
                              query: "query", http: HTTPClient(session: session)) { await answers.record($0) }
    #expect(await answers.ids.sorted() == ["other:same", "same"])
}

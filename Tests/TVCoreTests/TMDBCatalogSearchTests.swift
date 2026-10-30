import Foundation
import Testing
@testable import TVCore

private final class CatalogSearchProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let params = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
        let fields = Dictionary(params.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, new in new })
        // Echo the request through a real decoded title to verify serialization.
        let title: [String: Any] = ["id": 1, "mediaType": "movie", "name": fields["q"] ?? "", "originalName": fields["mode"] ?? "",
                                    "overview": String(data: try! JSONSerialization.data(withJSONObject: fields), encoding: .utf8)!, "genreIDs": []]
        var body: [String: Any] = ["items": [title], "people": [["id": 31, "name": "Person", "works": []]],
                                   "keywords": [["id": 12, "name": "space"]], "page": Int(fields["page"] ?? "1")!, "totalPages": 5]
        if fields["mode"] == "profile" {
            body = ["id": Int(fields["id"] ?? "0")!, "name": fields["language"] ?? "", "biography": "Biography", "birthplace": "", "department": "Acting",
                    "works": [["item": title, "date": "2025-03-19", "roles": ["Lead", "Producer"], "departments": ["Acting", "Production"]]]]
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: fields["q"] == "fail" ? 429 : 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
struct TMDBCatalogSearchTests {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CatalogSearchProtocol.self]
        return URLSession(configuration: config)
    }
    @Test func searchEncodesChineseAndReservedCharactersWithoutQueryInjection() async throws {
        let page = try await TMDBCatalog.search(query: "电影 & kind=person?", kind: .tv, page: 3, language: "zh-CN", session: session())
        #expect(page.items[0].name == "电影 & kind=person?")
        let fields = try JSONDecoder().decode([String: String].self, from: Data(page.items[0].overview.utf8))
        #expect(fields["kind"] == "tv"); #expect(fields["mode"] == "search")
        #expect(fields["language"] == "zh-CN"); #expect(page.page == 3)
        #expect(page.people[0].profile == nil); #expect(page.keywords[0].id == 12)
    }
    @Test func filtersKeepRangesKeywordsAndTVNetworksAcrossPages() async throws {
        var filter = TMDBCatalog.Filter(); filter.kind = .tv; filter.from = "2020"; filter.to = "2026"
        filter.genres = [18,80]; filter.company = "213"; filter.originalLanguage = "ko"; filter.rating = 7
        #expect(filter.isValid)
        let page = try await TMDBCatalog.search(page: 4, filter: filter, session: session())
        let fields = try JSONDecoder().decode([String: String].self, from: Data(page.items[0].overview.utf8))
        #expect(fields["mode"] == "discover"); #expect(fields["networks"] == "213"); #expect(fields["companies"] == nil)
        #expect(fields["genres"] == "18,80"); #expect(fields["from"] == "2020"); #expect(page.page == 4)
        filter.to = "2010"; #expect(!filter.isValid)
        filter.to = "hello"; #expect(!filter.isValid)
        filter.to = "2026"; filter.minRuntime = "150"; filter.maxRuntime = "90"; #expect(!filter.isValid)
    }
    @Test func errorsAreNotDisplayedAsEmptyResults() async {
        do { _ = try await TMDBCatalog.search(query: "fail", session: session()); Issue.record("Expected HTTP failure") }
        catch let error as TMDBMatch.Failure { #expect(error.code == "http"); #expect(error.message == "HTTP 429") }
        catch { Issue.record("Unexpected error: \(error)") }
    }
    @Test func personProfileKeepsDateAndContributionsAndRequestsTheCorrectID() async throws {
        let person = try await TMDBCatalog.person(9280, language: "zh-CN", session: session())
        #expect(person.id == 9280); #expect(person.name == "zh-CN")
        #expect(person.works[0].date == "2025-03-19")
        #expect(person.works[0].departments == ["Acting", "Production"])
        #expect(person.works[0].roles == ["Lead", "Producer"])
        #expect(person.works[0].id == "movie:1")
    }
    @Test func oldCachedDetailsWithoutNavigationIDsStillDecode() throws {
        let decoder = JSONDecoder()
        let person = try decoder.decode(TMDBMatch.Person.self, from: Data(#"{"name":"Actor"}"#.utf8))
        let studio = try decoder.decode(TMDBMatch.Studio.self, from: Data(#"{"name":"Studio"}"#.utf8))
        #expect(person.id == nil); #expect(studio.id == nil); #expect(studio.kind == nil)
    }

}

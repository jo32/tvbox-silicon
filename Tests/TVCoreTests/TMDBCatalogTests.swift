import Foundation
import Testing
@testable import TVCore

private final class CatalogProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
        let value = Dictionary(query.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        let denied = value["feed"] == "kids"
        let body: String
        if url.path.hasSuffix("/catalog/collections") {
            body = #"{"people":[{"id":3,"name":"Person","profile":null,"works":[]}],"networks":[{"feed":"netflix","name":"Netflix","logo":null}],"companies":[]}"#
        } else {
            body = #"""
            {"items":[{"id":7,"mediaType":"tv","name":"\#(value["language"] ?? "")","originalName":"Series","year":null,"overview":"\#(url.path)","poster":null,"backdrop":null,"rating":null,"genreIDs":[16]},
                      {"id":7,"mediaType":"movie","name":"Film","originalName":"Film","year":2026,"overview":"","poster":"https://image.tmdb.org/t/p/w500/a.jpg","backdrop":null,"rating":8.5,"genreIDs":[]}],
             "page":\#(value["page"] ?? "1"),"totalPages":4}
            """#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: denied ? 429 : 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct TMDBCatalogTests {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test func pagePreservesLanguagePaginationAndTypedIdentities() async throws {
        let value = try await TMDBCatalog.page(.trending, page: 3, language: "ja-JP", session: session())
        #expect(value.page == 3)
        #expect(value.totalPages == 4)
        #expect(value.items.map(\.key) == ["tv:7", "movie:7"])
        #expect(value.items[0].name == "ja-JP")
        #expect(value.items[0].overview == "/v1/catalog")
        #expect(value.items[0].poster == nil)
        #expect(value.items[0].rating == nil)
        #expect(value.items[1].rating == 8.5)
    }

    @Test func failedListsThrowRatherThanBecomeEmptySuccesses() async throws {
        do {
            _ = try await TMDBCatalog.page(.kids, session: session())
            Issue.record("Expected the rate limit to surface")
        } catch let failure as TMDBMatch.Failure {
            #expect(failure.code == "http")
            #expect(failure.message == "HTTP 429")
        }
    }

    @Test func collectionsDecodePeopleAndBoundedBrandDestinations() async throws {
        let value = try await TMDBCatalog.collections(session: session())
        #expect(value.people.first?.id == 3)
        #expect(value.networks.first?.feed == .netflix)
        #expect(value.companies.isEmpty)
    }
}

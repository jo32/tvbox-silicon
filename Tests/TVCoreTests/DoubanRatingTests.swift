import Foundation
import Testing
@testable import TVCore

@Suite struct DoubanRatingTests {
    @Test func readsTheIDWikidataGives() {
        let json = #"{"head":{"vars":["d"]},"results":{"bindings":[{"d":{"type":"literal","value":"1889243"}}]}}"#
        #expect(DoubanRating.parseID(Data(json.utf8)) == "1889243")
    }

    @Test func noRowMeansNoID() {
        let json = #"{"results":{"bindings":[]}}"#
        #expect(DoubanRating.parseID(Data(json.utf8)) == nil)
        #expect(DoubanRating.parseID(Data("not json".utf8)) == nil)
    }

    @Test func anIDThatIsNotDigitsIsRefused() {
        let json = #"{"results":{"bindings":[{"d":{"value":"12/../x"}}]}}"#
        #expect(DoubanRating.parseID(Data(json.utf8)) == nil)
    }

    @Test func readsTheScoreAndCount() {
        let json = #"{"title":"x","rating":{"count":2238783,"max":10,"star_count":4.5,"value":9.4}}"#
        #expect(DoubanRating.parseScore(Data(json.utf8)) == DoubanRating.Score(value: 9.4, count: 2238783))
    }

    @Test func fewRatingsAndNoScoreSayNothing() {
        #expect(DoubanRating.parseScore(Data(#"{"rating":{"count":3,"value":9.9}}"#.utf8)) == nil)
        #expect(DoubanRating.parseScore(Data(#"{"rating":{"count":0,"value":0}}"#.utf8)) == nil)
        #expect(DoubanRating.parseScore(Data(#"{"rating":null}"#.utf8)) == nil)
    }

    @Test func acceptsOnlyTheMatchingWorkOrItsFirstSeason() throws {
        let json = #"""
        {"title":"法警小队 第一季","original_title":"Marshals Season 1",
         "type":"tv","year":"2026","rating":{"value":6.4,"count":123}}
        """#
        let subject = try JSONDecoder().decode(DoubanRating.Subject.self, from: Data(json.utf8))
        #expect(subject.matches(titles: ["法警小队"], year: 2026, mediaType: .tv))
        #expect(subject.matches(titles: ["marshals"], year: 2026, mediaType: .tv))
        #expect(!subject.matches(titles: ["marshals"], year: 2025, mediaType: .tv))
        #expect(!subject.matches(titles: ["marshals"], year: 2026, mediaType: .movie))
        #expect(!subject.matches(titles: ["another title"], year: 2026, mediaType: .tv))
        #expect(subject.score == DoubanRating.Score(value: 6.4, count: 123, season: 1))

        let secondSeason = json.replacingOccurrences(of: "第一季", with: "第二季")
            .replacingOccurrences(of: "Season 1", with: "Season 2")
        let sequel = try JSONDecoder().decode(DoubanRating.Subject.self, from: Data(secondSeason.utf8))
        #expect(!sequel.matches(titles: ["marshals season 2"], year: 2026, mediaType: .tv))
    }

    @Test func switchingSeasonsUsesSeparateScoresAndNeverFallsBackToAnotherSeason() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SeasonRatingProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let id = Int.random(in: 100_000_000..<Int.max)

        for (number, expected) in [(1, 6.4), (2, 8.1)] {
            let score = await DoubanRating.seasonScore(tmdbID: id, name: "法警小队", originalName: "Marshals",
                                                       season: number, year: 2026, session: session)
            #expect(score == DoubanRating.Score(value: expected, count: 123, season: number))
        }
        #expect(await DoubanRating.seasonScore(tmdbID: id, name: "法警小队", originalName: "Marshals",
                                               season: 3, year: 2026, session: session) == nil)
        #expect(await DoubanRating.seasonScore(tmdbID: id, name: "法警小队", originalName: "Marshals",
                                               season: 2, year: 2025, session: session) == nil)
        #expect(DoubanRating.cachedScore(tmdbID: id, mediaType: .tv) == nil)
    }

    @Test func acceptsOnlyNumericIDsAndDoubanSubjectLinks() {
        #expect(DoubanRating.subjectID("38377058") == "38377058")
        #expect(DoubanRating.subjectID("https://movie.douban.com/subject/38377058/?x=1") == "38377058")
        #expect(DoubanRating.subjectID("https://m.douban.com/tv/subject/38377058/") == "38377058")
        #expect(DoubanRating.subjectID("https://movie.douban.com.example/subject/38377058/") == nil)
        #expect(DoubanRating.subjectID("https://movie.douban.com/celebrity/38377058/") == nil)
        #expect(DoubanRating.subjectID("１２３") == nil)
    }

    @Test func resolvesSourceSeasonsAndExplicitIDsWithoutTMDB() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SeasonRatingProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let second = Video(id: "source-2", name: "法警小队 第2季", year: "2026", category: "电视剧")
        let match = try await DoubanRating.sourceMatch(second, listVideo: second, key: UUID().uuidString, session: session)
        #expect(match?.id == "2")
        #expect(match?.score == DoubanRating.Score(value: 8.1, count: 123, season: 2))

        let origin = URL(string: "https://example.com")!
        let supplied = try #require(Video(json: ["vod_id": .string("foo"), "vod_douban_url": .string(
            "https://movie.douban.com/subject/2/")], origin: origin))
        #expect(supplied.doubanID == "2")
        let direct = try await DoubanRating.sourceMatch(supplied, listVideo: supplied, key: UUID().uuidString, session: session)
        #expect(direct?.id == "2")
        #expect(direct?.season == 2)

        let wrong = Video(id: "source-3", name: second.name, year: "2025")
        let key = UUID().uuidString
        #expect(try await DoubanRating.sourceMatch(wrong, listVideo: wrong, key: key, session: session) == nil)
        let selection = try #require(direct)
        DoubanRating.choose(selection, for: key)
        defer { UserDefaults.standard.removeObject(forKey: "douban.subject-choices.\(key)") }
        #expect(DoubanRating.chosenSubject(for: key) == selection.id)
        #expect(try await DoubanRating.sourceMatch(wrong, listVideo: wrong, key: key, session: session) == selection)
    }
}

private final class SeasonRatingProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let body: String
        switch (url.host(), url.path()) {
        case ("www.douban.com", "/j/search_suggest"):
            body = #"""
            {"cards":[{"type":"movie","url":"https://movie.douban.com/subject/1"},
                      {"type":"movie","url":"https://movie.douban.com/subject/2"},
                      {"type":"movie","url":"https://movie.douban.com/subject/3"}]}
            """#
        case ("m.douban.com", "/rexxar/api/v2/tv/1"):
            body = #"{"title":"法警小队 第一季","type":"tv","year":"2026","rating":{"value":6.4,"count":123}}"#
        case ("m.douban.com", "/rexxar/api/v2/tv/2"), ("m.douban.com", "/rexxar/api/v2/movie/2"):
            body = #"{"title":"法警小队 第二季","type":"tv","year":"2026","rating":{"value":8.1,"count":123}}"#
        case ("m.douban.com", "/rexxar/api/v2/tv/3"):
            body = #"{"title":"另一部剧 第二季","type":"tv","year":"2026","rating":{"value":9.0,"count":123}}"#
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

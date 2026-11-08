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
}

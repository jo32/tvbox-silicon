import Foundation
import Testing
@testable import TVCore

private func json(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }

/// FongMi's new-SDK spiders (#500) answer a play `url` as FongMi's Url object: every quality, and the one to play.
@Test func fongMiURLObjectListsEveryQualityStartingWithItsPosition() throws {
    let url = try json(#"{"values":[{"n":"4K 超清","v":"https://cdn.example.com/4k.mp4"},{"n":"1080P","v":"https://cdn.example.com/1080.mp4"},{"n":"","v":" "},{"n":"","v":"https://cdn.example.com/720.mp4"}],"position":1}"#)
    let choices = PlaybackChoice.parse(url, prefix: "", fallbackName: "第1集")
    #expect(choices.map(\.address) == ["https://cdn.example.com/1080.mp4", "https://cdn.example.com/4k.mp4", "https://cdn.example.com/720.mp4"])
    #expect(choices.map(\.name) == ["1080P", "4K 超清", "第1集"])
    #expect(choices.map(\.id) == [0, 1, 2])

    let unplaced = try json(#"{"values":[{"n":"高清","v":"https://cdn.example.com/a.m3u8"}],"position":9}"#)
    #expect(PlaybackChoice.parse(unplaced, prefix: "parse:", fallbackName: "x").map(\.address) == ["parse:https://cdn.example.com/a.m3u8"])
    #expect(PlaybackChoice.parse(try json(#"{"url":"https://cdn.example.com/a.mp4"}"#), fallbackName: "x").isEmpty)
}

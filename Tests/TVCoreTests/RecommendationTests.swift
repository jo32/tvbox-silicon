import Foundation
import Testing
@testable import TVCore

@Test func realIndexRecommendationsDoNotRequirePlaybackIDs() throws {
    let origin = URL(string: "https://example.com/config.json")!
    let url = try #require(Bundle.module.url(forResource: "recommendations", withExtension: "json", subdirectory: "Fixtures"))
    let raw = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
    let entries = try #require(raw["list"]?.array)
    let items = entries.compactMap { $0.object.flatMap { Recommendation(json: $0, origin: origin, isIndex: true) } }
    #expect(items.count == 3)
    #expect(items[1].name == "兰香如故")
    #expect(items[1].destination == .search("兰香如故"))
    #expect(items[1].poster?.url.path.hasSuffix(".jpg") == true)
    #expect(items[1].poster?.headers["Referer"] == "https://api.douban.com/")
    #expect(items[1].poster?.headers["User-Agent"]?.hasPrefix("Mozilla/") == true)
    // Ranking cards must not fabricate an ID and try to call a detail endpoint.
    #expect(CatalogPage(json: raw, origin: origin).videos.isEmpty)
}

@Test func recommendationsRouteIndexTitlesAndRealVideoIDsSeparately() throws {
    let origin = URL(string: "https://example.com/config.json")!
    let json: [String: JSONValue] = ["vod_id": .string("real-id"), "vod_name": .string("Movie")]
    let ranking = try #require(Recommendation(json: json, origin: origin, isIndex: true))
    #expect(ranking.destination == .search("Movie"))
    let playable = try #require(Recommendation(json: json, origin: origin, isIndex: false))
    guard case .detail(let video) = playable.destination else { Issue.record("Playable recommendation lost its detail route"); return }
    #expect(video.id == "real-id")
    #expect(Recommendation(json: ["vod_name": .string(" ")], origin: origin, isIndex: true) == nil)
    #expect(Recommendation(json: ["vod_name": .string("Settings"), "action": .string("configure")], origin: origin, isIndex: true) == nil)
}

@Test func posterHeaderSuffixPreservesURLAndTransportHeaders() throws {
    let origin = URL(string: "https://example.com/config.json")!
    let poster = try #require(PosterResource(address: "/art/@2x.jpg@Referer=https://origin.example/@User-Agent=Example Agent@Cookie=id=1", origin: origin))
    #expect(poster.url.absoluteString == "https://example.com/art/@2x.jpg")
    #expect(poster.headers["Referer"] == "https://origin.example/")
    #expect(poster.headers["User-Agent"] == "Example Agent")
    #expect(poster.headers["Cookie"] == "id=1")
    let plain = try #require(PosterResource(address: "/image@2x.jpg", origin: origin))
    #expect(plain.url.path == "/image@2x.jpg")
    #expect(plain.headers.isEmpty)
    let json = try #require(PosterResource(address: #"/image.jpg@Headers={"Referer":"https://example.org/","User-Agent":"Custom"}"#, origin: origin))
    #expect(json.headers["Referer"] == "https://example.org/")
}

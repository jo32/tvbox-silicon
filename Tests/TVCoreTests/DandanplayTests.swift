import Foundation
import Testing
@testable import TVCore

@Test func dandanplaySignatureUsesPathWithoutQueryAndNeverSendsSecret() {
    let credentials = DandanplayCredentials(appId: "test-app", appSecret: "test-secret")
    var request = URLRequest(url: URL(string: "https://api.dandanplay.net/api/v2/search/anime?keyword=test")!)
    credentials.sign(&request, timestamp: 1_735_660_800)
    #expect(request.value(forHTTPHeaderField: "X-AppId") == "test-app")
    #expect(request.value(forHTTPHeaderField: "X-Timestamp") == "1735660800")
    #expect(request.value(forHTTPHeaderField: "X-Signature") == "by3qBixv6/Q+lA3PE55Mys/52PRs2qWDD+OWwQlm7Ac=")
    #expect(request.value(forHTTPHeaderField: "X-AppSecret") == nil)
    for address in ["http://api.dandanplay.net/api/v2/search/anime", "https://example.com/api/v2/search/anime",
                    "https://api.dandanplay.net.example.com/api/v2/search/anime", "https://api.dandanplay.net:8443/api/v2/search/anime"] {
        var custom = URLRequest(url: URL(string: address)!)
        credentials.sign(&custom)
        #expect(custom.value(forHTTPHeaderField: "X-AppId") == nil)
        #expect(custom.value(forHTTPHeaderField: "X-Signature") == nil)
    }
}

@Test func dandanplayClientSignsOfficialRequestsButKeepsCustomServersIndependent() async throws {
    let credentials = DandanplayCredentials(appId: "test-app", appSecret: "test-secret")
    let transport = DanmakuHTTP { request in
        let official = request.url?.host == "api.dandanplay.net"
        #expect((request.value(forHTTPHeaderField: "X-AppId") != nil) == official)
        #expect((request.value(forHTTPHeaderField: "X-Signature") != nil) == official)
        return Data(#"{"success":true,"animes":[{"animeId":17617,"animeTitle":"葬送的芙莉莲"}]}"#.utf8)
    }
    for address in [CatalogDanmakuClient.defaultServer, CatalogDanmakuClient.legacyDefaultServer, "https://custom.test/prefix"] {
        let client = try CatalogDanmakuClient(address: address, transport: transport, credentials: credentials)
        #expect(try await client.search("葬送的芙莉莲").first?.id == "17617")
    }
    let missing = try CatalogDanmakuClient(transport: DanmakuHTTP { _ in
        Issue.record("An unconfigured official request must fail before transport")
        return Data()
    }, credentials: nil)
    await #expect(throws: (any Error).self) { try await missing.search("test") }
}

@Test func dandanplayCommentRedirectsOnlyToItsCDNWithoutAPIHeaders() throws {
    var request = URLRequest(url: URL(string: "https://cas2.dandanplay.net/api/comment/176170001?sign=server-token")!)
    request.setValue("signature", forHTTPHeaderField: "X-Signature")
    request.setValue("test-app", forHTTPHeaderField: "X-AppId")
    let redirected = try #require(DandanplayRedirectPolicy.sanitized(request))
    #expect(redirected.value(forHTTPHeaderField: "X-Signature") == nil)
    #expect(redirected.value(forHTTPHeaderField: "X-AppId") == nil)
    #expect(redirected.url?.query == "sign=server-token")
    for address in ["https://evil.test/comment", "http://cas2.dandanplay.net/comment", "https://cas2.dandanplay.net.evil.test/comment"] {
        request.url = URL(string: address)
        #expect(DandanplayRedirectPolicy.sanitized(request) == nil)
    }
}

/// Explicit opt-in: never consumes API quota during ordinary test runs.
@Test(.enabled(if: ProcessInfo.processInfo.environment["DANDANPLAY_LIVE_CONFIG"] != nil))
func dandanplayLiveSearchEpisodesAndComments() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["DANDANPLAY_LIVE_CONFIG"])
    let credentials = try JSONDecoder().decode(DandanplayCredentials.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    let client = try CatalogDanmakuClient(transport: .init(), credentials: credentials)
    let anime = try #require(try await client.search("葬送的芙莉莲").first { $0.title == "葬送的芙莉莲" })
    let episodes = try await client.episodes(anime)
    let episode = try #require(CatalogDanmakuMatcher.episode(name: "第1集", in: episodes))
    let comments = try await client.comments(episode)
    #expect(!comments.isEmpty)
    print("Dandanplay live: \(episodes.count) episodes, \(comments.count) parsed comments")
}

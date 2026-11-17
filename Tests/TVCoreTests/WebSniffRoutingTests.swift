import Foundation
import Testing
@testable import TVCore

private final class RoutingProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!.absoluteString
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let play = items.first { $0.name == "play" }?.value ?? ""
        let body: String
        switch play {
        case "page": body = #"{"parse":1,"url":"https://fixture.test/player.html","click":"result-click"}"#
        case "embedded": body = #"{"parse":1,"url":"https://fixture.test/embedded.html"}"#
        case "json": body = #"{"parse":1,"playUrl":"json:https://fixture.test/only?url=","url":"PAGE"}"#
        case "json-empty": body = #"{"parse":1,"playUrl":"json:https://fixture.test/empty?url=","url":"PAGE"}"#
        case "named-json": body = #"{"parse":1,"playUrl":"parse:json","url":"PAGE"}"#
        case "named-web": body = #"{"parse":1,"playUrl":"parse:web","url":"PAGE"}"#
        case "named-jar": body = #"{"parse":1,"playUrl":"parse:jar","url":"PAGE"}"#
        case "named-missing": body = #"{"parse":1,"playUrl":"parse:missing","url":"PAGE"}"#
        case "super": body = #"{"parse":1,"playUrl":"parse:super","url":"https://page.example/v"}"#
        case "direct": body = #"{"parse":0,"url":"https://cdn.example/direct.m3u8"}"#
        default:
            if url.contains("/only") { body = #"{"url":"https://cdn.example/from-json.m3u8"}"# }
            else if url.contains("/empty") { body = #"{"url":""}"# }
            else if url.contains("/named-json") { body = #"{"data":{"url":"https://cdn.example/named.m3u8"}}"# }
            else if url.contains("embedded.html") { body = #"<script>var player_aaaa={"encrypt":0,"url":"https://cdn.example/embedded.m3u8"};</script>"# }
            else { body = "<html>no media</html>" }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Type 4 calls this from several tasks at once, so every field is behind the lock.
private final class RecordingSniffer: WebSniffing, @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [String] = []
    private var _clicks: [String] = []
    private var _detects: [Bool] = []
    private var running = 0
    private var _mostAtOnce = 0
    var answer: URL?
    var delay: Duration = .zero
    var urls: [String] { lock.withLock { _urls } }
    var clicks: [String] { lock.withLock { _clicks } }
    var detects: [Bool] { lock.withLock { _detects } }
    var mostAtOnce: Int { lock.withLock { _mostAtOnce } }
    func sniff(url: String, headers: [String: String], click: String, detect: Bool, ads: [String], rules: [SniffRule]) async -> (url: URL, headers: [String: String])? {
        lock.withLock {
            _urls.append(url); _clicks.append(click); _detects.append(detect)
            running += 1; _mostAtOnce = max(_mostAtOnce, running)
        }
        if delay > .zero { try? await Task.sleep(for: delay) }
        lock.withLock { running -= 1 }
        return answer.map { ($0, ["Referer": "https://player.example/"]) }
    }
}

private func http() -> HTTPClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RoutingProtocol.self]
    return HTTPClient(session: URLSession(configuration: config))
}

private func catalog(play: String, click: String = "site-click", parses: [ParseService] = []) throws -> (CatalogClient, RecordingSniffer, Episode) {
    let base = URL(string: "https://fixture.test/config.json")!
    let site = Site(key: "a", name: "A", type: 4, api: "https://fixture.test/api", raw: ["key": .string("a"), "click": .string(click)])
    let sniffer = RecordingSniffer()
    let client = CatalogClient(site: site, origin: base, http: http()).with(parses: parses).with(sniffer: sniffer)
    let episode = Episode(id: "1", name: "Episode", address: play, flag: "线路1")
    return (client, sniffer, episode)
}

private let sniffError = "This source requires web video detection or additional parsing. Only resolved media URLs are supported."
private let sniffTimeout = "Video detection timed out before a playable address appeared."

/// A json: play address, a named JSON parser, media in the page and a direct address resolve without the sniffer.
@Test(arguments: [
    ("json", "https://cdn.example/from-json.m3u8"),
    ("named-json", "https://cdn.example/named.m3u8"),
    ("embedded", "https://cdn.example/embedded.m3u8"),
    ("direct", "https://cdn.example/direct.m3u8"),
])
func resolvedAddressesDoNotSniff(_ play: String, _ expected: String) async throws {
    let parses = play == "named-json" ? [ParseService(name: "json", type: 1, url: "https://fixture.test/named-json?url=", headers: [:])] : []
    let (client, sniffer, episode) = try catalog(play: play, parses: parses)
    let channel = try await client.playback(episode)
    #expect(channel.url.absoluteString == expected)
    #expect(sniffer.urls.isEmpty)
}

@Test func jsonPlayURLDoesNotSniffWhenTheServiceIsEmpty() async throws {
    let (client, sniffer, episode) = try catalog(play: "json-empty")
    await #expect(throws: TVError.self) { try await client.playback(episode) }
    #expect(sniffer.urls.isEmpty)
    do { _ = try await client.playback(episode) } catch {
        #expect(error.localizedDescription == sniffError)
    }
}

@Test func namedWebParserSniffsItsOwnAddress() async throws {
    let parser = ParseService(name: "web", type: 0, url: "https://jx.example/player/?url=", headers: [:])
    let (client, sniffer, episode) = try catalog(play: "named-web", parses: [parser])
    sniffer.answer = URL(string: "https://cdn.example/sniffed.m3u8")
    let channel = try await client.playback(episode)
    #expect(sniffer.urls == ["https://jx.example/player/?url=PAGE"])
    #expect(sniffer.detects == [false])
    #expect(sniffer.clicks == ["site-click"])
    #expect(channel.url.absoluteString == "https://cdn.example/sniffed.m3u8")
}

@Test func jarParsersAndMissingNamesFailWithoutSniffing() async throws {
    let jar = ParseService(name: "jar", type: 2, url: "csp_Jar", headers: [:])
    let (jarClient, jarSniffer, jarEpisode) = try catalog(play: "named-jar", parses: [jar])
    await #expect(throws: TVError.self) { try await jarClient.playback(jarEpisode) }
    #expect(jarSniffer.urls.isEmpty)
    let (missingClient, missingSniffer, missingEpisode) = try catalog(play: "named-missing")
    await #expect(throws: TVError.self) { try await missingClient.playback(missingEpisode) }
    #expect(missingSniffer.urls.isEmpty)
}

@Test func type4UsesOnlyParsersWhoseFlagMatches() async throws {
    let parsers = [
        ParseService(name: "super", type: 4, url: "csp_Super", headers: [:]),
        ParseService(name: "match", type: 0, url: "https://match.example/?url=", headers: [:], flags: ["线路1"]),
        ParseService(name: "other", type: 0, url: "https://other.example/?url=", headers: [:], flags: ["其它"])
    ]
    let (client, sniffer, episode) = try catalog(play: "super", parses: parsers)
    sniffer.answer = URL(string: "https://cdn.example/super.m3u8")
    _ = try await client.playback(episode)
    #expect(sniffer.urls == ["https://match.example/?url=https://page.example/v"])
}

@Test func type4SniffsOnlyAFewWebParsersAtATime() async throws {
    let webs = (1...5).map { ParseService(name: "web\($0)", type: 0, url: "https://web\($0).example/?url=", headers: [:]) }
    let (client, sniffer, episode) = try catalog(play: "super", parses: [ParseService(name: "super", type: 4, url: "csp_Super", headers: [:])] + webs)
    sniffer.delay = .milliseconds(50)
    await #expect(throws: TVError.self) { try await client.playback(episode) }
    #expect(sniffer.urls.count == 5)
    #expect(sniffer.mostAtOnce == CatalogClient.superParseWebWidth)
}

@Test func anEmptyPlayURLSniffsThePageAfterTheFastPathFails() async throws {
    let (client, sniffer, episode) = try catalog(play: "page", click: "")
    sniffer.answer = URL(string: "https://cdn.example/page.m3u8")
    let channel = try await client.playback(episode)
    #expect(sniffer.urls == ["https://fixture.test/player.html"])
    #expect(sniffer.clicks == ["result-click"])
    #expect(channel.headers["Referer"] == "https://player.example/")
}

@Test func aSnifferThatFindsNothingReportsATimeout() async throws {
    let (client, _, episode) = try catalog(play: "page", click: "")
    do {
        _ = try await client.playback(episode)
        Issue.record("expected the sniff timeout")
    } catch {
        #expect(error.localizedDescription == sniffTimeout)
    }
}

@Test func noSnifferKeepsTheCurrentError() async throws {
    let base = URL(string: "https://fixture.test/config.json")!
    let site = Site(key: "a", name: "A", type: 4, api: "https://fixture.test/api", raw: ["key": .string("a")])
    let client = CatalogClient(site: site, origin: base, http: http())
    do {
        _ = try await client.playback(Episode(id: "1", name: "Episode", address: "page", flag: ""))
        Issue.record("expected the sniff error")
    } catch {
        #expect(error.localizedDescription == sniffError)
    }
}

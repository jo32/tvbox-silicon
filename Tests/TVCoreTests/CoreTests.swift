import Foundation
import Testing
@testable import TVCore

private let base = URL(string: "https://example.com/config/main.json")!
private func fixture(_ name: String, _ ext: String) throws -> Data {
    try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")))
}
@Test func realFantaiyingSubscription() throws {
    let config = try Subscription.parse(fixture("fantaiying", "json"), origin: URL(string: "https://raw.githubusercontent.com/qist/tvbox/master/fty.json")!)
    #expect(config.sites.count == 47)
    #expect(config.lives.count == 6)
    #expect(config.sites.allSatisfy { $0.type == 3 })
    #expect(config.sites.filter(\.native).isEmpty)
    #expect(config.spiderURL?.absoluteString == "https://raw.githubusercontent.com/qist/tvbox/master/jar/fan.txt")
    #expect(config.lives[1].headers["User-Agent"] == "bingcha/1.1 (mianfeifenxiang)")
    #expect(config.sites.first(where: { $0.key == "立播" })?.raw["ext"]?.object?["siteUrl"]?.string == "https://www.libvio.pw/")
}
@Test func persistedSubscriptionKeepsOriginAndOpaqueFields() throws {
    let config = try Subscription.parse(fixture("fantaiying", "json"), origin: base)
    let saved = try JSONEncoder().encode(config)
    let restored = try JSONDecoder().decode(Subscription.self, from: saved)
    #expect(restored.raw == config.raw)
    #expect(restored.origin == config.origin)
    #expect(restored.sites == config.sites)
}
@Test func flexibleTypesAndRelativeURLs() throws {
    let data = Data(#"{"sites":[{"key":"a","api":"./vod","type":"4"},{"key":"a","api":"duplicate","type":4}],"lives":[{"name":"Live","url":"../live.m3u"}]}"#.utf8)
    let config = try Subscription.parse(data, origin: base)
    #expect(config.sites.count == 1)
    #expect(config.sites[0].native)
    #expect(config.lives[0].url.absoluteString == "https://example.com/live.m3u")
}
@Test func invalidConfigurationsAndSchemesFail() throws {
    #expect(throws: (any Error).self) { try Subscription.parse(Data("{}".utf8), origin: base) }
    for value in ["", "file:///etc/passwd", "javascript:alert(1)", "ftp://example.com/a", "not a url"] {
        #expect(throws: (any Error).self) { try WebAddress.resolve(value) }
    }
}
@Test func m3uGroupsHeadersAndCommas() throws {
    let text = """
    #EXTM3U
    #EXTINF:-1 tvg-logo="../logo.png" group-title="News, Live",News One
    #EXTVLCOPT:http-user-agent=CustomPlayer
    #EXTVLCOPT:http-referrer=https://example.com/
    ../stream/news.m3u8
    #EXTINF:-1 group-title="Sports",Sports Two
    https://media.example.com/live.m3u8|User-Agent=TV%20App
    #EXTINF:-1,Invalid
    rtmp://example.com/live
    """
    let channels = try Playlist.parse(text, origin: base, headers: ["User-Agent": "Default"])
    #expect(channels.count == 2)
    #expect(channels[0].group == "News, Live")
    #expect(channels[0].name == "News One")
    #expect(channels[0].logo?.absoluteString == "https://example.com/logo.png")
    #expect(channels[0].headers["Referer"] == "https://example.com/")
    #expect(channels[1].headers["User-Agent"] == "TV App")
    #expect(channels[1].headers["Referer"] == nil)
}
@Test func txtGroupsAndDeduplication() throws {
    let text = "新闻,#genre#\n一台,https://example.com/1.m3u8\n一台,https://example.com/1.m3u8\n体育,#genre#\n二台,https://example.com/2.m3u8"
    let channels = try Playlist.parse(text, origin: base)
    #expect(channels.count == 2)
    #expect(channels[0].group == "新闻")
    #expect(channels[1].group == "体育")
    #expect(throws: (any Error).self) { try Playlist.parse("<html>502 Bad Gateway</html>", origin: base) }
}
@Test func apiQueryPreservesExistingAuthentication() throws {
    let config = try Subscription.parse(Data(#"{"sites":[{"key":"a","api":"https://example.com/api?token=abc&pg=99","type":4,"ext":{"foo":"中文"}}]}"#.utf8), origin: base)
    let client = CatalogClient(site: config.sites[0], origin: base)
    let url = try client.requestURL(["pg": "2", "wd": "a&b + 中文"])
    let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(items.filter { $0.name == "pg" }.count == 1)
    #expect(items.first { $0.name == "token" }?.value == "abc")
    #expect(items.first { $0.name == "wd" }?.value == "a&b + 中文")
    let ext = try #require(items.first { $0.name == "extend" }?.value)
    #expect(try JSONDecoder().decode([String: String].self, from: Data(ext.utf8)) == ["foo": "中文"])
}
@Test func pluginCannotAccidentallyBeCalledAsHTTP() throws {
    let config = try Subscription.parse(fixture("fantaiying", "json"), origin: base)
    #expect(throws: (any Error).self) { try CatalogClient(site: config.sites[0], origin: base).requestURL([:]) }
}
@Test func episodeFlagsAndNumericVideoIDs() throws {
    let json = try JSONDecoder().decode([String: JSONValue].self, from: Data(#"{"vod_id":123,"vod_name":"Film","vod_play_from":"A$$$B","vod_play_url":"E1$https://e.com/1.m3u8#E2$https://e.com/2.m3u8$$$Main$opaque-id","vod_content":"<p>Hello</p>"}"#.utf8))
    let video = try #require(Video(json: json, origin: base))
    #expect(video.id == "123")
    #expect(video.episodes.count == 3)
    #expect(video.episodes[2].flag == "B")
    #expect(video.episodes[2].address == "opaque-id")
    #expect(video.synopsis == "Hello")
}
@Test func synopsisDecodesDoubleEscapedEntities() {
    #expect(HTMLText.plain("该剧改编。 &amp;nbsp; &amp;nbsp;&amp;nbsp") == "该剧改编。")
    #expect(HTMLText.plain("<p>Tom &amp;amp; Jerry&#39;s &ldquo;day&rdquo;</p><br/>Part&#x20;2") == "Tom & Jerry's “day”\nPart 2")
    #expect(HTMLText.plain("R&D &unknown; a&b") == "R&D &unknown; a&b")
}
@Test func dexJarActuallyExecutesBytecode() async throws {
    let runtime = JarRuntime()
    let jar = try fixture("runtime-probe", "jar")
    let report = await runtime.inspect(jar)
    #expect(report.status == 0)
    #expect(report.dexFiles == 1)
    #expect(report.classes == 1)
    let run = await runtime.runStaticInt(jar, className: "Ltvbox/RuntimeProbe;", method: "run")
    #expect(run.status == 0, "\(run.message)")
    #expect(run.value == 42)
    #expect(run.instructions > 10)
}
@Test func interpreterStopsInfiniteLoop() async throws {
    let result = await JarRuntime().runStaticInt(try fixture("runtime-probe", "jar"), className: "Ltvbox/RuntimeProbe;", method: "forever")
    #expect(result.status != 0)
    #expect(result.message.contains("BUDGET") || result.message.contains("CANCELLED"))
}
@Test func malformedJarFailsWithoutExecution() async {
    let report = await JarRuntime().inspect(Data("not a jar".utf8))
    #expect(report.status != 0)
    #expect(report.instructions == 0)
}
@Test func nativeLibrariesAreRejectedBeforeCodeRuns() async throws {
    let result = await JarRuntime().runStaticInt(try fixture("native-probe", "jar"), className: "Ltvbox/RuntimeProbe;", method: "run")
    #expect(result.nativeLibraries == 1)
    #expect(result.status == 1001)
    #expect(result.instructions == 0)
}

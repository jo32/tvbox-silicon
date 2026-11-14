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
@Test func typedAddressesForgiveMissingSchemeAndFullWidthPunctuation() throws {
    #expect(try WebAddress.resolve(typed: "example.com/config.json").absoluteString == "http://example.com/config.json")
    #expect(try WebAddress.resolve(typed: " 192.168.1.5:8080/a?x=1 \n").absoluteString == "http://192.168.1.5:8080/a?x=1")
    #expect(try WebAddress.resolve(typed: "https：／／example.com／a.json").absoluteString == "https://example.com/a.json")
    #expect(try WebAddress.resolve(typed: "https://example.com/a").absoluteString == "https://example.com/a")
    for value in ["", "file:///etc/passwd", "javascript:alert(1)", "ftp://example.com/a", "not a url", "example", "example.com /a"] {
        #expect(throws: (any Error).self) { try WebAddress.resolve(typed: value) }
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
/// #995: "我的电视" (APTV-style) sets `http-user-agent` on the #EXTINF line; its CCTV1 server answers 404 to any other agent.
@Test func m3uHeadersOnTheEntryLine() throws {
    let text = """
    #EXTM3U x-tvg-url="http://example.com/e.xml"
    #EXTINF:-1 tvg-name="CCTV1" http-user-agent="AptvPlayer-UA" group-title="央视频道",CCTV1
    http://example.com/live.php?id=CCTV1
    #EXTINF:-1 http-referrer="https://example.com/" group-title="News",News
    https://example.com/news.m3u8
    #EXTINF:-1 http-user-agent="Entry" group-title="News",Overridden
    #EXTVLCOPT:http-user-agent=Option
    https://example.com/other.m3u8
    #EXTINF:-1 group-title="News",Plain
    https://example.com/plain.m3u8
    """
    let channels = try Playlist.parse(text, origin: base, headers: ["User-Agent": "Default"])
    #expect(channels.map(\.headers["User-Agent"]) == ["AptvPlayer-UA", "Default", "Option", "Default"])
    #expect(channels.map(\.headers["Referer"]) == [nil, "https://example.com/", nil, nil])
    #expect(channels[0].group == "央视频道")
}
@Test func txtGroupsAndDeduplication() throws {
    let text = "新闻,#genre#\n一台,https://example.com/1.m3u8\n一台,https://example.com/1.m3u8\n体育,#genre#\n二台,https://example.com/2.m3u8"
    let channels = try Playlist.parse(text, origin: base)
    #expect(channels.count == 2)
    #expect(channels[0].group == "新闻")
    #expect(channels[1].group == "体育")
    #expect(throws: (any Error).self) { try Playlist.parse("<html>502 Bad Gateway</html>", origin: base) }
}
/// #679: a channel listed again in its group, or with TVBox's `url1#url2`, is one channel with several lines.
@Test func repeatedChannelsBecomeLinesOfOne() throws {
    let text = """
    央视,#genre#
    CCTV1,https://a.example.com/1.m3u8
    CCTV1,https://b.example.com/1.m3u8$备用|Referer=https://b.example.com/
    CCTV2,https://a.example.com/2.m3u8#https://b.example.com/2.m3u8$高清#https://a.example.com/2.m3u8
    CCTV1,https://a.example.com/1.m3u8
    卫视,#genre#
    CCTV1,https://c.example.com/1.m3u8
    Fragment,https://a.example.com/live.m3u8#t=1
    """
    let channels = try Playlist.parse(text, origin: base, headers: ["User-Agent": "Default"])
    #expect(channels.map(\.name) == ["CCTV1", "CCTV2", "CCTV1", "Fragment"])
    #expect(channels[0].alternates == [ChannelLine(url: URL(string: "https://b.example.com/1.m3u8")!,
                                                   headers: ["User-Agent": "Default", "Referer": "https://b.example.com/"])])
    #expect(channels[0].headers == ["User-Agent": "Default"])
    #expect(channels[0].lines.map(\.url.host) == ["a.example.com", "b.example.com"])
    #expect(channels[1].lines.map(\.url.absoluteString) == ["https://a.example.com/2.m3u8", "https://b.example.com/2.m3u8"])
    #expect(channels[2].group == "卫视" && channels[2].alternates.isEmpty)
    #expect(channels[3].url.absoluteString == "https://a.example.com/live.m3u8#t=1")
    // M3U too, by name within the group.
    let m3u = try Playlist.parse("""
    #EXTM3U
    #EXTINF:-1 group-title="News",News
    https://a.example.com/news.m3u8
    #EXTINF:-1 group-title="News" http-user-agent="Other",News
    https://b.example.com/news.m3u8
    """, origin: base)
    #expect(m3u.count == 1 && m3u[0].alternates.map(\.headers["User-Agent"]) == ["Other"])
}

/// #1010: Previous and Next Channel go round the list the channel was picked from.
@Test func liveLineupGoesRoundItsChannels() {
    let channels = ["一", "二", "三"].map { Channel(name: $0, group: "G", url: URL(string: "https://example.com/\($0.unicodeScalars.first!.value)")!) }
    let lineup = LiveLineup(title: "List", channels: channels)
    #expect(lineup.neighbor(of: channels[0], back: false)?.name == "二")
    #expect(lineup.neighbor(of: channels[0], back: true)?.name == "三")
    #expect(lineup.neighbor(of: channels[2], back: false)?.name == "一")
    #expect(lineup.position(of: channels[1]) == 1)
    let stranger = Channel(name: "四", group: "G", url: URL(string: "https://example.com/4")!)
    #expect(lineup.position(of: stranger) == nil && lineup.neighbor(of: stranger, back: false) == nil)
    #expect(LiveLineup(title: "One", channels: [channels[0]]).neighbor(of: channels[0], back: false) == nil)
}

/// A favorite saved before channels had lines still opens, and one with lines keeps them.
@Test func channelLinesAreSavedAndOptional() throws {
    let old = #"{"name":"CCTV1","group":"央视","url":"https://a.example.com/1.m3u8","headers":{}}"#
    let decoded = try JSONDecoder().decode(Channel.self, from: Data(old.utf8))
    #expect(decoded.alternates.isEmpty && decoded.lines.count == 1)
    var channel = Channel(name: "CCTV1", group: "央视", url: URL(string: "https://a.example.com/1.m3u8")!)
    channel.alternates = [ChannelLine(url: URL(string: "https://b.example.com/1.m3u8")!, headers: ["Referer": "x"])]
    let again = try JSONDecoder().decode(Channel.self, from: JSONEncoder().encode(channel))
    #expect(again == channel && again.lines[1].headers == ["Referer": "x"] && again.lines[1].name == "CCTV1")
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
@Test func driveFoldersOpenAsListings() throws {
    // csp_AList (小雅 drives) lists folders and files with vod_tag "folder" / "file".
    let folder = try #require(Video(json: ["vod_id": .string("小雅/电影/2024"), "vod_name": .string("2024"), "vod_tag": .string("folder")], origin: base))
    let file = try #require(Video(json: ["vod_id": .string("小雅/电影/a.mkv"), "vod_name": .string("a.mkv"), "vod_tag": .string("file")], origin: base))
    let film = try #require(Video(json: ["vod_id": .string("1"), "type_name": .string("剧情"), "vod_class": .string("动作")], origin: base))
    #expect(folder.isFolder)
    #expect(!file.isFolder)
    #expect(!film.isFolder)
}
@Test func synopsisDecodesDoubleEscapedEntities() {
    #expect(HTMLText.plain("该剧改编。 &amp;nbsp; &amp;nbsp;&amp;nbsp") == "该剧改编。")
    #expect(HTMLText.plain("<p>Tom &amp;amp; Jerry&#39;s &ldquo;day&rdquo;</p><br/>Part&#x20;2") == "Tom & Jerry's “day”\nPart 2")
    #expect(HTMLText.plain("R&D &unknown; a&b") == "R&D &unknown; a&b")
}
@Test func synopsisDropsOnlyLayoutLabelLines() {
    // A line that holds only a 线路 label or a quality word is page layout, not plot.
    #expect(HTMLText.synopsis("<p>一段正经剧情。</p><br>播放线路1<br>高清线路二<br>蓝光<br>1080P<br>线路：") == "一段正经剧情。")
    #expect(HTMLText.synopsis("4K") == "")
    // The provider's own text stays, its promotion and addresses included.
    #expect(HTMLText.synopsis("《xxx》讲述了……<br>最新网址 http://abc.com<br>线路1<br>永久域名 www.xyz.net")
            == "《xxx》讲述了……\n最新网址 http://abc.com\n永久域名 www.xyz.net")
    for plot in ["他按照信上的地址找到了失散多年的妹妹。", "一名弹幕网站的UP主卷入风波。", "线路是他唯一的退路",
                 "Adam.Smith.Jr returns to Boston.\nA 1080p remaster of the 1999 film.", "主角历经磨难，最终成长。"] {
        #expect(HTMLText.synopsis(plot) == plot)
    }
    // A plugin's config center address must survive: ConfigCenter reads it from the synopsis (#360).
    #expect(HTMLText.synopsis("请打开网页版配置中心：http://192.168.1.5:19988/config") == "请打开网页版配置中心：http://192.168.1.5:19988/config")
    #expect(HTMLText.synopsis("手机扫码打开：http://127.0.0.1:52380/website") == "手机扫码打开：http://127.0.0.1:52380/website")
}

@Test func namesDecodeEntitiesWithoutStrippingText() {
    #expect(HTMLText.name("宝可梦 太阳&amp;月亮 第三季") == "宝可梦 太阳&月亮 第三季")
    #expect(HTMLText.name("I &lt;3 &amp;amp; you") == "I <3 & you")
    #expect(HTMLText.name("  A\u{3000}\u{3000}B ") == "A B")
    let video = Video(json: ["vod_id": .string("1"), "vod_name": .string("Tom &amp; Jerry"), "vod_play_url": .string("第1集 &amp; 序$https://e.com/1.m3u8")],
                      origin: URL(string: "https://e.com")!)
    #expect(video?.name == "Tom & Jerry")
    #expect(video?.episodes.first?.name == "第1集 & 序")
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

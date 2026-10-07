import Foundation
import Testing
@testable import TVCore

@Test func chineseSubscriptionURLsNormalizeWithoutLosingPathsOrQueries() throws {
    let url = try WebAddress.resolve(" \nhttp://肥猫.net/中文/配置.json?名=值%26二\t")
    #expect(url.host == "xn--z7x900a.net")
    #expect(url.path == "/中文/配置.json")
    #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "值&二")
    #expect(try WebAddress.resolve("http://肥猫.net/") == WebAddress.resolve("http://xn--z7x900a.net/"))
    let relative = try WebAddress.resolve("../插件.jar", relativeTo: url)
    #expect(relative.host == "xn--z7x900a.net")
    #expect(relative.path == "/插件.jar")
    #expect(try WebAddress.resolve("https://我不是.摸鱼儿.top/接口").host == "xn--ihqu10cn4c.xn--v4q818bf34b.top")
    let encoded = try WebAddress.resolve("https://肥猫.net/中%2F文?x=%2526&y=100%&z=hello+world#中文")
    let components = try #require(URLComponents(url: encoded, resolvingAgainstBaseURL: false))
    #expect(components.percentEncodedPath == "/%E4%B8%AD%2F%E6%96%87")
    #expect(components.queryItems?.map(\.value) == ["%26", "100%", "hello+world"])
    #expect(try WebAddress.resolve("http://[::1]:8080/中文").port == 8080)
}

@Test func subscriptionCommentsPreserveURLsEscapesAndOpaqueValues() throws {
    let text = #"""
    // introduction
    {
      # TVBox configuration
      "sites": [
        {"key":"中文", "type":3, "api":"csp_Test", /* comment */
         "ext":{"url":"https://肥猫.net/a//b#tag", "literal":"/*keep*/ #keep ,}", "quote":"\"//keep",},
        }, // last source
      ],
      "lives":[{"url":"./直播.m3u",}],
    }
    """#
    let sub = try Subscription.parse(Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8), origin: WebAddress.resolve("http://肥猫.net/config.json"))
    #expect(sub.sites.count == 1)
    #expect(sub.sites[0].raw["ext"]?.object?["url"]?.string == "https://肥猫.net/a//b#tag")
    #expect(sub.sites[0].raw["ext"]?.object?["literal"]?.string == "/*keep*/ #keep ,}")
    #expect(sub.sites[0].raw["ext"]?.object?["quote"]?.string == "\"//keep")
    #expect(sub.lives.first?.url.host == "xn--z7x900a.net")
}

@Test func binaryImageEnvelopeDecodesBeforeJSON() throws {
    let payload = Data("// config\n{\"sites\":[{\"key\":\"a\",\"type\":3,\"api\":\"csp_A\"}]}".utf8)
    let wrapped = Data([0xFF, 0xD8, 0xFF, 0xD9]) + Data(("Abcd1234**\n" + payload.base64EncodedString() + "\r\n").utf8)
    let sub = try Subscription.parse(wrapped, origin: WebAddress.resolve("https://饭太硬.net/tv"))
    #expect(sub.sites.first?.key == "a")
}

@Test func compatibilityDoesNotSilentlyRepairBrokenOrForeignDocuments() throws {
    let base = try WebAddress.resolve("https://example.com/config")
    for text in [
        #"{"sites":[{"key":"a","type":3,"api":"csp_A",ext":{}}]}"#,
        #"{"sites":[{"key":爱迪V2,"type":3,"api":"csp_A"}]}"#,
        #"{"sites":[{"key":"a","type":3,"api":"csp_A"}]}<html>injected</html>"#,
        #"{"sites":[{"key":"a","type":3,"api":"csp_A"}]}/* unclosed"#,
        "<!doctype html><html>landing page</html>", "24233234abcdef",
        #"{"urls":[{"name":"仓库","url":"https://example.com/a"}]}"#,
        #"{"storeHouse":[{"sourceUrl":"https://example.com/a"}]}"#
    ] {
        #expect(throws: (any Error).self) { try Subscription.parse(Data(text.utf8), origin: base) }
    }
    // A marker inside valid JSON must remain ordinary text.
    let sub = try Subscription.parse(Data(#"{"sites":[{"key":"a","type":3,"api":"csp_A","ext":"abcdefgh**not-base64"}]}"#.utf8), origin: base)
    #expect(sub.sites[0].raw["ext"]?.string == "abcdefgh**not-base64")
    let commented = try Subscription.parse(Data("// intro\n".utf8) + Data(#"{"sites":[{"key":"a","type":3,"api":"csp_A","ext":"abcdefgh**not-base64"}]}"#.utf8), origin: base)
    #expect(commented.sites[0].raw["ext"]?.string == "abcdefgh**not-base64")
}

@Test func sourceSpecificPluginsOverrideGlobalPluginAndResolveRelativeURLs() throws {
    let origin = try WebAddress.resolve("https://肥猫.net/config/main.json")
    let sub = try Subscription.parse(Data(#"{"spider":"../global.jar","sites":[{"key":"custom","type":3,"api":"csp_Test","jar":"./插件.jar;md5;0123456789abcdef0123456789abcdef"},{"key":"fallback","type":3,"api":"csp_Test"},{"key":"bad","type":3,"api":"csp_Test","jar":"file:///tmp/plugin.jar"}]}"#.utf8), origin: origin)
    #expect(try sub.sites[0].pluginURL(origin: origin, fallback: sub.spiderURL)?.path == "/config/插件.jar")
    #expect(try sub.sites[0].pluginURL(origin: origin, fallback: nil)?.host == "xn--z7x900a.net")
    #expect(try sub.sites[1].pluginURL(origin: origin, fallback: sub.spiderURL)?.path == "/global.jar")
    #expect(try sub.sites[1].pluginURL(origin: origin, fallback: nil) == nil)
    #expect(throws: (any Error).self) { try sub.sites[2].pluginURL(origin: origin, fallback: sub.spiderURL) }
}

@Test func nestedPluginResourcesKeepTheirSubscriptionOrigin() throws {
    let origin = try WebAddress.resolve("https://肥猫.net/config/main.json")
    let sub = try Subscription.parse(Data(#"{"sites":[{"key":"a","type":3,"api":"csp_Test","ext":{"json":"../data/中文.json","items":["./one.txt"],"token":"opaque-value","script":"var path='./unchanged';"}}]}"#.utf8), origin: origin)
    let ext = try #require(sub.sites[0].pluginExtension(origin: origin)?.object)
    #expect(ext["json"]?.string == "https://xn--z7x900a.net/data/%E4%B8%AD%E6%96%87.json")
    #expect(ext["items"]?.array?.first?.string == "https://xn--z7x900a.net/config/one.txt")
    #expect(ext["token"]?.string == "opaque-value")
    #expect(ext["script"]?.string == "var path='./unchanged';")
    #expect(try sub.sites[0].pluginExtension(origin: nil) == sub.sites[0].raw["ext"])
}

@Test func sourcesSelectTheirRuntimeAndRankCheapestFirst() throws {
    func site(_ type: Int, _ api: String, ext: JSONValue? = nil) -> Site {
        Site(key: api, name: api, type: type, api: api, raw: ext.map { ["ext": $0] } ?? [:])
    }
    #expect(site(1, "https://example.com/api.php/provide/vod/").runtime == .api)
    #expect(site(4, "https://example.com/api").runtime == .api)
    #expect(site(3, "http://example.com/lib/drpy2.min.js", ext: .string("./js/rule.js")).runtime == .javascript)
    #expect(site(3, "./spider.js?v=2").runtime == .javascript)
    #expect(site(3, "https://example.com/py/永乐视频.py").runtime == .python)
    #expect(site(3, "py_cctv", ext: .string("https://example.com/lib/py_cctv.py?extend=x")).runtime == .python)
    #expect(site(3, "csp_XBPQ", ext: .string("https://example.com/rules.json")).runtime == .jar)
    #expect(site(3, "csp_Bili").runtime == .jar)
    #expect(site(0, "https://example.com/xml").runtime == .unsupported)
    #expect([SourceRuntime.jar, .javascript, .api, .python].sorted() == [.api, .python, .javascript, .jar])

    let origin = try #require(URL(string: "https://example.com/config/tv.json"))
    #expect(try site(3, "py_cctv", ext: .string("../lib/cctv.py")).scriptURL(origin: origin).absoluteString == "https://example.com/lib/cctv.py")
    #expect(try site(3, "./spider.py").scriptURL(origin: origin).absoluteString == "https://example.com/config/spider.py")
}

@Test func sourceNamesGroupIntoChannelsAcrossPluginTypes() {
    for (names, channel) in [(["低端影视", "影视 | 低端影视[js]", "🛣┃低端┃影视", "低端｜影视", "♻️低端(drpy)"], "低端"),
                             (["LIBVIO[py]", "🐛LIBVIO", "🦋Libvio(XPF)", "影视 | libvio[js]"], "libvio"),
                             (["影视-瓜子(T4)", "瓜子[py]", "瓜子｜APP", "⭐瓜子┃秒播"], "瓜子"),
                             (["🐯┃虎牙┃直播", "虎牙直播(JS)"], "虎牙直播")] {
        for name in names { #expect(SourceStrategy.channel(of: name) == channel, "\(name)") }
    }
    // Content words keep a brand's other channels apart, including bracketed ones.
    #expect(SourceStrategy.channel(of: "🅱️┃哔哩┃听书") != SourceStrategy.channel(of: "🅱️┃哔哩┃影视"))
    #expect(SourceStrategy.channel(of: "😘多多┃[网盘]") != SourceStrategy.channel(of: "多多影视[py]"))
}

@Test func sourceStrategyFiltersAndOrdersChannelsByRuntime() {
    func site(_ key: String, _ name: String, _ type: Int, _ api: String) -> Site { Site(key: key, name: name, type: type, api: api, raw: [:]) }
    let sites = [
        site("jar-a", "低端影视", 3, "csp_Ddys"),
        site("xml", "XML", 0, "https://example.com/xml"),
        site("js-a", "影视 | 低端影视[js]", 3, "https://example.com/drpy2.min.js"),
        site("py-other", "其他[py]", 3, "https://example.com/other.py"),
        site("py-a", "低端[py]", 3, "https://example.com/ddys.py"),
        site("api-b", "低端(T4)", 4, "https://example.com/b"),
        site("js-b", "🔥┃低端┃Js", 3, "https://example.com/b.js"),
        site("api-a", "低端影视", 1, "https://example.com/a"),
        site("py-b", "低端影视[py]", 3, "https://example.com/ddys2.py"),
        site("jar-b", "🐞低端影视", 3, "csp_Ddys2"),
        site("jar-only", "仅JAR", 3, "csp_Only"),
    ]
    let arranged = SourceStrategy.arrange(sites) { $0.runtime != .unsupported }
    // Channel 低端 has a JSON source, so it leads: JSON a, JSON b, Python a, Python b, JS a, JS b, JAR a, JAR b.
    // Then the Python-only channel, then the JAR-only channel; the XML source is not offered.
    #expect(arranged.map(\.key) == ["api-b", "api-a", "py-a", "py-b", "js-a", "js-b", "jar-a", "jar-b", "py-other", "jar-only"])
}

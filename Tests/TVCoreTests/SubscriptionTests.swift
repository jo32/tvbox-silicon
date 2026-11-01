#if canImport(CoreImage.CIFilterBuiltins)
import CoreImage.CIFilterBuiltins
#endif
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
    let media = try WebAddress.resolve("http://127.0.0.1:8080/play/夸父盘/[ANi] 你好%20[1080P].mp4")
    #expect(media.path == "/play/夸父盘/[ANi] 你好 [1080P].mp4")
    #expect(!media.absoluteString.contains("%25"))
    #expect(try WebAddress.resolve(media.absoluteString) == media)
    let ipv6Media = try WebAddress.resolve("http://[::1]:8080/[字幕] 你好.mp4")
    #expect(ipv6Media.port == 8080)
    #expect(ipv6Media.path == "/[字幕] 你好.mp4")
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

@Test func rawLineBreaksInsideStringsReadAsTheCharacters() throws {
    // Seen in xhztv.top/4k.json and iyouhun.com/tv/et: Gson-based TVBox apps accept these.
    let base = try WebAddress.resolve("https://example.com/config")
    let text = "{\"sites\":[{\"key\":\"a\",\"name\":\"优\n酷\t\",\"type\":3,\"api\":\"csp_A\"}]," +
        "\"parses\":[{\"url\":\"   \r\nhttps://jx.example.com/?url=\"}]} // \"quoted\" comment"
    let sub = try Subscription.parse(Data(text.utf8), origin: base)
    #expect(sub.sites.first?.name == "优\n酷\t")
    #expect(sub.raw["parses"]?.array?.first?.object?["url"]?.string == "   \r\nhttps://jx.example.com/?url=")
}

@Test func absoluteAddressesIgnoreMissingSlashesLikeBrowsers() throws {
    #expect(try WebAddress.resolve("https:/raw.githubusercontent.com/a/b/main/c.json").absoluteString == "https://raw.githubusercontent.com/a/b/main/c.json")
    #expect(try WebAddress.resolve("HTTP:///example.com/tv").host() == "example.com")
    #expect(try WebAddress.resolve("http://肥猫.net").host() == "xn--z7x900a.net")
}

@Test func catVodEncryptedSubscriptionsDecrypt() throws {
    // `$#YingXia#$` + AES-128-CBC of a commented config (key "yingxia000000000", IV "abcdefghijklm000",
    // made with OpenSSL) + `AbcDefGhiJklM`. Uppercase hex and line breaks as some servers send it.
    let hex = "242359696E675869612324376CAB87BB81CC55FB20B09E3AE8FD3D3D84BAA3CAB01DFD414C09643B359B29E1588CB05705F7194E4D82834C6D12140E6F402930F85A11E3E16F6B99565266750A06CB6FF390074801779D118454E34162634465664768694A6B6C4D"
    let base = try WebAddress.resolve("https://example.com/config")
    let sub = try Subscription.parse(Data((" \n" + hex.prefix(100) + "\n" + hex.dropFirst(100) + "\n").utf8), origin: base)
    #expect(sub.sites.map(\.key) == ["a"])
    #expect(sub.sites.first?.name == "甲")
    // A wrong key (`XingXia`) must not yield a configuration.
    #expect(throws: (any Error).self) { try Subscription.parse(Data(("242358" + hex.dropFirst(6)).utf8), origin: base) }
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

@Test func bareLivePlaylistsImportAsSubscriptions() throws {
    let origin = URL(string: "https://example.com/output/result.txt")!
    let txt = "\u{FEFF}🕘️更新时间,#genre#\n2026-10-14 08:47:48,http://example.com/a.m3u8\n\n📺央视频道,#genre#\nCCTV-1,http://example.com/cctv1.m3u8\n"
    let config = try Subscription.parse(Data(txt.utf8), origin: origin)
    #expect(config.sites.isEmpty)
    #expect(config.lives.map(\.url) == [origin])
    let m3u = "#EXTM3U\n#EXTINF:-1 group-title=\"新闻\",一台\nhttps://example.com/1.m3u8\n"
    #expect(try Subscription.parse(Data(m3u.utf8), origin: origin).lives.map(\.url) == [origin])
    let plain = "一台,https://example.com/1.m3u8\r\n二台,https://example.com/2.m3u8"
    #expect(try Subscription.parse(Data(plain.utf8), origin: origin).lives.count == 1)
    // Broken JSON and other text still fail instead of turning into a playlist.
    #expect(throws: (any Error).self) { try Subscription.parse(Data(#"{"sites":[{"key":"a","api":"https://x/y"}"#.utf8), origin: origin) }
    #expect(throws: (any Error).self) { try Subscription.parse(Data("hello,world\n".utf8), origin: origin) }
    #expect(throws: (any Error).self) { try Subscription.parse(Data("分组,#genre#\n".utf8), origin: origin) }
}

@Test func catPawBundlesAskForTheUCTVToken() {
    #expect(CatPawSignIn.provider(for: "插件错误：Error: The source failed (HTTP 500): 非高会需要配置 UC TV Token，请到配置中心扫码获取") == "ucToken")
    #expect(CatPawSignIn.provider(for: "刷新 UC TV Token 失败") == "ucToken")
    #expect(CatPawSignIn.provider(for: "夸克授权失败，请扫码登录") == nil)
}

@Test func catPawBundlesAskForTheAppsBaiduSignIn() {
    // #297: the bundle's config center can't be reached from another phone, so the app offers its own Baidu sign-in.
    #expect(CloudDriveLoginRequired(bundleMessage: "插件错误：Error: The source failed (HTTP 500): 还没有配置百度网盘 Cookie，请先去配置中心登录百度网盘") == .baidu)
    #expect(CloudDriveLoginRequired(bundleMessage: "非高会需要配置 UC TV Token，请到配置中心扫码获取") == nil)
    #expect(CloudDriveLoginRequired(bundleMessage: "百度网盘分享已失效") == nil)
}

#if canImport(CoreImage.CIFilterBuiltins)
@Test func catPawSignInReadsTheLinkInItsCode() throws {
    let link = "https://su.uc.cn/9_iCI3h?uc_param_str=&token=sta326333a3maasaq80nd5xub2ws0ib1"
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(link.utf8)
    let code = try #require(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 8, y: 8))
    let png = try #require(CIContext().pngRepresentation(of: code, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()))
    #expect(CatPawSignIn.decode(png)?.absoluteString == link)
}
#endif

@Test func catPawOpenMediaProxiesAreRecognized() throws {
    #expect(CatPawOpen.isMediaProxy(try #require(URL(string: "http://127.0.0.1:59322/spider/duoduo/3/proxy/quark/9d6b9453?token=1"))))
    #expect(!CatPawOpen.isMediaProxy(try #require(URL(string: "http://127.0.0.1:59322/spider/duoduo/3/play"))))
    #expect(!CatPawOpen.isMediaProxy(try #require(URL(string: "http://127.0.0.1:9978/proxy?do=quark&id=1"))))
    #expect(!CatPawOpen.isMediaProxy(try #require(URL(string: "https://example.com/spider/duoduo/3/proxy/quark/1"))))
}

@Test func catPawOpenAddressesNameTheirBundle() throws {
    let checksum = try #require(URL(string: "https://example.com/cat/index.js.md5"))
    let bundle = try #require(URL(string: "https://example.com/cat/index.js"))
    #expect(CatPawOpen.bundle(Data("84b8d21a4d3fe28c524da6c198b47460\n".utf8), at: checksum) == bundle)
    #expect(CatPawOpen.bundle(Data("<html>Not Found</html>".utf8), at: checksum) == nil)
    #expect(CatPawOpen.bundle(Data("at=(0,jW.default)({serverFactory:catServerFactory,".utf8), at: bundle) == bundle)
    #expect(CatPawOpen.bundle(Data("var rule = {title: 'drpy'}".utf8), at: bundle) == nil)
    #expect(CatPawOpen.bundle(Data(#"{"sites":[]}"#.utf8), at: try #require(URL(string: "https://example.com/tv.json"))) == nil)

    let site = Site(key: "nodejs_jinpai", name: "金牌影院", type: 3, api: bundle.absoluteString, raw: ["catPawOpen": .string("/spider/jinpai/3")])
    #if os(macOS)
    #expect(site.runtime == .javascript)
    #elseif os(iOS)
    #expect(site.runtime == (EmbeddedNodeHost.available ? .javascript : .unsupported))
    #else
    #expect(site.runtime == .unsupported)
    #endif
}

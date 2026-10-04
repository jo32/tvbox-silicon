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

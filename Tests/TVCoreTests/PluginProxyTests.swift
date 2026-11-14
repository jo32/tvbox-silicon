import Testing
@testable import TVCore

@Test func pluginLoopbackProxyIsUnwrapped() {
    let wrapped = "http://127.0.0.1:-1/proxy?do=m3u8&url=https%3A%2F%2Fexample.com%2Fa%2Findex.m3u8%3Ftoken%3D1"
    #expect(CatalogClient.unwrapPluginProxy(wrapped) == "https://example.com/a/index.m3u8?token=1")
    #expect(CatalogClient.unwrapPluginProxy("http://127.0.0.1:9978/proxy?do=m3u8&url=https%3A%2F%2Fexample.com%2Fb.m3u8") == "https://example.com/b.m3u8")
}

@Test func otherAddressesAreNotRewritten() {
    for address in ["https://example.com/index.m3u8", "http://127.0.0.1:9978/proxy?do=danmu&url=https%3A%2F%2Fexample.com",
                    "http://127.0.0.1:1/proxy?do=m3u8", "https://example.com/proxy?do=m3u8&url=https%3A%2F%2Fother.com",
                    "http://127.0.0.1.evil/proxy?do=m3u8&url=https%3A%2F%2Fother.com", "http://127.0.0.1:1@evil/proxy?do=m3u8&url=https%3A%2F%2Fother.com"] {
        #expect(CatalogClient.unwrapPluginProxy(address) == address)
    }
}

@Test func unencodedPluginProxyAddressesDoNotCrash() {
    // Setting these queries on URLComponents.percentEncodedQuery was a fatal error (crash 0dfaa7d0c462).
    let base = "http://127.0.0.1:9978/proxy?do=m3u8&url="
    for inner in ["https://example.com/a b.m3u8", "https://example.com/中文.m3u8", "https://example.com/a.m3u8|Referer=https://example.com",
                  "https://example.com/100%.m3u8"] {
        #expect(CatalogClient.unwrapPluginProxy(base + inner) == inner)
    }
    #expect(CatalogClient.unwrapPluginProxy("http://127.0.0.1:9978/proxy?do=danmu&url=https://example.com/a b") == "http://127.0.0.1:9978/proxy?do=danmu&url=https://example.com/a b")
    #expect(CatalogClient.bilibiliProxyID("http://127.0.0.1:9978/proxy?do=bili&aid=1&cid=2&ep=3&title=第 1 集") == "1_2_3")
    #expect(CatalogClient.bilibiliProxyID("http://127.0.0.1:9978/proxy?do=bili&aid=1&cid=2%") == nil)
}

/// #990: a CatPawOpen bundle's play result points at its own `/proxy?url=` (a video kept on an image or photo CDN), which
/// its Node server answers like its `/m3u8-proxy?`. Only a JAR or script spider's TVBox proxy is one the app can't play.
@Test func aCatPawBundlesOwnProxyPlaysAsItIs() {
    let own = "http://127.0.0.1:59371/proxy?url=https%3A%2F%2Fexample.com%2Fv.mp4&sig=abc"
    #expect(CatalogClient.servesOwnProxy(own, catPaw: true))
    #expect(CatalogClient.unwrapPluginProxy(own) == own)
    #expect(!CatalogClient.servesOwnProxy(own, catPaw: false))
    for other in ["http://127.0.0.1:-1/proxy?do=py&url=x", "http://127.0.0.1/proxy?url=x", "http://127.0.0.1:0/proxy?url=x",
                  "https://example.com:8080/proxy?url=x", "http://127.0.0.1:59371/m3u8-proxy?url=x"] {
        #expect(!CatalogClient.servesOwnProxy(other, catPaw: true))
    }
}

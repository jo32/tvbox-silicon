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

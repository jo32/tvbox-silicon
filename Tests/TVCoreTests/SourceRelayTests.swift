import Foundation
import Testing
@testable import TVCore

/// 源中继（SourceRelay）：直连地址与中继地址之间的对称编解码。
/// P1-2 之前 relay 丢端口/query/https，反向还原靠 hasPrefix("https") 猜而恒错；这里锁定 scheme/host/port/path/query 全保留。
@Suite struct SourceRelayTests {

    @Test func relayAndDirectRoundTripAnHTTPSAddressWithPortAndQuery() {
        let direct = "https://api.example.com:8443/api.php?id=1&v=2"
        let relayed = SourceRelay.relayedAddress(direct)
        #expect(relayed.contains("cmsr"))                        // https → cmsr
        #expect(relayed.contains("api.example.com:8443"))        // 端口保留
        #expect(relayed.contains("id=1"))                        // query 保留
        #expect(SourceRelay.directAddress(relayed) == direct)
    }

    @Test func relayAndDirectRoundTripPlainHTTP() {
        let direct = "http://api.example.com/api"
        let relayed = SourceRelay.relayedAddress(direct)
        #expect(relayed.contains("/cms/"))
        #expect(SourceRelay.directAddress(relayed) == direct)
    }

    @Test func anAlreadyRelayedAddressIsLeftAlone() {
        let direct = "https://api.example.com/api"
        let relayed = SourceRelay.relayedAddress(direct)
        #expect(SourceRelay.relayedAddress(relayed) == relayed)
        #expect(SourceRelay.isRelayed(relayed))
    }

    @Test func nonHTTPApisAreReturnedUnchanged() {
        // JAR/csp 类、本地文件不是原生 CMS 端点，不中继。
        #expect(SourceRelay.relayedAddress("csp_Spider") == "csp_Spider")
        #expect(SourceRelay.relayedAddress("file:///tmp/a.json") == "file:///tmp/a.json")
        #expect(SourceRelay.relayedAddress("jar://com.x.Spider") == "jar://com.x.Spider")
    }

    @Test func directAddressLeavesANonRelayedAddressAlone() {
        #expect(SourceRelay.directAddress("https://api.example.com/api") == "https://api.example.com/api")
    }
}

/// 测速里「从 m3u8 / 路径读出声明分辨率」的纯解析。网络探测本身不测，这里锁解析不臆造。
@Suite struct SourceProbeDeclaredHeightTests {

    @Test func readsResolutionFromAnM3U8() {
        let head = #"#EXT-X-STREAM-INF:RESOLUTION=1920x1080,BANDWIDTH=5000000"#
        #expect(SourceProbeRunner.declaredHeight(in: head, url: URL(string: "https://x.com/a.m3u8")!) == 1080)
    }

    @Test func readsResolutionFromAPathToken() {
        #expect(SourceProbeRunner.declaredHeight(in: "", url: URL(string: "https://x.com/a/1080p.m3u8")!) == 1080)
        #expect(SourceProbeRunner.declaredHeight(in: "", url: URL(string: "https://x.com/x720.m3u8")!) == 720)
        #expect(SourceProbeRunner.declaredHeight(in: "", url: URL(string: "https://x.com/2160p.m3u8")!) == 2160)
        #expect(SourceProbeRunner.declaredHeight(in: "", url: URL(string: "https://x.com/film_480p.mp4")!) == 480)
    }

    @Test func returnsNilInsteadOfGuessing() {
        #expect(SourceProbeRunner.declaredHeight(in: "", url: URL(string: "https://x.com/video.mp4")!) == nil)
        #expect(SourceProbeRunner.declaredHeight(in: "just text", url: URL(string: "https://x.com/a.m3u8")!) == nil)
    }
}

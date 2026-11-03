import Foundation
import Testing
@testable import TVCore

/// A relay that redirects `/huya/<room>.flv` to a Huya FLV line, and answers anything else with FLV.
private final class RelayProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let agent = request.value(forHTTPHeaderField: "User-Agent")
        var status = 200, fields = ["Content-Type": "video/x-flv"]
        if agent != HTTPClient.subscriptionUserAgent && agent != "Custom" { status = 403 }
        else if url.path.contains("/huya/") {
            status = 302
            fields["Location"] = "//tx.flv.huya.com/src/1394575547-1394575547-0-0-10057-A-0-1.flv?wsSecret=abc&wsTime=6ada458e&ctype=huya_adr&fs=bgct&ratio=6000"
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("FLV".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private func relaySession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RelayProtocol.self]
    return URLSession(configuration: config)
}

/// A platform whose FLV lines are on `.flv.huya.com`; the conversion stands in for its script's `play("relay", …)`.
private let huya = LivePlatform(json: ["id": .string("huya"), "scheme": .string("huya-live"), "api": .string("https://example.com/huya.js"),
                                       "relayHosts": .array([.string(".flv.huya.com")])])!
private func hls(_ platform: LivePlatform, _ flv: URL) async -> URL? {
    URL(string: "https://tx.hls.huya.com" + flv.path.replacingOccurrences(of: ".flv", with: ".m3u8") + "?" + (flv.query ?? ""))
}
private func playable(_ channel: Channel) async -> Channel {
    await LiveCatalog.playable(channel, session: relaySession(), platforms: [huya], convert: hls)
}

@Test func flvRelayChannelsResolveToHuyaHLS() async {
    let relayed = Channel(name: "刘德华", group: "✨明星剧场", url: URL(string: "http://relay.example/cdn/huya/11342424.flv")!)
    let channel = await playable(relayed)
    #expect(channel.url.absoluteString == "https://tx.hls.huya.com/src/1394575547-1394575547-0-0-10057-A-0-1.m3u8?wsSecret=abc&wsTime=6ada458e&ctype=huya_adr&fs=bgct&ratio=6000")
    #expect(channel.name == relayed.name && channel.group == relayed.group)
    // The channel's own headers reach the relay.
    let custom = Channel(name: "A", url: URL(string: "http://relay.example/cdn/huya/1.flv")!, headers: ["User-Agent": "Custom"])
    #expect(await playable(custom).url.host() == "tx.hls.huya.com")
    // Other FLV streams, and other formats, stay as they are, the latter without a request.
    let other = Channel(name: "B", url: URL(string: "http://relay.example/live/2.flv")!)
    #expect(await playable(other) == other)
    let playlist = Channel(name: "C", url: URL(string: "http://relay.example/huya/3.m3u8")!)
    #expect(await playable(playlist) == playlist)
    // Without a platform that relays, nothing is asked.
    #expect(await LiveCatalog.playable(relayed, session: relaySession(), platforms: []) == relayed)
}

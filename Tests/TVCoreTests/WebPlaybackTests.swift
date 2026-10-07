import Foundation
import Testing
@testable import TVCore

@Test func webPlayerPagesYieldTheMediaTheyEmbed() throws {
    let base = URL(string: "https://site.example/play/1-1.html")!
    let plain = #"<script>var player_aaaa={"flag":"play","encrypt":0,"url":"https:\/\/cdn.example\/a\/index.m3u8"};</script>"#
    #expect(WebPlayback.embeddedMedia(in: plain, base: base)?.absoluteString == "https://cdn.example/a/index.m3u8")
    let encoded = Data("https%3A%2F%2Fcdn.example%2Fb.mp4".utf8).base64EncodedString()
    let hidden = #"<script>var player_data = {"encrypt":2,"url":"\#(encoded)"}</script>"#
    #expect(WebPlayback.embeddedMedia(in: hidden, base: base)?.absoluteString == "https://cdn.example/b.mp4")
    let inline = #"new DPlayer({video: {url: 'https:\/\/v.example\/x\/index.m3u8?sign=1'}})"#
    #expect(WebPlayback.embeddedMedia(in: inline, base: base)?.absoluteString == "https://v.example/x/index.m3u8?sign=1")
    #expect(WebPlayback.embeddedMedia(in: "<html><body>no video</body></html>", base: base) == nil)
}

@Test func parseServicesKeepTypeAndHeaders() throws {
    let config = try Subscription.parse(Data(#"""
    {"sites":[{"key":"a","api":"https://example.com/api","type":1}],
     "parses":[{"name":"json","type":1,"url":"https://jx.example/?url=","ext":{"header":{"Origin":"https://jx.example"}}},
               {"name":"web","type":"0","url":"https://web.example/?url="},
               {"name":"broken"}]}
    """#.utf8), origin: URL(string: "https://example.com/tv.json")!)
    #expect(config.parseServices == [
        ParseService(name: "json", type: 1, url: "https://jx.example/?url=", headers: ["Origin": "https://jx.example"]),
        ParseService(name: "web", type: 0, url: "https://web.example/?url=", headers: [:]),
    ])
}

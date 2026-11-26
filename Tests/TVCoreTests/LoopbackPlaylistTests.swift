import Foundation
import Testing
@testable import TVCore

private func base64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }
private func route(_ address: String) -> LoopbackPlaylist.Route? { LoopbackPlaylist.route(URL(string: address)!) }

/// Live playlists on Android TVBox's own server (127.0.0.1:9978), the largest live failure in error reports.
@Test func loopbackLivePlaylistsReadTheirOwnAddress() throws {
    let list = "https://example.com/tv/live.txt"
    // takagen99's form: the address in Base64, standard or URL-safe, sometimes with a trailing newline.
    #expect(route("http://127.0.0.1:9978/proxy?do=live&type=txt&ext=" + base64(list)) == .playlist(URL(string: list)!))
    let urlSafe = base64("https://example.com/a?b=1>").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    #expect(route("http://127.0.0.1:9978/proxy?do=live&type=txt&ext=" + urlSafe) == .playlist(URL(string: "https://example.com/a?b=1%3E")!))
    #expect(route("http://127.0.0.1:9978/proxy?do=live&type=txt&ext=" + base64(list + "\n")) == .playlist(URL(string: list)!))
    // A plain address, with its own unencoded query, in `ext` or `url`.
    #expect(route("http://127.0.0.1:9978/proxy?do=live&type=txt&ext=https://example.com/m3u?id=1&key=2") == .playlist(URL(string: "https://example.com/m3u?id=1&key=2")!))
    #expect(route("http://127.0.0.1:9978/proxy?do=live&url=https://tv.example/m3u/Gather") == .playlist(URL(string: "https://tv.example/m3u/Gather")!))
    #expect(route("http://127.0.0.1:9978/proxy?do=live&url=https%3A%2F%2Ftv.example%2Fa.m3u&type=m3u") == .playlist(URL(string: "https://tv.example/a.m3u")!))
    // The playlist itself in Base64.
    #expect(route("http://127.0.0.1:9978/proxy?do=live&ext=" + base64("央视,#genre#\nCCTV1,https://a.example/1.m3u8")) == .text("央视,#genre#\nCCTV1,https://a.example/1.m3u8"))
    // Anything only the configuration's spider knows: its own `do=live` parameters, other actions.
    #expect(route("http://127.0.0.1:9978/proxy?do=live&u=Gather") == .spider(query: "do=live&u=Gather"))
    #expect(route("http://localhost:9978/proxy?do=xyz&id=1") == .spider(query: "do=xyz&id=1"))
    // Files on the Android device can't be read here.
    #expect(route("http://127.0.0.1:9978/file/TVBox/live.txt") == .deviceFile)
    #expect(route("http://127.0.0.1:9978/proxy?do=live&ext=" + base64("clan://localhost/TVBox/live.txt")) == .deviceFile)
    // Other addresses are fetched as they are.
    #expect(route("https://example.com/proxy?do=live&ext=" + base64(list)) == nil)
    #expect(route("http://127.0.0.1:8080/live.m3u") == nil)
    #expect(route("http://127.example.com/proxy?do=live&url=" + list) == nil)
    #expect(LoopbackPlaylist.normalize("proxy://do=live&type=txt&ext=abc") == "http://127.0.0.1:9978/proxy?do=live&type=txt&ext=abc")
    // Diagnostics name the kind, never the address.
    #expect(LoopbackPlaylist.label(URL(string: "http://127.0.0.1:9978/proxy?do=live&u=Gather")!) == "route=spider do=live")
    #expect(LoopbackPlaylist.label(URL(string: "http://127.0.0.1:9978/proxy?do=secret-name&x=1")!) == "route=spider do=other")
    #expect(LoopbackPlaylist.label(URL(string: "http://127.0.0.1:9978/file/TVBox/live.txt")!) == "route=file")
    #expect(LoopbackPlaylist.label(URL(string: "https://example.com/live.txt")!) == nil)
}

@Test func subscriptionLivesOnTheLocalServerKeepTheirSpider() throws {
    let encoded = base64("https://example.com/old.txt")
    let json = """
    {"spider":"./spider.jar;md5;abc","sites":[{"key":"cms","name":"CMS","type":1,"api":"https://cms.example/api"},
      {"key":"own","name":"Own","type":3,"api":"csp_Own","jar":"./own.jar"},{"key":"main","name":"Main","type":3,"api":"csp_Main"}],
     "lives":[{"name":"Spider","type":0,"url":"http://127.0.0.1:9978/proxy?do=live&u=Gather","ua":"okhttp/3.12.13"},
      {"name":"Web","url":"https://example.com/web.m3u"},
      {"group":"redirect","channels":[{"name":"Old","urls":["proxy://do=live&type=txt&ext=\(encoded)"]}]}]}
    """
    let config = try Subscription.parse(Data(json.utf8), origin: URL(string: "https://example.com/c/config.json")!)
    #expect(config.lives.map(\.name) == ["Spider", "Web", "Old"])
    let spider = try #require(config.lives[0].spider)
    #expect(spider.site.key == "main" && spider.archive?.absoluteString == "https://example.com/c/spider.jar")
    #expect(config.lives[1].spider == nil)
    #expect(config.lives[2].url.absoluteString == "http://127.0.0.1:9978/proxy?do=live&type=txt&ext=\(encoded)")
    #expect(LoopbackPlaylist.route(config.lives[2].url) == .playlist(URL(string: "https://example.com/old.txt")!))
    // Without a main spider, a source with its own archive answers.
    let own = try Subscription.parse(Data(#"{"sites":[{"key":"own","name":"Own","type":3,"api":"csp_Own","jar":"./own.jar"}],"lives":[{"name":"L","url":"http://127.0.0.1:9978/proxy?do=xyz"}]}"#.utf8),
                                     origin: URL(string: "https://example.com/c.json")!)
    #expect(own.lives[0].spider?.site.key == "own" && own.lives[0].spider?.archive == nil)
    // Saved subscriptions keep it.
    let decoded = try JSONDecoder().decode(Subscription.self, from: JSONEncoder().encode(config))
    #expect(decoded.lives[0].spider == config.lives[0].spider)
}

private final class LoopbackListProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [URL] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.requests.append(url)
        let body: Data
        switch url.path {
        case "/list.txt": body = Data("央视,#genre#\nCCTV1,https://a.example/1.m3u8\nCCTV2,https://a.example/2.m3u8".utf8)
        case "/lists/relative.txt": body = Data("Local,#genre#\nOne,one/index.m3u8\nTwo,/two.m3u8".utf8)
        default: body = Data()
        }
        if url.host() == "127.0.0.1" {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: body.isEmpty ? 404 : 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Before: every one of these asked 127.0.0.1:9978, where nothing listens (NSURLErrorDomain -1004).
@Test func loopbackLivePlaylistsLoadWithoutTheAndroidServer() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [LoopbackListProtocol.self]
    let http = HTTPClient(session: URLSession(configuration: configuration))
    let source = LiveSource(name: "Live", url: URL(string: "http://127.0.0.1:9978/proxy?do=live&type=txt&ext=" + base64("https://lists.example/list.txt"))!)
    let playlist = try await http.playlist(source)
    #expect(playlist.channels.map(\.name) == ["CCTV1", "CCTV2"] && playlist.channels[0].group == "央视")
    #expect(!LoopbackListProtocol.requests.contains { $0.host() == "127.0.0.1" })
    // Relative channel addresses resolve against the list's own address, never 127.0.0.1:9978…
    let relative = try await http.playlist(LiveSource(name: "R", url: URL(string: "http://127.0.0.1:9978/proxy?do=live&url=https://lists.example/lists/relative.txt")!))
    #expect(relative.channels.map(\.url.absoluteString) == ["https://lists.example/lists/one/index.m3u8", "https://lists.example/two.m3u8"])
    // …and a list given inline has no address to resolve them against: its relative ones are dropped, and say so.
    let inline = { (text: String) in LiveSource(name: "I", url: URL(string: "http://127.0.0.1:9978/proxy?do=live&type=txt&ext=" + base64(text))!) }
    let mixed = try await http.playlist(inline("News,#genre#\nA,https://a.example/a.m3u8\nB,b.m3u8"))
    #expect(mixed.channels.map(\.url.absoluteString) == ["https://a.example/a.m3u8"])
    do { _ = try await http.playlist(inline("News,#genre#\nA,a.m3u8\nB,/b.m3u8")); Issue.record("relative list loaded") }
    catch { #expect(error.localizedDescription.contains("relative")) }
    // A spider's own list without a spider to ask, and an Android file, say why.
    await #expect(throws: TVError.self) { try await http.playlist(LiveSource(name: "S", url: URL(string: "http://127.0.0.1:9978/proxy?do=live&u=Gather")!)) }
    do { _ = try await http.playlist(LiveSource(name: "F", url: URL(string: "http://127.0.0.1:9978/file/TVBox/live.txt")!)); Issue.record("file loaded") }
    catch { #expect(error.localizedDescription.contains("Android")) }
    #expect(!LoopbackListProtocol.requests.contains { $0.host() == "127.0.0.1" })
}

@Test func playlistsLoadAsAndroidPlayersReadThem() throws {
    let origin = URL(string: "https://example.com/live.txt")!
    // TVBox's JSON live format.
    let json = #"[{"group":"News","channels":[{"name":"One","urls":["https://a.example/1.m3u8","https://b.example/1.m3u8"]},{"name":"Two","urls":["proxy://do=x"]}]}]"#
    let channels = try Playlist.parse(json, origin: origin)
    #expect(channels.map(\.name) == ["One"] && channels[0].group == "News" && channels[0].alternates.count == 1)
    // Lists of streams Apple's player can't open say so, instead of "no HTTP channels".
    do { _ = try Playlist.parse("体育,#genre#\nA,rtmp://x.example/live/a\nB,rtsp://x.example/b", origin: origin); Issue.record("parsed") }
    catch { #expect(error.localizedDescription.contains("rtmp://, rtsp://")) }
    do { _ = try Playlist.parse("<!DOCTYPE html><html><body>Mirror</body></html>", origin: origin); Issue.record("parsed") }
    catch { #expect(error.localizedDescription.contains("web page")) }
    // A few bad bytes don't lose the list (OkHttp replaces them); a GBK list reads as GBK.
    var broken = Data("CCTV1,https://a.example/1.m3u8\n".utf8); broken.append(contentsOf: [0xFF, 0xFE]); broken.append(Data(",#genre#\n".utf8))
    #expect(try Playlist.parse(Playlist.text(broken), origin: origin).count == 1)
    let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    let chinese = try #require(String(repeating: "央视频道,#genre#\n中央一台,https://a.example/1.m3u8\n", count: 3).data(using: gbk))
    #expect(String(data: chinese, encoding: .utf8) == nil)
    #expect(try Playlist.parse(Playlist.text(chinese), origin: origin).first?.name == "中央一台")
}

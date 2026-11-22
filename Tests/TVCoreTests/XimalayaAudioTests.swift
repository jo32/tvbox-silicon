import Foundation
import Testing
@testable import TVCore

/// Ximalaya for Legado audio sources (#1130): the retired app track list is asked of the one still answering, blank
/// play addresses become track pages, and a track page plays from the web player's address. No network.

@Test func ximalayaRetiredTrackListGoesToTheOneStillAnswering() throws {
    let retired = URL(string: "http://mobile.ximalaya.com/fmobile-album/album/track/ts-1576706285548?ac=4G&albumId=95190670&device=android&isAsc=true&pageSize=200&source=3&pageId=2")!
    #expect(XimalayaAudio.request(for: retired)?.absoluteString == "http://mobile.ximalaya.com/mobile/others/ca/album/track/95190670/true/2/200")
    let descending = URL(string: "http://mobile.ximalaya.com/fmobile-album/album/track/ts-1?albumId=7&isAsc=false&pageSize=500")!
    #expect(XimalayaAudio.request(for: descending)?.absoluteString == "http://mobile.ximalaya.com/mobile/others/ca/album/track/7/false/1/200")
    // Every other address goes where it was sent.
    #expect(XimalayaAudio.request(for: URL(string: "http://mobile.ximalaya.com/mobile/others/ca/album/track/7/true/1/200")!) == nil)
    #expect(XimalayaAudio.request(for: URL(string: "http://search.ximalaya.com/speed/album/v1/list?kw=x")!) == nil)
    #expect(XimalayaAudio.request(for: URL(string: "https://example.com/fmobile-album/album/track/ts-1?albumId=7")!) == nil)
}

private let trackList = Data("""
{"msg":"0","ret":0,"album":{"albumId":41},"tracks":{"list":[
 {"trackId":101,"title":"第一章","playPathAacv224":"","playUrl64":""},
 {"trackId":102,"title":"第二章","playUrl64":"https://a.example/2.m4a"}],
 "pageId":1,"pageSize":200,"maxPageId":2,"totalCount":386}}
""".utf8)

private func object(_ data: Data?) throws -> [String: Any] {
    let data = try #require(data)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test func ximalayaTrackListsGetTrackPagesAndTheShapeAsked() throws {
    // Asked at the retired address: `data.list`, as those sources read it.
    let retired = URL(string: "http://mobile.ximalaya.com/fmobile-album/album/track/ts-1?albumId=41&isAsc=true&pageSize=200&pageId=1")!
    let adapted = try object(XimalayaAudio.adapt(trackList, requested: retired))
    let list = try #require((adapted["data"] as? [String: Any])?["list"] as? [[String: Any]])
    #expect(list.count == 2)
    // A track with no address gets its page in every field a source may read; one with an address keeps it.
    for field in ["playPathAacv224", "playPathAacv164", "playUrl64", "playUrl32"] {
        #expect(list[0][field] as? String == "https://www.ximalaya.com/sound/101")
    }
    #expect(list[1]["playUrl64"] as? String == "https://a.example/2.m4a")
    #expect(list[1]["playPathAacv224"] == nil)
    #expect((adapted["album"] as? [String: Any])?["albumId"] as? Int == 41)

    // Asked at the address still answering: `tracks.list`, filled the same way.
    let current = URL(string: "http://mobile.ximalaya.com/mobile/others/ca/album/track/41/true/1/200")!
    let same = try object(XimalayaAudio.adapt(trackList, requested: current))
    let tracks = try #require((same["tracks"] as? [String: Any])?["list"] as? [[String: Any]])
    #expect(tracks[0]["playPathAacv224"] as? String == "https://www.ximalaya.com/sound/101")
    #expect(same["data"] == nil)

    // Other answers pass through untouched.
    #expect(XimalayaAudio.adapt(Data(#"{"ret":999,"msg":"busy"}"#.utf8), requested: current) == nil)
    #expect(XimalayaAudio.adapt(trackList, requested: URL(string: "https://www.ximalaya.com/revision/search?kw=x")!) == nil)
}

@Test func ximalayaPagesPastTheEndNeedNoRequest() throws {
    let first = URL(string: "http://mobile.ximalaya.com/mobile/others/ca/album/track/42/true/1/200")!
    // Before the album's first page is seen, nothing is known: every page is asked for.
    #expect(XimalayaAudio.localAnswer(requested: URL(string: "http://mobile.ximalaya.com/mobile/others/ca/album/track/42/true/9/200")!) == nil)
    var list = String(decoding: trackList, as: UTF8.self)
    list = list.replacingOccurrences(of: "\"albumId\":41", with: "\"albumId\":42")
    _ = XimalayaAudio.adapt(Data(list.utf8), requested: first)
    // The album has 2 pages: the second is asked for, the ninth answered here, empty, in the shape asked.
    #expect(XimalayaAudio.localAnswer(requested: URL(string: "http://mobile.ximalaya.com/mobile/others/ca/album/track/42/true/2/200")!) == nil)
    let past = try object(XimalayaAudio.localAnswer(requested: URL(string: "http://mobile.ximalaya.com/fmobile-album/album/track/ts-1?albumId=42&pageId=9&pageSize=200")!))
    #expect(((past["data"] as? [String: Any])?["list"] as? [Any])?.isEmpty == true)
    #expect(((past["tracks"] as? [String: Any])?["maxPageId"] as? Int) == 2)
}

@Test func ximalayaTrackPagesAreRecognized() {
    #expect(XimalayaAudio.track(in: "https://www.ximalaya.com/sound/877427893") == 877427893)
    #expect(XimalayaAudio.track(in: "http://m.ximalaya.com/sound/5") == 5)
    #expect(XimalayaAudio.track(in: "https://www.ximalaya.com/sound/x") == nil)
    #expect(XimalayaAudio.track(in: "https://www.ximalaya.com/album/5") == nil)
    #expect(XimalayaAudio.track(in: "https://example.com/sound/5") == nil)
    #expect(XimalayaAudio.track(in: "https://audio.xmcdn.com/storages/a.m4a") == nil)
}

/// "https://audio.example/storages/a/b.m4a?sign=abc&buy_key=k", encrypted as the web player receives addresses.
private let encrypted = "s5hBDAWDgj82X65-VZ-SLlIx-9c7RqeHMSm7FGis8LrJPSTe9rBvclZjkiAkuRLTMxo5XPo3JWSFnwQ3u9xEGg"

@Test func ximalayaWebPlayerAddressesAreDecrypted() throws {
    #expect(XimalayaAudio.decrypt(encrypted) == "https://audio.example/storages/a/b.m4a?sign=abc&buy_key=k")
    #expect(XimalayaAudio.decrypt("not base64!") == nil)
    #expect(XimalayaAudio.decrypt("") == nil)
}

@Test func ximalayaTrackInfoGivesTheSoundOrSaysWhy() async throws {
    let free = Data(#"{"ret":0,"trackInfo":{"trackId":1,"isAuthorized":true,"playUrlList":[{"qualityLevel":0,"url":"\#(encrypted)"}]}}"#.utf8)
    #expect(try XimalayaAudio.sound(from: free).absoluteString == "https://audio.example/storages/a/b.m4a?sign=abc&buy_key=k")
    // The request goes to the web player's track info for that track.
    let asked = Locked<URLRequest?>(nil)
    let url = try await XimalayaAudio.sound(track: 877427893) { request in asked.set(request); return free }
    #expect(url.host == "audio.example")
    let request = try #require(asked.get())
    #expect(request.url?.host == "www.ximalaya.com")
    #expect(request.url?.query?.contains("trackId=877427893") == true)
    // A paid track, or none of its addresses readable: a reason, not a broken address.
    let paid = Data(#"{"ret":0,"trackInfo":{"trackId":1,"isAuthorized":false,"playUrlList":[]}}"#.utf8)
    #expect(throws: TVError.self) { try XimalayaAudio.sound(from: paid) }
    #expect(throws: TVError.self) { try XimalayaAudio.sound(from: Data(#"{"ret":1001,"msg":"系统繁忙"}"#.utf8)) }
}

/// The audio player is handed a track page's sound; other sounds go through as they are.
@Test func audiobookSoundsOtherThanXimalayaPassThrough() async throws {
    let sound = NovelAudio(url: "https://a.example/1.m4a", headers: ["Referer": "https://a.example"])
    #expect(try await NovelListening.playable(sound) == sound)
}

private final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ value: Value) { lock.withLock { self.value = value } }
}

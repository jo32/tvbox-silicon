import Foundation
import Testing
@testable import TVCore

/// Answers the Worker's questions from a closure, counting requests.
private final class WorkerStub: MusicTransport, @unchecked Sendable {
    let handler: @Sendable (URLComponents) -> MusicHTTPResponse
    private let lock = NSLock()
    private var _asked: [URLComponents] = []
    var asked: [URLComponents] { lock.withLock { _asked } }
    init(_ handler: @escaping @Sendable (URLComponents) -> MusicHTTPResponse) { self.handler = handler }
    func send(_ request: URLRequest, limit: Int) async throws -> MusicHTTPResponse {
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        lock.withLock { _asked.append(components) }
        return handler(components)
    }
}

private func json(_ text: String, status: Int = 200) -> MusicHTTPResponse { MusicHTTPResponse(status: status, body: Data(text.utf8)) }

@Test func appleMusicSongsAreIdentifiedThroughTheWorkerAndKeptForTheRun() async {
    let stub = WorkerStub { _ in json(#"{"song":{"id":"9","title":"晴天","artist":"周杰伦","artists":["周杰伦"],"album":"叶惠美","duration":269,"isrc":"TWK970300307","released":"2003-07-31","genres":["华语流行"],"artwork":"https://a/{w}x{h}bb.jpg","url":"https://music.apple.com/cn/song/9"}}"#) }
    let catalog = AppleMusicCatalog(transport: stub, base: URL(string: "https://w.example/v1/")!, storefront: "cn")
    let song = await catalog.identify(title: "晴天", artists: ["周杰伦"], duration: 268.6)
    #expect(song?.isrc == "TWK970300307")
    #expect(song?.duration == 269)
    _ = await catalog.identify(title: "晴天", artists: ["周杰伦"], duration: 268.6)
    #expect(stub.asked.count == 1)
    let asked = stub.asked[0]
    #expect(asked.path == "/v1/identify")
    #expect(asked.queryItems == [URLQueryItem(name: "title", value: "晴天"), URLQueryItem(name: "artist", value: "周杰伦"),
                                 URLQueryItem(name: "duration", value: "269"), URLQueryItem(name: "storefront", value: "cn")])
    #expect(AppleMusicCatalog.artwork(song?.artwork, side: 600)?.absoluteString == "https://a/600x600bb.jpg")
}

@Test func appleMusicAnswersNothingWhenTheWorkerFailsAndAsksAgainLater() async {
    let stub = WorkerStub { components in
        components.path == "/v1/artist" ? json(#"{"artist":null}"#) : json(#"{"error":"not configured"}"#, status: 503)
    }
    let catalog = AppleMusicCatalog(transport: stub, base: URL(string: "https://w.example/v1/")!, storefront: "cn")
    #expect(await catalog.album(title: "叶惠美", artist: "周杰伦") == nil)
    #expect(await catalog.album(title: "叶惠美", artist: "周杰伦") == nil)
    #expect(await catalog.artist(named: "周杰伦") == nil)
    #expect(await catalog.artist(named: "周杰伦") == nil)
    // The failed album question is asked again; "no such artist" is an answer and is kept.
    #expect(stub.asked.map(\.path) == ["/v1/album", "/v1/album", "/v1/artist"])
    #expect(AppleMusicCatalog.storefront(language: "zh-Hant") == "tw")
    #expect(AppleMusicCatalog.storefront(language: "en") == "us")
}

@Test func appleMusicArtistsAndAlbumsDecode() async {
    let stub = WorkerStub { components in
        components.path == "/v1/artist"
            ? json(#"{"artist":{"id":"6","name":"周杰伦","genres":["华语流行"],"artwork":null,"notes":"华语乐坛天王。","url":null,"topSongs":[],"albums":[{"id":"7","title":"叶惠美","artist":"周杰伦","released":"2003-07-31","artwork":null,"trackCount":11,"url":null}]}}"#)
            : json(#"{"album":{"id":"7","title":"叶惠美","artist":"周杰伦","released":"2003-07-31","artwork":null,"trackCount":11,"url":null,"notes":"经典。","label":"JVR Music","genres":[],"copyright":"℗ 2003 JVR","tracks":[]}}"#)
    }
    let catalog = AppleMusicCatalog(transport: stub, base: URL(string: "https://w.example/v1/")!, storefront: "cn")
    let artist = await catalog.artist(named: "周杰伦")
    #expect(artist?.notes == "华语乐坛天王。")
    #expect(artist?.albums.first?.year == "2003")
    #expect(await catalog.album(title: "叶惠美", artist: "周杰伦")?.label == "JVR Music")
}

@Test func anArtistsTopSongsComeFirstButNotAnotherVersionOfThem() {
    let tracks = ["开不了口", "晴天 (Live)", "稻香", "晴天", "七里香"].enumerated().map { MusicTrack(platform: .qq, songID: "\($0.offset)", title: $0.element, artists: ["周杰伦"]) }
    func top(_ title: String) -> AppleMusicCatalog.Song {
        AppleMusicCatalog.Song(id: title, title: title, artist: "周杰伦", artists: ["周杰伦"], genres: [])
    }
    let ranked = AppleMusicCatalog.ranked(tracks, top: [top("七里香"), top("晴天"), top("双截棍")])
    #expect(ranked.map(\.title) == ["七里香", "晴天", "开不了口", "晴天 (Live)", "稻香"])
    #expect(AppleMusicCatalog.ranked(tracks, top: []) == tracks)
}

@Test func sourceSongNamesAreReadAsTitleAndArtistButBookChaptersAreNot() {
    func track(_ name: String, album: String = "热歌榜", source: String = "听歌|抖音") -> MusicTrack {
        MusicTrack(source: PlaybackHistoryContext(origin: URL(string: "https://s.example")!, sourceKey: "k", sourceName: source, videoID: "v",
                                                  videoName: album, episodeID: "e", episodeName: name, episodeFlag: "f"), address: "a")
    }
    typealias Guess = MusicSourceSong.Guess
    #expect(MusicSourceSong.guesses(for: track("周杰伦 - 晴天")) == [Guess(title: "晴天", artists: ["周杰伦"]), Guess(title: "周杰伦", artists: ["晴天"])])
    #expect(MusicSourceSong.guesses(for: track("03. 晴天-周杰伦.mp3")).first == Guess(title: "周杰伦", artists: ["晴天"]))
    #expect(MusicSourceSong.guesses(for: track("晴天", album: "周杰伦")) == [Guess(title: "晴天", artists: ["周杰伦"])])
    #expect(MusicSourceSong.guesses(for: track("第12集")).isEmpty)
    #expect(MusicSourceSong.guesses(for: track("周杰伦 - 晴天", source: "有声小说")).isEmpty)
    // Not a source's track: catalog songs find lyrics their own way.
    #expect(MusicSourceSong.guesses(for: MusicTrack(platform: .qq, songID: "1", title: "晴天", artists: ["周杰伦"])).isEmpty)
}

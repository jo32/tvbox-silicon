import Foundation

/// A catalog's song search. It only finds songs: a song a catalog lists may still have no audio.
public protocol MusicCatalogSource: Sendable {
    var platform: MusicPlatform { get }
    /// One page of results, 1-based, in the catalog's own order.
    func search(_ query: String, page: Int) async throws -> [MusicTrack]
}

/// QQ Music's keyword search, as its mobile app asks it. The desktop method answered code 2001
/// to anonymous callers in testing (2026-10-13); the mobile one returned results.
public struct QQMusicCatalog: MusicCatalogSource {
    public let platform = MusicPlatform.qq
    let transport: MusicTransport
    static let pageSize = 20
    static let timeout: TimeInterval = 6
    public init(transport: MusicTransport = URLSessionMusicTransport()) { self.transport = transport }

    public func search(_ query: String, page: Int) async throws -> [MusicTrack] {
        let body: [String: Any] = [
            "comm": ["ct": 11, "cv": "1003006", "uin": "0"],
            "req": ["module": "music.search.SearchCgiService", "method": "DoSearchForQQMusicMobile",
                    "param": ["query": query, "num_per_page": Self.pageSize, "page_num": page, "search_type": 0,
                              // Without a search ID, back-to-back searches drew code 2001 (2026-10-13).
                              "searchid": String(UInt64.random(in: 1_000_000_000...9_999_999_999))]],
        ]
        var request = MusicHTTP.request(URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!, timeout: Self.timeout,
                                        headers: ["Referer": "https://y.qq.com/", "Content-Type": "application/json"])
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try Self.parse(try await MusicHTTP.json(transport, request, timeout: Self.timeout))
    }

    static func parse(_ json: JSONValue) throws -> [MusicTrack] {
        let code = json[path: "req", "code"]?.int ?? json["code"]?.int
        guard code == 0 else { throw MusicProviderError.invalidResponse("QQ search code \(code.map(String.init) ?? "-")") }
        let songs = json[path: "req", "data", "body", "item_song"]?.array ?? json[path: "req", "data", "body", "song", "list"]?.array ?? []
        return songs.compactMap(track)
    }

    /// One song as QQ lists it in search results, albums and playlists.
    static func track(_ song: JSONValue) -> MusicTrack? {
        guard let mid = song["mid"]?.string, !mid.isEmpty,
              let title = (song["title"]?.string ?? song["name"]?.string).map(MusicText.plain), !title.isEmpty else { return nil }
        let artists = (song["singer"]?.array ?? []).compactMap { $0["name"]?.string }
        let albumMid = song[path: "album", "mid"]?.string ?? ""
        var track = MusicTrack(platform: .qq, songID: mid, title: title, artists: artists,
                               album: song[path: "album", "name"]?.string, duration: song["interval"]?.double,
                               artwork: albumMid.isEmpty ? nil : URL(string: "https://y.gtimg.cn/music/photo_new/T002R300x300M000\(albumMid).jpg"))
        // "2005-11-01"; empty for some live recordings.
        track.year = song["time_public"]?.string.flatMap { Int($0.prefix(4)) }.flatMap { $0 > 1900 ? $0 : nil }
        track.genre = song["genre"]?.int.flatMap(MusicGenre.init(qqCode:))
        track.language = song["language"]?.int.flatMap(MusicLanguage.init(qqCode:))
        return track
    }
}

/// NetEase Cloud Music, searched through GD Studio's API (which counts against its request
/// budget), with durations and covers from NetEase's own song details in one more request.
public struct NeteaseMusicCatalog: MusicCatalogSource {
    public let platform = MusicPlatform.netease
    let transport: MusicTransport
    let health: MusicHealth
    static let pageSize = 20
    static let timeout: TimeInterval = 6
    public init(transport: MusicTransport = URLSessionMusicTransport(), health: MusicHealth = .shared) {
        self.transport = transport; self.health = health
    }

    public func search(_ query: String, page: Int) async throws -> [MusicTrack] {
        try await health.admit("gdstudio")
        let url = MusicHTTP.url("https://music-api.gdstudio.xyz/api.php", [
            ("types", "search"), ("source", "netease"), ("name", query), ("count", String(Self.pageSize)), ("pages", String(page)),
        ])
        var tracks = try Self.parse(try await MusicHTTP.json(transport, MusicHTTP.request(url, timeout: Self.timeout), timeout: Self.timeout))
        guard !tracks.isEmpty else { return [] }
        // Without durations a NetEase song can't be told from a preview, nor merged with QQ's by length.
        if let details = try? await details(tracks.compactMap { $0.ids[.netease] }) {
            for index in tracks.indices {
                guard let id = tracks[index].ids[.netease], let detail = details[id] else { continue }
                tracks[index].duration = tracks[index].duration ?? detail.duration
                tracks[index].artwork = tracks[index].artwork ?? detail.artwork
            }
        }
        return tracks
    }

    static func parse(_ json: JSONValue) throws -> [MusicTrack] {
        guard let songs = json.array else {
            throw MusicProviderError.invalidResponse("GD search: \(json["error"]?.string ?? json["msg"]?.string ?? "not a list")")
        }
        return songs.compactMap { song in
            guard let id = song["id"]?.string, !id.isEmpty, let title = song["name"]?.string, !title.isEmpty else { return nil }
            let artists = song["artist"]?.array?.compactMap(\.string) ?? song["artist"]?.string.map { [$0] } ?? []
            return MusicTrack(platform: .netease, songID: id, title: title, artists: artists, album: song["album"]?.string)
        }
    }

    struct Detail: Equatable { var duration: Double?; var artwork: URL? }

    func details(_ ids: [String]) async throws -> [String: Detail] {
        let url = MusicHTTP.url("https://music.163.com/api/song/detail/", [("ids", "[" + ids.joined(separator: ",") + "]")])
        let request = MusicHTTP.request(url, timeout: Self.timeout, headers: ["Referer": "https://music.163.com/"])
        return Self.parseDetails(try await MusicHTTP.json(transport, request, timeout: Self.timeout))
    }

    /// One song as NetEase lists it in details, albums and playlists (old and new field names).
    static func track(_ song: JSONValue) -> MusicTrack? {
        guard let id = song["id"]?.string, !id.isEmpty, let title = song["name"]?.string, !title.isEmpty else { return nil }
        let artists = (song["ar"]?.array ?? song["artists"]?.array ?? []).compactMap { $0["name"]?.string }
        let album = song["al"] ?? song["album"]
        let milliseconds = song["dt"]?.double ?? song["duration"]?.double
        return MusicTrack(platform: .netease, songID: id, title: title, artists: artists, album: album?["name"]?.string,
                          duration: milliseconds.map { $0 / 1000 },
                          artwork: album?["picUrl"]?.string.flatMap { URL(string: $0 + "?param=300y300") })
    }

    static func parseDetails(_ json: JSONValue) -> [String: Detail] {
        var details: [String: Detail] = [:]
        for song in json["songs"]?.array ?? [] {
            guard let id = song["id"]?.string else { continue }
            let milliseconds = song["duration"]?.double ?? song["dt"]?.double
            let picture = (song[path: "album", "picUrl"] ?? song[path: "al", "picUrl"])?.string
            details[id] = Detail(duration: milliseconds.map { $0 / 1000 },
                                 artwork: picture.flatMap { URL(string: $0 + "?param=300y300") })
        }
        return details
    }
}

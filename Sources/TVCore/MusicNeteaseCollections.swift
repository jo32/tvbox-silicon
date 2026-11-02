import Foundation

extension NeteaseMusicCatalog: MusicCollectionSource {
    /// NetEase's own search: albums and playlists, which GD Studio's API does not search. Not
    /// counted against GD's budget.
    public func searchCollections(_ query: String, kind: MusicCollection.Kind, page: Int) async throws -> [MusicCollection] {
        let url = MusicHTTP.url("https://music.163.com/api/search/get/web", [
            ("s", query), ("type", kind == .album ? "10" : "1000"), ("limit", String(Self.pageSize)), ("offset", String((page - 1) * Self.pageSize)),
        ])
        return Self.parseCollections(try await neteaseJSON(url), kind: kind)
    }

    public func tracks(of collection: MusicCollection) async throws -> [MusicTrack] {
        switch collection.kind {
        case .album:
            let json = try await neteaseJSON(URL(string: "https://music.163.com/api/v1/album/\(collection.collectionID)")!)
            return (json["songs"]?.array ?? json[path: "album", "songs"]?.array ?? []).compactMap(Self.track)
        case .playlist:
            let json = try await neteaseJSON(MusicHTTP.url("https://music.163.com/api/v6/playlist/detail", [("id", collection.collectionID), ("n", "1000")]))
            var tracks = (json[path: "playlist", "tracks"]?.array ?? []).compactMap(Self.track)
            // Long playlists list only their first tracks in full, the rest by ID.
            let listed = Set(tracks.compactMap { $0.ids[.netease] })
            let missing = (json[path: "playlist", "trackIds"]?.array ?? []).compactMap { $0["id"]?.string }.filter { !listed.contains($0) }
            let wanted = Array(missing.prefix(max(0, MusicCollections.trackLimit - tracks.count)))
            for start in stride(from: 0, to: wanted.count, by: 200) {
                let ids = wanted[start..<min(wanted.count, start + 200)]
                let url = MusicHTTP.url("https://music.163.com/api/song/detail/", [("ids", "[" + ids.joined(separator: ",") + "]")])
                tracks += (try await neteaseJSON(url)["songs"]?.array ?? []).compactMap(Self.track)
            }
            return Array(tracks.prefix(MusicCollections.trackLimit))
        }
    }

    func neteaseJSON(_ url: URL) async throws -> JSONValue {
        let request = MusicHTTP.request(url, timeout: Self.timeout, headers: ["Referer": "https://music.163.com/"])
        let json = try await MusicHTTP.json(transport, request, timeout: Self.timeout)
        if let code = json["code"]?.int, code != 200 { throw MusicProviderError.invalidResponse("NetEase code \(code)") }
        return json
    }

    static func parseCollections(_ json: JSONValue, kind: MusicCollection.Kind) -> [MusicCollection] {
        switch kind {
        case .album: (json[path: "result", "albums"]?.array ?? []).compactMap(album)
        case .playlist: (json[path: "result", "playlists"]?.array ?? []).compactMap(playlist)
        }
    }

    /// An album as search results and new releases list it.
    static func album(_ album: JSONValue) -> MusicCollection? {
        guard let id = album["id"]?.string, let name = album["name"]?.string else { return nil }
        let year = album["publishTime"]?.double.map { Date(timeIntervalSince1970: $0 / 1000).formatted(.dateTime.year()) }
        return MusicCollection(kind: .album, platform: .netease, collectionID: id, title: name,
                               subtitle: album[path: "artist", "name"]?.string,
                               artwork: album["picUrl"]?.string.flatMap { URL(string: $0 + "?param=300y300") },
                               trackCount: album["size"]?.int, year: year)
    }

    /// A playlist as search results, charts and recommendations list it (recommendations name the cover `picUrl`).
    static func playlist(_ list: JSONValue) -> MusicCollection? {
        guard let id = list["id"]?.string, let name = list["name"]?.string else { return nil }
        // Cover URLs carry watermark parameters; the plain image is enough.
        let cover = (list["coverImgUrl"]?.string ?? list["picUrl"]?.string).map { $0.components(separatedBy: "?")[0] + "?param=300y300" }
        return MusicCollection(kind: .playlist, platform: .netease, collectionID: id, title: name,
                               subtitle: list[path: "creator", "nickname"]?.string, artwork: cover.flatMap(URL.init(string:)),
                               trackCount: list["trackCount"]?.int)
    }
}

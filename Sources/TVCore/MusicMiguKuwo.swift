import CryptoKit
import Foundation

// Migu and Kuwo, from the BakaMusic plugins (github.com/Zencok/baka-plugins, 2026-10-14). In a
// test of 14 songs from this Mac, Migu's own servers played 12 in full (all of Jay Chou's, which
// the QQ channels no longer reach) and Kuwo through Nianxin or Xinghai played all 14, mostly FLAC.

/// Migu's app search. A Migu song needs two IDs to play, so its song ID is "contentId_copyrightId".
public struct MiguMusicCatalog: MusicCatalogSource {
    public let platform = MusicPlatform.migu
    let transport: MusicTransport
    static let pageSize = 20
    static let timeout: TimeInterval = 6
    /// The Android app's device ID and signing constants, as its search requests carry them.
    static let deviceID = "963B7AA0D21511ED807EE5846EC87D20"
    static let signing = "6cdc72a439cef99a3418d2a78aa28c73yyapp2d16148780a1dcc7408e06336b98cfd50"
    static let appAgent = "Mozilla/5.0 (Linux; U; Android 11.0.0; zh-cn; MI 11 Build/OPR1.170623.032) AppleWebKit/534.30 (KHTML, like Gecko) Version/4.0 Mobile Safari/534.30"
    public init(transport: MusicTransport = URLSessionMusicTransport()) { self.transport = transport }

    public func search(_ query: String, page: Int) async throws -> [MusicTrack] {
        let time = String(Int(Date().timeIntervalSince1970 * 1000))
        let sign = Insecure.MD5.hash(data: Data((query + Self.signing + Self.deviceID + time).utf8)).map { String(format: "%02x", $0) }.joined()
        let url = MusicHTTP.url("https://jadeite.migu.cn/music_search/v3/search/searchAll", [
            ("isCorrect", "0"), ("isCopyright", "1"),
            ("searchSwitch", #"{"song":1,"album":0,"singer":0,"tagSong":1,"mvSong":0,"bestShow":1,"songlist":0,"lyricSong":0}"#),
            ("pageSize", String(Self.pageSize)), ("text", query), ("pageNo", String(page)), ("sort", "0"), ("sid", "USS"),
        ])
        let request = MusicHTTP.request(url, timeout: Self.timeout, headers: [
            "uiVersion": "A_music_3.6.1", "deviceId": Self.deviceID, "timestamp": time, "sign": sign, "channel": "0146921",
            "User-Agent": Self.appAgent,
        ])
        return try Self.parse(try await MusicHTTP.json(transport, request, timeout: Self.timeout))
    }

    static func parse(_ json: JSONValue) throws -> [MusicTrack] {
        guard json["code"]?.string == "000000" else {
            throw MusicProviderError.invalidResponse("Migu search code \(json["code"]?.string ?? "-")")
        }
        // Results come in groups (a song and its other versions); each entry is a song.
        return (json[path: "songResultData", "resultList"]?.array ?? []).flatMap { $0.array ?? [] }.compactMap(track)
    }

    static func track(_ song: JSONValue) -> MusicTrack? {
        guard let content = song["contentId"]?.string, !content.isEmpty, let copyright = song["copyrightId"]?.string, !copyright.isEmpty,
              let title = (song["name"]?.string ?? song["songName"]?.string).map(MusicText.plain), !title.isEmpty else { return nil }
        let artists = (song["singerList"]?.array ?? []).compactMap { $0["name"]?.string }
        let picture = song["img3"]?.string ?? song["img2"]?.string ?? song["img1"]?.string
        return MusicTrack(platform: .migu, songID: content + "_" + copyright, title: title, artists: artists,
                          album: song["album"]?.string, duration: song["duration"]?.double,
                          artwork: picture.flatMap { URL(string: $0.hasPrefix("http") ? $0 : "https://d.musicapp.migu.cn" + $0) })
    }

    /// The two IDs in a Migu song ID.
    static func ids(_ songID: String) -> (content: String, copyright: String)? {
        let parts = songID.split(separator: "_", maxSplits: 1).map(String.init)
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty ? (parts[0], parts[1]) : nil
    }
}

/// Migu's own playback addresses, as its web player asks for them. The answer names the 128 kbps
/// file; the same song's FLAC and 320 kbps files sit at sibling paths on the same server, so
/// those are tried first, each confirmed with a HEAD request.
public struct MiguProvider: MusicStreamProvider {
    public let id = MusicProviderID.migu
    public let platforms: Set<MusicPlatform> = [.migu]
    let transport: MusicTransport
    static let timeout: TimeInterval = 8
    static let checkTimeout: TimeInterval = 4
    /// The key the web player's answers are scrambled with.
    static let key = Array("Jk8qzuePiJ1qE3mDYhLQ3T73DtDoAhLP".utf8)
    /// Path and extension of each tier, best first; the answer is always the last.
    static let tiers: [(name: String, path: String, ext: String)] = [
        ("SQ", "歌曲下载/flac", ".flac"), ("HQ", "标清高清/MP3_320_16_Stero", ".mp3"), ("PQ", "标清高清/MP3_128_16_Stero", ".mp3"),
    ]
    public init(transport: MusicTransport = URLSessionMusicTransport()) { self.transport = transport }

    public func resolve(_ songID: String, platform: MusicPlatform, quality: MusicAudioQuality) async throws -> ResolvedMusicStream {
        guard let ids = MiguMusicCatalog.ids(songID) else { throw MusicProviderError.noResource }
        let url = MusicHTTP.url("https://c.musicapp.migu.cn/strategy/listen-url/h5/v2.4", [
            ("contentId", ids.content), ("copyrightId", ids.copyright), ("resourceType", "2"), ("netType", "01"),
            ("toneFlag", "PQ"), ("scene", ""), ("lowerQualityContentId", ids.content),
        ])
        let request = MusicHTTP.request(url, timeout: Self.timeout, headers: [
            "birth": "h5page", "channel": "014X031", "Referer": "https://y.migu.cn/", "location-data": "30.6698676660,104.1229614820",
        ])
        let response = try await MusicHTTP.withTimeout(Self.timeout) { try await transport.send(request, limit: MusicHTTP.jsonLimit) }
        guard (200..<300).contains(response.status) else { throw MusicProviderError.invalidResponse("Migu HTTP \(response.status)") }
        let base = try Self.address(Self.unscramble(response.body))
        // The answer is always PQ; the tiers above it are sibling paths, each confirmed first.
        for tier in Self.tiers(for: quality) {
            guard let better = Self.retone(base, to: tier.name), await exists(better) else { continue }
            return ResolvedMusicStream(url: better, claimedQuality: tier.name, upstream: "migu")
        }
        return ResolvedMusicStream(url: base, claimedQuality: "PQ", upstream: "migu")
    }

    /// The tiers above PQ to try: lossless falls back to 320 kbps, High asks for 320 kbps, and
    /// Standard keeps the 128 kbps answer.
    static func tiers(for quality: MusicAudioQuality) -> [(name: String, path: String, ext: String)] {
        switch quality {
        case .lossless: Array(tiers.dropLast())
        case .high: [tiers[1]]
        case .standard: []
        }
    }

    private func exists(_ url: URL) async -> Bool {
        var head = MusicHTTP.request(url, timeout: Self.checkTimeout)
        head.httpMethod = "HEAD"
        let request = head
        let response = try? await MusicHTTP.withTimeout(Self.checkTimeout) { try await transport.send(request, limit: 0) }
        return response.map { (200..<400).contains($0.status) } ?? false
    }

    /// The web player's answer: "AB CD 01", an offset byte, then JSON with each byte shifted by
    /// the offset less a key byte.
    static func unscramble(_ data: Data) throws -> JSONValue {
        let bytes = [UInt8](data)
        guard bytes.count > 4, bytes[0] == 0xAB, bytes[1] == 0xCD, bytes[2] == 0x01 else {
            throw MusicProviderError.invalidResponse("Migu answer format")
        }
        let offset = Int(bytes[3])
        let plain = bytes.dropFirst(4).enumerated().map { index, byte in
            UInt8((Int(byte) + offset - Int(key[index % key.count]) + 512) % 256)
        }
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: Data(plain)) else {
            throw MusicProviderError.invalidResponse("Migu answer not JSON")
        }
        return json
    }

    static func address(_ json: JSONValue) throws -> URL {
        guard json["code"]?.string == "000000" else {
            // A song Migu holds no rights to here answers with a message instead of an address.
            throw MusicProviderError.noResource
        }
        guard var text = json[path: "data", "url"]?.string ?? json[path: "data", "playUrl"]?.string, !text.isEmpty else {
            throw MusicProviderError.noResource
        }
        if text.hasPrefix("//") { text = "https:" + text }
        guard let url = URL(string: text.replacingOccurrences(of: "+", with: "%2B")), url.host() != nil else {
            throw MusicProviderError.noResource
        }
        return url
    }

    /// The address of another tier of the same file: the tier's folder and extension, without the
    /// 128 kbps answer's signature, which the other tiers do not need.
    static func retone(_ url: URL, to name: String) -> URL? {
        guard let source = tiers.last, let target = tiers.first(where: { $0.name == name }),
              let sourcePath = source.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let targetPath = target.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        let bare = url.absoluteString.components(separatedBy: "?")[0]
        guard bare.contains(sourcePath), bare.hasSuffix(source.ext) else { return nil }
        return URL(string: String(bare.replacingOccurrences(of: sourcePath, with: targetPath).dropLast(source.ext.count)) + target.ext)
    }
}

/// Kuwo's own search, as its Android app asks it.
public struct KuwoMusicCatalog: MusicCatalogSource {
    public let platform = MusicPlatform.kuwo
    let transport: MusicTransport
    static let pageSize = 20
    static let timeout: TimeInterval = 6
    public init(transport: MusicTransport = URLSessionMusicTransport()) { self.transport = transport }

    public func search(_ query: String, page: Int) async throws -> [MusicTrack] {
        let url = MusicHTTP.url("https://search.kuwo.cn/r.s", [
            ("client", "kt"), ("all", query), ("pn", String(page - 1)), ("rn", String(Self.pageSize)), ("uid", "2574109560"),
            ("ver", "kwplayer_ar_8.5.4.2"), ("vipver", "1"), ("ft", "music"), ("cluster", "0"), ("strategy", "2012"),
            ("encoding", "utf8"), ("rformat", "json"), ("vermerge", "1"), ("mobi", "1"),
        ])
        return try Self.parse(try await MusicHTTP.json(transport, MusicHTTP.request(url, timeout: Self.timeout), timeout: Self.timeout))
    }

    static func parse(_ json: JSONValue) throws -> [MusicTrack] {
        guard let songs = json["abslist"]?.array else { throw MusicProviderError.invalidResponse("Kuwo search: no list") }
        return songs.compactMap(track)
    }

    static func track(_ song: JSONValue) -> MusicTrack? {
        guard let rid = song["MUSICRID"]?.string, case let id = rid.replacingOccurrences(of: "MUSIC_", with: ""), !id.isEmpty,
              let title = song["NAME"]?.string.map(MusicText.plain), !title.isEmpty else { return nil }
        // Several artists come joined with "&".
        let artists = (song["ARTIST"]?.string).map { MusicText.plain($0).components(separatedBy: "&").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } } ?? []
        // "120/s3s94/93/211513640.jpg": the size folder, then the cover's path.
        let cover = song["web_albumpic_short"]?.string.flatMap { short in
            short.firstIndex(of: "/").flatMap { URL(string: "https://img4.kuwo.cn/star/albumcover/500" + short[$0...]) }
        }
        return MusicTrack(platform: .kuwo, songID: id, title: title, artists: artists, album: song["ALBUM"]?.string.map(MusicText.plain),
                          duration: song["DURATION"]?.double, artwork: cover)
    }
}

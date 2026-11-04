import Foundation

/// Turns a catalog song ID into a temporary audio address. A provider's answer is only a claim:
/// `MusicProber` reads what the address actually serves.
public protocol MusicStreamProvider: Sendable {
    var id: MusicProviderID { get }
    var platforms: Set<MusicPlatform> { get }
    /// Asks for `quality`: lossless, or 320 or 128 kbps lossy audio. A provider that can't ask for
    /// that tier plays its best instead, and probing tells what came back.
    func resolve(_ songID: String, platform: MusicPlatform, quality: MusicAudioQuality) async throws -> ResolvedMusicStream
    /// The same, for providers that also want the song's title and artist (LX Music sources).
    func resolve(_ songID: String, platform: MusicPlatform, track: MusicTrack?, quality: MusicAudioQuality) async throws -> ResolvedMusicStream
}

extension MusicStreamProvider {
    public func resolve(_ songID: String, platform: MusicPlatform, track: MusicTrack?, quality: MusicAudioQuality) async throws -> ResolvedMusicStream {
        try await resolve(songID, platform: platform, quality: quality)
    }
}

/// VKeys' current QQ endpoint. Its older `/v2/music/tencent/geturl` returned 60-second previews
/// that it reported as successes, so only this one is used. Quality 10 was tested (2026-10-13):
/// it returned FLAC for most of the samples.
public struct VKeysProvider: MusicStreamProvider {
    public let id = MusicProviderID.vkeys
    public let platforms: Set<MusicPlatform> = [.qq]
    let transport: MusicTransport
    static let timeout: TimeInterval = 8
    public init(transport: MusicTransport = URLSessionMusicTransport()) { self.transport = transport }

    public func resolve(_ songID: String, platform: MusicPlatform, quality: MusicAudioQuality) async throws -> ResolvedMusicStream {
        let url = MusicHTTP.url("https://api.vkeys.cn/music/tencent/song/link", [("mid", songID), ("quality", Self.code(for: quality))])
        return try Self.parse(try await MusicHTTP.json(transport, MusicHTTP.request(url, timeout: Self.timeout), timeout: Self.timeout))
    }

    /// The endpoint's codes, found by probing on 2026-11-04: 10 FLAC, 8 320 kbps MP3, 6 128 kbps MP3.
    static func code(for quality: MusicAudioQuality) -> String {
        switch quality {
        case .lossless: "10"
        case .high: "8"
        case .standard: "6"
        }
    }

    static func parse(_ json: JSONValue, now: Date = Date()) throws -> ResolvedMusicStream {
        let message = json["message"]?.string ?? ""
        guard json["code"]?.int == 0 else {
            if message.contains("风控") || message.contains("風控") { throw MusicProviderError.upstreamRisk }
            if message.contains("频繁") || message.contains("限流") { throw MusicProviderError.rateLimited(until: nil) }
            throw MusicProviderError.noResource
        }
        guard let address = json[path: "data", "url"]?.string, let url = URL(string: address), url.host() != nil else {
            throw MusicProviderError.noResource
        }
        return ResolvedMusicStream(url: url, claimedQuality: json[path: "data", "kbps"]?.string, resolvedAt: now, upstream: "vkeys")
    }
}

/// GD Studio's NetEase addresses. `br=999` asks for its highest tier; the tier asked for says
/// nothing about what comes back (all 2026-10-13 samples were 16-bit). Requests share the
/// service's budget of 50 per 5 minutes with search.
public struct GDStudioProvider: MusicStreamProvider {
    public let id = MusicProviderID.gdstudio
    public let platforms: Set<MusicPlatform> = [.netease]
    let transport: MusicTransport
    let health: MusicHealth
    static let timeout: TimeInterval = 8
    public init(transport: MusicTransport = URLSessionMusicTransport(), health: MusicHealth = .shared) {
        self.transport = transport; self.health = health
    }

    public func resolve(_ songID: String, platform: MusicPlatform, quality: MusicAudioQuality) async throws -> ResolvedMusicStream {
        try await health.admit("gdstudio")
        let url = MusicHTTP.url("https://music-api.gdstudio.xyz/api.php", [("types", "url"), ("source", "netease"), ("id", songID), ("br", Self.bitrate(for: quality))])
        return try Self.parse(try await MusicHTTP.json(transport, MusicHTTP.request(url, timeout: Self.timeout), timeout: Self.timeout))
    }

    /// The API's bitrates: 999 for its highest tier, 320 or 128 kbps for lossy audio.
    static func bitrate(for quality: MusicAudioQuality) -> String {
        switch quality {
        case .lossless: "999"
        case .high: "320"
        case .standard: "128"
        }
    }

    static func parse(_ json: JSONValue, now: Date = Date()) throws -> ResolvedMusicStream {
        guard let address = json["url"]?.string, !address.isEmpty, let url = URL(string: address), url.host() != nil else {
            if json["error"] != nil || json["msg"] != nil { throw MusicProviderError.invalidResponse("GD: \(json["error"]?.string ?? json["msg"]?.string ?? "")") }
            throw MusicProviderError.noResource
        }
        return ResolvedMusicStream(url: url, claimedQuality: json["br"]?.string.map { "br \($0)" }, resolvedAt: now, upstream: "gdstudio")
    }
}

/// HYW's public-benefit service, a QQ fallback. Its key comes from its own published script and
/// changes with its releases, so the viewer supplies it; it is never written to logs. Its NetEase
/// route reuses GD Studio, so it is only asked for QQ songs. It reports which upstream answered,
/// and its quality flags are not evidence: it once labelled 48 kbps AAC as high quality.
public struct HYWProvider: MusicStreamProvider {
    public let id = MusicProviderID.hyw
    public let platforms: Set<MusicPlatform> = [.qq]
    let transport: MusicTransport
    let key: String
    static let base = "https://103.79.184.97/api/music/url"
    static let timeout: TimeInterval = 8
    public init(key: String, transport: MusicTransport = URLSessionMusicTransport()) {
        self.key = key.trimmingCharacters(in: .whitespacesAndNewlines); self.transport = transport
    }

    public func resolve(_ songID: String, platform: MusicPlatform, quality: MusicAudioQuality) async throws -> ResolvedMusicStream {
        guard !key.isEmpty else { throw MusicProviderError.authRequired }
        let url = MusicHTTP.url(Self.base, [("platform", "tx"), ("source", "tx"), ("songId", songID), ("quality", Self.quality(for: quality)), ("key", key)])
        var headers: [String: String] = [:]
        if key.allSatisfy({ $0.isASCII }) { headers["X-Card-Key"] = key }
        return try Self.parse(try await MusicHTTP.json(transport, MusicHTTP.request(url, timeout: Self.timeout, headers: headers), timeout: Self.timeout))
    }

    /// The tiers its published script gives: "flac", "320k" and "128k".
    static func quality(for quality: MusicAudioQuality) -> String {
        switch quality {
        case .lossless: "flac"
        case .high: "320k"
        case .standard: "128k"
        }
    }

    static func parse(_ json: JSONValue, now: Date = Date()) throws -> ResolvedMusicStream {
        switch json["code"]?.int {
        case 200: break
        case 401, 403: throw MusicProviderError.authRequired
        case 429: throw MusicProviderError.rateLimited(until: nil)
        case 404: throw MusicProviderError.noResource
        case let code: throw MusicProviderError.invalidResponse("HYW code \(code.map(String.init) ?? "-")")
        }
        let address = json["url"]?.string ?? json[path: "data", "url"]?.string ?? json["data"]?.string
        guard let address, let url = URL(string: address), url.host() != nil else { throw MusicProviderError.noResource }
        return ResolvedMusicStream(url: url, claimedQuality: json["actualQuality"]?.string ?? json["quality"]?.string, resolvedAt: now,
                                   upstream: json["source"]?.string.map { "hyw:" + $0 } ?? "hyw")
    }
}

/// Nianxin's free resolver, which the BakaMusic plugins use first for Kuwo; it also answers for
/// NetEase. Its Kuwo addresses come from Kuwo's in-car player and were FLAC for 13 of 14 songs
/// tested (2026-10-14). A song without a lossless file answers an empty address, so 320 kbps is
/// asked next.
public struct NianxinProvider: MusicStreamProvider {
    public let id = MusicProviderID.nianxin
    public let platforms: Set<MusicPlatform> = [.kuwo, .netease]
    let transport: MusicTransport
    static let timeout: TimeInterval = 8
    public init(transport: MusicTransport = URLSessionMusicTransport()) { self.transport = transport }

    public func resolve(_ songID: String, platform: MusicPlatform, quality: MusicAudioQuality) async throws -> ResolvedMusicStream {
        let base = "https://mcp.nianxinxz.com/share/ceshi/" + (platform == .kuwo ? "kw.php" : "wy.php")
        var lastError = MusicProviderError.noResource
        for level in Self.levels(for: quality) {
            let url = MusicHTTP.url(base, [("id", songID), ("level", level)])
            do { return try Self.parse(try await MusicHTTP.json(transport, MusicHTTP.request(url, timeout: Self.timeout), timeout: Self.timeout), level: level) }
            catch let error as MusicProviderError where error == .noResource { lastError = error }
        }
        throw lastError
    }

    /// The resolver's levels. Lossless falls back to 320 kbps, and 320 to 128, but Standard never
    /// asks for more than the 128 kbps the viewer chose.
    static func levels(for quality: MusicAudioQuality) -> [String] {
        switch quality {
        case .lossless: ["lossless", "exhigh"]
        case .high: ["exhigh", "standard"]
        case .standard: ["standard"]
        }
    }

    static func parse(_ json: JSONValue, level: String, now: Date = Date()) throws -> ResolvedMusicStream {
        guard json["code"]?.int == 200 else { throw MusicProviderError.invalidResponse("Nianxin code \(json["code"]?.string ?? "-")") }
        guard let address = json[path: "data", "url"]?.string ?? json["url"]?.string, !address.isEmpty,
              let url = URL(string: address), url.host() != nil else { throw MusicProviderError.noResource }
        return ResolvedMusicStream(url: url, claimedQuality: level, resolvedAt: now, upstream: "nianxin")
    }
}

/// Xinghai's free LX Music resolver, the plugins' second choice. Its answers ask callers to
/// credit it and to keep within an overall request limit, so it is a fallback only, with a budget
/// of its own, and the player names it as the source.
public struct XinghaiProvider: MusicStreamProvider {
    public let id = MusicProviderID.xinghai
    public let platforms: Set<MusicPlatform> = [.kuwo, .netease]
    let transport: MusicTransport
    let health: MusicHealth
    static let timeout: TimeInterval = 8
    public init(transport: MusicTransport = URLSessionMusicTransport(), health: MusicHealth = .shared) {
        self.transport = transport; self.health = health
    }

    public func resolve(_ songID: String, platform: MusicPlatform, quality: MusicAudioQuality) async throws -> ResolvedMusicStream {
        try await health.admit("xinghai")
        let url = MusicHTTP.url("https://yy.zddyr.top/lx/api/", [
            ("source", platform == .kuwo ? "kw" : "netease"), ("name", ""), ("songmid", songID), ("quality", Self.quality(for: quality, platform: platform)),
        ])
        return try Self.parse(try await MusicHTTP.json(transport, MusicHTTP.request(url, timeout: Self.timeout), timeout: Self.timeout))
    }

    /// Kuwo's endpoint names its tiers with bitrates, NetEase's with its own words.
    static func quality(for quality: MusicAudioQuality, platform: MusicPlatform) -> String {
        if platform == .kuwo {
            switch quality {
            case .lossless: "flac"
            case .high: "320k"
            case .standard: "128k"
            }
        } else {
            switch quality {
            case .lossless: "lossless"
            case .high: "exhigh"
            case .standard: "standard"
            }
        }
    }

    static func parse(_ json: JSONValue, now: Date = Date()) throws -> ResolvedMusicStream {
        guard json["code"]?.int == 200 else {
            if json["code"]?.int == 429 { throw MusicProviderError.rateLimited(until: nil) }
            throw MusicProviderError.noResource
        }
        guard let address = json["url"]?.string ?? json[path: "data", "url"]?.string, !address.isEmpty,
              let url = URL(string: address), url.host() != nil else { throw MusicProviderError.noResource }
        return ResolvedMusicStream(url: url, claimedQuality: json["quality"]?.string, resolvedAt: now, upstream: "xinghai")
    }
}

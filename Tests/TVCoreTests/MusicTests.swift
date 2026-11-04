import Foundation
import Testing
@testable import TVCore

// MARK: - Fixtures

/// Answers requests from a closure, recording the byte limits asked for.
private final class FakeTransport: MusicTransport, @unchecked Sendable {
    let handler: @Sendable (URLRequest) async throws -> MusicHTTPResponse
    private let lock = NSLock()
    private var _limits: [Int] = []
    private var _requests: [URLRequest] = []
    var limits: [Int] { lock.withLock { _limits } }
    var requests: [URLRequest] { lock.withLock { _requests } }
    init(_ handler: @escaping @Sendable (URLRequest) async throws -> MusicHTTPResponse) { self.handler = handler }
    func send(_ request: URLRequest, limit: Int) async throws -> MusicHTTPResponse {
        lock.withLock { _limits.append(limit); _requests.append(request) }
        var response = try await handler(request)
        if response.body.count > limit { response.body = response.body.prefix(limit); response.truncated = true }
        return response
    }
}

private struct FakeProvider: MusicStreamProvider {
    let id: MusicProviderID
    let platforms: Set<MusicPlatform>
    let handler: @Sendable (String) async throws -> ResolvedMusicStream
    func resolve(_ songID: String, platform: MusicPlatform, quality: MusicAudioQuality) async throws -> ResolvedMusicStream { try await handler(songID) }
}

/// Records which quality each channel was asked for.
private final class QualityLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _qualities: [MusicAudioQuality] = []
    func record(_ quality: MusicAudioQuality) { lock.withLock { _qualities.append(quality) } }
    var qualities: [MusicAudioQuality] { lock.withLock { _qualities } }
}

private struct QualityProvider: MusicStreamProvider {
    let id: MusicProviderID
    let platforms: Set<MusicPlatform>
    let log: QualityLog
    let handler: @Sendable (MusicAudioQuality) async throws -> ResolvedMusicStream
    func resolve(_ songID: String, platform: MusicPlatform, quality: MusicAudioQuality) async throws -> ResolvedMusicStream {
        log.record(quality)
        return try await handler(quality)
    }
}

/// A FLAC file's first bytes: "fLaC" and a STREAMINFO block.
private func flacHeader(rate: Int = 44100, depth: Int = 16, seconds: Double) -> Data {
    var bytes: [UInt8] = Array("fLaC".utf8) + [0x80, 0x00, 0x00, 0x22]
    bytes += [0x10, 0x00, 0x10, 0x00, 0, 0, 0, 0, 0, 0]
    let samples = UInt64((seconds * Double(rate)).rounded())
    let packed = UInt64(rate) << 44 | UInt64(1) << 41 | UInt64(depth - 1) << 36 | samples
    bytes += (0..<8).reversed().map { UInt8(truncatingIfNeeded: packed >> (UInt64($0) * 8)) }
    bytes += [UInt8](repeating: 0, count: 16)
    return Data(bytes) + Data(count: 4096)
}

/// A constant-bit-rate MP3 frame header at 320 kbps, 44.1 kHz.
private func mp3Header() -> Data { Data([0xFF, 0xFB, 0xE0, 0xC4]) + Data(count: 4096) }

/// Audio served by URL: /flac/<depth>/<rate>/<seconds> or /mp3/<seconds>.
private func audioTransport() -> FakeTransport {
    FakeTransport { request in
        let parts = request.url!.pathComponents.dropFirst()
        switch parts.first {
        case "flac":
            let values = parts.dropFirst().map { Double($0)! }
            let body = flacHeader(rate: Int(values[1]), depth: Int(values[0]), seconds: values[2])
            return MusicHTTPResponse(status: 206, headers: ["content-range": "bytes 0-\(body.count - 1)/31646511"], body: body)
        case "mp3":
            let seconds = Double(parts.dropFirst().first!)!
            let total = Int(seconds * 40_000)
            return MusicHTTPResponse(status: 206, headers: ["content-range": "bytes 0-4099/\(total)"], body: mp3Header())
        default:
            return MusicHTTPResponse(status: 404, body: Data())
        }
    }
}

private func stream(_ path: String, claimed: String? = nil) -> ResolvedMusicStream {
    ResolvedMusicStream(url: URL(string: "https://audio.test" + path)!, claimedQuality: claimed)
}

private func qqTrack(_ title: String, _ artists: [String], duration: Double?, id: String = "mid1", album: String? = nil) -> MusicTrack {
    MusicTrack(platform: .qq, songID: id, title: title, artists: artists, album: album, duration: duration)
}
private func neteaseTrack(_ title: String, _ artists: [String], duration: Double?, id: String = "1", album: String? = nil) -> MusicTrack {
    MusicTrack(platform: .netease, songID: id, title: title, artists: artists, album: album, duration: duration)
}

private func resolver(_ providers: [any MusicStreamProvider], health: MusicHealth = MusicHealth(file: nil), budget: TimeInterval = 15) -> MusicResolver {
    MusicResolver(providers: providers, prober: MusicProber(transport: audioTransport(), inspector: nil), health: health, budget: budget)
}

// MARK: - Identity and matching

@Test func versionTagsComeFromBracketsAndDashSuffixes() {
    #expect(MusicMatching.tags(in: "七里香 (Live)") == [.live])
    #expect(MusicMatching.tags(in: "Live Forever").isEmpty)
    #expect(MusicMatching.tags(in: "Love Story (Taylor’s Version)") == [.rerecorded])
    #expect(MusicMatching.tags(in: "七里香 (女声版)") == [.cover])
    #expect(MusicMatching.tags(in: "江南 - DJ版") == [.remix])
    #expect(MusicMatching.tags(in: "晴天（伴奏）") == [.instrumental])
    #expect(MusicMatching.tags(in: "Adjustment (Remastered 2015)").isEmpty)
    #expect(MusicMatching.baseTitle("七里香 (Live)") == MusicMatching.baseTitle("七里香"))
    #expect(MusicMatching.normalize("Ｌｏｖｅ Ｓｔｏｒｙ") == "lovestory")
    #expect(MusicMatching.tags(inQuery: "七里香 live") == [.live])
    #expect(MusicMatching.tags(inQuery: "olive").isEmpty)
}

@Test func catalogsMergeOnlyTheSameRecording() {
    let qq = qqTrack("江南", ["林俊杰"], duration: 267, album: "第二天堂")
    let same = neteaseTrack("江南", ["林俊杰"], duration: 267.946, id: "108914", album: "第二天堂")
    let live = neteaseTrack("江南 (Live)", ["林俊杰"], duration: 268.04, id: "108779")
    let otherArtist = neteaseTrack("江南", ["某人"], duration: 267, id: "5")
    let longer = neteaseTrack("江南", ["林俊杰"], duration: 290, id: "6")
    let merged = MusicMatching.merge([[qq], [same, live, otherArtist, longer]])
    #expect(merged.count == 4)
    #expect(merged[0].ids == [.qq: "mid1", .netease: "108914"])
    #expect(merged[0].evidence.contains { $0.hasPrefix("duration") })
    // Without a duration on one side, only the same album joins them.
    let noDuration = neteaseTrack("江南", ["林俊杰"], duration: nil, id: "7", album: "第二天堂")
    let noAlbum = neteaseTrack("江南", ["林俊杰"], duration: nil, id: "8", album: "精选")
    #expect(MusicMatching.sameRecording(qq, noDuration)?.contains("album") == true)
    #expect(MusicMatching.sameRecording(qq, noAlbum) == nil)
    // Taylor's Version never joins the original.
    #expect(MusicMatching.sameRecording(qqTrack("Love Story", ["Taylor Swift"], duration: 235),
                                        neteaseTrack("Love Story (Taylor's Version)", ["Taylor Swift"], duration: 236)) == nil)
    // The same ID twice is one entry.
    #expect(MusicMatching.merge([[qq], [qq]]).count == 1)
}

@Test func rankingPrefersTheOriginalAndOnlyClearQueriesPlayDirectly() {
    let original = qqTrack("七里香", ["周杰伦"], duration: 299, id: "a")
    let cover = qqTrack("七里香 (女声版)", ["吉拉朵"], duration: 261, id: "b")
    let live = qqTrack("七里香 (Live)", ["周杰伦"], duration: 302, id: "c")
    let otherSong = qqTrack("七里香", ["马嘉祺"], duration: 280, id: "d")
    let tracks = [live, cover, otherSong, original]

    let named = MusicMatching.rank(tracks, query: "七里香 周杰伦")
    #expect(named.first?.id == original.id)
    #expect(MusicMatching.directHit(named, query: "七里香 周杰伦")?.id == original.id)

    // Two artists have a song of that title: the viewer chooses.
    let titleOnly = MusicMatching.rank(tracks, query: "七里香")
    #expect(titleOnly.first.map { $0.tags.isEmpty } == true)
    #expect(MusicMatching.directHit(titleOnly, query: "七里香") == nil)

    let wantsLive = MusicMatching.rank(tracks, query: "七里香 周杰伦 live")
    #expect(wantsLive.first?.id == live.id)
    #expect(MusicMatching.directHit(wantsLive, query: "七里香 周杰伦 live")?.id == live.id)

    // A unique title plays directly; the same recording on a compilation is no rival.
    let compilation = qqTrack("倒强", ["五月天"], duration: 271, id: "y", album: "精选")
    let unique = MusicMatching.rank([qqTrack("倒强", ["五月天"], duration: 270, id: "x"), compilation], query: "倒强")
    #expect(MusicMatching.directHit(unique, query: "倒强")?.id == "qq:x")
    // Seen 2026-10-13 with QQ down: NetEase's "七里香周杰伦" by 魏国栋 is not what "七里香 周杰伦" means.
    let lookalike = [neteaseTrack("七里香周杰伦", ["魏国栋"], duration: 113, id: "w"), neteaseTrack("七里香", ["Xai小爱"], duration: 317, id: "x")]
    #expect(MusicMatching.directHit(MusicMatching.rank(lookalike, query: "七里香 周杰伦"), query: "七里香 周杰伦") == nil)
    // A partial title never plays directly.
    #expect(MusicMatching.directHit(MusicMatching.rank([original], query: "七里"), query: "七里") == nil)
}

@Test func unnamedVersionsAndCompilationsDoNotBlockTheOriginal() {
    // Seen in NetEase results (2026-10-13): unnamed "…版" edits and language versions.
    #expect(MusicMatching.tags(in: "稻香(治愈版)") == [.alternate])
    #expect(MusicMatching.tags(in: "十年 (国语版)") == [.alternate])
    #expect(MusicMatching.tags(in: "江南(粤语版)") == [.alternate])
    #expect(MusicMatching.tags(in: "晴天 (DJ阿lo版)") == [.remix])
    #expect(MusicMatching.tags(in: "十年 (OT: 明年今日)").isEmpty)
    // The original on its album and three compilations, and one unmarked remix album cut.
    let entries = [("第二天堂", 267.9), ("他是…JJ林俊杰", 267.0), ("SOT电remix专辑", 125.0), ("精选", 268.0), ("海蝶", 268.2)]
        .enumerated().map { neteaseTrack("江南", ["林俊杰"], duration: $0.element.1, id: String($0.offset), album: $0.element.0) }
    let ranked = MusicMatching.rank(entries, query: "江南 林俊杰")
    #expect(MusicMatching.directHit(ranked, query: "江南 林俊杰")?.album == "第二天堂")
    // One original against one other cut of the same length class: too close to call.
    let split = [neteaseTrack("江南", ["林俊杰"], duration: 268, id: "a"), neteaseTrack("江南", ["林俊杰"], duration: 125, id: "b")]
    #expect(MusicMatching.directHit(split, query: "江南 林俊杰") == nil)
}

// MARK: - Catalog and provider answers

@Test func catalogAnswersParse() throws {
    let qq = try JSONDecoder().decode(JSONValue.self, from: Data("""
    {"code":0,"req":{"code":0,"data":{"body":{"item_song":[
      {"mid":"004Z8Ihr0JIu5s","name":"七里香","title":"七里香","singer":[{"name":"周杰伦","mid":"0025NhlN2yWrP4"}],
       "album":{"mid":"003DFRzD192KKD","name":"七里香"},"interval":299},
      {"mid":"002ZKnKQ34rbZu","name":"七里香","title":"七里香 (Live)","singer":[{"name":"周杰伦"}],"album":{"mid":"","name":"无与伦比"},"interval":302},
      {"name":"no mid"}]}}}}
    """.utf8))
    let tracks = try QQMusicCatalog.parse(qq)
    #expect(tracks.count == 2)
    #expect(tracks[0].id == "qq:004Z8Ihr0JIu5s" && tracks[0].duration == 299 && tracks[0].artists == ["周杰伦"])
    #expect(tracks[0].artwork?.absoluteString == "https://y.gtimg.cn/music/photo_new/T002R300x300M000003DFRzD192KKD.jpg")
    #expect(tracks[1].tags == [.live] && tracks[1].artwork == nil)
    #expect(throws: MusicProviderError.self) { try QQMusicCatalog.parse(try JSONDecoder().decode(JSONValue.self, from: Data(#"{"code":0,"req":{"code":2001}}"#.utf8))) }

    let gd = try JSONDecoder().decode(JSONValue.self, from: Data(#"[{"id":"108914","name":"江南","artist":["林俊杰"],"album":"第二天堂"},{"id":108779,"name":"江南 (Live)","artist":["林俊杰"],"album":""}]"#.utf8))
    let netease = try NeteaseMusicCatalog.parse(gd)
    #expect(netease.map(\.id) == ["netease:108914", "netease:108779"])
    #expect(netease[0].duration == nil && netease[1].album == nil)
    let details = NeteaseMusicCatalog.parseDetails(try JSONDecoder().decode(JSONValue.self, from: Data(
        #"{"code":200,"songs":[{"id":108914,"duration":267946,"album":{"picUrl":"https://p1.music.126.net/a.jpg"}}]}"#.utf8)))
    #expect(details["108914"]?.duration == 267.946)
    #expect(details["108914"]?.artwork?.absoluteString == "https://p1.music.126.net/a.jpg?param=300y300")
}

@Test func providerAnswersMapToClearErrors() throws {
    func json(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
    let ok = try VKeysProvider.parse(json(#"{"code":0,"data":{"kbps":"931kbps","url":"http://ws.stream.qqmusic.qq.com/F000.flac?vkey=x"}}"#))
    #expect(ok.url.host() == "ws.stream.qqmusic.qq.com" && ok.claimedQuality == "931kbps")
    #expect(throws: MusicProviderError.upstreamRisk) { try VKeysProvider.parse(json(#"{"code":-1,"message":"上游账号触发风控"}"#)) }
    #expect(throws: MusicProviderError.noResource) { try VKeysProvider.parse(json(#"{"code":0,"data":{"url":""}}"#)) }
    #expect(throws: MusicProviderError.noResource) { try VKeysProvider.parse(json(#"{"code":404,"message":"暂无"}"#)) }

    #expect(try GDStudioProvider.parse(json(#"{"url":"https://m8.music.126.net/a.flac","br":944,"size":31646511}"#)).claimedQuality == "br 944")
    #expect(throws: MusicProviderError.noResource) { try GDStudioProvider.parse(json(#"{"url":"","br":-1}"#)) }

    let hyw = try HYWProvider.parse(json(#"{"code":200,"url":"https://car-er.kuwo.cn/a.flac","source":"builtin-x","actualQuality":"flac","qualityVerified":false}"#))
    #expect(hyw.upstream == "hyw:builtin-x" && hyw.claimedQuality == "flac")
    #expect(throws: MusicProviderError.authRequired) { try HYWProvider.parse(json(#"{"code":403,"message":"bad key"}"#)) }
    #expect(throws: MusicProviderError.invalidResponse("HYW code 500")) { try HYWProvider.parse(json(#"{"code":500}"#)) }
}

@Test func gdRequestsEncodeTheQueryAndShareOneBudget() async throws {
    let health = MusicHealth(file: nil)
    let transport = FakeTransport { request in
        if request.url!.host() == "music.163.com" { return MusicHTTPResponse(status: 200, body: Data(#"{"songs":[]}"#.utf8)) }
        return MusicHTTPResponse(status: 200, body: Data(#"[{"id":"1","name":"A+B","artist":["C"]}]"#.utf8))
    }
    let catalog = NeteaseMusicCatalog(transport: transport, health: health)
    _ = try await catalog.search("A+B 林俊杰", page: 1)
    let query = transport.requests[0].url!.query(percentEncoded: true) ?? ""
    #expect(query.contains("name=A%2BB%20%E6%9E%97"))
    #expect(transport.requests[0].value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Mozilla/5.0") == true)
    #expect(await health.remaining("gdstudio") == 49)
}

// MARK: - Probing

@Test func probeReadsTheRealFormatWithinTheByteLimit() async throws {
    // The server ignores Range and starts sending 20 MB: the probe stops at 256 KiB.
    let transport = FakeTransport { _ in
        MusicHTTPResponse(status: 200, headers: ["content-length": "20000000", "content-type": "audio/x-ogg"],
                          body: flacHeader(rate: 48000, depth: 24, seconds: 223.33) + Data(count: 1_000_000))
    }
    let prober = MusicProber(transport: transport, inspector: nil)
    let result = try await prober.probe(stream("/a.mp3"), expected: 223.33)
    #expect(transport.limits.allSatisfy { $0 <= 256 * 1024 })
    #expect(transport.requests[0].value(forHTTPHeaderField: "Range") == "bytes=0-262143")
    #expect(result.format == MusicAudioFormat(codec: .flac, sampleRate: 48000, bitDepth: 24))
    #expect(result.format.label == "FLAC · 24-bit / 48 kHz")
    #expect(abs((result.duration ?? 0) - 223.33) < 0.01)
    #expect(result.byteLength == 20_000_000 && result.completeness == .complete && result.evidence == [.header])

    let mp3 = try await MusicProber(transport: audioTransport(), inspector: nil).probe(stream("/mp3/200"), expected: 200)
    #expect(mp3.format.codec == .mp3 && mp3.format.bitrate == 320 && !mp3.format.isLossless)
    #expect(abs((mp3.duration ?? 0) - 200) < 0.5)
    #expect(mp3.format.label == "MP3 · 44.1 kHz · 320 kbps")

    await #expect(throws: MusicProviderError.unsupportedFormat("unrecognized audio header")) {
        try await MusicProber(transport: FakeTransport { _ in MusicHTTPResponse(status: 200, body: Data("<html>".utf8)) }, inspector: nil)
            .probe(stream("/x"), expected: nil)
    }
    await #expect(throws: MusicProviderError.noResource) {
        try await MusicProber(transport: audioTransport(), inspector: nil).probe(stream("/gone"), expected: nil)
    }
}

@Test func completenessNeedsBothLengths() {
    #expect(MusicProber.completeness(duration: 60, expected: 223.45) == .preview)
    #expect(MusicProber.completeness(duration: 30, expected: 223.45) == .preview)
    #expect(MusicProber.completeness(duration: 219, expected: 223.45) == .complete)
    // A short song is not a preview, and an unknown length is never called complete.
    #expect(MusicProber.completeness(duration: 48, expected: 48.5) == .complete)
    #expect(MusicProber.completeness(duration: 60, expected: nil) == .unknown)
    #expect(MusicProber.completeness(duration: nil, expected: 200) == .unknown)
}

// MARK: - Selection

@Test func firstCompleteLosslessStreamWins() async throws {
    let track = qqTrack("晴天", ["周杰伦"], duration: 269.75, id: "0039MnYb0qxYhV")
    let vkeys = FakeProvider(id: .vkeys, platforms: [.qq]) { _ in stream("/flac/24/44100/269.75") }
    let hyw = FakeProvider(id: .hyw, platforms: [.qq]) { _ in Issue.record("fallback asked"); return stream("/flac/16/44100/269.75") }
    let selection = try await resolver([vkeys, hyw]).select(track, preference: .losslessPreferred)
    #expect(selection.candidate.provider == .vkeys && !selection.degraded)
    #expect(selection.probe.format.label == "FLAC · 24-bit / 44.1 kHz")
    #expect(selection.untried.map(\.provider) == [.hyw])
}

@Test func previewsAndFalseQualityLabelsAreRejected() async throws {
    let track = qqTrack("稻香", ["周杰伦"], duration: 223.45, id: "003aAYrm3GE0Ac")
    // A 60-second sample reported as a success.
    let preview = FakeProvider(id: .vkeys, platforms: [.qq]) { _ in stream("/flac/16/44100/60", claimed: "flac") }
    // "flac" claimed, MP3 served.
    let mislabelled = FakeProvider(id: .hyw, platforms: [.qq]) { _ in stream("/mp3/223.45", claimed: "flac") }
    let selection = try await resolver([preview, mislabelled]).select(track, preference: .losslessPreferred)
    #expect(selection.candidate.provider == .hyw)
    #expect(selection.degraded && selection.probe.format.codec == .mp3)
    #expect(selection.attempts.contains { if case .failed(.preview(let s)) = $0.outcome { abs(s - 60) < 0.01 } else { false } })

    await #expect(throws: MusicProviderError.notLossless) {
        try await resolver([preview, mislabelled]).select(track, preference: .losslessOnly)
    }
    await #expect(throws: MusicProviderError.preview(60)) {
        try await resolver([preview]).select(track, preference: .losslessPreferred)
    }
}

@Test func lossyPreferencesAskChannelsForLossyAudioAndNeverCallItDegraded() async throws {
    let track = qqTrack("晴天", ["周杰伦"], duration: 269.75, id: "q")
    let log = QualityLog()
    let flac = QualityProvider(id: .vkeys, platforms: [.qq], log: log) { _ in stream("/flac/16/44100/269.75") }
    let mp3 = QualityProvider(id: .hyw, platforms: [.qq], log: log) { _ in stream("/mp3/269.75") }
    // A lossless answer is not the wanted kind: the fallback gets its turn, and its MP3 wins.
    let high = try await resolver([flac, mp3]).select(track, preference: .high)
    #expect(high.candidate.provider == .hyw && high.probe.format.codec == .mp3 && !high.degraded)
    #expect(log.qualities == [.high, .high])

    // A channel that only has lossless still plays it rather than failing.
    let standard = try await resolver([flac]).select(track, preference: .standard)
    #expect(standard.candidate.provider == .vkeys && standard.probe.format.isLossless && !standard.degraded)
    #expect(log.qualities.last == .standard)
}

@Test func channelsAskForTheChosenTier() {
    #expect(MusicQualityPreference.high.requested == .high && MusicQualityPreference.standard.requested == .standard)
    #expect(MusicQualityPreference.losslessPreferred.wantsLossless && !MusicQualityPreference.high.wantsLossless)
    #expect(VKeysProvider.code(for: .lossless) == "10" && VKeysProvider.code(for: .high) == "8" && VKeysProvider.code(for: .standard) == "6")
    #expect(GDStudioProvider.bitrate(for: .lossless) == "999" && GDStudioProvider.bitrate(for: .high) == "320" && GDStudioProvider.bitrate(for: .standard) == "128")
    #expect(HYWProvider.quality(for: .lossless) == "flac" && HYWProvider.quality(for: .standard) == "128k")
    #expect(NianxinProvider.levels(for: .lossless) == ["lossless", "exhigh"] && NianxinProvider.levels(for: .standard) == ["standard"])
    #expect(XinghaiProvider.quality(for: .lossless, platform: .kuwo) == "flac" && XinghaiProvider.quality(for: .high, platform: .kuwo) == "320k")
    #expect(XinghaiProvider.quality(for: .lossless, platform: .netease) == "lossless" && XinghaiProvider.quality(for: .standard, platform: .netease) == "standard")
    #expect(MiguProvider.tiers(for: .lossless).map(\.name) == ["SQ", "HQ"] && MiguProvider.tiers(for: .high).map(\.name) == ["HQ"])
    #expect(MiguProvider.tiers(for: .standard).isEmpty)
}

@Test func lossyFirstKeepsLookingForLossless() async throws {
    var track = qqTrack("十年", ["陈奕迅"], duration: 205.4, id: "q")
    track.ids[.netease] = "66842"
    let vkeys = FakeProvider(id: .vkeys, platforms: [.qq]) { _ in stream("/mp3/205.4") }
    let gd = FakeProvider(id: .gdstudio, platforms: [.netease]) { _ in
        try await Task.sleep(for: .milliseconds(100))
        return stream("/flac/16/44100/205.42")
    }
    let selection = try await resolver([vkeys, gd]).select(track, preference: .losslessPreferred)
    #expect(selection.candidate.provider == .gdstudio && !selection.degraded)
    // A different, longer version is refused rather than played in its place.
    let live = FakeProvider(id: .gdstudio, platforms: [.netease]) { _ in stream("/flac/16/44100/260") }
    let fallback = try await resolver([vkeys, live]).select(track, preference: .losslessPreferred)
    #expect(fallback.candidate.provider == .vkeys && fallback.degraded)
    #expect(fallback.attempts.contains { $0.outcome == .failed(.differentRecording(260)) })
}

@Test func blockedPrimaryFallsBackAndCoolsDown() async throws {
    let health = MusicHealth(file: nil)
    let track = qqTrack("七里香", ["周杰伦"], duration: 299.2, id: "004Z8Ihr0JIu5s")
    let blocked = FakeProvider(id: .vkeys, platforms: [.qq]) { _ in throw MusicProviderError.upstreamRisk }
    let hyw = FakeProvider(id: .hyw, platforms: [.qq]) { _ in stream("/flac/16/44100/299.2") }
    let first = try await resolver([blocked, hyw], health: health).select(track, preference: .losslessPreferred)
    #expect(first.candidate.provider == .hyw)
    #expect(await health.failing(MusicHealth.key("vkeys", .qq, .resolve)))
    // While VKeys cools down, HYW is asked first and VKeys not at all.
    let second = try await resolver([blocked, hyw], health: health).select(track, preference: .losslessPreferred)
    #expect(second.attempts.map(\.candidate.provider) == [.hyw])

    // Both fail: the clearest reason is reported.
    let down = FakeProvider(id: .hyw, platforms: [.qq]) { _ in throw MusicProviderError.invalidResponse("HYW code 500") }
    await #expect(throws: MusicProviderError.upstreamRisk) {
        try await resolver([blocked, down]).select(track, preference: .losslessPreferred)
    }
}

@Test func aFailedQQSongIsLookedUpOnNetEase() async throws {
    let track = qqTrack("倒强", ["五月天"], duration: 271.2, id: "qqmid")
    let blocked = FakeProvider(id: .vkeys, platforms: [.qq]) { _ in throw MusicProviderError.upstreamRisk }
    let gd = FakeProvider(id: .gdstudio, platforms: [.netease]) { id in
        #expect(id == "386175")
        return stream("/flac/16/44100/271.3")
    }
    let netease = FakeCatalog(platform: .netease) { query in
        #expect(query == "倒强 五月天")
        // A live cut first: never joined. Then the same recording.
        return [neteaseTrack("倒强 (Live)", ["五月天"], duration: 300, id: "9"), neteaseTrack("倒强", ["五月天"], duration: 271.0, id: "386175")]
    }
    let resolver = MusicResolver(providers: [blocked, gd], prober: MusicProber(transport: audioTransport(), inspector: nil),
                                 health: MusicHealth(file: nil), companions: MusicCompanionFinder(catalogs: [netease]))
    let selection = try await resolver.select(track, preference: .losslessPreferred)
    #expect(selection.candidate.provider == .gdstudio && selection.track.ids[.netease] == "386175")
    #expect(selection.attempts.map(\.candidate.provider) == [.vkeys, .gdstudio])
    // No same recording on NetEase: the original failure stands.
    let nothing = MusicResolver(providers: [blocked, gd], prober: MusicProber(transport: audioTransport(), inspector: nil), health: MusicHealth(file: nil),
                                companions: MusicCompanionFinder(catalogs: [FakeCatalog(platform: .netease) { _ in [neteaseTrack("倒强", ["别人"], duration: 271, id: "1")] }]))
    await #expect(throws: MusicProviderError.upstreamRisk) { try await nothing.select(track, preference: .losslessPreferred) }
}

@Test func theBudgetBoundsSlowChannels() async throws {
    let track = qqTrack("夜曲", ["周杰伦"], duration: 226.83, id: "001zMQr71F1Qo8")
    let slow = FakeProvider(id: .vkeys, platforms: [.qq]) { _ in
        try await Task.sleep(for: .seconds(30))
        return stream("/flac/16/44100/226.83")
    }
    let start = Date()
    await #expect(throws: MusicProviderError.timeout) {
        try await resolver([slow], budget: 1).select(track, preference: .losslessPreferred)
    }
    #expect(Date().timeIntervalSince(start) < 3)
}

@Test func cancellingASelectionBlamesNoChannel() async throws {
    let health = MusicHealth(file: nil)
    let track = qqTrack("青花瓷", ["周杰伦"], duration: 239.35, id: "002qU5aY3Qu24y")
    let slow = FakeProvider(id: .vkeys, platforms: [.qq]) { _ in
        try await Task.sleep(for: .seconds(5))
        return stream("/flac/16/44100/239.35")
    }
    let task = Task { try await resolver([slow], health: health).select(track, preference: .losslessPreferred) }
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()
    _ = await task.result
    #expect(!(await health.failing(MusicHealth.key("vkeys", .qq, .resolve))))
    for _ in 0..<3 { await health.record(MusicHealth.key("vkeys", .qq, .resolve), error: .cancelled) }
    #expect(!(await health.failing(MusicHealth.key("vkeys", .qq, .resolve))))
}

@Test func expiredAddressesResolveAgainOnce() async throws {
    let track = qqTrack("那天下雨了", ["周杰伦"], duration: 223.33, id: "0044SaFh0apuR2")
    let counter = Counter()
    let vkeys = FakeProvider(id: .vkeys, platforms: [.qq]) { _ in
        stream("/flac/24/48000/223.33?n=\(counter.next())")
    }
    let resolver = resolver([vkeys])
    let cache = MusicStreamCache()
    let first = try await resolver.select(track, preference: .losslessPreferred, cache: cache)
    // Within one playback the address is reused...
    let again = try await resolver.select(track, preference: .losslessPreferred, cache: cache)
    #expect(again.stream.url == first.stream.url)
    // ...until it fails, when the same channel is asked again.
    let refreshed = try await resolver.refresh(first.candidate, track: track, preference: .losslessPreferred, cache: cache)
    #expect(refreshed.stream.url != first.stream.url)
    #expect(MusicRecovery.canResume(from: first.probe, to: refreshed.probe))
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}

@Test func recoveryRefreshesThenSwitchesThenStops() {
    let a = MusicCandidate(platform: .qq, songID: "x", provider: .vkeys)
    let b = MusicCandidate(platform: .netease, songID: "1", provider: .gdstudio)
    var recovery = MusicRecovery()
    #expect(recovery.next(failed: a, untried: [b]) == .refresh(a))
    #expect(recovery.next(failed: a, untried: [b]) == .switchTo(b))
    #expect(recovery.next(failed: b, untried: []) == .giveUp)
    var single = MusicRecovery()
    #expect(single.next(failed: a, untried: []) == .refresh(a))
    #expect(single.next(failed: a, untried: []) == .giveUp)

    let short = MusicProbeResult(format: MusicAudioFormat(codec: .flac), duration: 223.3, evidence: [.header])
    var other = short; other.duration = 260
    var unknown = short; unknown.duration = nil
    #expect(MusicRecovery.canResume(from: short, to: short))
    #expect(!MusicRecovery.canResume(from: short, to: other))
    #expect(!MusicRecovery.canResume(from: short, to: unknown))
}

// MARK: - Health and budgets

@Test func gdBudgetAllowsFiftyRequestsPerFiveMinutes() async throws {
    let health = MusicHealth(file: nil), now = Date()
    for second in 0..<50 { try await health.admit("gdstudio", now: now.addingTimeInterval(Double(second))) }
    do {
        try await health.admit("gdstudio", now: now.addingTimeInterval(60))
        Issue.record("51st request admitted")
    } catch {
        #expect(error == .rateLimited(until: now.addingTimeInterval(300)))
    }
    // The window slides: the first request leaves it after five minutes.
    try await health.admit("gdstudio", now: now.addingTimeInterval(300.5))
    // Other services are not limited here.
    for _ in 0..<100 { try await health.admit("vkeys", now: now) }
}

@Test func cooldownsFollowTheKindOfFailure() async {
    let health = MusicHealth(file: nil), now = Date()
    let key = MusicHealth.key("gdstudio", .netease, .resolve)
    // A song a channel lacks, or this device being offline, never cools it down.
    for _ in 0..<5 {
        await health.record(key, error: .noResource, now: now)
        await health.record(key, error: .network("offline"), now: now)
        await health.record(key, error: .preview(60), now: now)
    }
    #expect(await health.coolingUntil(key, now: now) == nil)
    // Retry-After is honoured.
    await health.record(key, error: .rateLimited(until: now.addingTimeInterval(600)), now: now)
    #expect(await health.coolingUntil(key, now: now) == now.addingTimeInterval(600))
    #expect(await health.coolingUntil(key, now: now.addingTimeInterval(601)) == nil)
    // One timeout is noted; two in a row start a cooldown; a success clears it.
    let other = MusicHealth.key("vkeys", .qq, .resolve)
    await health.record(other, error: .timeout, now: now)
    #expect(await health.coolingUntil(other, now: now) == nil)
    await health.record(other, error: .timeout, now: now)
    #expect(await health.coolingUntil(other, now: now) != nil)
    await health.record(other, error: nil, now: now)
    #expect(await health.coolingUntil(other, now: now) == nil)
    // Search failures say nothing about playback.
    await health.record(MusicHealth.key("qq", .qq, .search), error: .upstreamRisk, now: now)
    #expect(await health.coolingUntil(MusicHealth.key("vkeys", .qq, .resolve), now: now) == nil)
    let response = MusicHTTPResponse(status: 429, headers: ["retry-after": "120"], body: Data())
    #expect(response.retryAfter(now: now) == now.addingTimeInterval(120))
}

// MARK: - Search

private struct FakeCatalog: MusicCatalogSource {
    let platform: MusicPlatform
    let handler: @Sendable (String) async throws -> [MusicTrack]
    func search(_ query: String, page: Int) async throws -> [MusicTrack] { try await handler(query) }
}

@MainActor @Test func aLateAnswerNeverReplacesNewerResults() async throws {
    let qq = FakeCatalog(platform: .qq) { query in
        // The first query's answer arrives after the second query's.
        try? await Task.sleep(for: .milliseconds(query == "晴天" ? 400 : 10))
        return [qqTrack(query, ["周杰伦"], duration: 200, id: query)]
    }
    let netease = FakeCatalog(platform: .netease) { _ in throw MusicProviderError.rateLimited(until: nil) }
    let model = MusicSearchModel(catalogs: [qq, netease], health: MusicHealth(file: nil))
    model.search("晴天", immediately: true)
    try await Task.sleep(for: .milliseconds(50))
    model.search("稻香 周杰伦", immediately: true)
    try await Task.sleep(for: .milliseconds(500))
    try await settle(model)
    #expect(model.results.map(\.title) == ["稻香 周杰伦"])
    #expect(!model.busy)
    // One catalog failing is reported, but the search still has results.
    #expect(model.failures[.netease] != nil && !model.failed && !model.empty)
}

@MainActor @Test func searchFindsTheDirectHitAcrossCatalogs() async throws {
    let qq = FakeCatalog(platform: .qq) { _ in [qqTrack("江南", ["林俊杰"], duration: 267, id: "q", album: "第二天堂")] }
    let netease = FakeCatalog(platform: .netease) { _ in
        [neteaseTrack("江南", ["林俊杰"], duration: 267.9, id: "108914"), neteaseTrack("江南 (Live)", ["林俊杰"], duration: 268, id: "108779")]
    }
    let model = MusicSearchModel(catalogs: [qq, netease], health: MusicHealth(file: nil))
    model.search("江南 林俊杰")
    try await Task.sleep(for: .milliseconds(400))
    try await settle(model)
    #expect(model.results.count == 2)
    #expect(model.results.first?.ids == [.qq: "q", .netease: "108914"])
    #expect(model.directHit?.id == "qq:q")
    let empty = MusicSearchModel(catalogs: [FakeCatalog(platform: .qq) { _ in [] }], health: MusicHealth(file: nil))
    empty.search("zzzz", immediately: true)
    try await settle(empty)
    #expect(empty.empty && !empty.failed)
}

/// Waits for a search to finish, up to 5 seconds: fixed sleeps were too short with the whole suite running.
@MainActor func settle(_ model: MusicSearchModel) async throws {
    try await Task.sleep(for: .milliseconds(20))
    for _ in 0..<250 where model.busy { try await Task.sleep(for: .milliseconds(20)) }
}

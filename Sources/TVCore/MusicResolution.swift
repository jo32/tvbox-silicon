import AVFoundation
import Foundation

/// Reads what an audio address really serves: the first 256 KiB at most, by Range, parsed for the
/// format, and the platform decoder when the header leaves the codec or duration open. Extensions,
/// Content-Type and provider labels are never evidence; both CDNs sent FLAC as audio/x-ogg or
/// audio/mpeg in testing.
public struct MusicProber: Sendable {
    public typealias Inspector = @Sendable (ResolvedMusicStream) async throws -> MusicProbeResult
    let transport: MusicTransport
    let inspector: Inspector?
    static let byteLimit = 256 * 1024
    /// For the header read and the decoder together.
    static let timeout: TimeInterval = 3

    public init(transport: MusicTransport = URLSessionMusicTransport(), inspector: Inspector? = AVFoundationMusicInspector.inspect) {
        self.transport = transport; self.inspector = inspector
    }

    public func probe(_ stream: ResolvedMusicStream, expected: Double?) async throws -> MusicProbeResult {
        let start = Date()
        var request = MusicHTTP.request(stream.url, timeout: Self.timeout, headers: stream.headers)
        request.setValue("bytes=0-\(Self.byteLimit - 1)", forHTTPHeaderField: "Range")
        let transport = transport, ranged = request
        let response = try await MusicHTTP.withTimeout(Self.timeout) { try await transport.send(ranged, limit: Self.byteLimit) }
        switch response.status {
        case 200, 206: break
        case 403, 404, 410: throw MusicProviderError.noResource
        case 429: throw MusicProviderError.rateLimited(until: response.retryAfter())
        default: throw MusicProviderError.invalidResponse("audio HTTP \(response.status)")
        }
        let total = Self.totalLength(response)
        var result = Self.sniff(response.body, totalLength: total)
        let settled = result.map { $0.format.codec != .unknown && $0.duration != nil } ?? false
        if !settled, let inspector {
            let left = Self.timeout - Date().timeIntervalSince(start)
            if left > 0.3, let deep = try? await MusicHTTP.withTimeout(left, { try await inspector(stream) }) {
                if var header = result {
                    if header.format.codec == .unknown { header.format = deep.format }
                    header.format.sampleRate = header.format.sampleRate ?? deep.format.sampleRate
                    header.format.bitDepth = header.format.bitDepth ?? deep.format.bitDepth
                    header.duration = header.duration ?? deep.duration
                    header.evidence.formUnion(deep.evidence)
                    result = header
                } else {
                    result = deep
                }
            }
        }
        guard var result, result.format.codec != .unknown else {
            throw MusicProviderError.unsupportedFormat("unrecognized audio header")
        }
        result.byteLength = total
        result.completeness = Self.completeness(duration: result.duration, expected: expected)
        return result
    }

    /// Complete when the audio is as long as the recording (within `max(3 s, 2%)`), a preview when
    /// clearly shorter. With either length unknown it stays unknown: a short song is not a preview.
    public static func completeness(duration: Double?, expected: Double?) -> MusicCompleteness {
        guard let duration, duration > 0, let expected, expected > 0 else { return .unknown }
        return duration < expected - MusicMatching.durationTolerance(expected) ? .preview : .complete
    }

    static func totalLength(_ response: MusicHTTPResponse) -> Int? {
        if let range = response.headers["content-range"], let slash = range.lastIndex(of: "/"), let total = Int(range[range.index(after: slash)...]) {
            return total
        }
        return response.status == 200 ? response.headers["content-length"].flatMap { Int($0) } : nil
    }

    // MARK: - Headers

    /// The format, and the duration when the header holds it, from a file's first bytes.
    public static func sniff(_ data: Data, totalLength: Int?) -> MusicProbeResult? {
        let bytes = [UInt8](data)
        var offset = 0
        // ID3v2 tags precede FLAC and MP3 audio: "ID3", version, flags, then a syncsafe size.
        if bytes.count >= 10, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 {
            let size = Int(bytes[6] & 0x7F) << 21 | Int(bytes[7] & 0x7F) << 14 | Int(bytes[8] & 0x7F) << 7 | Int(bytes[9] & 0x7F)
            offset = 10 + size + (bytes[5] & 0x10 != 0 ? 10 : 0)
        }
        guard bytes.count >= offset + 4 else { return nil }
        if bytes[offset..<offset + 4] == [0x66, 0x4C, 0x61, 0x43] { return flac(bytes, at: offset + 4) }
        if offset == 0, bytes.count >= 12, bytes[0..<4] == [0x52, 0x49, 0x46, 0x46], bytes[8..<12] == [0x57, 0x41, 0x56, 0x45] { return wav(bytes) }
        if offset == 0, bytes[0..<4] == [0x4F, 0x67, 0x67, 0x53] { return ogg(bytes) }
        if offset == 0, bytes.count >= 8, bytes[4..<8] == [0x66, 0x74, 0x79, 0x70] {
            // MP4 holds AAC or ALAC; the decoder tells which.
            return MusicProbeResult(format: MusicAudioFormat(codec: .unknown), duration: nil, evidence: [.header])
        }
        return mpeg(bytes, at: offset, totalLength: totalLength)
    }

    /// FLAC's STREAMINFO block: sample rate (20 bits), channels (3), bits per sample (5), total samples (36).
    static func flac(_ bytes: [UInt8], at start: Int) -> MusicProbeResult? {
        guard bytes.count >= start + 4 + 18, bytes[start] & 0x7F == 0 else { return nil }
        let info = start + 4 + 10
        let rate = Int(bytes[info]) << 12 | Int(bytes[info + 1]) << 4 | Int(bytes[info + 2]) >> 4
        let depth = (Int(bytes[info + 2] & 0x01) << 4 | Int(bytes[info + 3]) >> 4) + 1
        let samples = Int(bytes[info + 3] & 0x0F) << 32 | Int(bytes[info + 4]) << 24 | Int(bytes[info + 5]) << 16 | Int(bytes[info + 6]) << 8 | Int(bytes[info + 7])
        guard rate > 0 else { return nil }
        return MusicProbeResult(format: MusicAudioFormat(codec: .flac, sampleRate: rate, bitDepth: depth),
                                duration: samples > 0 ? Double(samples) / Double(rate) : nil, evidence: [.header])
    }

    static func wav(_ bytes: [UInt8]) -> MusicProbeResult? {
        var index = 12, rate = 0, depth = 0, channels = 0, dataSize: Int?
        while index + 8 <= bytes.count {
            let id = bytes[index..<index + 4], size = le32(bytes, index + 4)
            if id == [0x66, 0x6D, 0x74, 0x20], index + 24 <= bytes.count {
                channels = Int(bytes[index + 10]) | Int(bytes[index + 11]) << 8
                rate = le32(bytes, index + 12)
                depth = index + 24 <= bytes.count ? Int(bytes[index + 22]) | Int(bytes[index + 23]) << 8 : 0
            } else if id == [0x64, 0x61, 0x74, 0x61] {
                dataSize = size; break
            }
            index += 8 + size + (size & 1)
        }
        guard rate > 0 else { return nil }
        let bytesPerSecond = rate * max(channels, 1) * max(depth, 8) / 8
        return MusicProbeResult(format: MusicAudioFormat(codec: .wav, sampleRate: rate, bitDepth: depth > 0 ? depth : nil),
                                duration: dataSize.map { Double($0) / Double(bytesPerSecond) }, evidence: [.header])
    }

    static func ogg(_ bytes: [UInt8]) -> MusicProbeResult? {
        let window = Array(bytes.prefix(256))
        func find(_ marker: [UInt8]) -> Int? {
            guard window.count >= marker.count else { return nil }
            return (0...(window.count - marker.count)).first { window[$0..<$0 + marker.count].elementsEqual(marker) }
        }
        if let at = find(Array("OpusHead".utf8)), at + 16 <= window.count {
            return MusicProbeResult(format: MusicAudioFormat(codec: .opus, sampleRate: le32(window, at + 12)), duration: nil, evidence: [.header])
        }
        if let at = find([0x01] + Array("vorbis".utf8)), at + 16 <= window.count {
            return MusicProbeResult(format: MusicAudioFormat(codec: .vorbis, sampleRate: le32(window, at + 12)), duration: nil, evidence: [.header])
        }
        if let at = find([0x7F] + Array("FLAC".utf8)), let inner = flac(window, at: at + 13) {
            return inner
        }
        return nil
    }

    private static let mp3Rates: [[Int]] = [[11025, 12000, 8000], [], [22050, 24000, 16000], [44100, 48000, 32000]]
    private static let mpeg1Layer3 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
    private static let mpeg2Layer3 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
    private static let aacRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    /// MP3 or ADTS AAC frames. MP3 duration comes from a Xing/Info header, or from the file size at a constant bit rate.
    static func mpeg(_ bytes: [UInt8], at offset: Int, totalLength: Int?) -> MusicProbeResult? {
        guard bytes.count >= offset + 4, bytes[offset] == 0xFF, bytes[offset + 1] & 0xE0 == 0xE0 else { return nil }
        let b1 = bytes[offset + 1], b2 = bytes[offset + 2]
        let version = Int(b1 >> 3 & 0x03), layer = Int(b1 >> 1 & 0x03)
        if layer == 0 {
            // ADTS: the layer bits are zero.
            let index = Int(b2 >> 2 & 0x0F)
            return MusicProbeResult(format: MusicAudioFormat(codec: .aac, sampleRate: index < aacRates.count ? aacRates[index] : nil), duration: nil, evidence: [.header])
        }
        guard layer == 1, version != 1 else { return nil }
        let rateIndex = Int(b2 >> 2 & 0x03), bitrateIndex = Int(b2 >> 4)
        guard rateIndex < 3, bitrateIndex > 0, bitrateIndex < 15 else { return nil }
        let sampleRate = mp3Rates[version][rateIndex]
        let bitrate = (version == 3 ? mpeg1Layer3 : mpeg2Layer3)[bitrateIndex]
        var duration: Double?
        let window = Array(bytes[offset..<min(bytes.count, offset + 200)])
        let xing = (0..<max(0, window.count - 12)).first { i in
            window[i..<i + 4].elementsEqual("Xing".utf8) || window[i..<i + 4].elementsEqual("Info".utf8)
        }
        if let xing, be32(window, xing + 4) & 1 != 0 {
            let frames = be32(window, xing + 8)
            duration = Double(frames * (version == 3 ? 1152 : 576)) / Double(sampleRate)
        } else if let totalLength, totalLength > offset {
            duration = Double(totalLength - offset) * 8 / Double(bitrate * 1000)
        }
        return MusicProbeResult(format: MusicAudioFormat(codec: .mp3, sampleRate: sampleRate, bitrate: xing == nil ? bitrate : nil),
                                duration: duration, evidence: [.header])
    }

    private static func le32(_ bytes: [UInt8], _ at: Int) -> Int {
        guard at + 4 <= bytes.count else { return 0 }
        return Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
    }
    private static func be32(_ bytes: [UInt8], _ at: Int) -> Int {
        guard at + 4 <= bytes.count else { return 0 }
        return Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
    }
}

/// The platform decoder's view of a stream: whether it can play it, its codec, sample rate, bit
/// depth (for FLAC and ALAC, from the format flags) and duration.
public enum AVFoundationMusicInspector {
    @Sendable public static func inspect(_ stream: ResolvedMusicStream) async throws -> MusicProbeResult {
        let asset = AVURLAsset(url: stream.url, options: stream.headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": stream.headers])
        guard try await asset.load(.isPlayable) else { throw MusicProviderError.unsupportedFormat("not playable here") }
        let duration = try await asset.load(.duration)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first,
              let description = try await track.load(.formatDescriptions).first else {
            throw MusicProviderError.unsupportedFormat("no audio track")
        }
        let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
        let codec: MusicCodec, depth: Int?
        switch CMFormatDescriptionGetMediaSubType(description) {
        case kAudioFormatFLAC: codec = .flac; depth = basic.flatMap { losslessDepth($0.mFormatFlags) }
        case kAudioFormatAppleLossless: codec = .alac; depth = basic.flatMap { losslessDepth($0.mFormatFlags) }
        case kAudioFormatLinearPCM: codec = .wav; depth = basic.map { Int($0.mBitsPerChannel) }
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_LD: codec = .aac; depth = nil
        case kAudioFormatMPEGLayer3: codec = .mp3; depth = nil
        case kAudioFormatOpus: codec = .opus; depth = nil
        default: codec = .unknown; depth = nil
        }
        let rate = basic.map { Int($0.mSampleRate) }.flatMap { $0 > 0 ? $0 : nil }
        let seconds = duration.seconds.isFinite && duration.seconds > 0 ? duration.seconds : nil
        return MusicProbeResult(format: MusicAudioFormat(codec: codec, sampleRate: rate, bitDepth: depth), duration: seconds, evidence: [.decoder])
    }

    /// `kAppleLosslessFormatFlag_16BitSourceData` and its siblings, which FLAC descriptions share.
    static func losslessDepth(_ flags: AudioFormatFlags) -> Int? {
        switch flags {
        case 1: 16
        case 2: 20
        case 3: 24
        case 4: 32
        default: nil
        }
    }
}

/// Addresses resolved during one playback, so switching channels or recovering reuses them. A new
/// song starts a new cache: an address whose lifetime is unknown is resolved again next time.
public actor MusicStreamCache {
    struct Entry { var stream: ResolvedMusicStream; var probe: MusicProbeResult }
    private var entries: [String: Entry] = [:]
    public init() {}
    func get(_ id: String, now: Date = Date()) -> Entry? {
        guard let entry = entries[id] else { return nil }
        // Known lifetimes end 30 seconds early, so playback doesn't start on a dying address.
        if let expires = entry.stream.expiresAt, expires.timeIntervalSince(now) < 30 { entries[id] = nil; return nil }
        return entry
    }
    func put(_ id: String, _ entry: Entry) { entries[id] = entry }
    public func invalidate(_ id: String) { entries[id] = nil }
}

/// Picks the channel a track plays from: candidates in order (each catalog's primary provider,
/// then fallbacks), at most two at a time, each resolved and probed. The first complete,
/// playable lossless stream wins at once; otherwise, when the budget or the candidates run out,
/// the best found by completeness, losslessness and format, or a clear failure.
public struct MusicResolver: Sendable {
    let providers: [MusicProviderID: any MusicStreamProvider]
    let prober: MusicProber
    let health: MusicHealth
    /// Finds the track in catalogs it was not found in, when every channel it has failed.
    let companions: MusicCompanionFinder?
    /// For one selection, resolution and probing together.
    var budget: TimeInterval = 15
    var parallel = 2
    /// Primary providers per catalog, then fallbacks. Migu's own servers and Kuwo through Nianxin
    /// lead: in the 2026-10-14 test they played songs VKeys and GD no longer reach (Jay Chou's).
    static let primaries: [(MusicPlatform, MusicProviderID)] = [(.migu, .migu), (.kuwo, .nianxin), (.qq, .vkeys), (.netease, .gdstudio)]
    /// LX Music sources the listener imported come last: third-party scripts, asked when the built-in channels
    /// found nothing better.
    static let order: [(MusicPlatform, MusicProviderID)] = primaries + [(.kuwo, .xinghai), (.netease, .nianxin), (.qq, .hyw), (.netease, .xinghai),
                                                                         (.qq, .lx), (.netease, .lx), (.kuwo, .lx), (.migu, .lx)]
    static func isPrimary(_ candidate: MusicCandidate) -> Bool {
        primaries.contains { $0.0 == candidate.platform && $0.1 == candidate.provider }
    }

    public init(providers: [any MusicStreamProvider], prober: MusicProber = MusicProber(), health: MusicHealth = .shared,
                companions: MusicCompanionFinder? = nil, budget: TimeInterval = 15) {
        self.providers = Dictionary(providers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.prober = prober; self.health = health; self.companions = companions; self.budget = budget
    }

    /// The providers the viewer left on.
    public init(preferences: MusicPreferences, transport: MusicTransport = URLSessionMusicTransport(), health: MusicHealth = .shared) {
        var list: [any MusicStreamProvider] = []
        if preferences.enabled(.extension), let extensions = MusicExtensionProvider() { list.append(extensions) }
        if preferences.enabled(.vkeys) { list.append(VKeysProvider(transport: transport)) }
        if preferences.enabled(.gdstudio) { list.append(GDStudioProvider(transport: transport, health: health)) }
        if preferences.enabled(.hyw) { list.append(HYWProvider(key: preferences.hywKey, transport: transport)) }
        if preferences.enabled(.migu) { list.append(MiguProvider(transport: transport)) }
        if preferences.enabled(.nianxin) { list.append(NianxinProvider(transport: transport)) }
        if preferences.enabled(.xinghai) { list.append(XinghaiProvider(transport: transport, health: health)) }
        if preferences.enabled(.lx), let lx = LXMusicProvider(sources: LXSourceLibrary.shared.enabled, health: health) { list.append(lx) }
        self.init(providers: list, prober: MusicProber(transport: transport), health: health,
                  companions: MusicCompanionFinder(catalogs: MusicSearchModel.defaultCatalogs(transport: transport, health: health)))
    }

    public func candidates(for track: MusicTrack) -> [MusicCandidate] {
        let listed = Self.order.compactMap { platform, provider -> MusicCandidate? in
            guard let songID = track.ids[platform], let resolver = providers[provider], resolver.platforms.contains(platform) else { return nil }
            return MusicCandidate(platform: platform, songID: songID, provider: provider)
        }
        // A music extension's own song plays from what the extension gives; after the built-in channels when the
        // song was also found in a catalog.
        guard let songID = track.ids[.ext], providers[.extension]?.platforms.contains(.ext) == true else { return listed }
        return listed + [MusicCandidate(platform: .ext, songID: songID, provider: .extension)]
    }

    private struct Found: Sendable {
        var candidate: MusicCandidate
        var stream: ResolvedMusicStream
        var probe: MusicProbeResult
        var order: Int
    }

    public func select(_ track: MusicTrack, preference: MusicQualityPreference, excluding: Set<String> = [],
                       cache: MusicStreamCache = MusicStreamCache()) async throws -> MusicPlaybackSelection {
        let deadline = Date().addingTimeInterval(budget)
        let quality = preference.requested
        var ready: [MusicCandidate] = [], cooling: [MusicCandidate] = []
        for candidate in candidates(for: track) where !excluding.contains(candidate.id) {
            let key = MusicHealth.key(candidate.provider.rawValue, candidate.platform, .resolve)
            if await health.failing(key) { cooling.append(candidate) } else { ready.append(candidate) }
        }
        guard !(ready.isEmpty && cooling.isEmpty) else { throw providers.isEmpty ? MusicProviderError.authRequired : MusicProviderError.noResource }
        // A cooling channel is only asked when nothing else is left: one probe, after the others.
        var queue = ready + cooling
        var attempts: [MusicAttempt] = [], found: [Found] = [], order = 0

        while !queue.isEmpty {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0.5 else { break }
            if !found.isEmpty, let first = queue.first, cooling.contains(first) { break }
            // Each catalog's primary channel runs alongside the other's; a fallback, or a channel
            // cooling down, only runs alone, after what came before it failed.
            let together = queue.prefix(parallel).prefix { Self.isPrimary($0) && !cooling.contains($0) }
            let wave = together.isEmpty ? [queue[0]] : Array(together)
            queue.removeFirst(wave.count)
            let winner: Found? = await withTaskGroup(of: (MusicCandidate, Result<(ResolvedMusicStream, MusicProbeResult), MusicProviderError>, Double).self) { group in
                for candidate in wave {
                    group.addTask { await self.attempt(candidate, track: track, quality: quality, timeout: remaining, cache: cache) }
                }
                for await (candidate, result, seconds) in group {
                    switch result {
                    case .success(let (stream, probe)):
                        attempts.append(MusicAttempt(candidate: candidate, outcome: .playable(probe), seconds: seconds))
                        let item = Found(candidate: candidate, stream: stream, probe: probe, order: order); order += 1
                        found.append(item)
                        // The wanted kind of audio, complete: nothing left to compare.
                        let wanted = preference.wantsLossless ? probe.format.isLossless : !probe.format.isLossless
                        if wanted && probe.completeness == .complete { group.cancelAll(); return item }
                    case .failure(let error):
                        attempts.append(MusicAttempt(candidate: candidate, outcome: .failed(error), seconds: seconds))
                    }
                }
                return nil
            }
            if let winner {
                return selection(track, winner, degraded: false, attempts: attempts, untried: queue)
            }
        }
        for candidate in queue {
            attempts.append(MusicAttempt(candidate: candidate, outcome: .skipped(found.isEmpty ? .timeout : .cancelled), seconds: 0))
        }
        let usable = Self.usable(found, for: preference)
        // Every channel failed: the same recording in another catalog may have one that works.
        if usable.isEmpty, let companions, deadline.timeIntervalSinceNow > 2,
           let wider = await companions.find(track), wider.ids.count > track.ids.count {
            var rest = self; rest.budget = deadline.timeIntervalSinceNow
            let tried = Set(attempts.map(\.candidate.id)).union(excluding)
            if var selection = try? await rest.select(wider, preference: preference, excluding: tried, cache: cache) {
                selection.attempts = attempts.filter { attempt in if case .skipped = attempt.outcome { false } else { true } } + selection.attempts
                return selection
            }
        }
        guard let best = usable.min(by: { Self.better($0, than: $1, preference: preference) }) else {
            if !found.isEmpty { throw MusicProviderError.notLossless }
            throw Self.summary(attempts.compactMap { attempt in
                if case .failed(let error) = attempt.outcome { return error }
                return nil
            }, budgetSpent: !queue.isEmpty)
        }
        return selection(track, best, degraded: preference.wantsLossless && !best.probe.format.isLossless, attempts: attempts, untried: queue)
    }

    /// What can play: only lossless for lossless-only; for a lossy preference, lossy streams, with
    /// lossless kept as a fallback for a channel that ignored the request.
    private static func usable(_ found: [Found], for preference: MusicQualityPreference) -> [Found] {
        switch preference {
        case .losslessOnly: return found.filter(\.probe.format.isLossless)
        case .losslessPreferred: return found
        case .high, .standard:
            let lossy = found.filter { !$0.probe.format.isLossless }
            return lossy.isEmpty ? found : lossy
        }
    }

    /// Resolves one candidate again, ignoring its cached address: for an address that stopped working.
    public func refresh(_ candidate: MusicCandidate, track: MusicTrack, preference: MusicQualityPreference,
                        cache: MusicStreamCache) async throws -> MusicPlaybackSelection {
        let quality = preference.requested
        await cache.invalidate(candidate.id + "|" + quality.rawValue)
        let (_, result, seconds) = await attempt(candidate, track: track, quality: quality, timeout: budget, cache: cache)
        switch result {
        case .success(let (stream, probe)):
            let attempt = MusicAttempt(candidate: candidate, outcome: .playable(probe), seconds: seconds)
            return MusicPlaybackSelection(track: track, candidate: candidate, stream: stream, probe: probe,
                                          degraded: preference.wantsLossless && !probe.format.isLossless, attempts: [attempt], untried: [])
        case .failure(let error): throw error
        }
    }

    private func selection(_ track: MusicTrack, _ found: Found, degraded: Bool, attempts: [MusicAttempt], untried: [MusicCandidate]) -> MusicPlaybackSelection {
        MusicPlaybackSelection(track: track, candidate: found.candidate, stream: found.stream, probe: found.probe,
                               degraded: degraded, attempts: attempts, untried: untried)
    }

    /// Complete first, then the kind of audio asked for, then the best within it, then what answered first.
    private static func better(_ a: Found, than b: Found, preference: MusicQualityPreference) -> Bool {
        func key(_ found: Found) -> [Int] {
            let format = found.probe.format
            let complete = found.probe.completeness == .complete ? 0 : 1
            switch preference {
            case .losslessPreferred, .losslessOnly:
                return [complete, format.isLossless ? 0 : 1,
                        -(format.bitDepth ?? 0), -(format.sampleRate ?? 0), -(format.bitrate ?? 0), found.order]
            case .high:
                return [complete, format.isLossless ? 1 : 0,
                        -(format.bitrate ?? 0), -(format.sampleRate ?? 0), found.order]
            case .standard:
                // The lightest stream wins, and one whose rate the header stated beats an unknown one.
                return [complete, format.isLossless ? 1 : 0, format.bitrate == nil ? 1 : 0, format.bitrate ?? 0, found.order]
            }
        }
        return key(a).lexicographicallyPrecedes(key(b))
    }

    /// The failure that best explains why nothing played.
    static func summary(_ errors: [MusicProviderError], budgetSpent: Bool) -> MusicProviderError {
        let ranked: [(MusicProviderError) -> Bool] = [
            { if case .network = $0 { true } else { false } },
            { if case .rateLimited = $0 { true } else { false } },
            { $0 == .upstreamRisk }, { $0 == .authRequired },
            { if case .preview = $0 { true } else { false } },
            { if case .differentRecording = $0 { true } else { false } },
            { if case .unsupportedFormat = $0 { true } else { false } },
            { $0 == .timeout }, { if case .invalidResponse = $0 { true } else { false } },
        ]
        for matches in ranked { if let error = errors.first(where: matches) { return error } }
        return budgetSpent ? .timeout : .noResource
    }

    private func attempt(_ candidate: MusicCandidate, track: MusicTrack, quality: MusicAudioQuality, timeout: TimeInterval,
                         cache: MusicStreamCache) async
        -> (MusicCandidate, Result<(ResolvedMusicStream, MusicProbeResult), MusicProviderError>, Double) {
        let start = Date()
        // Each quality gets its own address: a lossless resolution is no stand-in for a 128 kbps request.
        let cacheKey = candidate.id + "|" + quality.rawValue
        if let cached = await cache.get(cacheKey) { return (candidate, .success((cached.stream, cached.probe)), 0) }
        let key = MusicHealth.key(candidate.provider.rawValue, candidate.platform, .resolve)
        do {
            guard let provider = providers[candidate.provider] else { throw MusicProviderError.authRequired }
            let stream = try await MusicHTTP.withTimeout(min(8, timeout)) {
                try await provider.resolve(candidate.songID, platform: candidate.platform, track: track, quality: quality)
            }
            await health.record(key, error: nil)
            let probe = try await prober.probe(stream, expected: track.duration)
            if probe.completeness == .preview { throw MusicProviderError.preview(probe.duration ?? 0) }
            if let expected = track.duration, let duration = probe.duration, duration > expected + MusicMatching.durationTolerance(expected) {
                throw MusicProviderError.differentRecording(duration)
            }
            await cache.put(cacheKey, .init(stream: stream, probe: probe))
            Diagnostics.shared.record(.info, "music", "\(candidate.provider.rawValue) \(candidate.platform.rawValue) host=\(stream.url.host() ?? "-") \(probe.format.label) \(probe.completeness.rawValue) in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
            return (candidate, .success((stream, probe)), Date().timeIntervalSince(start))
        } catch {
            let failure = MusicProviderError(error)
            if failure != .cancelled { await health.record(key, error: failure) }
            Diagnostics.shared.record(.info, "music", "\(candidate.provider.rawValue) \(candidate.platform.rawValue) failed: \(failure.detail)")
            return (candidate, .failure(failure), Date().timeIntervalSince(start))
        }
    }
}

/// Looks a track up in the catalogs that did not list it, by title and first artist, and joins
/// an entry only when `MusicMatching.sameRecording` holds: title, artist, version, and length or album.
public struct MusicCompanionFinder: Sendable {
    let catalogs: [any MusicCatalogSource]
    public init(catalogs: [any MusicCatalogSource]) { self.catalogs = catalogs }

    public func find(_ track: MusicTrack) async -> MusicTrack? {
        var wider = track
        for catalog in catalogs where track.ids[catalog.platform] == nil {
            let query = ([track.title] + track.artists.prefix(1)).joined(separator: " ")
            guard let results = try? await MusicHTTP.withTimeout(6, { try await catalog.search(query, page: 1) }),
                  let match = results.first(where: { MusicMatching.sameRecording(wider, $0) != nil }) else { continue }
            wider = MusicMatching.merge([[wider], [match]]).first ?? wider
            Diagnostics.shared.record(.info, "music", "companion \(catalog.platform.rawValue) found: \(wider.evidence.joined(separator: ","))")
        }
        return wider.ids.count > track.ids.count ? wider : nil
    }
}

/// What to do when playback of a selection fails: re-resolve the same channel once (its address
/// may have expired), then move to a channel not tried yet, with at most two resolutions per
/// recovery; then stop and offer Retry.
public struct MusicRecovery: Sendable {
    public enum Step: Equatable, Sendable {
        case refresh(MusicCandidate)
        case switchTo(MusicCandidate)
        case giveUp
    }
    public private(set) var resolvesLeft: Int
    private var refreshed: Set<String> = []
    public init(resolves: Int = 2) { resolvesLeft = resolves }

    public mutating func next(failed: MusicCandidate, untried: [MusicCandidate]) -> Step {
        guard resolvesLeft > 0 else { return .giveUp }
        resolvesLeft -= 1
        if !refreshed.contains(failed.id) { refreshed.insert(failed.id); return .refresh(failed) }
        if let next = untried.first(where: { !refreshed.contains($0.id) }) { refreshed.insert(next.id); return .switchTo(next) }
        return .giveUp
    }

    /// Whether playback may continue where it was on another stream: only when both are the same
    /// length within tolerance, since a different version must not take over at the same second.
    public static func canResume(from previous: MusicProbeResult, to next: MusicProbeResult) -> Bool {
        guard let a = previous.duration, let b = next.duration else { return false }
        return abs(a - b) <= MusicMatching.durationTolerance(max(a, b))
    }
}

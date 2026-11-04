import Foundation

/// A music catalog the app searches. Each has its own song IDs; one recording can carry an ID in each.
public enum MusicPlatform: String, Codable, Sendable, CaseIterable, Hashable {
    // Merging takes catalogs in this order: QQ's entries carry durations and covers the others join.
    case qq, netease, migu, kuwo
    /// Songs, albums and playlists from the music extensions the listener imported (MusicExtensions.swift).
    case ext
    public var name: String {
        switch self {
        case .qq: L10n.text("QQ Music")
        case .netease: L10n.text("NetEase Cloud Music")
        case .migu: L10n.text("Migu Music")
        case .kuwo: L10n.text("Kuwo Music")
        case .ext: L10n.text("Music Extensions")
        }
    }
}

/// What sets a recording apart from the original studio version. Two tracks with different tags
/// are different recordings even when their titles and artists match.
public enum MusicVersionTag: String, Codable, Sendable, Hashable, CaseIterable, Comparable {
    case live, instrumental, remix, cover, rerecorded, acoustic, demo
    /// Any other "…版" or "… Version": a language version, a "healing" edit, a sped-up cut.
    case alternate
    public static func < (lhs: MusicVersionTag, rhs: MusicVersionTag) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
    public var name: String {
        switch self {
        case .live: L10n.text("Live")
        case .instrumental: L10n.text("Instrumental")
        case .remix: L10n.text("Remix")
        case .cover: L10n.text("Cover")
        case .rerecorded: L10n.text("Re-recorded")
        case .acoustic: L10n.text("Acoustic")
        case .demo: L10n.text("Demo")
        case .alternate: L10n.text("Other Version")
        }
    }
}

/// One recording, possibly found in both catalogs. `ids` holds its song ID in each catalog that has it.
public struct MusicTrack: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var title: String
    public var artists: [String]
    public var album: String?
    /// Seconds, as the catalog lists it; nil when no catalog said.
    public var duration: Double?
    public var artwork: URL?
    public var tags: Set<MusicVersionTag>
    public var ids: [MusicPlatform: String]
    /// Why entries from different catalogs were taken as one recording, for diagnostics.
    public var evidence: [String]
    /// Set for an episode of a TVBox source (an audiobook's chapter, #289): it plays from the source, not a catalog.
    public var source: MusicSourceEpisode?

    public init(platform: MusicPlatform, songID: String, title: String, artists: [String], album: String? = nil,
                duration: Double? = nil, artwork: URL? = nil) {
        id = platform.rawValue + ":" + songID
        self.title = title
        self.artists = artists
        self.album = album.flatMap { $0.isEmpty ? nil : $0 }
        self.duration = duration.flatMap { $0 > 0 ? $0 : nil }
        self.artwork = artwork
        tags = MusicMatching.tags(in: title)
        ids = [platform: songID]
        evidence = []
    }

    public var artistLine: String { artists.joined(separator: " / ") }
}

public enum MusicCodec: String, Codable, Sendable, Hashable {
    case flac, alac, wav, aac, mp3, vorbis, opus, unknown
    public var isLossless: Bool { [.flac, .alac, .wav].contains(self) }
    public var name: String {
        switch self {
        case .flac: "FLAC"
        case .alac: "ALAC"
        case .wav: "WAV"
        case .aac: "AAC"
        case .mp3: "MP3"
        case .vorbis: "Vorbis"
        case .opus: "Opus"
        case .unknown: L10n.text("Unknown format")
        }
    }
}

/// A stream's audio format as read from the file itself, never from what a provider claims.
public struct MusicAudioFormat: Hashable, Codable, Sendable {
    public var codec: MusicCodec
    /// Hz.
    public var sampleRate: Int?
    public var bitDepth: Int?
    /// kbps, for lossy streams when the header says.
    public var bitrate: Int?
    public init(codec: MusicCodec, sampleRate: Int? = nil, bitDepth: Int? = nil, bitrate: Int? = nil) {
        self.codec = codec; self.sampleRate = sampleRate; self.bitDepth = bitDepth; self.bitrate = bitrate
    }
    public var isLossless: Bool { codec.isLossless }

    /// "FLAC · 16-bit / 44.1 kHz", "MP3 · 320 kbps"; only what was read.
    public var label: String {
        var detail: [String] = []
        if let bitDepth, isLossless { detail.append("\(bitDepth)-bit") }
        if let sampleRate {
            let khz = Double(sampleRate) / 1000
            detail.append((khz.rounded() == khz ? String(format: "%.0f", khz) : String(format: "%.1f", khz)) + " kHz")
        }
        var text = codec.name
        if !detail.isEmpty { text += " · " + detail.joined(separator: " / ") }
        if !isLossless, let bitrate { text += " · \(bitrate) kbps" }
        return text
    }
}

public enum MusicCompleteness: String, Codable, Sendable, Hashable {
    /// As long as the catalog says the recording is.
    case complete
    /// Clearly shorter than the recording: a 30 or 60 second sample.
    case preview
    /// Not enough information to tell; never shown as complete.
    case unknown
}

/// What probing a stream established, and how.
public struct MusicProbeResult: Hashable, Codable, Sendable {
    public enum Evidence: String, Codable, Sendable, Hashable { case header, decoder }
    public var format: MusicAudioFormat
    /// Seconds; nil when neither the header nor the decoder said.
    public var duration: Double?
    /// Bytes in the whole file, from Content-Range or Content-Length.
    public var byteLength: Int?
    public var completeness: MusicCompleteness
    public var evidence: Set<Evidence>
    public var probedAt: Date
    public init(format: MusicAudioFormat, duration: Double?, byteLength: Int? = nil, completeness: MusicCompleteness = .unknown,
                evidence: Set<Evidence>, probedAt: Date = Date()) {
        self.format = format; self.duration = duration; self.byteLength = byteLength
        self.completeness = completeness; self.evidence = evidence; self.probedAt = probedAt
    }
}

/// A service that turns a catalog song ID into a temporary audio address.
public enum MusicProviderID: String, Codable, Sendable, Hashable, CaseIterable {
    case vkeys, gdstudio, hyw, migu, nianxin, xinghai
    /// What a music extension's `getSongInfo` gives for its own songs.
    case `extension`
    /// The LX Music sources the listener imported (MusicLXSources.swift).
    case lx
    public var name: String {
        switch self {
        case .vkeys: "VKeys"
        case .gdstudio: L10n.text("GD Music")
        case .hyw: "HYW"
        case .migu: L10n.text("Migu")
        case .nianxin: L10n.text("Nianxin")
        case .xinghai: L10n.text("Xinghai")
        case .extension: L10n.text("Extension")
        case .lx: L10n.text("LX Music Sources")
        }
    }
    /// Services this provider is known to call itself, so a fallback never repeats a failed one.
    public var upstreams: Set<String> {
        switch self {
        case .vkeys: ["vkeys"]
        case .gdstudio: ["gdstudio"]
        case .hyw: ["hyw"]
        case .migu: ["migu"]
        case .nianxin: ["nianxin"]
        case .xinghai: ["xinghai"]
        case .extension: ["extension"]
        case .lx: ["lx"]
        }
    }
}

/// One way to get a track's audio: a catalog ID and the provider that resolves it.
public struct MusicCandidate: Identifiable, Hashable, Codable, Sendable {
    public var platform: MusicPlatform
    public var songID: String
    public var provider: MusicProviderID
    public init(platform: MusicPlatform, songID: String, provider: MusicProviderID) {
        self.platform = platform; self.songID = songID; self.provider = provider
    }
    public var id: String { provider.rawValue + "|" + platform.rawValue + "|" + songID }
    /// "VKeys · QQ Music".
    public var name: String { provider.name + " · " + platform.name }
}

/// A temporary address from a provider. Its URL and headers stay in resolution and playback: they
/// often carry signatures, so logs only ever name the host.
public struct ResolvedMusicStream: Hashable, Sendable {
    public var url: URL
    public var headers: [String: String]
    /// What the provider said the quality is; shown nowhere, since probing decides.
    public var claimedQuality: String?
    public var resolvedAt: Date
    /// When the address stops working, if the provider said; nil means unknown, not never.
    public var expiresAt: Date?
    /// The service the provider says it used, when it says.
    public var upstream: String?
    public init(url: URL, headers: [String: String] = [:], claimedQuality: String? = nil, resolvedAt: Date = Date(),
                expiresAt: Date? = nil, upstream: String? = nil) {
        self.url = url; self.headers = headers; self.claimedQuality = claimedQuality
        self.resolvedAt = resolvedAt; self.expiresAt = expiresAt; self.upstream = upstream
    }
}

/// What a channel is asked for: its lossless audio, or lossy audio at 320 or 128 kbps, which
/// costs far less data to stream.
public enum MusicAudioQuality: String, Codable, Sendable, Equatable {
    case lossless
    case high
    case standard
}

public enum MusicQualityPreference: String, Codable, Sendable, CaseIterable {
    /// Lossless when any channel has it within the budget, otherwise the best lossy stream, marked.
    case losslessPreferred
    case losslessOnly
    /// 320 kbps audio, lossy.
    case high
    /// 128 kbps audio, lossy and the lightest on data.
    case standard
    public var name: String {
        switch self {
        case .losslessPreferred: L10n.text("Lossless first")
        case .losslessOnly: L10n.text("Lossless only")
        case .high: L10n.text("High (320 kbps)")
        case .standard: L10n.text("Standard (128 kbps)")
        }
    }
    /// The tier every channel is asked for.
    public var requested: MusicAudioQuality {
        switch self {
        case .losslessPreferred, .losslessOnly: .lossless
        case .high: .high
        case .standard: .standard
        }
    }
    /// Whether the viewer asked for lossless; the lossy choices play it only as a last resort.
    public var wantsLossless: Bool { requested == .lossless }
}

/// One channel tried for a track, and how it went; the player's channel list shows these.
public struct MusicAttempt: Identifiable, Hashable, Sendable {
    public enum Outcome: Hashable, Sendable {
        case playable(MusicProbeResult)
        case failed(MusicProviderError)
        /// Not tried, with the reason (cooling down, budget spent).
        case skipped(MusicProviderError)
    }
    public var candidate: MusicCandidate
    public var outcome: Outcome
    public var seconds: Double
    public var id: String { candidate.id }
    public init(candidate: MusicCandidate, outcome: Outcome, seconds: Double) {
        self.candidate = candidate; self.outcome = outcome; self.seconds = seconds
    }
}

/// The channel chosen for a track and why, with what is left to fall back on.
public struct MusicPlaybackSelection: Sendable {
    public var track: MusicTrack
    public var candidate: MusicCandidate
    public var stream: ResolvedMusicStream
    public var probe: MusicProbeResult
    /// Lossy while lossless was the goal.
    public var degraded: Bool
    public var attempts: [MusicAttempt]
    /// Channels not tried yet, in the order they would be tried.
    public var untried: [MusicCandidate]
}

public enum MusicProviderError: LocalizedError, Hashable, Sendable {
    /// No song in the catalogs matches.
    case noMatch
    /// The song exists, but this channel has no audio for it.
    case noResource
    /// The audio is a sample, seconds long, of a longer recording.
    case preview(Double)
    /// The audio runs clearly longer than the recording: another version, seconds long.
    case differentRecording(Double)
    case rateLimited(until: Date?)
    /// The provider's upstream account was blocked by the platform's risk control.
    case upstreamRisk
    case authRequired
    case timeout
    case invalidResponse(String)
    case unsupportedFormat(String)
    /// Only lossy audio was found while the preference is lossless only.
    case notLossless
    case network(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noMatch: L10n.text("No matching song was found.")
        case .noResource: L10n.text("This channel has no audio for the song.")
        case .preview(let seconds): L10n.text("This channel only has a %lld-second preview.", Int(seconds.rounded()))
        case .differentRecording: L10n.text("This channel has a different version of the song.")
        case .rateLimited: L10n.text("The channel is limiting requests. Try again in a few minutes.")
        case .upstreamRisk: L10n.text("The channel's music account is blocked for now.")
        case .authRequired: L10n.text("The channel needs a valid key.")
        case .timeout: L10n.text("The channel took too long to answer.")
        case .invalidResponse: L10n.text("The channel sent an answer the app can't read.")
        case .unsupportedFormat: L10n.text("This device can't play the channel's audio format.")
        case .notLossless: L10n.text("No lossless version is available right now.")
        case .network: L10n.text("Can't connect to the network.")
        case .cancelled: L10n.text("Cancelled.")
        }
    }

    /// Technical detail for diagnostics; never holds URLs or keys.
    public var detail: String {
        switch self {
        case .invalidResponse(let text), .unsupportedFormat(let text), .network(let text): text
        case .rateLimited(let until): until.map { "until \($0.formatted(.iso8601))" } ?? "rate limited"
        case .preview(let seconds): "preview \(seconds)s"
        case .differentRecording(let seconds): "different recording \(seconds)s"
        default: String(describing: self)
        }
    }

    /// Whether the failure says something about the channel rather than this song or this device.
    public var countsAgainstChannel: Bool {
        switch self {
        case .rateLimited, .upstreamRisk, .authRequired, .timeout, .invalidResponse: true
        case .noMatch, .noResource, .preview, .differentRecording, .unsupportedFormat, .notLossless, .network, .cancelled: false
        }
    }

    /// Maps a transport error; offline and cancelled never blame the channel.
    public init(_ error: Error) {
        if let error = error as? MusicProviderError { self = error; return }
        if error is CancellationError { self = .cancelled; return }
        if let url = error as? URLError {
            switch url.code {
            case .cancelled: self = .cancelled
            case .timedOut: self = .timeout
            default: self = .network("URLError \(url.code.rawValue)")
            }
            return
        }
        self = .invalidResponse(String(describing: type(of: error)))
    }
}

/// Viewer choices for music, kept in user defaults.
public struct MusicPreferences: Equatable, Sendable {
    public var quality: MusicQualityPreference
    public var disabled: Set<MusicProviderID>
    /// HYW needs a key from its own published script; without one it stays off.
    public var hywKey: String
    public init(quality: MusicQualityPreference = .losslessPreferred, disabled: Set<MusicProviderID> = [], hywKey: String = "") {
        self.quality = quality; self.disabled = disabled; self.hywKey = hywKey
    }

    public func enabled(_ provider: MusicProviderID) -> Bool {
        guard !disabled.contains(provider) else { return false }
        return provider != .hyw || !hywKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public static func load(_ defaults: UserDefaults = .standard) -> MusicPreferences {
        MusicPreferences(quality: defaults.string(forKey: "musicQuality").flatMap(MusicQualityPreference.init(rawValue:)) ?? .losslessPreferred,
                         disabled: Set((defaults.stringArray(forKey: "musicDisabledProviders") ?? []).compactMap(MusicProviderID.init(rawValue:))),
                         hywKey: defaults.string(forKey: "musicHYWKey") ?? "")
    }

    public func save(_ defaults: UserDefaults = .standard) {
        defaults.set(quality.rawValue, forKey: "musicQuality")
        defaults.set(disabled.map(\.rawValue).sorted(), forKey: "musicDisabledProviders")
        defaults.set(hywKey, forKey: "musicHYWKey")
    }
}

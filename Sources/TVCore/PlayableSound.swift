import AVFoundation

/// Sound that AVPlayer opens but can't decode plays as silence beside a picture that plays (#1774, #2119): TrueHD
/// (`mlpa`) in an MP4 is listed and never heard, and DTS or MPEG audio in an MP4 isn't even listed. AVFoundation's
/// own pick doesn't skip such a track either: a file with a TrueHD and an AAC dub in one group starts on the TrueHD
/// one, and one that groups neither plays both, which `UngroupedAudio` narrows to the first.
public enum PlayableSound {
    public struct Track: Equatable, Sendable {
        public let id: CMPersistentTrackID
        /// The sample entries' codes (`aac `, `ac-3`, `mlpa`).
        public let codecs: [String]
        public let playable: Bool
    }

    public enum Verdict: Equatable, Sendable {
        /// What plays decodes.
        case plays
        /// It was playing only sound nothing here decodes; now a track that decodes.
        case switched
        /// It lists sound, none of which decodes here.
        case undecodable
        /// It lists no sound: the file has none, or has sound AVFoundation leaves out (DTS in MP4).
        case missing
    }

    public struct Check: Sendable {
        public let tracks: [Track]
        public let verdict: Verdict
        /// The tracks nothing decodes, in a file that groups none of them: `UngroupedAudio` keeps clear of them.
        public let ungroupedUnplayable: Set<CMPersistentTrackID>
        /// For the diagnostics log: each track's codec, and `!` after one that doesn't decode.
        public var summary: String {
            tracks.isEmpty ? "none" : tracks.map { ($0.codecs.joined(separator: "+").trimmingCharacters(in: .whitespaces)) + ($0.playable ? "" : "!") }
                .joined(separator: ",")
        }
        /// Whether the file needs its sound converted (`Remux`) to be heard: a picture with no sound that decodes.
        public var needsConverting: Bool { verdict == .undecodable || verdict == .missing }
    }

    /// The asset's sound tracks, in its order.
    public static func tracks(_ asset: AVAsset) async -> [Track] {
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio) else { return [] }
        var found: [Track] = []
        for track in tracks {
            guard let (formats, playable) = try? await track.load(.formatDescriptions, .isPlayable) else { continue }
            let codecs = formats.map { format -> String in
                let code = CMFormatDescriptionGetMediaSubType(format)
                return String(decoding: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }, as: UTF8.self)
            }
            found.append(Track(id: track.trackID, codecs: codecs, playable: playable))
        }
        return found
    }

    /// The verdict from the tracks alone, nil when some track decodes (then what plays decides).
    static func verdict(_ tracks: [Track]) -> Verdict? {
        if tracks.isEmpty { return .missing }
        return tracks.contains(where: \.playable) ? nil : .undecodable
    }

    /// The track to play in place of the ones playing, when none of those decodes: the first that does. Nil leaves
    /// them as they are.
    static func replacement(playing: [Bool], decodes: [Bool]) -> Int? {
        guard !zip(playing, decodes).contains(where: { $0 && $1 }) else { return nil }
        return decodes.firstIndex(of: true)
    }

    /// Plays sound that decodes in place of sound that doesn't, where the file has both, and says what is heard.
    /// Run once the item is ready to play.
    @MainActor public static func check(_ item: AVPlayerItem) async -> Check {
        let tracks = await tracks(item.asset)
        if let verdict = verdict(tracks) { return Check(tracks: tracks, verdict: verdict, ungroupedUnplayable: []) }
        let unplayable = Set(tracks.filter { !$0.playable }.map(\.id))
        guard !unplayable.isEmpty else { return Check(tracks: tracks, verdict: .plays, ungroupedUnplayable: []) }
        // A selection group: AVFoundation plays its selected option, so another option is selected.
        let group = try? await item.asset.loadMediaSelectionGroup(for: .audible)
        if let group, let selected = item.currentMediaSelection.selectedMediaOption(in: group) {
            let options = group.options
            if let index = replacement(playing: options.map { $0 == selected }, decodes: options.map(\.isPlayable)) {
                // The same language when another option has it.
                let same = options.first { $0.isPlayable && $0.extendedLanguageTag == selected.extendedLanguageTag }
                item.select(same ?? options[index], in: group)
                return Check(tracks: tracks, verdict: .switched, ungroupedUnplayable: [])
            }
        }
        // Every track is the group's: AVFoundation chose, and what it chose decodes.
        if let group, group.options.count >= tracks.count { return Check(tracks: tracks, verdict: .plays, ungroupedUnplayable: []) }
        let switched = UngroupedAudio.playDecodable(item, avoiding: unplayable)
        return Check(tracks: tracks, verdict: switched ? .switched : .plays, ungroupedUnplayable: unplayable)
    }
}

import AVFoundation

/// The sound tracks of an MP4 or MOV that puts none of them in an alternate group, as a file with a Mandarin and a
/// Cantonese dub often does (#428). AVFoundation then has nothing to choose between: the asset has no audible
/// selection group, so the player shows no Audio choice, and it plays every enabled track at once. The player keeps
/// one playing and offers the others itself. A file that groups its tracks, and HLS, have a selection group:
/// AVFoundation plays one of them and the player offers its options.
public enum UngroupedAudio {
    public struct Choice: Identifiable, Equatable, Sendable {
        public let id: CMPersistentTrackID
        public let name: String
    }

    /// Leaves only the first enabled sound track playing when the item plays more than one at once; true when it
    /// switched any off.
    @MainActor @discardableResult public static func playOne(_ item: AVPlayerItem) -> Bool {
        let playing = audio(item).filter(\.isEnabled)
        guard playing.count > 1 else { return false }
        for track in playing.dropFirst() { track.isEnabled = false }
        return true
    }

    /// The sound tracks to choose between, in the file's order; empty when there is only one, or when the file
    /// groups them and the selection group offers them.
    @MainActor public static func choices(_ item: AVPlayerItem) async -> [Choice] {
        let tracks = audio(item).compactMap(\.assetTrack)
        guard tracks.count > 1 else { return [] }
        if let group = try? await item.asset.loadMediaSelectionGroup(for: .audible), group.options.count > 1 { return [] }
        var titles: [String?] = [], languages: [String?] = []
        for track in tracks {
            let loaded = try? await track.load(.extendedLanguageTag, .languageCode, .commonMetadata)
            languages.append(loaded?.0 ?? loaded?.1)
            let title = loaded?.2.first { $0.commonKey == .commonKeyTitle }
            titles.append(try? await title?.load(.stringValue))
        }
        return zip(tracks, names(titles: titles, languages: languages)).map { Choice(id: $0.trackID, name: $1) }
    }

    /// The sound track playing now.
    @MainActor public static func playing(_ item: AVPlayerItem) -> CMPersistentTrackID? {
        audio(item).first(where: \.isEnabled)?.assetTrack?.trackID
    }

    /// Plays the sound track `id` in place of the one playing.
    @MainActor public static func play(_ id: CMPersistentTrackID, in item: AVPlayerItem) {
        let tracks = audio(item)
        guard tracks.contains(where: { $0.assetTrack?.trackID == id }) else { return }
        // The others go off first, so the two never play together.
        for track in tracks where track.assetTrack?.trackID != id { track.isEnabled = false }
        for track in tracks where track.assetTrack?.trackID == id { track.isEnabled = true }
    }

    /// Each track's title, else its language in the app's, else "Audio" and its number; a name two tracks share
    /// gets their numbers too.
    static func names(titles: [String?], languages: [String?], language: String? = nil) -> [String] {
        let locale = Locale(identifier: L10n.resolvedLanguage(language))
        let named = zip(titles, languages).map { title, code -> String? in
            if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
            guard let code, !code.isEmpty, code != "und" else { return nil }
            return locale.localizedString(forIdentifier: code)
        }
        return named.enumerated().map { index, name in
            guard let name else { return L10n.text("Audio", language: language) + " \(index + 1)" }
            return named.filter { $0 == name }.count > 1 ? "\(name) \(index + 1)" : name
        }
    }

    @MainActor private static func audio(_ item: AVPlayerItem) -> [AVPlayerItemTrack] {
        item.tracks.filter { $0.assetTrack?.mediaType == .audio }
    }
}

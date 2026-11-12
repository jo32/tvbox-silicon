import Foundation

/// A repackaged track's title and format, which its HLS option doesn't carry: AVPlayer names an option by its
/// LANGUAGE alone (`displayName`, "Unknown" without one) and keeps its NAME as the option's title.
public struct TrackDetail: Sendable, Equatable {
    /// The stream's own title; empty when it has none.
    public let title: String
    /// "TrueHD 5.1", "PGS"; nil for a subtitle file or translation.
    public let format: String?
}

extension Remux {
    /// What the player's Audio and Subtitles menus add to the language of each track of the stream at `url`, by its
    /// option's title (its NAME in the master playlist); empty when the repackager doesn't serve it.
    public static func trackDetails(_ url: URL) -> (audio: [String: TrackDetail], subtitles: [String: TrackDetail]) {
        session(url)?.plan?.trackDetails() ?? (audio: [:], subtitles: [:])
    }
}

/// How the player's Audio and Subtitles menus name a selection group's options: the language, then what else is
/// known (a title, the format and channels), as "Korean · TrueHD 5.1". AVPlayer's `displayName` alone is the
/// language, so tracks without one were all "Unknown" and tracks in one language looked alike (#884).
public enum TrackLabel {
    public struct Option: Sendable, Equatable {
        /// AVPlayer's name for it: its language's, or "Unknown".
        public var displayName: String
        /// Its language tag; nil when it has none.
        public var language: String?
        /// Its title (the HLS NAME, or the repackaged stream's own title).
        public var title: String?
        public var format: String?
        public init(displayName: String, language: String?, title: String?, format: String? = nil) {
            self.displayName = displayName; self.language = language; self.title = title; self.format = format
        }
    }

    /// Each option's name; a name two options share gets " (2)", " (3)" on the later ones.
    public static func names(_ options: [Option]) -> [String] {
        var seen: [String: Int] = [:]
        return options.map { option in
            let name = name(option)
            seen[name, default: 0] += 1
            return seen[name] == 1 ? name : "\(name) (\(seen[name]!))"
        }
    }

    static func name(_ option: Option) -> String {
        let language = option.language.flatMap { $0.isEmpty ? nil : $0 }
        var parts: [String] = language == nil ? [] : [option.displayName]
        if let title = option.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty, !names(of: language).contains(title.lowercased()),
           title.caseInsensitiveCompare(option.displayName) != .orderedSame {
            parts.append(title)
        }
        if let format = option.format, !format.isEmpty, !parts.contains(format) { parts.append(format) }
        return parts.isEmpty ? option.displayName : parts.joined(separator: " · ")
    }

    /// A language's names a title may repeat: in English, in itself, and in this device's language.
    private static func names(of language: String?) -> Set<String> {
        guard let language else { return [] }
        let code = Locale.Language(identifier: language).languageCode?.identifier ?? language
        return Set([Locale(identifier: "en"), Locale(identifier: language), Locale.current]
            .compactMap { $0.localizedString(forLanguageCode: code)?.lowercased() })
    }
}

import Foundation

/// The small line under an episode whose name is a file name (#620): its resolution and size, "4K · 5.2G" for
/// "[5.2GB]The.Silent.Storm.2026.S01E01.2160p.HQ.WEB-DL.mp4". The pickers show such episodes as 第1集 (`EpisodeLabels`),
/// so this is what is left of the file name. Display only, read from the name; nil when it gives neither.
public enum EpisodeFileInfo {
    /// `title` is what the picker shows for the episode: a resolution it already says ("第1集 · 4K", "4K国语") isn't repeated.
    public static func summary(_ name: String, besides title: String? = nil) -> String? {
        // Most names (第1集, 正片) have no digit at all: no need to look further.
        guard name.utf8.contains(where: { $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        var parts: [String] = []
        if let resolution = resolution(name), title?.range(of: resolution, options: .caseInsensitive) == nil { parts.append(resolution) }
        if let size = size(name) { parts.append(size) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Every episode's line that has one, by episode id, next to the labels the pickers show (`EpisodeLabels`). Worked out
    /// with them, off the main thread: a line can hold thousands of episodes.
    public static func details(_ episodes: [Episode], labels: [Episode.ID: String]) -> [Episode.ID: String] {
        var result: [Episode.ID: String] = [:]
        for episode in episodes {
            if let summary = summary(episode.name, besides: labels[episode.id] ?? episode.name) { result[episode.id] = summary }
        }
        return result
    }

    /// 8K, 4K, 2K, 1080P, 720P or 480P, from its own name (4K, UHD) or its line count (2160p), as a word of its own:
    /// `S01E04K` or `24K纯金` is not 4K.
    static func resolution(_ name: String) -> String? {
        let range = NSRange(name.startIndex..., in: name)
        for (label, pattern) in resolutions where pattern.firstMatch(in: name, range: range) != nil { return label }
        return nil
    }

    /// "5.2G" for 5.2GB, "797M" for 796.61MB: a size with its unit (GB, MB, TB), or a bare G/M/T in brackets (【1.7G】).
    /// A G or M alone elsewhere is too often something else (5G, 60M).
    static func size(_ name: String) -> String? {
        let range = NSRange(name.startIndex..., in: name)
        guard let match = sizeWithUnit.firstMatch(in: name, range: range) ?? bracketedSize.firstMatch(in: name, range: range),
              let number = Range(match.range(at: 1), in: name).flatMap({ Double(name[$0]) }), number > 0,
              let unit = Range(match.range(at: 2), in: name).map({ name[$0].uppercased() }) else { return nil }
        // Megabytes as a whole number; gigabytes and terabytes with one decimal, without a trailing .0.
        let shown = unit == "M" ? String(Int(number.rounded())) : String(format: "%.1f", number).replacingOccurrences(of: ".0", with: "")
        return shown + unit
    }

    private static let resolutions: [(String, NSRegularExpression)] = [
        ("8K", #"8K|4320[PI]"#), ("4K", #"4K|UHD|2160[PI]"#), ("2K", #"2K|1440[PI]"#),
        ("1080P", #"1080[PI]"#), ("720P", #"720[PI]"#), ("480P", #"480[PI]"#),
    ].map { ($0.0, try! NSRegularExpression(pattern: #"(?<![A-Z0-9])(?:"# + $0.1 + #")(?![A-Z0-9])"#, options: .caseInsensitive)) }
    private static let sizeWithUnit = try! NSRegularExpression(pattern: #"(?<![0-9.A-Z])([0-9]{1,4}(?:\.[0-9]{1,3})?)\s?([TGM])i?B(?![A-Z])"#,
                                                                options: .caseInsensitive)
    private static let bracketedSize = try! NSRegularExpression(pattern: #"[\[(【（]\s*([0-9]{1,4}(?:\.[0-9]{1,3})?)\s?([TGM])\s*[\])】）]"#,
                                                                 options: .caseInsensitive)
}

import CryptoKit
import Foundation

/// Which of the subtitle files beside a video belong to it (#576). A cloud-drive plugin hands over every subtitle in
/// the folder, so a series' folder offers each episode's: a file naming another episode is left out, never shown
/// with this one. The rest keep every language and version, closest name first.
public enum SubtitleMatch {
    /// The files for the video named `video` (its file name, else its title), best first.
    public static func candidates(_ subtitles: [ExternalSubtitle], video: String) -> [ExternalSubtitle] {
        let wanted = episode(video)
        let stem = normalized(video)
        let kept = subtitles.enumerated().filter { _, subtitle in
            guard let wanted, let theirs = episode(subtitle.name) else { return true }
            return theirs == wanted
        }
        return kept.sorted { left, right in
            let (a, b) = (score(left.element.name, stem: stem), score(right.element.name, stem: stem))
            return a != b ? a > b : left.offset < right.offset
        }.map(\.element)
    }

    /// Season and episode a file or title names: `S01E02`, `1x02`, `EP02`, `第2集`, `[02]` or ` - 02 `.
    /// A season-less name counts as season 1.
    public static func episode(_ name: String) -> Episode? {
        let text = stripExtension(name)
        if let match = text.firstMatch(of: /(?i)s(\d{1,2})[ ._-]?e(\d{1,4})/) { return Episode(Int(match.1), Int(match.2)) }
        if let match = text.firstMatch(of: /(?i)(?:^|[^0-9a-z])(\d{1,2})x(\d{2,3})(?![0-9])/) { return Episode(Int(match.1), Int(match.2)) }
        if let match = text.firstMatch(of: /(?i)(?:^|[^0-9a-z])(?:ep|e)[ ._-]?(\d{1,4})(?![0-9])/) { return Episode(1, Int(match.1)) }
        if let match = text.firstMatch(of: /第\s*(\d{1,4})\s*[集话話回]/) { return Episode(1, Int(match.1)) }
        if let match = text.wholeMatch(of: /\s*(\d{1,3})\s*/) { return Episode(1, Int(match.1)) }
        // A two- or three-digit number in brackets or between separators (anime releases), never a codec, a year or a
        // resolution; one digit alone is too often a sound format's (5.1).
        if let match = text.firstMatch(of: /(?:^|[\[\s._\-【])(\d{2,3})(?:v\d)?(?:[\]\s._\-】]|$)/), let number = Int(match.1),
           ![264, 265, 480, 576, 720].contains(number), !text.contains("\(number)p") { return Episode(1, number) }
        return nil
    }

    public struct Episode: Hashable, Sendable {
        public let season: Int, number: Int
        init(_ season: Int?, _ number: Int?) { self.season = season ?? 1; self.number = number ?? 0 }
    }

    /// A language a subtitle's file name gives (`movie.chs.srt`, `movie.zh-Hant.ass`, `movie.简体.srt`); empty when
    /// it names none.
    public static func language(_ name: String) -> String {
        let parts = stripExtension(name).lowercased().split(whereSeparator: { ".-_ []()".contains($0) }).map(String.init)
        let known: [String: String] = ["chs": "zh-Hans", "sc": "zh-Hans", "gb": "zh-Hans", "zh": "zh", "chi": "zh", "zho": "zh",
                                       "cht": "zh-Hant", "tc": "zh-Hant", "big5": "zh-Hant", "hans": "zh-Hans", "hant": "zh-Hant",
                                       "en": "en", "eng": "en", "english": "en", "ja": "ja", "jp": "ja", "jpn": "ja",
                                       "ko": "ko", "kor": "ko", "简体": "zh-Hans", "简中": "zh-Hans", "繁体": "zh-Hant",
                                       "繁體": "zh-Hant", "繁中": "zh-Hant", "英文": "en", "日文": "ja", "中文": "zh"]
        for part in parts.reversed() { if let code = known[part] { return code } }
        return ""
    }

    /// A stable identity for a subtitle file the viewer added: its name and contents.
    public static func identity(name: String, data: Data) -> String {
        "file:" + name + ":" + SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The file's name without its extension and with punctuation as spaces, lowercased.
    static func normalized(_ name: String) -> String {
        stripExtension(name).lowercased().replacing(/[\s._\-\[\]()【】]+/, with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// How much of the video's name the subtitle's name starts with.
    private static func score(_ name: String, stem: String) -> Int {
        let theirs = normalized(name)
        guard !stem.isEmpty else { return 0 }
        if theirs.hasPrefix(stem) { return 1000 }
        return zip(theirs, stem).prefix { $0 == $1 }.count
    }

    private static func stripExtension(_ name: String) -> String {
        let known = ["srt", "ass", "ssa", "vtt", "mkv", "mp4", "m4v", "mov", "avi", "ts", "flv", "rmvb", "webm", "m3u8"]
        var text = name
        while let dot = text.lastIndex(of: "."), known.contains(text[text.index(after: dot)...].lowercased()) { text = String(text[..<dot]) }
        return text
    }
}

extension SubtitleDocument {
    /// A source's subtitle file, fetched with the video's request headers (none to a loopback proxy).
    public static func load(_ subtitle: ExternalSubtitle, headers: [String: String], session: URLSession = .shared) async throws -> SubtitleDocument {
        let data = try await SubtitleFile.download(subtitle.url, headers: headers, session: session)
        return try SubtitleDocument(id: subtitle.url.absoluteString, name: subtitle.name, language: subtitle.language, data: data, format: subtitle.format)
    }

    /// A file the viewer picked on this device, or one dropped on the player.
    public static func load(file url: URL) throws -> SubtitleDocument {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= SubtitleFile.largest else { throw SubtitleLoadError.tooLarge }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw SubtitleLoadError.unreadable }
        return try SubtitleDocument(id: SubtitleMatch.identity(name: url.lastPathComponent, data: data), name: url.lastPathComponent, data: data)
    }

    /// A file at an address the viewer typed.
    public static func load(address url: URL, session: URLSession = .shared) async throws -> SubtitleDocument {
        let data = try await SubtitleFile.download(url, headers: [:], session: session)
        let name = url.lastPathComponent.isEmpty ? (url.host() ?? "subtitles") : url.lastPathComponent
        return try SubtitleDocument(id: url.absoluteString, name: name, data: data)
    }
}

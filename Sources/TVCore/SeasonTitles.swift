import Foundation

/// A series' other seasons on the same source (#1066). Sources list each season as a title of its own ("X 第二季",
/// "X Season 2", short dramas "X第十六季"), so a page finds them with one search of the title without its season,
/// made only when someone asks for them.
public enum SeasonTitles {
    /// One season found on the source, and the video that plays it.
    public struct Found: Identifiable, Hashable, Sendable {
        public let season: Int
        public let video: Video
        public var id: Int { season }
    }

    /// The season in a title: 第二季, 第2季, 第二部, Season 2, S2 (at the end). The number is the first group.
    private static let patterns: [NSRegularExpression] = [
        #"第\s*([0-9]{1,3}|[一二两三四五六七八九十]{1,3})\s*[季部]"#,
        #"(?i)season\s*([0-9]{1,3})"#,
        #"(?i)(?<![a-z0-9])s([0-9]{1,2})$"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    /// The title without its season and without bracketed notes (`[国语]`, `【4K】`), and the season it names (nil
    /// when it names none).
    public static func parse(_ title: String) -> (core: String, season: Int?) {
        var core = title
        var season: Int?
        if let (range, number) = seasonMatch(in: title) {
            season = number
            core.removeSubrange(range)
        }
        core = core.replacingOccurrences(of: #"[\[【(（][^\]】)）]*[\]】)）]"#, with: " ", options: .regularExpression)
        core = core.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        core = core.trimmingCharacters(in: CharacterSet(charactersIn: " -_·:：,，.。|/"))
        return (core, season)
    }

    /// What to search the source for: the title without its season.
    public static func query(for title: String) -> String { parse(title).core }

    /// Another season's title, written the way this one writes its season: "X第十六季" → "X第十七季",
    /// "X 第2季" → "X 第3季", "X S2" → "X S3". Nil when the title names no season.
    public static func renamed(_ title: String, season: Int) -> String? {
        guard season > 0 else { return nil }
        for pattern in patterns {
            let range = NSRange(title.startIndex..., in: title)
            guard let match = pattern.firstMatch(in: title, range: range), let digits = Range(match.range(at: 1), in: title) else { continue }
            let written = title[digits].allSatisfy(\.isNumber) && title[digits].allSatisfy(\.isASCII) ? String(season) : chinese(season)
            guard let written else { return nil }
            var renamed = title
            renamed.replaceSubrange(digits, with: written)
            return renamed
        }
        return nil
    }

    /// The seasons among a source's answer to `query(for:)`: titles that are this one without their season, one per
    /// season, in order. A title naming no season counts as the first. This video is always among them, in its own
    /// season's place.
    public static func seasons(of video: Video, among results: [Video]) -> [Found] {
        let own = parse(video.name)
        let core = TitleMatch.normalize(own.core)
        var bySeason: [Int: Video] = [own.season ?? 1: video]
        guard !core.isEmpty else { return [Found(season: own.season ?? 1, video: video)] }
        for result in results where result.id != video.id {
            let parsed = parse(result.name)
            guard TitleMatch.normalize(parsed.core) == core else { continue }
            let season = parsed.season ?? 1
            if bySeason[season] == nil { bySeason[season] = result }
        }
        return bySeason.keys.sorted().map { Found(season: $0, video: bySeason[$0]!) }
    }

    private static func seasonMatch(in title: String) -> (Range<String.Index>, Int)? {
        for pattern in patterns {
            let range = NSRange(title.startIndex..., in: title)
            guard let match = pattern.firstMatch(in: title, range: range), let whole = Range(match.range, in: title),
                  let digits = Range(match.range(at: 1), in: title) else { continue }
            let text = String(title[digits])
            guard let number = Int(text) ?? number(chinese: text), number > 0 else { continue }
            return (whole, number)
        }
        return nil
    }

    private static let units: [Character: Int] = ["一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]

    /// 一 to 九十九: 十六 is 16, 二十 is 20, 二十三 is 23.
    static func number(chinese text: String) -> Int? {
        let characters = Array(text)
        if let ten = characters.firstIndex(of: "十") {
            guard characters.filter({ $0 == "十" }).count == 1 else { return nil }
            let tens = ten == 0 ? 1 : (ten == 1 ? units[characters[0]] : nil)
            guard let tens else { return nil }
            let rest = characters[(ten + 1)...]
            guard rest.count <= 1 else { return nil }
            let ones = rest.first.map { units[$0] } ?? 0
            guard let ones else { return nil }
            return tens * 10 + ones
        }
        guard characters.count == 1 else { return nil }
        return units[characters[0]]
    }

    /// 1 to 99 in Chinese numerals, as season names write them: 十, 十六, 二十, 二十三.
    static func chinese(_ number: Int) -> String? {
        let digits = ["", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
        switch number {
        case 1...9: return digits[number]
        case 10...19: return "十" + digits[number - 10]
        case 20...99: return digits[number / 10] + "十" + digits[number % 10]
        default: return nil
        }
    }
}

import Foundation

/// Short episode labels (第1集) for lines whose episode names are file names, such as a netdisk's
/// "[1.18GB] 海市蜃楼.The.Mirage.2025.S01E01.2160p.WEB-DL.mkv": the pickers cut those off after the show's name, so
/// every episode looked the same (#318). Display only: history, playback, downloads and TMDB or danmaku matching keep
/// the source's names.
///
/// A line is relabeled only when most of its names give a number it can trust: a marker (S01E05, EP05, 第5集), else the
/// one number that changes from name to name (`Show.4K.01.mkv`, `Show.4K.02.mkv`). Otherwise the whole line keeps its
/// names, so a guess never puts a wrong 第N集 on a line. Lines whose names are already short (第1集, 01, 4K国语) are
/// left alone.
public enum EpisodeLabels {
    /// The label of every episode on a line that gets labels, by episode id. Lines that keep their names are left out.
    public static func labels(_ episodes: [Episode], language: String? = nil) -> [Episode.ID: String] {
        var lines: [String: [Episode]] = [:], order: [String] = []
        for episode in episodes {
            if lines[episode.flag] == nil { order.append(episode.flag) }
            lines[episode.flag, default: []].append(episode)
        }
        var result: [Episode.ID: String] = [:]
        for flag in order {
            guard let line = lines[flag], let shown = labels(names: line.map(\.name), language: language) else { continue }
            for (episode, label) in zip(line, shown) { result[episode.id] = label }
        }
        return result
    }

    /// One line's labels, in order, or nil when the line keeps its names. Names without a number (花絮, 预告) keep
    /// theirs, without the size tag and the file extension. History passes a line of one name: with no other name to
    /// compare with, only the number that name carries itself is trusted.
    public static func labels(names: [String], language: String? = nil) -> [String]? {
        guard !names.isEmpty, names.filter(isFileName).count * 2 >= names.count else { return nil }
        let cleaned = names.map(clean)
        var found: [Int: Mark] = [:]
        for (index, name) in cleaned.enumerated() { if let mark = marked(name) { found[index] = mark } }
        if !enough(found.count, of: names.count) {
            var merged = byDifference(cleaned).mapValues { Mark(season: nil, episode: $0) }
            merged.merge(found) { $1 }
            guard enough(merged.count, of: names.count) else {
                if let shown = ranges(cleaned, language: language) { return shown }
                guard names.count == 1, let episode = trailingEpisode(cleaned[0]) else { return nil }
                return [L10n.text("Episode %1$@", String(episode), language: language)]
            }
            found = merged
        }
        // A season only when the line holds more than one.
        let seasons = Set(found.values.compactMap(\.season))
        let keys = found.mapValues { Mark(season: seasons.count > 1 ? $0.season : nil, episode: $0.episode) }
        var twins: [Mark: [Int]] = [:]
        for index in names.indices { if let key = keys[index] { twins[key, default: []].append(index) } }
        let shown = names.indices.map { index -> String in
            guard let key = keys[index] else { return cleaned[index] }
            var label = (key.season.map { "S\($0) " } ?? "") + L10n.text("Episode %1$@", String(key.episode), language: language)
            // Two files of one episode (a 4K and a 1080p copy): the tag that tells them apart, else their order.
            if let group = twins[key], group.count > 1, let place = group.firstIndex(of: index) {
                let tags = tags(group.map { cleaned[$0] })
                if Set(tags).count == tags.count { if let mine = tags[place] { label += " · " + mine } }
                else { label += " (\(place + 1))" }
            }
            return label
        }
        return Set(shown).count == shown.count ? shown : nil
    }

    /// The label History and Watch Now show for one stored episode name (#521, #522), or the name itself when it gives
    /// no number. A season past the first stays (S2 第5集): with no line around it, the label is all that tells S1E05
    /// from S2E05. Cached, since cards and headers ask again on every redraw.
    public static func historyLabel(_ name: String, language: String? = nil) -> String {
        historyLabel(name, showsDetails: false, language: language)
    }

    /// The same label, with the file's size and picture quality after it when the viewer asked for them (#595):
    /// "第1集 · 5.4GB · 2160p". A name the label doesn't shorten keeps its own text, details included.
    public static func historyLabel(_ name: String, showsDetails: Bool, language: String? = nil) -> String {
        let key = ((language ?? "") + "\u{1}" + (showsDetails ? "1" : "0") + "\u{1}" + name) as NSString
        if let cached = historyLabels.object(forKey: key) { return cached as String }
        var label = labels(names: [name], language: language)?.first ?? name
        if label != name {
            if let season = marked(clean(name))?.season, season > 1 { label = "S\(season) " + label }
            if showsDetails, let details = fileDetails(name) { label += " · " + details }
        }
        historyLabels.setObject(label as NSString, forKey: key)
        return label
    }

    /// The file's size and picture quality ("5.4GB · 2160p") read from its name: the size tag a netdisk puts first,
    /// and the resolution word wherever it stands. Nil when the name carries neither.
    static func fileDetails(_ name: String) -> String? {
        var parts: [String] = []
        if let size = groups(sizeTag, in: name)?.first, !size.isEmpty {
            parts.append(size.replacingOccurrences(of: " ", with: ""))
        }
        if let quality = groups(resolutionDetail, in: name)?.first {
            parts.append(quality.lowercased().hasSuffix("k") ? quality.uppercased() : quality.lowercased())
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    // NSCache is thread-safe.
    nonisolated(unsafe) private static let historyLabels: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>(); cache.countLimit = 500; return cache
    }()

    // The numbers go in as text: formatted as numbers they would get the locale's grouping (第1,000集). `Episode %@` is the
    // short dramas' spaced 第 1 集, too wide for the small tiles once past nine.
    struct Mark: Hashable { let season: Int?; let episode: Int }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
    private static let sizeTag = regex(#"^\s*\[([\d.]+\s*[kmgt]?b)\]\s*"#)
    /// 2160p, 4K, 8K, 1080p: the picture's resolution, wherever it stands in a name.
    private static let resolutionDetail = regex(#"(?<![a-z0-9])(4k|8k|2160p|1080p|720p|480p)(?![a-z0-9])"#)
    private static let fileExtension = regex(#"\.(?:mkv|mp4|m4v|ts|avi|rmvb|flv|mov|wmv|iso|webm|m2ts)$"#)
    /// The share's own tag some drive sources put after a file's extension: "E01.mp4【太阳鱼】" (#595).
    private static let shareTag = regex(#"\s*【[^【】]*】\s*$"#)
    private static let seasonEpisode = regex(#"(?<![a-z0-9])s(\d{1,2})[ ._-]?ep?(\d{1,4})(?!\d)"#)
    private static let chineseEpisode = regex(#"第\s*([0-9]{1,4}|[零〇一二两三四五六七八九十百]+)\s*[集话話回]"#)
    /// E05 or EP05, not inside a word (HEVC, WEB-DL) and not a resolution (E1080P).
    private static let episodeMark = regex(#"(?<![a-z0-9])ep?[ ._-]?(\d{1,4})(?![\dp])"#)
    /// A pack of episodes on a magnet line: "01-04.2160p.HD国语中字.mkv".
    private static let episodeRange = regex(#"^(\d{1,3})-(\d{1,3})(?!\d)"#)
    /// A single name's own last word as a plain number: "Show.4K.01", "01".
    private static let trailingNumber = regex(#"(?:^|[ ._-])(\d{1,3})$"#)
    /// A version at the end, "AAC2.0" or "DDP5.1", not an episode.
    private static let versionNumber = regex(#"[0-9]\.[0-9]$"#)
    /// A date at the end, "2026.01.02", not an episode.
    private static let dateStamp = regex(#"(?:19|20)[0-9]{2}[._-][0-9]{1,2}[._-][0-9]{1,2}$"#)
    private static let qualityTag = regex(#"^(?:2160p|1080p|720p|480p|4k|8k|hdr\d*|dv|dovi|hevc|h26[45]|x26[45]|60fps|国语|粤语|英语|中字|双语)$"#)

    private static func replacing(_ expression: NSRegularExpression, in text: String) -> String {
        expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }
    private static func groups(_ expression: NSRegularExpression, in text: String) -> [String]? {
        guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }

    /// The name without its size tag ("[1.18GB] "), the share's tag after it ("【太阳鱼】") and file extension.
    static func clean(_ name: String) -> String {
        replacing(fileExtension, in: replacing(shareTag, in: replacing(sizeTag, in: name))).trimmingCharacters(in: .whitespaces)
    }
    private static func isFileName(_ name: String) -> Bool {
        groups(fileExtension, in: replacing(shareTag, in: name)) != nil || clean(name).count > 12
    }
    private static func enough(_ count: Int, of total: Int) -> Bool { count * 10 >= total * 6 }

    static func marked(_ name: String) -> Mark? {
        if let parts = groups(seasonEpisode, in: name), let season = Int(parts[0]), let episode = Int(parts[1]) {
            return Mark(season: season, episode: episode)
        }
        if let parts = groups(chineseEpisode, in: name), let episode = chineseNumber(parts[0]) { return Mark(season: nil, episode: episode) }
        if let parts = groups(episodeMark, in: name), let episode = Int(parts[0]) { return Mark(season: nil, episode: episode) }
        return nil
    }

    /// The number one name carries itself. With no other names to compare, only its own last word counts:
    /// "Show.4K.01" gives 1, while a year, a date and a codec's version are not trusted.
    private static func trailingEpisode(_ name: String) -> Int? {
        guard groups(versionNumber, in: name) == nil, groups(dateStamp, in: name) == nil,
              let parts = groups(trailingNumber, in: name), let episode = Int(parts[0]), episode > 0 else { return nil }
        return episode
    }

    private static func chineseNumber(_ text: String) -> Int? {
        if let value = Int(text) { return value }
        let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        var total = 0, digit = 0
        for character in text {
            if let value = digits[character] { digit = value }
            else { total += max(1, digit) * (character == "百" ? 100 : 10); digit = 0 }
        }
        return total + digit > 0 ? total + digit : nil
    }

    /// Text and digit runs in turn, always starting and ending with text (possibly empty): "A 01.4k" is
    /// ["A ", "01", ".", "4", "k"].
    private static func pieces(_ text: String) -> [String] {
        var parts = [""], digits = false
        for character in text {
            let isDigit = character.isASCII && character.isNumber
            if isDigit != digits { parts.append(""); digits = isDigit }
            parts[parts.count - 1].append(character)
        }
        if digits { parts.append("") }
        return parts
    }

    /// For each naming pattern on the line, the number in the one place its names differ, by name index. A line can
    /// mix patterns (`H-海市蜃.楼 01.mp4` and `4K 01.2160p.HDR.mkv`); a name with a suffix of its own (`… 09 W.mp4`)
    /// still counts when the text before the number matches. Years and dates (2025, 20251220) are not episodes.
    static func byDifference(_ names: [String]) -> [Int: Int] {
        let split = names.map(pieces)
        let skeletons = split.map { parts in stride(from: 0, to: parts.count, by: 2).map { parts[$0] } }
        var counts: [[String]: Int] = [:], first: [[String]: Int] = [:]
        for (index, skeleton) in skeletons.enumerated() {
            counts[skeleton, default: 0] += 1
            if first[skeleton] == nil { first[skeleton] = index }
        }
        let patterns = counts.keys.filter { counts[$0]! >= 2 }
            .sorted { counts[$0]! != counts[$1]! ? counts[$0]! > counts[$1]! : first[$0]! < first[$1]! }
        var result: [Int: Int] = [:]
        for pattern in patterns {
            let group = skeletons.indices.filter { skeletons[$0] == pattern && result[$0] == nil }
            guard group.count >= 2 else { continue }
            let varying = (0..<split[group[0]].count / 2).filter { slot in Set(group.map { split[$0][2 * slot + 1] }).count > 1 }
            guard varying.count == 1, let slot = varying.first else { continue }
            let prefix = split[group[0]][..<(2 * slot + 1)]
            var values: [Int: String] = [:]
            for (index, parts) in split.enumerated() where result[index] == nil && parts.count > 2 * slot + 1
                && parts[..<(2 * slot + 1)] == prefix {
                values[index] = parts[2 * slot + 1]
            }
            guard !values.values.contains(where: { $0.count > 4 || ($0.count == 4 && ($0.hasPrefix("19") || $0.hasPrefix("20"))) })
            else { continue }
            for (index, digits) in values { result[index] = Int(digits) }
        }
        return result
    }

    private static func words(_ name: String) -> [String] {
        name.split(whereSeparator: { " ._-[]()".contains($0) }).map(String.init)
    }
    /// For each name, its first quality word (4K, 2160p, 国语…) that some of the other names lack.
    private static func tags(_ names: [String]) -> [String?] {
        let split = names.map(words)
        var counts: [String: Int] = [:]
        for words in split { for word in Set(words) { counts[word, default: 0] += 1 } }
        return split.map { words in words.first { counts[$0, default: 0] < names.count && groups(qualityTag, in: $0) != nil } }
    }

    /// A magnet line of packs, "01-04.2160p….mkv": 第1-4集 · 2160p.
    private static func ranges(_ cleaned: [String], language: String?) -> [String]? {
        var found: [Int: (Int, Int)] = [:]
        for (index, name) in cleaned.enumerated() {
            if let parts = groups(episodeRange, in: name), let low = Int(parts[0]), let high = Int(parts[1]) { found[index] = (low, high) }
        }
        guard enough(found.count, of: cleaned.count) else { return nil }
        let tags = tags(cleaned)
        let shown = cleaned.indices.map { index -> String in
            guard let range = found[index] else { return cleaned[index] }
            let label = L10n.text("Episodes %1$@–%2$@", String(range.0), String(range.1), language: language)
            return tags[index].map { label + " · " + $0 } ?? label
        }
        return Set(shown).count == shown.count ? shown : nil
    }
}

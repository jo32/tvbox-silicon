import Foundation

/// What a drive's folder or video file name says about the title it holds, for Cloud Files posters (#880, #1465): the
/// title to look up, its year, and the season and episode the name gives. Read from the name alone, so
/// "The.Silent.Storm.2026.S01E15.2160p.WEB-DL.H.265.mp4" is The Silent Storm (2026), season 1 episode 15, and
/// "[电影天堂www.dytt89.com]消失的她-2023_HD国语中字.mp4" is 消失的她 (2023).
public struct MediaName: Equatable, Sendable {
    public var title: String
    public var year: Int?
    public var season: Int?
    public var episode: Int?
    /// A folder that sorts videos by kind or place ("电影", "Movies", "4K"), never one title.
    public var isCategory = false

    /// A name that gives only a season ("Season 2", "S02", "第二季"): the title is the folder's above it.
    public var isSeasonOnly: Bool { title.isEmpty && season != nil && !isCategory }
    /// Whether a lookup can go by this name.
    public var isTitle: Bool { !title.isEmpty && !isCategory }
    /// Episodes and seasons are a series'.
    public var isSeries: Bool { season != nil || episode != nil }

    public init(title: String, year: Int? = nil, season: Int? = nil, episode: Int? = nil, isCategory: Bool = false) {
        self.title = title; self.year = year; self.season = season; self.episode = episode; self.isCategory = isCategory
    }

    /// `isFile` drops the extension first.
    public init(_ raw: String, isFile: Bool) {
        self = Self.parse(raw, isFile: isFile)
    }

    // MARK: Parsing

    static func parse(_ raw: String, isFile: Bool) -> MediaName {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFile, CloudFile.kind(of: name) != .other { name = (name as NSString).deletingPathExtension }
        // A title some uploaders spell out in corner brackets, split with 丨 to dodge filters: 「挽丨救丨计丨划（2026）」. Before the
        // width change, which turns 「」 into ｢｣.
        if let quoted = first(#"「([^」]+)」"#, in: name), quoted.contains(where: \.isCJK) {
            name = quoted.replacingOccurrences(of: "丨", with: "").replacingOccurrences(of: "|", with: "")
        }
        name = name.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? name
        name = name.replacingOccurrences(of: "【", with: "[").replacingOccurrences(of: "】", with: "]")
            .replacingOccurrences(of: "〔", with: "[").replacingOccurrences(of: "〕", with: "]")
        if isCategoryName(name) { return MediaName(title: "", isCategory: true) }

        var result = MediaName(title: "")
        // Season and episode, wherever they are.
        if let match = groups(#"(?i)(?<![A-Z0-9])S(\d{1,2})[ ._-]?E[P]?(\d{1,4})(?![0-9])"#, in: name) {
            result.season = Int(match[0]); result.episode = Int(match[1])
        }
        if result.season == nil, let match = groups(#"(?i)(?<![A-Z0-9])(?:S|Season[ ._-]?)(\d{1,2})(?![0-9])"#, in: name) { result.season = Int(match[0]) }
        if result.season == nil, let match = groups(#"第\s*([0-9零一二两三四五六七八九十]+)\s*季"#, in: name) { result.season = number(match[0]) }
        if result.episode == nil, let match = groups(#"第\s*([0-9零一二两三四五六七八九十百]+)\s*[集话話期]"#, in: name) { result.episode = number(match[0]) }
        if result.episode == nil, let match = groups(#"(?i)(?<![A-Z0-9])EP?(\d{1,4})(?![0-9])"#, in: name) { result.episode = Int(match[0]) }

        // What's outside square brackets is the title, unless brackets hold all of it ([字幕组][Frieren][01][1080p]).
        let outside = name.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
        var text = outside
        if cleaned(cut(outside)).isEmpty {
            let inside = all(#"\[([^\]]*)\]"#, in: name).filter { !isTag($0) }
            // The first of several is the group that made the file.
            text = inside.count > 1 ? inside[1] : inside.first ?? ""
            if isFile, result.episode == nil, let bare = all(#"\[([^\]]*)\]"#, in: name).first(where: { $0.allSatisfy(\.isNumber) && $0.count <= 4 }) {
                result.episode = Int(bare)
            }
        }
        if result.year == nil, let year = year(in: text) { result.year = year.value }
        else if result.year == nil, let year = year(in: name) { result.year = year.value }
        result.title = cleaned(cut(text))
        // A file named for its episode alone ("01", "E05") has no title of its own.
        if isFile, result.episode == nil, let whole = Int(result.title), result.title.count <= 3 { result.episode = whole; result.title = "" }
        if result.title.isEmpty, result.season == nil, result.episode == nil, isCategoryName(text) { result.isCategory = true }
        return result
    }

    /// The part of the name before the first thing that isn't the title: the year, the season or episode, the
    /// resolution, the release's tags.
    static func cut(_ text: String) -> String {
        var end = text.endIndex
        // A name that starts with its season or episode ("S01E01", "Season 1") has no title before it.
        func stop(at index: String.Index?) { if let index, index < end { end = index } }
        if let year = year(in: text) { stop(at: year.range.lowerBound) }
        for pattern in stops {
            if let range = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)).flatMap({ Range($0.range, in: text) }) {
                stop(at: range.lowerBound)
            }
        }
        return String(text[..<end])
    }

    /// Separators to spaces, a site's address and a trailing "合集" gone; for a name in Chinese and English
    /// ("流浪地球2 The Wandering Earth II") the Chinese.
    static func cleaned(_ text: String) -> String {
        var text = text.replacingOccurrences(of: #"(?i)(https?://)?(www\.)?[a-z0-9-]+\.(com|net|org|cc|me|tv|vip|top|xyz|cn)"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[._\[\]()「」《》<>]"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?<=[^\s])-(?=[^\s])"#, with: " ", options: .regularExpression)
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        words.removeAll { noise.contains($0.lowercased()) }
        if words.contains(where: { $0.contains(where: \.isCJK) }) {
            // The Chinese words, and a number or Roman numeral right after one ("复仇者联盟 4").
            var kept: [String] = []
            for word in words {
                if word.contains(where: \.isCJK) { kept.append(word) }
                else if let last = kept.last, last.contains(where: \.isCJK), word.allSatisfy({ $0.isNumber }) || romanNumerals.contains(word) { kept.append(word) }
                else if !kept.isEmpty { break }
            }
            words = kept
        }
        var title = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " -–—:：,，·+&"))
        for suffix in titleSuffixes where title.hasSuffix(suffix) && title.count > suffix.count {
            title = String(title.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        return title
    }

    /// The year that ends the title: the last one in parentheses, else the last one after the start.
    static func year(in text: String) -> (value: Int, range: Range<String.Index>)? {
        let range = NSRange(text.startIndex..., in: text)
        if let match = yearInParentheses.matches(in: text, range: range).last, let found = Range(match.range(at: 1), in: text),
           let value = Int(text[found]) {
            return (value, Range(match.range, in: text) ?? found)
        }
        // Not at the very start: "2012.2009.1080p" is the film 2012.
        let matches = yearPattern.matches(in: text, range: range).compactMap { Range($0.range, in: text) }.filter { $0.lowerBound > text.startIndex }
        guard !matches.isEmpty else { return nil }
        // The last year before the release's tags: "Blade.Runner.2049.2017.1080p" is Blade Runner 2049, from 2017, and a
        // year after the tags ("…BluRay.2023重制") is not the film's.
        let tags = stops.compactMap { $0.firstMatch(in: text, range: range).flatMap { Range($0.range, in: text)?.lowerBound } }.min() ?? text.endIndex
        let chosen = matches.last { $0.lowerBound < tags } ?? matches[0]
        return Int(text[chosen]).map { ($0, chosen) }
    }

    static func isCategoryName(_ text: String) -> Bool {
        let key = text.lowercased().replacingOccurrences(of: #"[\s._\-\[\]()]"#, with: "", options: .regularExpression)
        if categories.contains(key) { return true }
        // "4K电影", "高分美剧", "国产动漫": a short qualifier before a kind.
        return key.count <= 6 && categoryKinds.contains { key.hasSuffix($0) && key.count > $0.count }
            && !key.contains(where: { $0.isNumber && !"4k8k2k".contains($0) })
    }

    /// A bracket's text that isn't a title: a size, resolution, episode number, site or release tag.
    static func isTag(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespaces)
        if value.isEmpty || value.allSatisfy({ $0.isNumber || $0 == "-" || $0 == "v" || $0 == "V" }) { return true }
        if value.range(of: #"(?i)www\.|\.(com|net|org|cc|me|tv)\b|字幕|压制|搬运|\d+(\.\d+)?\s?[GMT]i?B?$"#, options: .regularExpression) != nil { return true }
        return stops.contains { $0.firstMatch(in: value, range: NSRange(value.startIndex..., in: value))?.range.location == 0 }
    }

    static func number(_ text: String) -> Int? {
        if let value = Int(text) { return value }
        let digits: [Character: Int] = ["零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        var total = 0, current = 0
        for character in text {
            if let digit = digits[character] { current = digit }
            else if character == "十" { total += (current == 0 ? 1 : current) * 10; current = 0 }
            else if character == "百" { total += (current == 0 ? 1 : current) * 100; current = 0 }
            else { return nil }
        }
        let value = total + current
        return value > 0 ? value : nil
    }

    private static func first(_ pattern: String, in text: String) -> String? { groups(pattern, in: text)?.first }
    private static func groups(_ pattern: String, in text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }
    private static func all(_ pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
    }

    private static let yearPattern = try! NSRegularExpression(pattern: #"(?<![0-9])(?:19[2-9][0-9]|20[0-4][0-9])(?![0-9]|[pPiIkK])"#)
    private static let yearInParentheses = try! NSRegularExpression(pattern: #"[(\[]\s*((?:19[2-9][0-9]|20[0-4][0-9]))\s*[)\]]"#)
    /// Where a title ends: an episode or season, a resolution or source, a codec, audio, Chinese release words.
    private static let stops: [NSRegularExpression] = [
        #"(?i)(?<![A-Z0-9])S\d{1,2}(?:[ ._-]?EP?\d{1,4})?(?![0-9])"#,
        #"(?i)(?<![A-Z0-9])(?:Season|EP?)[ ._-]?\d{1,4}(?![0-9])"#,
        #"第\s*[0-9零一二两三四五六七八九十百]+\s*[季集话話期部]"#,
        #"(?i)(?<![A-Z0-9])(?:\d{3,4}[PI]|[248]K|UHD|FHD|HD|BD|WEB-?DL|WEB-?RIP|WEB|BluRay|Blu-ray|BDRip|DVDRip|HDTV|HDR10\+?|HDR|DV|DoVi|REMUX|x26[45]|H\.?26[45]|HEVC|AVC|AV1|AAC|AC3|DTS(?:-HD)?|DDP?\d?(?:\.\d)?|TrueHD|Atmos|\d{1,2}bit|60fps|IMAX|Complete|COMPLETE|PROPER|REPACK|NF|AMZN|DSNP|iTunes)(?![A-Z0-9])"#,
        #"国语|粤语|國語|粵語|中字|中英|英语|英語|双语|雙語|国英|字幕|高清|超清|蓝光|藍光|原盘|无删减|未删减|完结|完結|全\s*\d+\s*集|更新至|特效|内封|内嵌|外挂|杜比"#,
        #"(?<![0-9.])\d+(?:\.\d+)?\s?[GMT]i?B(?![A-Za-z])"#,
    ].map { try! NSRegularExpression(pattern: $0) }
    private static let noise: Set<String> = ["mp4", "mkv", "hd", "tc", "ts", "cam", "国语", "中字", "-", "+", "&"]
    private static let romanNumerals: Set<String> = ["II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X"]
    private static let titleSuffixes = ["合集", "全集", "系列", "完整版", "导演剪辑版", "加长版", "剧场版合集", "全系列"]
    private static let categories: Set<String> = [
        "电影", "電影", "电视剧", "電視劇", "剧集", "劇集", "连续剧", "動漫", "动漫", "动画", "動畫", "番剧", "综艺", "綜藝", "纪录片", "紀錄片",
        "少儿", "儿童", "短剧", "短劇", "国产剧", "国剧", "美剧", "美劇", "韩剧", "韓劇", "日剧", "日劇", "港剧", "港劇", "台剧", "英剧", "泰剧",
        "欧美", "华语", "國語", "日韩", "港台", "大陆", "音乐", "音樂", "视频", "影视", "影視", "下载", "资源", "我的资源", "来自分享", "共享",
        "媒体库", "合集", "其他", "其它", "未分类", "蓝光", "原盘", "高清", "4k", "8k", "1080p", "2160p", "uhd", "remux",
        "movie", "movies", "film", "films", "tv", "tvshows", "tvseries", "series", "shows", "show", "anime", "animation", "cartoon",
        "documentary", "documentaries", "docs", "kids", "music", "videos", "video", "downloads", "download", "media", "library",
        "collection", "collections", "others", "other", "misc", "temp", "tmp", "share", "shared", "public", "home", "data", "volume1",
        "specials", "special", "extras", "featurettes", "trailers", "sample", "samples", "subs", "subtitles", "字幕",
    ]
    private static let categoryKinds = ["电影", "電影", "电视剧", "剧集", "动漫", "动画", "综艺", "纪录片", "美剧", "韩剧", "日剧", "港剧", "短剧", "番剧"]
}

extension Character {
    /// A Chinese, Japanese or Korean character.
    var isCJK: Bool {
        unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value) || (0x3040...0x30FF).contains(scalar.value)
                || (0xAC00...0xD7AF).contains(scalar.value) || (0xF900...0xFAFF).contains(scalar.value)
        }
    }
}

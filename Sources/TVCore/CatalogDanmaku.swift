import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct CatalogDanmakuComment: Sendable, Hashable, Codable {
    public enum Mode: Int, Sendable, Codable { case scroll = 1, bottom = 4, top = 5 }
    public let time: Double
    public let mode: Mode
    public let color: UInt32
    public let text: String

    public init?(time: Double, mode: Int, color: UInt32, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard time.isFinite, (0...604_800).contains(time), let mode = Mode(rawValue: mode), !text.isEmpty else { return nil }
        self.time = time; self.mode = mode; self.color = color & 0xffffff
        self.text = String(text.replacingOccurrences(of: "\n", with: " ").prefix(120))
    }
}

public enum CatalogDanmakuParser {
    public static let maximumBytes = 8 * 1024 * 1024
    public static let maximumComments = 30_000

    /// Dandanplay v2 JSON: p = time,mode,color,user. Bilibili-style XML uses
    /// time,mode,size,color,... instead; these two layouts must not be confused.
    public static func parse(_ data: Data) throws -> [CatalogDanmakuComment] {
        guard data.count <= maximumBytes else { throw TVError.unsupported(L10n.text("The danmaku file is too large.")) }
        if data.first(where: { ![9, 10, 13, 32].contains($0) }) == 60 {
            let reader = DanmakuXMLReader()
            return try reader.read(data)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["success"] as? Bool != false, root["comments"] != nil || root["danmuku"] != nil else {
            throw TVError.unsupported(L10n.text("The service did not return a supported danmaku list."))
        }
        // dmku (code 23): time,"right"|"top"|"bottom",color,size,text. danmu.zxz.ee (code 200): time,mode,color,text,sent.
        let code = (root["code"] as? NSNumber)?.intValue
        if let rows = root["danmuku"] as? [[Any]], code == 23 || code == 200 {
            var seen = Set<CatalogDanmakuComment>()
            return rows.prefix(maximumComments).compactMap { row in
                guard row.count >= 5, let time = row[0] as? NSNumber else { return nil }
                let mode: Int, text: String
                if code == 23 {
                    guard let value = row[4] as? String else { return nil }
                    let direction = row[1] as? String ?? "right"
                    mode = direction == "top" ? 5 : direction == "bottom" ? 4 : 1; text = value
                } else {
                    // Its first row announces the count ("有475条弹幕正在赶来…"); it isn't a comment.
                    guard let value = row[3] as? String, let number = row[1] as? NSNumber, !value.contains("条弹幕正在赶来") else { return nil }
                    mode = number.intValue; text = value
                }
                var colorText = (row[2] as? String ?? "").replacingOccurrences(of: "#", with: "")
                if colorText.count == 3 { colorText = colorText.map { "\($0)\($0)" }.joined() }
                let color = UInt32(colorText, radix: 16) ?? 0xffffff
                guard let comment = CatalogDanmakuComment(time: time.doubleValue, mode: mode, color: color, text: text), seen.insert(comment).inserted else { return nil }
                return comment
            }.sorted { $0.time < $1.time }
        }
        guard let rows = root["comments"] as? [[String: Any]] else {
            throw TVError.unsupported(L10n.text("The service did not return a supported danmaku list."))
        }
        var seen = Set<CatalogDanmakuComment>()
        return rows.prefix(maximumComments).compactMap { row -> CatalogDanmakuComment? in
            guard let p = row["p"] as? String, let text = row["m"] as? String else { return nil }
            let fields = p.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3, let time = Double(fields[0]), let mode = Int(fields[1]), let color = UInt32(fields[2]),
                  let comment = CatalogDanmakuComment(time: time, mode: mode, color: color, text: text), seen.insert(comment).inserted else { return nil }
            return comment
        }.sorted { $0.time < $1.time }
    }
}

private final class DanmakuXMLReader: NSObject, XMLParserDelegate {
    private var comments: [CatalogDanmakuComment] = []
    private var attributes: String?
    private var text = ""
    private var rootIsValid = false
    func read(_ data: Data) throws -> [CatalogDanmakuComment] {
        // Local files need no DTD/entity expansion or external network access.
        guard !String(decoding: data, as: UTF8.self).uppercased().contains("<!DOCTYPE") else { throw TVError.unsupported(L10n.text("The service did not return a supported danmaku list.")) }
        let parser = XMLParser(data: data)
        parser.delegate = self; parser.shouldResolveExternalEntities = false
        let valid = parser.parse()
        guard rootIsValid, valid || comments.count >= CatalogDanmakuParser.maximumComments else { throw TVError.unsupported(L10n.text("The service did not return a supported danmaku list.")) }
        return Array(Set(comments)).sorted { $0.time < $1.time }
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes fields: [String: String]) {
        if name == "i" { rootIsValid = true }
        if name == "d" { attributes = fields["p"]; text = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if attributes != nil, text.count < 512 { text += string }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard name == "d", let p = attributes else { return }
        attributes = nil
        let fields = p.split(separator: ",", omittingEmptySubsequences: false)
        if fields.count >= 4, let time = Double(fields[0]), let mode = Int(fields[1]), let color = UInt32(fields[3]),
           let comment = CatalogDanmakuComment(time: time, mode: mode, color: color, text: text) { comments.append(comment) }
        if comments.count >= CatalogDanmakuParser.maximumComments { parser.abortParsing() }
    }
}

public struct CatalogDanmakuAnime: Identifiable, Sendable, Hashable {
    /// The service's catalog ID, not the platform-native bangumi ID.
    public let id: String
    public let title: String
    public let type: String
    public let source: String
    public let year: String?
    public let typeCode: String?
    public let bangumiID: String?
    public var provider: DanmakuProvider { DanmakuProvider(source: source) }
    public var sourceTitle: String { provider == .automatic ? source : provider.title }

    public init(id: String, title: String, type: String = "", source: String = "", year: String? = nil,
                typeCode: String? = nil, bangumiID: String? = nil) {
        let metadata = CatalogDanmakuMatcher.titleMetadata(title)
        self.id = id; self.title = title; self.type = type.isEmpty ? metadata.type ?? "" : type
        self.source = source.isEmpty ? metadata.source ?? "" : source
        self.year = year ?? metadata.year; self.typeCode = typeCode; self.bangumiID = bangumiID
    }
}

public struct CatalogDanmakuEpisode: Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let episodeNumber: Int?
    public let source: String
    public let url: URL?
    public var provider: DanmakuProvider { DanmakuProvider(source: source) }
    public var sourceTitle: String { provider == .automatic ? source : provider.title }

    public init(id: String, title: String, episodeNumber: Int? = nil, source: String = "", url: URL? = nil) {
        self.id = id; self.title = title
        self.episodeNumber = episodeNumber.flatMap { (1...9999).contains($0) ? $0 : nil } ?? CatalogDanmakuMatcher.explicitEpisodeNumber(title)
        self.source = source.isEmpty ? CatalogDanmakuMatcher.episodeSource(title: title, url: url) : source
        self.url = url
    }
}

/// Prefer no track to a track from the wrong season or episode.
public enum CatalogDanmakuMatcher {
    public static func anime(title: String, year: String? = nil, source: DanmakuProvider = .automatic,
                             in results: [CatalogDanmakuAnime]) -> CatalogDanmakuAnime? {
        let matches = animeCandidates(title: title, year: year, source: source, in: results)
        return matches.count == 1 ? matches.first : nil
    }

    /// Exact work/season matches. Multiple platforms are kept separate by the resolver; duplicate
    /// editions within one platform remain ambiguous. Unknown aggregators can expose a requested platform.
    static func animeCandidates(title: String, year: String?, source: DanmakuProvider,
                                in results: [CatalogDanmakuAnime]) -> [CatalogDanmakuAnime] {
        let metadata = titleMetadata(title), key = normalized(metadata.title)
        guard !key.isEmpty else { return [] }
        let requestedYear = year.flatMap(parseYear) ?? metadata.year
        if let year = year.flatMap(parseYear), let titledYear = metadata.year, year != titledYear { return [] }
        var seen = Set<String>()
        let matches = results.filter { anime in
            let candidate = titleMetadata(anime.title)
            guard normalized(candidate.title) == key,
                  source == .automatic || anime.provider == source || anime.provider == .automatic,
                  anime.year == nil || candidate.year == nil || anime.year == candidate.year,
                  requestedYear == nil || anime.year == nil || anime.year == requestedYear else { return false }
            return seen.insert(anime.source + "|" + anime.id).inserted
        }
        if requestedYear == nil, Set(matches.compactMap(\.year)).count > 1 { return [] }
        // A known exact year is stronger than an undated duplicate, but only for that platform.
        return matches.filter { anime in
            requestedYear == nil || anime.year != nil || !matches.contains { $0.source == anime.source && $0.year == requestedYear }
        }
    }

    public static func episode(name: String, in episodes: [CatalogDanmakuEpisode]) -> CatalogDanmakuEpisode? {
        episode(name: name, seriesTitle: "", in: episodes)
    }

    /// Titles with an explicit episode number outrank metadata. Metadata never overrides an explicit
    /// contradictory title, nor supplies a number to a preview, special, or an arbitrary named extra.
    public static func episode(name: String, seriesTitle: String, source: DanmakuProvider = .automatic,
                               in episodes: [CatalogDanmakuEpisode]) -> CatalogDanmakuEpisode? {
        guard !isExtra(name) else { return nil }
        let candidates = episodes.filter { !isExtra($0.title) && (source == .automatic || $0.provider == source) }
        if let number = explicitEpisodeNumber(name) {
            let explicit = candidates.filter { explicitEpisodeNumber($0.title) == number }
            if !explicit.isEmpty { return explicit.count == 1 ? explicit.first : nil }
            let metadata = candidates.filter {
                explicitEpisodeNumber($0.title) == nil && $0.episodeNumber == number && isUnnamedMain($0.title, seriesTitle: seriesTitle)
            }
            return metadata.count == 1 ? metadata.first : nil
        }
        let movies = ["正片", "电影", "電影", "剧场版", "劇場版", "hd", "hd中字", "hd国语", "1080p", "720p", "蓝光", "藍光", "完整版", "fullmovie"]
        return candidates.count == 1 && movies.contains(normalized(name)) ? candidates.first : nil
    }

    static func isExtra(_ title: String) -> Bool {
        let key = normalized(title)
        let words = ["预告", "预览", "先导", "花絮", "彩蛋", "番外", "特典", "特别篇", "特别节目", "精华", "片段", "剪辑", "幕后", "采访", "访谈", "探班", "官宣", "阵容", "海报", "概念片", "宣传", "预热", "首映礼", "发布会"]
        return words.contains(where: key.contains)
            || title.range(of: #"(?i)(?<![a-z])(?:trailer|preview|teaser|bonus|special|extra|ova|oad)(?![a-z])"#, options: .regularExpression) != nil
            || title.range(of: #"(?i)(?:^|[\s【\[])SP\s*\d"#, options: .regularExpression) != nil
    }

    static func explicitEpisodeNumber(_ title: String) -> Int? {
        guard !isExtra(title) else { return nil }
        // Service titles often prefix the platform and work name: 【qq】 三体 第1集 …
        let pattern = #"第\s*([0-9]{1,4}|[零〇一二两三四五六七八九十百]+)\s*[集话話回]"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = expression.matches(in: title, range: NSRange(title.startIndex..., in: title))
        let numbers = matches.compactMap { match -> Int? in
            guard let range = Range(match.range, in: title) else { return nil }
            return episodeNumber(String(title[range]).replacingOccurrences(of: " ", with: ""))
        }
        if !matches.isEmpty { return Set(numbers).count == 1 ? numbers.first : nil }
        return episodeNumber(title)
    }

    static func isUnnamedMain(_ title: String, seriesTitle: String) -> Bool {
        guard !isExtra(title) else { return false }
        let clean = title.replacingOccurrences(of: #"^\s*[【\[][^】\]]+[】\]]\s*"#, with: "", options: .regularExpression)
        let key = normalized(clean)
        if !seriesTitle.isEmpty && key == normalized(titleMetadata(seriesTitle).title) { return true }
        guard !hasNumberedTitle(clean) else { return false }
        return key.isEmpty || ["正片", "全集", "full", "fullepisode"].contains(key)
    }

    private static func hasNumberedTitle(_ title: String) -> Bool {
        // A range, season/episode notation or malformed explicit label is not an unnamed main episode.
        title.range(of: #"[0-9零〇一二两三四五六七八九十百]"#, options: .regularExpression) != nil
    }

    static func episodeSource(title: String, url: URL?) -> String {
        if let expression = try? NSRegularExpression(pattern: #"^\s*[【\[]([^】\]]+)[】\]]"#),
           let match = expression.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
           let range = Range(match.range(at: 1), in: title) {
            let tag = String(title[range]).replacingOccurrences(of: #"[0-9]+$"#, with: "", options: .regularExpression)
            let provider = DanmakuProvider(source: tag)
            if provider != .automatic { return provider.rawValue }
        }
        let host = url?.host()?.lowercased() ?? ""
        for (domain, provider) in [("iqiyi.com", DanmakuProvider.iqiyi), ("qq.com", .tencent), ("bilibili.com", .bilibili),
                                   ("youku.com", .youku), ("mgtv.com", .imgo), ("miguvideo.com", .migu)] {
            if host == domain || host.hasSuffix("." + domain) { return provider.rawValue }
        }
        return ""
    }

    static func parseYear(_ value: String) -> String? {
        guard let range = value.range(of: #"^(?:19|20)[0-9]{2}(?=$|[-/年])"#, options: .regularExpression) else { return nil }
        return String(value[range])
    }

    /// Remove service-authored metadata only; season names and arbitrary subtitles remain significant.
    static func titleMetadata(_ text: String) -> (title: String, year: String?, source: String?, type: String?) {
        var title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var source: String?, type: String?, year: String?
        // Services write "Title(2023)【电视剧】from tencent". Only that form, or a platform's own name, is a source:
        // "Escape from Alcatraz" and "Escape from Tomorrow" are different films, not one title from two sources.
        if let range = title.range(of: #"(?:\s+|(?<=】))from\s+([a-zA-Z0-9_-]+)\s*$"#, options: [.regularExpression, .caseInsensitive]),
           let word = title[range].split(whereSeparator: { $0.isWhitespace }).last.map(String.init),
           title[..<range.lowerBound].hasSuffix("】") || DanmakuProvider(source: word) != .automatic {
            source = word
            title.removeSubrange(range)
            if let range = title.range(of: #"【[^】]+】\s*$"#, options: .regularExpression) {
                type = String(title[range]).trimmingCharacters(in: CharacterSet(charactersIn: "【】 "))
                title.removeSubrange(range)
            }
        }
        // Some implementations label the source with parentheses instead of `from`.
        if let range = title.range(of: #"[（(][^()（）]+[）)]\s*$"#, options: .regularExpression) {
            let tag = String(title[range]).trimmingCharacters(in: CharacterSet(charactersIn: "（）() "))
            let provider = DanmakuProvider(source: tag)
            if provider != .automatic { source = source ?? provider.rawValue; title.removeSubrange(range) }
        }
        if let range = title.range(of: #"[（(](?:19|20)[0-9]{2}[）)]\s*$"#, options: .regularExpression) {
            year = String(title[range]).trimmingCharacters(in: CharacterSet(charactersIn: "（）() "))
            title.removeSubrange(range)
        }
        return (title.trimmingCharacters(in: .whitespacesAndNewlines), year, source, type)
    }

    public static func episodeNumber(_ name: String) -> Int? {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for pattern in [#"^(?:第\s*)?([0-9]{1,4})\s*(?:[集话話回]|$)"#,
                        #"^ep(?:isode)?\.?\s*([0-9]{1,4})(?:\D|$)"#] {
            if let expression = try? NSRegularExpression(pattern: pattern),
               let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
               let range = Range(match.range(at: 1), in: value), let number = Int(value[range]), number > 0 { return number }
        }
        let expression = try! NSRegularExpression(pattern: #"^第([零〇一二两三四五六七八九十百]+)[集话話回]"#)
        guard let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        let digits: [Character: Int] = ["零":0,"〇":0,"一":1,"二":2,"两":2,"三":3,"四":4,"五":5,"六":6,"七":7,"八":8,"九":9]
        var total = 0, digit = 0
        for char in value[range] {
            if let number = digits[char] { digit = number }
            else { total += max(1, digit) * (char == "百" ? 100 : 10); digit = 0 }
        }
        let number = total + digit
        return number > 0 ? number : nil
    }

    public static func normalized(_ text: String) -> String {
        let simplified = text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text
        return String(simplified.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}

/// Dandanplay's requests for this app are few and shared by every install. Once they are used up it answers
/// HTTP 429, or HTTP 200 with `errorCode` 429.
public struct DandanplayLimitReached: LocalizedError, Sendable {
    public init() {}
    public var errorDescription: String? {
        L10n.text("Dandanplay has reached its request limit for now. Try again later, or choose another danmaku server.")
    }
}

/// The server refused the request (HTTP 401 or 403): a token in its address is wrong or has expired, or it isn't public.
public struct DanmakuAuthorizationRequired: LocalizedError, Sendable {
    public var errorDescription: String? {
        L10n.text("This danmaku server requires authorization. Choose a compatible public or self-hosted server.")
    }
}

/// Automatic matching and manual searches send only titles and IDs. Video URLs,
/// subscription URLs, headers and credentials are never sent to this service.
public struct CatalogDanmakuClient: Sendable {
    public static let defaultServer = "https://api.dandanplay.net"
    public static let legacyDefaultServer = "https://danmaku-api.152468.xyz"
    public let server: URL
    private let transport: DanmakuHTTP?
    private let credentials: DandanplayCredentials?

    public init(address: String = Self.defaultServer, transport: DanmakuHTTP? = nil,
                credentials: DandanplayCredentials? = .bundled) throws {
        self.transport = transport
        self.credentials = credentials
        let url = try WebAddress.resolve(address.trimmingCharacters(in: .whitespacesAndNewlines))
        guard url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw TVError.unsupported(L10n.text("Enter the danmaku server base URL, without a query or fragment."))
        }
        // Work on the encoded path: a token containing %2F or %2B must not be decoded or re-encoded.
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.scheme = parts.scheme?.lowercased(); parts.host = parts.host?.lowercased()
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
        var path = parts.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/api/v2") { path = String(path.dropLast(7)) }
        parts.percentEncodedPath = path
        guard let base = parts.url else { throw TVError.invalidURL }
        server = base.absoluteString == Self.legacyDefaultServer ? URL(string: Self.defaultServer)! : base
    }

    public func search(_ keyword: String, source: DanmakuProvider = .automatic) async throws -> [CatalogDanmakuAnime] {
        let data = try await request("search/anime", query: [.init(name: "keyword", value: keyword)], timeout: 45)
        let root = try object(data)
        guard let rows = root["animes"] as? [[String: Any]] else { throw unsupported() }
        return rows.prefix(100).compactMap { row in
            // Self-hosted services return a numeric animeId alongside an opaque platform bangumiId.
            guard let id = Self.identifier(row["animeId"]) ?? Self.identifier(row["bangumiId"]),
                  let title = row["animeTitle"] as? String else { return nil }
            let anime = CatalogDanmakuAnime(id: id, title: title, type: row["typeDescription"] as? String ?? "",
                source: row["source"] as? String ?? "", year: (row["startDate"] as? String).flatMap(CatalogDanmakuMatcher.parseYear),
                typeCode: Self.text(row["type"]), bangumiID: Self.identifier(row["bangumiId"]))
            return source == .automatic || anime.provider == source || anime.provider == .automatic ? anime : nil
        }
    }

    public func episodes(_ anime: CatalogDanmakuAnime) async throws -> [CatalogDanmakuEpisode] {
        guard let animeID = Self.identifier(anime.id) else { throw unsupported() }
        let root = try object(try await request("bangumi/" + animeID))
        guard let bangumi = root["bangumi"] as? [String: Any], let rows = bangumi["episodes"] as? [[String: Any]] else { throw unsupported() }
        return rows.prefix(5_000).compactMap { row in
            guard let id = Self.identifier(row["episodeId"]) else { return nil }
            let title = row["episodeTitle"] as? String ?? ""
            let url = (row["url"] as? String).flatMap { try? WebAddress.resolve($0) }
            let inferred = CatalogDanmakuMatcher.episodeSource(title: title, url: url)
            let source = row["source"] as? String ?? (inferred.isEmpty ? anime.source : inferred)
            return CatalogDanmakuEpisode(id: id, title: title, episodeNumber: Self.text(row["episodeNumber"]).flatMap(Int.init), source: source, url: url)
        }
    }

    public func comments(_ episode: CatalogDanmakuEpisode) async throws -> [CatalogDanmakuComment] {
        guard let id = Self.identifier(episode.id) else { throw unsupported() }
        return try CatalogDanmakuParser.parse(await request("comment/" + id, query: [
            .init(name: "withRelated", value: "true"), .init(name: "chConvert", value: "0"), .init(name: "format", value: "json")]))
    }

    private static func text(_ value: Any?) -> String? { (value as? String) ?? (value as? NSNumber)?.stringValue }
    private static func identifier(_ value: Any?) -> String? {
        guard let text = text(value), !text.isEmpty, text.count <= 128,
              text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { return nil }
        return text
    }

    private func request(_ path: String, query: [URLQueryItem] = [], timeout: TimeInterval = 25) async throws -> Data {
        var parts = URLComponents(url: server, resolvingAgainstBaseURL: false)!
        parts.percentEncodedPath += "/api/v2/" + path
        parts.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: parts.url!, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Yingxia (danmaku; https://www.getmegaportal.com)", forHTTPHeaderField: "User-Agent")
        if DandanplayCredentials.isOfficial(request.url!) {
            guard let credentials else {
                throw TVError.unsupported(L10n.text("This build is missing its Dandanplay API configuration."))
            }
            credentials.sign(&request)
        }
        if let transport {
            let data: Data
            do { data = try await transport.send(request) }
            catch TVError.http(429) { throw DandanplayLimitReached() }
            catch TVError.http(let status) where status == 401 || status == 403 { throw DanmakuAuthorizationRequired() }
            guard data.count <= CatalogDanmakuParser.maximumBytes else { throw unsupported() }
            try Self.checkLimit(data)
            return data
        }
        let (bytes, response) = try await URLSession.shared.bytes(for: request, delegate: request.value(forHTTPHeaderField: "X-AppId") == nil ? nil : DandanplayRedirectPolicy.shared)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if status == 429 { throw DandanplayLimitReached() }
            if status == 401 || status == 403 { throw DanmakuAuthorizationRequired() }
            // Preserve HTTP status identity so a stale catalog ID can be refreshed on 404.
            throw TVError.http(status)
        }
        if response.expectedContentLength > CatalogDanmakuParser.maximumBytes { throw TVError.unsupported(L10n.text("The danmaku file is too large.")) }
        var data = Data()
        for try await byte in bytes {
            if data.count >= CatalogDanmakuParser.maximumBytes { throw TVError.unsupported(L10n.text("The danmaku file is too large.")) }
            data.append(byte)
        }
        try Task.checkCancellation()
        try Self.checkLimit(data)
        return data
    }

    /// A refusal is a short JSON object; comments and episode lists are far longer and never parsed here.
    static func checkLimit(_ data: Data) throws {
        guard data.count < 2048, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["success"] as? Bool == false, (root["errorCode"] as? NSNumber)?.intValue == 429 else { return }
        throw DandanplayLimitReached()
    }

    private func object(_ data: Data) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["success"] as? Bool != false else { throw unsupported() }
        return root
    }
    private func unsupported() -> TVError { .unsupported(L10n.text("The danmaku server could not complete this request. Try another server.")) }
}

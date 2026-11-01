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
              root["comments"] != nil || root["danmuku"] != nil else {
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
    public let id: String
    public let title: String
    public let type: String
}

public struct CatalogDanmakuEpisode: Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
}

/// Prefer no track to a track from the wrong season or episode.
public enum CatalogDanmakuMatcher {
    public static func anime(title: String, in results: [CatalogDanmakuAnime]) -> CatalogDanmakuAnime? {
        let key = normalized(title)
        guard !key.isEmpty else { return nil }
        var seen = Set<String>()
        let matches = results.filter { normalized($0.title) == key && seen.insert($0.id).inserted }
        return matches.count == 1 ? matches.first : nil
    }

    public static func episode(name: String, in episodes: [CatalogDanmakuEpisode]) -> CatalogDanmakuEpisode? {
        if let number = episodeNumber(name) {
            let matches = episodes.filter { episodeNumber($0.title) == number }
            return matches.count == 1 ? matches.first : nil
        }
        let movies = ["正片", "电影", "電影", "剧场版", "劇場版", "hd", "hd中字", "hd国语", "1080p", "720p", "蓝光", "藍光", "完整版", "fullmovie"]
        return episodes.count == 1 && movies.contains(normalized(name)) ? episodes.first : nil
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
        // Accept either a server root (including a self-hosted token path) or /api/v2.
        var value = url.absoluteString
        while value.hasSuffix("/") { value.removeLast() }
        if value.hasSuffix("/api/v2") { value = String(value.dropLast(7)) }
        guard let base = URL(string: value) else { throw TVError.invalidURL }
        server = base.absoluteString == Self.legacyDefaultServer ? URL(string: Self.defaultServer)! : base
    }

    public func search(_ keyword: String) async throws -> [CatalogDanmakuAnime] {
        let data = try await request("search/anime", query: [.init(name: "keyword", value: keyword)])
        let root = try object(data)
        guard let rows = root["animes"] as? [[String: Any]] else { throw unsupported() }
        return rows.prefix(100).compactMap { row in
            guard let id = Self.identifier(row["bangumiId"] ?? row["animeId"]), let title = row["animeTitle"] as? String else { return nil }
            return CatalogDanmakuAnime(id: id, title: title, type: row["typeDescription"] as? String ?? "")
        }
    }

    public func episodes(_ anime: CatalogDanmakuAnime) async throws -> [CatalogDanmakuEpisode] {
        let root = try object(try await request("bangumi/" + anime.id))
        guard let bangumi = root["bangumi"] as? [String: Any], let rows = bangumi["episodes"] as? [[String: Any]] else { throw unsupported() }
        return rows.prefix(5_000).compactMap { row in
            guard let id = Self.identifier(row["episodeId"]), let title = row["episodeTitle"] as? String else { return nil }
            return CatalogDanmakuEpisode(id: id, title: title)
        }
    }

    public func comments(_ episode: CatalogDanmakuEpisode) async throws -> [CatalogDanmakuComment] {
        try CatalogDanmakuParser.parse(await request("comment/" + episode.id, query: [
            .init(name: "withRelated", value: "true"), .init(name: "chConvert", value: "0")]))
    }

    private static func identifier(_ value: Any?) -> String? {
        let text = (value as? String) ?? (value as? NSNumber)?.stringValue
        guard let text, !text.isEmpty, text.count <= 64, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return text
    }

    private func request(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        var parts = URLComponents(url: server.appending(path: "api/v2/" + path), resolvingAgainstBaseURL: false)!
        parts.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: parts.url!, timeoutInterval: 25)
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
            do { data = try await transport.send(request) } catch TVError.http(429) { throw DandanplayLimitReached() }
            guard data.count <= CatalogDanmakuParser.maximumBytes else { throw unsupported() }
            try Self.checkLimit(data)
            return data
        }
        let (bytes, response) = try await URLSession.shared.bytes(for: request, delegate: request.value(forHTTPHeaderField: "X-AppId") == nil ? nil : DandanplayRedirectPolicy.shared)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if status == 429 { throw DandanplayLimitReached() }
            if status == 401 || status == 403 { throw TVError.unsupported(L10n.text("This danmaku server requires authorization. Choose a compatible public or self-hosted server.")) }
            throw TVError.unsupported(L10n.text("The server returned HTTP %lld.", status))
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

import CryptoKit
import Foundation

/// Subtitle sources (#576 M2): services the viewer turns on that find subtitle files for the playing video by its
/// title, season and episode, and say where to download the one chosen. A source is a script
/// (SubtitleScriptProvider) that keeps this contract; the search across sources is SubtitleSearch. The protocol is
/// written down in Docs/subtitles.md.
public enum SubtitleProtocol {
    /// The contract this build keeps. A source whose `minimumHost` is later is refused rather than half-run.
    public static let version = 1
}

/// What a source says about itself (`subtitleSource.manifest`).
public struct SubtitleProviderManifest: Codable, Hashable, Sendable {
    /// A value the viewer types in Settings (an API key, a user name). Kept in the Keychain and handed to the
    /// source on each call, never stored by it.
    public struct Credential: Codable, Hashable, Sendable, Identifiable {
        public let key: String
        public let title: String
        public let secret: Bool
        public let required: Bool
        /// Where to get it, shown under the field.
        public let note: String?
        public var id: String { key }

        public init(key: String, title: String, secret: Bool = true, required: Bool = true, note: String? = nil) {
            self.key = key; self.title = title; self.secret = secret; self.required = required; self.note = note
        }
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            key = try values.decode(String.self, forKey: .key)
            title = try values.decodeIfPresent(String.self, forKey: .title) ?? key
            secret = try values.decodeIfPresent(Bool.self, forKey: .secret) ?? true
            required = try values.decodeIfPresent(Bool.self, forKey: .required) ?? true
            note = try values.decodeIfPresent(String.self, forKey: .note)
        }
    }

    /// The manifest format; 1 is the only one.
    public let schema: Int
    public let id: String
    public let name: String
    public let version: String
    /// The oldest `SubtitleProtocol.version` the source works with.
    public let minimumHost: Int
    /// The hosts the source may reach (each with its subdomains). Nothing else is reachable from it.
    public let domains: [String]
    /// The languages it mostly has (BCP-47), for Settings.
    public let languages: [String]
    public let credentials: [Credential]
    public let homepage: URL?

    public init(schema: Int = 1, id: String, name: String, version: String = "1", minimumHost: Int = 1, domains: [String],
                languages: [String] = [], credentials: [Credential] = [], homepage: URL? = nil) {
        self.schema = schema; self.id = id; self.name = name; self.version = version; self.minimumHost = minimumHost
        self.domains = domains; self.languages = languages; self.credentials = credentials; self.homepage = homepage
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schema = try values.decodeIfPresent(Int.self, forKey: .schema) ?? 0
        id = try values.decode(String.self, forKey: .id)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? id
        version = try values.decodeIfPresent(String.self, forKey: .version) ?? "1"
        minimumHost = try values.decodeIfPresent(Int.self, forKey: .minimumHost) ?? 1
        domains = try values.decodeIfPresent([String].self, forKey: .domains) ?? []
        languages = try values.decodeIfPresent([String].self, forKey: .languages) ?? []
        credentials = try values.decodeIfPresent([Credential].self, forKey: .credentials) ?? []
        homepage = try values.decodeIfPresent(String.self, forKey: .homepage).flatMap(URL.init(string:))
    }

    /// Refuses a manifest this build can't keep its side of.
    public func validate() throws {
        guard schema == 1 else { throw SubtitleProviderError.incompatible(L10n.text("It uses manifest format %@.", String(schema))) }
        guard minimumHost <= SubtitleProtocol.version else { throw SubtitleProviderError.incompatible(L10n.text("It needs a newer version of Yingxia.")) }
        guard id.range(of: #"^[a-z0-9][a-z0-9._-]{0,63}$"#, options: .regularExpression) != nil else {
            throw SubtitleProviderError.incompatible(L10n.text("Its identifier is not valid."))
        }
        guard !domains.isEmpty, domains.allSatisfy(Self.isDomain) else { throw SubtitleProviderError.incompatible(L10n.text("It doesn't list the sites it uses.")) }
        guard Set(credentials.map(\.key)).count == credentials.count else { throw SubtitleProviderError.incompatible(L10n.text("Its settings repeat a name.")) }
    }

    /// Whether a request to `url` stays among the source's own sites.
    public func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", let host = url.host()?.lowercased(), !host.isEmpty else { return false }
        return domains.contains { domain in
            let domain = domain.lowercased()
            return host == domain || host.hasSuffix("." + domain)
        }
    }

    static func isDomain(_ text: String) -> Bool {
        text.range(of: #"^(?=.{1,253}$)([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$"#, options: .regularExpression) != nil
    }
}

/// What is known of the video: the search asks every source with it.
public struct SubtitleHint: Codable, Hashable, Sendable {
    public var title: String
    public var year: Int?
    public var season: Int?
    public var episode: Int?
    public var imdbID: String?
    public var tmdbID: Int?
    /// The video's file or release name, when it has one (`Show.S01E02.1080p.WEB-DL.mkv`).
    public var fileName: String?
    /// The viewer's languages, most wanted first (BCP-47: `zh-Hans`, `en`).
    public var languages: [String]
    /// OpenSubtitles' hash of the playing file (`SubtitleFileHash`), 16 hex digits, and the file's size in bytes.
    public var movieHash: String?
    public var fileSize: Int64?

    public init(title: String, year: Int? = nil, season: Int? = nil, episode: Int? = nil, imdbID: String? = nil, tmdbID: Int? = nil,
                fileName: String? = nil, languages: [String] = SubtitleHint.preferredLanguages(), movieHash: String? = nil, fileSize: Int64? = nil) {
        self.title = title; self.year = year; self.season = season; self.episode = episode; self.imdbID = imdbID; self.tmdbID = tmdbID
        self.fileName = fileName; self.languages = languages; self.movieHash = movieHash; self.fileSize = fileSize
    }

    /// The hint with the catalog's TMDB match (#576 M2): its id, and for a series the season (and episode offset)
    /// TMDB numbers the episode by. A match TMDB numbers across seasons (`absolute`) keeps the source's numbers.
    public func matched(_ match: TMDBMatch.Match) -> SubtitleHint {
        var hint = self
        hint.tmdbID = match.id
        switch match.mediaType {
        case .movie:
            hint.season = nil; hint.episode = nil
        case .tv:
            guard match.numbering == .season, let season = match.season, season > 0 else { break }
            hint.season = season
            if let episode = hint.episode, let offset = match.offset { hint.episode = episode + offset }
        }
        return hint
    }

    /// The hint with the playing file's hash.
    public func hashed(_ file: SubtitleFileHash?) -> SubtitleHint {
        guard let file else { return self }
        var hint = self
        hint.movieHash = file.hash; hint.fileSize = file.size
        return hint
    }

    /// A hint from what the catalog calls a video and its episode (`庆余年 第二季`, `第05集`).
    public init(video: String, episodeName: String, year: String?, fileName: String?, languages: [String] = SubtitleHint.preferredLanguages()) {
        let parsed = SubtitleHint.title(video)
        let episode = SubtitleMatch.episode(episodeName) ?? fileName.flatMap(SubtitleMatch.episode)
        let named = fileName.flatMap(SubtitleHint.seasonInName) ?? SubtitleHint.seasonInName(episodeName)
        // A film has no season; an episode without one named is in the first.
        self.init(title: parsed.title, year: year.flatMap { Int($0.prefix(4)) }, season: parsed.season ?? named ?? episode?.season,
                  episode: episode?.number, fileName: fileName, languages: languages)
    }

    /// The same request, as the search cache's key.
    var key: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: (try? encoder.encode(self)) ?? Data(), as: UTF8.self)
    }

    /// The device's languages as subtitle languages: Chinese split by script, others by language alone.
    public static func preferredLanguages(_ preferred: [String] = Locale.preferredLanguages) -> [String] {
        var out: [String] = []
        for identifier in preferred {
            let language = SubtitleLanguage.normalized(identifier)
            if !language.isEmpty, !out.contains(language) { out.append(language) }
        }
        if !out.contains("en") { out.append("en") }
        return out
    }

    /// A title without its season (`第二季`, `Season 2`, `S2`) and the season it names.
    static func title(_ name: String) -> (title: String, season: Int?) {
        var title = name
        var season: Int?
        let patterns = [#"\s*第\s*([0-9一二三四五六七八九十]+)\s*季"#, #"\s*[Ss]eason\s*([0-9]+)"#, #"\s+[Ss]([0-9]{1,2})$"#]
        for pattern in patterns {
            if let match = title.range(of: pattern, options: .regularExpression) {
                let digits = String(title[match]).filter { !"第季Seasonseason ".contains($0) }
                season = Int(digits) ?? chinese(digits)
                title.removeSubrange(match)
                break
            }
        }
        // Bracketed notes (`[国语]`, `(2024)`, `【4K】`) are the catalog's, not the title's.
        title = title.replacingOccurrences(of: #"[\[【(（][^\]】)）]*[\]】)）]"#, with: " ", options: .regularExpression)
        return (title.split(whereSeparator: \.isWhitespace).joined(separator: " "), season)
    }

    private static func seasonInName(_ name: String) -> Int? {
        guard let match = name.range(of: #"[Ss]([0-9]{1,2})[Ee][0-9]{1,4}"#, options: .regularExpression) else { return nil }
        return Int(name[match].dropFirst().prefix { $0.isNumber })
    }

    private static func chinese(_ text: String) -> Int? {
        let digits: [Character: Int] = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        if text == "十" { return 10 }
        if text.hasPrefix("十"), let last = text.last, let unit = digits[last] { return 10 + unit }
        if text.count == 1, let first = text.first { return digits[first] }
        if text.count >= 2, let first = text.first, let tens = digits[first], text.dropFirst().first == "十" {
            return tens * 10 + (text.count == 3 ? (text.last.flatMap { digits[$0] } ?? 0) : 0)
        }
        return nil
    }
}

/// Subtitle languages as BCP-47 tags the search compares: `zh-Hans`, `zh-Hant`, `en`, `pt-BR`.
public enum SubtitleLanguage {
    public static func normalized(_ identifier: String) -> String {
        let text = identifier.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "-")
        guard !text.isEmpty else { return "" }
        let lower = text.lowercased()
        switch lower {
        case "chs", "sc", "gb", "zh-cn", "zh-sg", "zh-hans", "zho-hans", "chi", "zho", "zh", "简体", "简中", "简": return "zh-Hans"
        case "cht", "tc", "big5", "zh-tw", "zh-hk", "zh-mo", "zh-hant", "zho-hant", "繁体", "繁體", "繁中", "繁": return "zh-Hant"
        case "pt-br", "pob", "pb": return "pt-BR"
        default: break
        }
        if lower.hasPrefix("zh-hans") { return "zh-Hans" }
        if lower.hasPrefix("zh-hant") { return "zh-Hant" }
        let base = lower.split(separator: "-").first.map(String.init) ?? lower
        // Three-letter codes (OpenSubtitles' older ones and many file names) to two.
        let three: [String: String] = ["eng": "en", "jpn": "ja", "kor": "ko", "fre": "fr", "fra": "fr", "ger": "de", "deu": "de", "spa": "es",
                                       "ita": "it", "rus": "ru", "por": "pt", "ara": "ar", "tha": "th", "vie": "vi", "ind": "id", "may": "ms"]
        if let two = three[base] { return two }
        return base.count == 2 ? base : ""
    }

    /// Whether a subtitle in `language` serves a viewer who wants `wanted` (`zh` serves both Chinese scripts).
    static func serves(_ language: String, _ wanted: String) -> Bool {
        guard !language.isEmpty else { return false }
        if language == wanted { return true }
        return language == "zh" && wanted.hasPrefix("zh")
    }
}

/// Why a result ranks where it does, shown beside it.
public enum SubtitleMatchReason: String, Codable, Hashable, Sendable, CaseIterable {
    /// The source matched the video file itself (by its hash).
    case file
    /// It is for this episode.
    case episode
    /// It is in a language the viewer reads.
    case language
    /// Its release name is the video's.
    case release
    /// Many people downloaded it.
    case popular

    public var title: String {
        switch self {
        case .file: L10n.text("Same file")
        case .episode: L10n.text("This episode")
        case .language: L10n.text("Your language")
        case .release: L10n.text("Same release")
        case .popular: L10n.text("Popular")
        }
    }
}

/// One subtitle file a source found.
public struct SubtitleCandidate: Codable, Hashable, Sendable, Identifiable {
    /// The source's manifest id.
    public var provider: String
    public var providerName: String
    /// The source's own id for the file, handed back to `resolve`.
    public var key: String
    /// Its release or file name.
    public var title: String
    /// BCP-47; empty when the source doesn't say.
    public var language: String
    public var format: String?
    /// Only the parts in another language (signs, foreign dialogue).
    public var forced: Bool
    /// Subtitles for the deaf and hard of hearing (sounds described).
    public var hearingImpaired: Bool
    public var season: Int?
    public var episode: Int?
    /// The source matched the video file's hash.
    public var fileMatch: Bool
    public var downloads: Int?
    /// A lasting address of the file, when the source knows one: two sources offering it are one result.
    public var url: URL?
    /// Anything else the source wants back in `resolve`.
    public var token: String?
    /// Set by the search.
    public var score = 0
    public var reasons: [SubtitleMatchReason] = []

    public var id: String { provider + "\n" + key }

    public init(provider: String, providerName: String = "", key: String, title: String, language: String = "", format: String? = nil,
                forced: Bool = false, hearingImpaired: Bool = false, season: Int? = nil, episode: Int? = nil, fileMatch: Bool = false,
                downloads: Int? = nil, url: URL? = nil, token: String? = nil) {
        self.provider = provider; self.providerName = providerName; self.key = key; self.title = title
        self.language = SubtitleLanguage.normalized(language).isEmpty ? language : SubtitleLanguage.normalized(language)
        self.format = format; self.forced = forced; self.hearingImpaired = hearingImpaired; self.season = season; self.episode = episode
        self.fileMatch = fileMatch; self.downloads = downloads; self.url = url; self.token = token
    }
}

/// Where to download a chosen file, from `resolve`: an address (often signed and short-lived) or the text itself.
public struct SubtitleResource: Hashable, Sendable {
    public var url: URL?
    public var headers: [String: String]
    public var text: String?
    public var name: String?
    public var format: String?
    /// When a signed address stops working.
    public var expires: Date?

    public init(url: URL? = nil, headers: [String: String] = [:], text: String? = nil, name: String? = nil, format: String? = nil, expires: Date? = nil) {
        self.url = url; self.headers = headers; self.text = text; self.name = name; self.format = format; self.expires = expires
    }
}

/// How a source call went wrong, in the few kinds the app tells apart.
public enum SubtitleProviderError: Error, Hashable, Sendable, LocalizedError {
    case timeout
    case rateLimited(retryAfter: Int?)
    case noResults
    /// The source needs a key or sign-in the viewer hasn't given.
    case authRequired
    /// What the viewer gave no longer works.
    case authExpired
    case incompatible(String)
    case downloadFailed(String)
    /// The source tried to reach a site outside its manifest.
    case blocked(String)
    case failed(String)

    public var kind: String {
        switch self {
        case .timeout: "timeout"
        case .rateLimited: "rateLimited"
        case .noResults: "noResults"
        case .authRequired: "authRequired"
        case .authExpired: "authExpired"
        case .incompatible: "incompatible"
        case .downloadFailed: "downloadFailed"
        case .blocked: "blocked"
        case .failed: "failed"
        }
    }

    /// A script's `SubtitleError` (`{kind, message, retryAfter}`).
    init(kind: String, message: String, retryAfter: Int?) {
        switch kind {
        case "timeout": self = .timeout
        case "rateLimited": self = .rateLimited(retryAfter: retryAfter)
        case "noResults": self = .noResults
        case "authRequired": self = .authRequired
        case "authExpired": self = .authExpired
        case "incompatible": self = .incompatible(message)
        case "downloadFailed": self = .downloadFailed(message)
        case "blocked": self = .blocked(message)
        default: self = .failed(message)
        }
    }

    public var errorDescription: String? {
        switch self {
        case .timeout: L10n.text("It took too long to answer.")
        case .rateLimited(let seconds):
            seconds.map { L10n.text("Too many searches. Try again in %@ s.", String($0)) } ?? L10n.text("Too many searches. Try again later.")
        case .noResults: L10n.text("No subtitles found.")
        case .authRequired: L10n.text("Add your key for it in Settings › Subtitle Sources.")
        case .authExpired: L10n.text("Your key or sign-in no longer works. Check it in Settings › Subtitle Sources.")
        case .incompatible(let reason): L10n.text("This source doesn't work with this version of Yingxia. %@", reason)
        case .downloadFailed(let reason): L10n.text("The file didn't download. %@", reason)
        case .blocked(let host): L10n.text("The source tried to reach a site it didn't list (%@).", host)
        case .failed(let reason): reason.isEmpty ? L10n.text("The source failed.") : reason
        }
    }
}

/// A subtitle source. Calls are cancellable and end by `seconds` at the latest.
public protocol SubtitleProvider: Sendable {
    var manifest: SubtitleProviderManifest { get }
    func search(_ hint: SubtitleHint, credentials: [String: String], within seconds: Double) async throws -> [SubtitleCandidate]
    func resolve(_ candidate: SubtitleCandidate, credentials: [String: String], within seconds: Double) async throws -> SubtitleResource
}

/// Which account a source's results belong to: another key or user name never sees them.
enum SubtitleAccount {
    static func partition(provider: String, credentials: [String: String]) -> String {
        let identity = ([provider] + credentials.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }).joined(separator: "\n")
        return SHA256.hash(data: Data(identity.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

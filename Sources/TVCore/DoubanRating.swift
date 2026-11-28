import Foundation

/// A title's Douban score. Prefer a Wikidata link and verify a title search against Douban's subject metadata
/// when there is no link.
public enum DoubanRating {
    public struct Match: Codable, Hashable, Sendable {
        public let id: String
        public let title: String
        public let mediaType: TMDBMatch.MediaType
        public let season: Int?
        public let score: Score?
    }

    public struct Score: Codable, Hashable, Sendable {
        public let value: Double
        public let count: Int
        public let season: Int?

        init(value: Double, count: Int, season: Int? = nil) {
            self.value = value
            self.count = count
            self.season = season
        }
    }

    /// Fewer ratings than this say nothing.
    static let fewestRatings = 10
    private static let userAgent = "Yingxia/1 (https://yingxia.getmegaportal.com)"
    private static let choices = "douban.subject-choices"

    /// An ID or a public Douban film/TV subject link. Always build the actual request from the numeric ID.
    public static func subjectID(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let id: String
        if let url = URL(string: value), url.scheme == "https" || url.scheme == "http" {
            let path = url.pathComponents
            switch url.host() {
            case "movie.douban.com" where path.count == 3 && path[1] == "subject": id = path[2]
            case "m.douban.com" where path.count == 4 && ["movie", "tv"].contains(path[1]) && path[2] == "subject": id = path[3]
            default: return nil
            }
        } else {
            id = value
        }
        return !id.isEmpty && id.utf8.count <= 16 && id.utf8.allSatisfy { (48...57).contains($0) }
            && id.first != "0" ? id : nil
    }

    public static func sourceKey(origin: URL, site: Site, videoID: String) -> String {
        let parts = [origin.absoluteString, site.key, site.api, videoID]
        let value = parts.map { "\($0.utf8.count):\($0)" }.joined()
        return PluginChecksum.sha256(Data(value.utf8))
    }

    public static func catalogKey(tmdbID: Int, mediaType: TMDBMatch.MediaType, season: Int?) -> String {
        "catalog-\(mediaType.rawValue)-\(tmdbID)-\(season ?? 0)"
    }

    public static func chosenSubject(for key: String) -> String? {
        UserDefaults.standard.string(forKey: "\(choices).\(key)")
    }

    public static func choose(_ match: Match, for key: String) {
        UserDefaults.standard.set(match.id, forKey: "\(choices).\(key)")
    }

    public static func subject(_ input: String, session: URLSession = .shared) async throws -> Match? {
        guard let id = subjectID(input) else { return nil }
        let key = "subject-\(id)"
        if let match = Cache.read(key)?.match { return match }
        var subject = try await fetchSubject(id: id, mediaType: .movie, session: session)
        if subject == nil { subject = try await fetchSubject(id: id, mediaType: .tv, session: session) }
        guard let match = subject?.match(id: id) else { return nil }
        try Task.checkCancellation()
        Cache.write(key, Entry(score: match.score, date: Date(), lasts: 2 * 86_400, match: match))
        return match
    }

    /// Identify a source's title directly on Douban. Accept an unambiguous candidate with a matching year
    /// or credited person. A known provider ID bypasses text matching.
    public static func sourceMatch(_ video: Video, listVideo: Video, key: String,
                                   session: URLSession = .shared) async throws -> Match? {
        if let id = chosenSubject(for: key) ?? video.doubanID ?? listVideo.doubanID {
            return try await subject(id, session: session)
        }
        let year = (video.year ?? listVideo.year).flatMap(Int.init)
        let credits = Set((video.credits ?? listVideo.credits ?? []).map { titleKey($0.name) })
        guard year != nil || !credits.isEmpty else { return nil }

        let parsed = seasonTitle(video.name)
        let listTitle = seasonTitle(listVideo.name)
        let number = parsed.season ?? listTitle.season
        let categories = [video.category, listVideo.category].compactMap { $0 }.joined(separator: ",")
        let mediaType: TMDBMatch.MediaType?
        if ["电视剧", "電視劇", "综艺", "綜藝", "剧集", "劇集"].contains(where: categories.contains) {
            mediaType = .tv
        } else if categories.contains("电影") || categories.contains("電影") {
            mediaType = .movie
        } else {
            mediaType = number == nil ? nil : .tv
        }
        let season = mediaType == .movie ? nil : number
        let titles = Set((mediaType == .movie ? [video.name, listVideo.name] : [parsed.core, listTitle.core]).map(titleKey))
        let cacheKey = "source-\(key)-\(video.name)-\(year ?? 0)-\(season ?? 0)"
        if let cached = Cache.read(cacheKey) { return cached.match }

        var suggestions = try await suggest(video.name, session: session)
        if suggestions.cards.isEmpty, titleKey(video.name) != titleKey(listVideo.name) {
            suggestions = try await suggest(listVideo.name, session: session)
        }
        let ids = suggestions.cards.filter { year == nil || $0.year == nil || $0.year == year }
            .compactMap(\.subjectID)
        var checked = Set<String>()
        var matches: [(match: Match, creditAgrees: Bool)] = []
        for id in ids where checked.count < 5 && checked.insert(id).inserted {
            try Task.checkCancellation()
            let candidate = try await fetchSubject(id: id, mediaType: mediaType ?? .movie, session: session)
            guard let candidate, let match = candidate.match(id: id), mediaType == nil || candidate.type == mediaType,
                  match.season == season, year == nil || candidate.year == year.map(String.init),
                  candidate.names.contains(where: { titles.contains(titleKey(match.mediaType == .movie ? $0 : seasonTitle($0).core)) }),
                  year != nil || !candidate.creditNames.isDisjoint(with: credits) else { continue }
            matches.append((match, !candidate.creditNames.isDisjoint(with: credits)))
        }
        let candidates = matches.count > 1 ? matches.filter(\.creditAgrees) : matches
        let match = candidates.count == 1 ? candidates.first?.match : nil
        try Task.checkCancellation()
        Cache.write(cacheKey, Entry(score: match?.score, date: Date(), lasts: 86_400, match: match))
        if let match { Cache.write("subject-\(match.id)", Entry(score: match.score, date: Date(), lasts: 2 * 86_400, match: match)) }
        return match
    }

    /// The score this device already has for a title, without asking anyone: what a catalog card shows, so a grid
    /// scrolling past doesn't send Douban a burst of searches (it limits busy addresses, and Discover's Douban
    /// lists come from the same address). A title page asks with `score(...)`, and its card shows it from then on.
    public static func cachedScore(tmdbID: Int, mediaType: TMDBMatch.MediaType) -> Score? {
        if let id = chosenSubject(for: catalogKey(tmdbID: tmdbID, mediaType: mediaType, season: nil)) {
            return Cache.read("subject-\(id)")?.match?.score
        }
        return Cache.read("\(mediaType.rawValue)-\(tmdbID)")?.score
    }

    /// The selected TV season has its own subject and cache entry, independent of the series score.
    public static func seasonScore(tmdbID: Int, name: String, originalName: String, season: Int, year: Int,
                                   session: URLSession = .shared) async -> Score? {
        guard season > 0 else { return nil }
        if let id = chosenSubject(for: catalogKey(tmdbID: tmdbID, mediaType: .tv, season: season)) {
            return (try? await subject(id, session: session))?.score
        }
        let key = "tv-\(tmdbID)-season-\(season)-\(year)"
        if let cached = Cache.read(key)?.score { return cached }
        let missKey = "search-\(key)-\(name)-\(originalName)"
        if Cache.read(missKey) != nil { return nil }
        do {
            let match = try await searchMatch(name: name, originalName: originalName, year: year, mediaType: .tv,
                                              season: season, session: session)
            let score = match?.score
            try Task.checkCancellation()
            Cache.write(score == nil ? missKey : key,
                        Entry(score: score, date: Date(), lasts: (score == nil ? 1 : 2) * 86_400, match: match))
            return score
        } catch {
            return nil
        }
    }

    public static func score(tmdbID: Int, mediaType: TMDBMatch.MediaType, name: String = "", originalName: String = "",
                             year: Int? = nil, session: URLSession = .shared) async -> Score? {
        if let id = chosenSubject(for: catalogKey(tmdbID: tmdbID, mediaType: mediaType, season: nil)) {
            return (try? await subject(id, session: session))?.score
        }
        let key = "\(mediaType.rawValue)-\(tmdbID)"
        if let cached = Cache.read(key)?.score { return cached }
        let missKey = "search-\(key)-\(year ?? 0)-\(name)-\(originalName)"
        if Cache.read(missKey) != nil { return nil }

        var mappingFailed = false
        do {
            if let id = try await doubanID(tmdbID: tmdbID, mediaType: mediaType, session: session),
               let subject = try await fetchSubject(id: id, mediaType: mediaType, session: session),
               let score = subject.score {
                Cache.write(key, Entry(score: score, date: Date(), lasts: 2 * 86_400, match: subject.match(id: id)))
                return score
            }
        } catch {
            mappingFailed = true
        }
        guard !Task.isCancelled else { return nil }
        do {
            let details = year == nil || name.isEmpty
                ? try await TMDBMatch.details(mediaType, id: tmdbID, season: nil, session: session) : nil
            guard let year = year ?? details?.year else { return nil }
            let match = try await searchMatch(name: details?.name ?? name, originalName: details?.originalName ?? originalName, year: year,
                                              mediaType: mediaType, session: session)
            let score = match?.score
            if let score {
                Cache.write(key, Entry(score: score, date: Date(), lasts: 2 * 86_400, match: match))
            } else if !mappingFailed {
                Cache.write(missKey, Entry(score: nil, date: Date(), lasts: 86_400))
            }
            return score
        } catch {
            return nil
        }
    }

    static func doubanID(tmdbID: Int, mediaType: TMDBMatch.MediaType, session: URLSession) async throws -> String? {
        let property = mediaType == .movie ? "P4947" : "P4983"
        let query = "SELECT ?d WHERE { ?s wdt:\(property) \"\(tmdbID)\"; wdt:P4529 ?d } LIMIT 1"
        var parts = URLComponents(string: "https://query.wikidata.org/sparql")!
        parts.queryItems = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "format", value: "json")]
        var request = URLRequest(url: parts.url!, timeoutInterval: 15)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/sparql-results+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw TVError.http((response as? HTTPURLResponse)?.statusCode ?? 0) }
        return parseID(data)
    }

    static func parseID(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = (root["results"] as? [String: Any])?["bindings"] as? [[String: Any]],
              let value = (rows.first?["d"] as? [String: Any])?["value"] as? String,
              !value.isEmpty, value.allSatisfy(\.isNumber) else { return nil }
        return value
    }

    struct Subject: Decodable {
        struct Person: Decodable { let name: String? }
        struct Rating: Decodable {
            let value: Double?
            let count: Int?
        }

        let title: String?
        let original_title: String?
        let aka: [String]?
        let year: String?
        let type: TMDBMatch.MediaType?
        let rating: Rating?
        let directors: [Person]?
        let actors: [Person]?

        var names: [String] { [title, original_title].compactMap { $0 } + (aka ?? []) }
        var creditNames: Set<String> {
            Set(((directors ?? []) + (actors ?? [])).compactMap(\.name).map(DoubanRating.titleKey))
        }

        func match(id: String) -> Match? {
            guard let title, !title.isEmpty, let type else { return nil }
            let season = type == .tv ? [title, original_title].compactMap { $0 }
                .compactMap { DoubanRating.seasonTitle($0).season }.first : nil
            return Match(id: id, title: title, mediaType: type, season: season,
                         score: score.map { Score(value: $0.value, count: $0.count, season: season) })
        }

        var firstSeason: Bool {
            [title, original_title].compactMap { $0 }.contains { DoubanRating.firstSeasonBase($0) != nil }
        }

        var score: Score? {
            guard let value = rating?.value, let count = rating?.count,
                  (0...10).contains(value), value > 0, count >= fewestRatings else { return nil }
            return Score(value: value, count: count, season: type == .tv && firstSeason ? 1 : nil)
        }

        func matches(titles: Set<String>, year: Int, mediaType: TMDBMatch.MediaType) -> Bool {
            guard self.year == String(year), type == mediaType else { return false }
            let names = [title, original_title].compactMap { $0 }
            if mediaType == .tv && names.contains(where: DoubanRating.isLaterSeason) { return false }
            let bases = mediaType == .tv ? names.compactMap(DoubanRating.firstSeasonBase) : []
            return (names + (aka ?? []) + bases).contains { titles.contains(DoubanRating.titleKey($0)) }
        }

        func matchesSeason(_ season: Int, titles: Set<String>, year: Int) -> Bool {
            guard type == .tv, self.year == String(year) else { return false }
            let names = [title, original_title].compactMap { $0 }
            return names.contains { name in
                let parsed = DoubanRating.seasonTitle(name)
                return parsed.season == season && titles.contains(DoubanRating.titleKey(parsed.core))
            }
        }
    }

    private struct Suggestions: Decodable {
        struct Card: Decodable {
            let type: String
            let url: String?
            let card_subtitle: String?

            var subjectID: String? {
                guard type == "movie", let url else { return nil }
                return DoubanRating.subjectID(url)
            }

            var year: Int? {
                card_subtitle?.components(separatedBy: " / ").dropFirst().first.flatMap(Int.init)
            }
        }

        let cards: [Card]
    }

    static func titleKey(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func seasonTitle(_ title: String) -> (core: String, season: Int?) {
        SeasonTitles.parse(title.folding(options: .widthInsensitive, locale: nil)
            .replacingOccurrences(of: "兩", with: "两"))
    }

    private static func suggest(_ query: String, session: URLSession) async throws -> Suggestions {
        var url = URLComponents(string: "https://www.douban.com/j/search_suggest")!
        url.queryItems = [URLQueryItem(name: "q", value: query)]
        var request = URLRequest(url: url.url!, timeoutInterval: 8)
        request.setValue("https://www.douban.com/", forHTTPHeaderField: "Referer")
        let (data, status) = try await doubanData(request, session: session)
        guard status == 200 else { throw TVError.http(status) }
        return try JSONDecoder().decode(Suggestions.self, from: data)
    }

    private static func firstSeasonBase(_ title: String) -> String? {
        guard let suffix = title.range(of: #"(?i)(?:\s*第\s*[一1１]\s*季|\s+season\s+1)\s*$"#, options: .regularExpression),
              suffix.lowerBound > title.startIndex else { return nil }
        return String(title[..<suffix.lowerBound])
    }

    private static func isLaterSeason(_ title: String) -> Bool {
        firstSeasonBase(title) == nil &&
            title.range(of: #"(?i)(?:第\s*[一二三四五六七八九十百零〇两兩0-9０-９]+\s*季|\s+season\s+\d+)\s*$"#,
                        options: .regularExpression) != nil
    }

    private static func searchMatch(name: String, originalName: String, year: Int, mediaType: TMDBMatch.MediaType,
                                    season: Int? = nil, session: URLSession) async throws -> Match? {
        var names = [name, originalName].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if season != nil { names = names.map { SeasonTitles.parse($0).core }.filter { !$0.isEmpty } }
        let titles = Set(names.map(titleKey))
        let queries = season.map { number in
            names.map { name in
                name.range(of: #"\p{Han}"#, options: .regularExpression) != nil
                    ? "\(name) 第\(SeasonTitles.chinese(number) ?? String(number))季"
                    : "\(name) Season \(number)"
            } + names
        } ?? names
        var searched: Set<String> = []
        var checked: Set<String> = []
        var firstSeasons: [Match] = []
        for query in queries where !query.isEmpty && searched.insert(titleKey(query)).inserted {
            try Task.checkCancellation()
            let suggestions = try await suggest(query, session: session)
            var works: [Match] = []
            let candidates = suggestions.cards.filter { $0.year == nil || $0.year == year }
            for id in candidates.compactMap(\.subjectID).prefix(5) where checked.insert(id).inserted {
                try Task.checkCancellation()
                guard let subject = try await fetchSubject(id: id, mediaType: mediaType, session: session),
                      let match = subject.match(id: id) else { continue }
                if let season {
                    if subject.matchesSeason(season, titles: titles, year: year), match.season == season { works.append(match) }
                    continue
                }
                guard subject.matches(titles: titles, year: year, mediaType: mediaType) else { continue }
                if mediaType == .tv && subject.firstSeason {
                    firstSeasons.append(match)
                } else {
                    works.append(match)
                }
            }
            if !works.isEmpty { return works.count == 1 ? works.first : nil }
        }
        return firstSeasons.count == 1 ? firstSeasons.first : nil
    }

    static func fetchSubject(id: String, mediaType: TMDBMatch.MediaType, session: URLSession) async throws -> Subject? {
        let path = mediaType == .movie ? "movie" : "tv"
        var request = URLRequest(url: URL(string: "https://m.douban.com/rexxar/api/v2/\(path)/\(id)")!, timeoutInterval: 8)
        request.setValue(DoubanCatalog.referer, forHTTPHeaderField: "Referer")
        let (data, status) = try await doubanData(request, session: session)
        if status == 404 { return nil }
        guard status == 200 else { throw TVError.http(status) }
        return try JSONDecoder().decode(Subject.self, from: data)
    }

    private static func doubanData(_ request: URLRequest, session: URLSession) async throws -> (Data, Int) {
        var request = request
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func parseScore(_ data: Data) -> Score? {
        (try? JSONDecoder().decode(Subject.self, from: data))?.score
    }

    // MARK: Cache

    struct Entry: Codable {
        let score: Score?
        let date: Date
        let lasts: TimeInterval
        var match: Match? = nil
    }

    /// Scores and completed lookup misses are kept briefly to limit requests to Douban.
    enum Cache {
        private static let defaultsKey = "douban.ratings"
        private static let lock = NSLock()
        /// Decoded once: every card on screen reads the cache. Only touched under `lock`.
        nonisolated(unsafe) private static var memo: [String: Entry]?

        static func read(_ key: String) -> Entry? {
            lock.withLock {
                guard let entry = load()[key], entry.date.addingTimeInterval(entry.lasts) > Date() else { return nil }
                return entry
            }
        }

        static func write(_ key: String, _ entry: Entry) {
            lock.withLock {
                var all = load().filter { $0.value.date.addingTimeInterval($0.value.lasts) > Date() }
                all[key] = entry
                if all.count > 300 { all = Dictionary(uniqueKeysWithValues: all.sorted { $0.value.date > $1.value.date }.prefix(300).map { ($0.key, $0.value) }) }
                memo = all
                if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: defaultsKey) }
            }
        }

        private static func load() -> [String: Entry] {
            if let memo { return memo }
            let all = UserDefaults.standard.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
            memo = all
            return all
        }
    }
}

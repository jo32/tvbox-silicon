import Foundation

/// A title's Douban score. Prefer a Wikidata link and verify a title search against Douban's subject metadata
/// when there is no link.
public enum DoubanRating {
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

    public static func score(tmdbID: Int, mediaType: TMDBMatch.MediaType, name: String = "", originalName: String = "",
                             year: Int? = nil, session: URLSession = .shared) async -> Score? {
        let key = "\(mediaType.rawValue)-\(tmdbID)"
        if let cached = Cache.read(key)?.score { return cached }
        let missKey = "search-\(key)-\(year ?? 0)-\(name)-\(originalName)"
        if Cache.read(missKey) != nil { return nil }

        var mappingFailed = false
        do {
            if let id = try await doubanID(tmdbID: tmdbID, mediaType: mediaType, session: session),
               let score = try await fetchSubject(id: id, mediaType: mediaType, session: session)?.score {
                Cache.write(key, Entry(score: score, date: Date(), lasts: 2 * 86_400))
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
            let score = try await searchScore(name: details?.name ?? name, originalName: details?.originalName ?? originalName, year: year,
                                              mediaType: mediaType, session: session)
            if let score {
                Cache.write(key, Entry(score: score, date: Date(), lasts: 2 * 86_400))
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
    }

    private struct Suggestions: Decodable {
        struct Card: Decodable {
            let type: String
            let url: String?
            let card_subtitle: String?

            var subjectID: String? {
                guard type == "movie", let url = url.flatMap({ URL(string: $0) }),
                      url.scheme == "https", url.host == "movie.douban.com",
                      url.pathComponents.count == 3, url.pathComponents[1] == "subject",
                      url.lastPathComponent.allSatisfy(\.isNumber) else { return nil }
                return url.lastPathComponent
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

    private static func searchScore(name: String, originalName: String, year: Int, mediaType: TMDBMatch.MediaType,
                                    session: URLSession) async throws -> Score? {
        let queries = [name, originalName].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let titles = Set(queries.map(titleKey).filter { !$0.isEmpty })
        var searched: Set<String> = []
        var checked: Set<String> = []
        var firstSeasons: [Subject] = []
        for query in queries where !query.isEmpty && searched.insert(titleKey(query)).inserted {
            try Task.checkCancellation()
            var url = URLComponents(string: "https://www.douban.com/j/search_suggest")!
            url.queryItems = [URLQueryItem(name: "q", value: query)]
            var request = URLRequest(url: url.url!, timeoutInterval: 8)
            request.setValue("https://www.douban.com/", forHTTPHeaderField: "Referer")
            let (data, status) = try await doubanData(request, session: session)
            guard status == 200 else { throw TVError.http(status) }
            let suggestions = try JSONDecoder().decode(Suggestions.self, from: data)
            var works: [Subject] = []
            let candidates = suggestions.cards.filter { $0.year == nil || $0.year == year }
            for id in candidates.compactMap(\.subjectID).prefix(5) where checked.insert(id).inserted {
                try Task.checkCancellation()
                guard let subject = try await fetchSubject(id: id, mediaType: mediaType, session: session),
                      subject.matches(titles: titles, year: year, mediaType: mediaType) else { continue }
                if mediaType == .tv && subject.firstSeason {
                    firstSeasons.append(subject)
                } else {
                    works.append(subject)
                }
            }
            if !works.isEmpty { return works.count == 1 ? works.first?.score : nil }
        }
        return firstSeasons.count == 1 ? firstSeasons.first?.score : nil
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
    }

    /// Scores and completed lookup misses are kept briefly to limit requests to Douban.
    enum Cache {
        private static let defaultsKey = "douban.ratings"
        private static let lock = NSLock()

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
                if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: defaultsKey) }
            }
        }

        private static func load() -> [String: Entry] {
            guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [:] }
            return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
        }
    }
}

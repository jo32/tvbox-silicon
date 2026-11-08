import Foundation

/// A title's Douban score (#505), for the TMDB match a page already has. Douban has no public search that
/// answers without a login, so the id comes from Wikidata, which stores TMDB's id and Douban's side by side
/// (P4947 for films, P4983 for series, P4529 for Douban). Many titles have no entry; then there's no score.
/// The score is read from the API Douban's mobile site uses, with its Referer, on the device.
public enum DoubanRating {
    public struct Score: Codable, Hashable, Sendable {
        public let value: Double
        public let count: Int
    }

    /// Fewer ratings than this say nothing.
    static let fewestRatings = 10
    private static let userAgent = "Yingxia/1 (https://yingxia.getmegaportal.com)"

    /// The score for a TMDB title, from the cache or the network; nil when Douban doesn't know it.
    public static func score(tmdbID: Int, mediaType: TMDBMatch.MediaType, session: URLSession = .shared) async -> Score? {
        let key = "\(mediaType.rawValue)-\(tmdbID)"
        if let cached = Cache.read(key) { return cached.score }
        do {
            guard let id = try await doubanID(tmdbID: tmdbID, mediaType: mediaType, session: session) else {
                Cache.write(key, Entry(score: nil, date: Date(), lasts: 7 * 86_400))
                return nil
            }
            let score = try await fetchScore(id: id, mediaType: mediaType, session: session)
            Cache.write(key, Entry(score: score, date: Date(), lasts: score == nil ? 86_400 : 2 * 86_400))
            return score
        } catch {
            return nil   // offline, or Douban is limiting this address: ask again next time
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

    static func fetchScore(id: String, mediaType: TMDBMatch.MediaType, session: URLSession) async throws -> Score? {
        let path = mediaType == .movie ? "movie" : "tv"
        var request = URLRequest(url: URL(string: "https://m.douban.com/rexxar/api/v2/\(path)/\(id)")!, timeoutInterval: 15)
        request.setValue(DoubanCatalog.referer, forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status == 200 else { throw TVError.http(status) }
        return parseScore(data)
    }

    static func parseScore(_ data: Data) -> Score? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rating = root["rating"] as? [String: Any],
              let value = (rating["value"] as? NSNumber)?.doubleValue, value > 0,
              let count = (rating["count"] as? NSNumber)?.intValue, count >= fewestRatings else { return nil }
        return Score(value: value, count: count)
    }

    // MARK: Cache

    struct Entry: Codable {
        let score: Score?
        let date: Date
        let lasts: TimeInterval
    }

    /// Scores move slowly and Douban limits busy addresses: kept on the device for a day or two. A title with no
    /// Douban entry is remembered longer, so a page doesn't ask Wikidata again each time.
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

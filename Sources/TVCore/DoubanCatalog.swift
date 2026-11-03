import Foundation

/// Douban's hot lists, read from the API its mobile site uses (`m.douban.com/rexxar`). It answers only with a
/// Douban Referer, and so do its covers (img*.doubanio.com sends HTTP 418 without one; `PosterResource` adds it).
public enum DoubanCatalog {
    public static let referer = "https://m.douban.com/movie/"

    public enum Feed: String, CaseIterable, Codable, Sendable {
        case movies = "movie_hot_gaia", television = "tv_hot", variety = "show_hot"
    }

    public struct Item: Hashable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let year: Int?
        /// Douban's score out of 10; nil while a title has too few ratings.
        public let rating: Double?
        public let cover: URL?
        public let mediaType: TMDBMatch.MediaType
        /// "2026 / 中国大陆 / 剧情 / <director> / <cast>"
        public let subtitle: String
        public init(id: String, title: String, year: Int?, rating: Double?, cover: URL?, mediaType: TMDBMatch.MediaType, subtitle: String = "") {
            self.id = id; self.title = title; self.year = year; self.rating = rating; self.cover = cover
            self.mediaType = mediaType; self.subtitle = subtitle
        }
    }

    /// `start` pages through the list: the first title to return, counting from 0.
    public static func items(_ feed: Feed, start: Int = 0, count: Int = 30, session: URLSession = .shared) async throws -> [Item] {
        var parts = URLComponents(string: "https://m.douban.com/rexxar/api/v2/subject_collection/\(feed.rawValue)/items")!
        parts.queryItems = [URLQueryItem(name: "start", value: String(start)), URLQueryItem(name: "count", value: String(count))]
        var request = URLRequest(url: parts.url!, timeoutInterval: 20)
        request.setValue(referer, forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw TVError.http(status) }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> [Item] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["subject_collection_items"] as? [[String: Any]] else { throw TVError.invalidConfiguration }
        var seen = Set<String>()
        return rows.compactMap { row -> Item? in
            // Lists can carry other kinds of rows (ads, books); only films and series open a title.
            guard let id = (row["id"] as? String) ?? (row["id"] as? NSNumber)?.stringValue, seen.insert(id).inserted,
                  let title = (row["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
                  let kind = row["type"] as? String, kind == "movie" || kind == "tv" else { return nil }
            // Series and variety lists give `pic`, the film list `cover`.
            let pic = row["pic"] as? [String: Any], cover = row["cover"] as? [String: Any]
            let address = (pic?["large"] as? String) ?? (pic?["normal"] as? String) ?? (cover?["url"] as? String)
            let score = ((row["rating"] as? [String: Any])?["value"] as? NSNumber)?.doubleValue
            let year = (row["year"] as? String).flatMap { Int($0) } ?? (row["year"] as? NSNumber)?.intValue
            return Item(id: id, title: title, year: year, rating: score.flatMap { $0 > 0 ? $0 : nil },
                        cover: address.flatMap { URL(string: $0) }, mediaType: kind == "movie" ? .movie : .tv,
                        subtitle: row["card_subtitle"] as? String ?? "")
        }
    }

    /// Douban names each season as its own title ("现在就出发 第四季", and for some shows the year: "我家那闺女2026");
    /// TMDB has one series with seasons. A film keeps its name ("银翼杀手2049").
    public static func searchTitle(_ item: Item) -> String {
        let title = item.title
        var pattern = #"\s*第[一二三四五六七八九十百零〇\d]+季$"#
        if item.mediaType == .tv { pattern = #"(\s*第[一二三四五六七八九十百零〇\d]+季|(?<=\D)\s*(19|20)\d\d)$"# }
        guard let range = title.range(of: pattern, options: .regularExpression), range.lowerBound > title.startIndex else { return title }
        return String(title[..<range.lowerBound])
    }

    /// The TMDB title for a Douban one: the same kind, then the same name, with a year at most one apart. A later
    /// season of a series keeps the series' first year on TMDB, so its year isn't compared. nil rather than a guess.
    public static func match(_ item: Item, in results: [TMDBMatch.SearchResult]) -> TMDBMatch.SearchResult? {
        let name = searchTitle(item)
        let season = name != item.title
        let key = CatalogDanmakuMatcher.normalized(name)
        let kind = results.filter { $0.mediaType == item.mediaType }
        func yearFits(_ result: TMDBMatch.SearchResult) -> Bool {
            guard !season, let year = item.year, let other = result.year else { return true }
            return abs(year - other) <= 1
        }
        let named = kind.filter { CatalogDanmakuMatcher.normalized($0.name) == key || $0.originalName.map(CatalogDanmakuMatcher.normalized) == key }
        if let exact = named.first(where: yearFits) { return exact }
        // Douban and TMDB often spell a title differently (punctuation, a subtitle): the best result of that kind
        // and year is still the work, when Douban gave a year to check it by.
        guard !season, item.year != nil else { return nil }
        return kind.first { $0.year != nil && yearFits($0) }
    }
}

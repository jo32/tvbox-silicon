import Foundation

/// TMDB catalogs served by the same credential-holding Worker as title matching.
public enum TMDBCatalog {
    public enum Feed: String, Codable, CaseIterable, Sendable {
        case trending, movies, television, onTheAir, nowPlaying, upcoming, topMovies, topTelevision, animation, chinese, korean, variety
        case family, kids, netflix, disney, appleTV, hbo, warner, universal, paramount, sony
    }

    public struct Item: Codable, Hashable, Sendable, Identifiable {
        public let id: Int
        public let mediaType: TMDBMatch.MediaType
        public let name: String
        public let originalName: String
        public let year: Int?
        public let overview: String
        public let poster: URL?
        public let backdrop: URL?
        public let rating: Double?
        public let genreIDs: [Int]
        public var key: String { "\(mediaType.rawValue):\(id)" }

        public init(id: Int, mediaType: TMDBMatch.MediaType, name: String, originalName: String, year: Int?, overview: String,
                    poster: URL?, backdrop: URL?, rating: Double?, genreIDs: [Int]) {
            self.id = id; self.mediaType = mediaType; self.name = name; self.originalName = originalName
            self.year = year; self.overview = overview; self.poster = poster; self.backdrop = backdrop
            self.rating = rating; self.genreIDs = genreIDs
        }
    }

    public struct Page: Codable, Sendable {
        public let items: [Item]
        public let page: Int
        public let totalPages: Int
    }

    public struct Person: Codable, Sendable, Identifiable {
        public let id: Int
        public let name: String
        public let profile: URL?
        public let works: [Item]
    }

    public struct Brand: Codable, Sendable, Identifiable {
        public let feed: Feed
        public let name: String
        public let logo: URL?
        public var id: Feed { feed }
    }

    public struct Collections: Codable, Sendable {
        public let people: [Person]
        public let networks: [Brand]
        public let companies: [Brand]
    }

    public static func collections(language: String = TMDBMatch.language, session: URLSession = .shared) async throws -> Collections {
        var parts = URLComponents(url: TMDBMatch.base.appending(path: "catalog/collections"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "language", value: language)]
        let (data, response) = try await session.data(from: parts.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Collections.self, from: data)
    }

    public static func page(_ feed: Feed, page: Int = 1, language: String = TMDBMatch.language, session: URLSession = .shared) async throws -> Page {
        var parts = URLComponents(url: TMDBMatch.base.appending(path: "catalog"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "feed", value: feed.rawValue), URLQueryItem(name: "page", value: String(page)),
                            URLQueryItem(name: "language", value: language)]
        var request = URLRequest(url: parts.url!, timeoutInterval: 30)
        request.cachePolicy = .useProtocolCachePolicy
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw TMDBMatch.Failure(code: "http", message: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return try JSONDecoder().decode(Page.self, from: data)
    }
}

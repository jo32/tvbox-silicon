import Foundation

extension TMDBCatalog {
    public enum SearchKind: String, Codable, CaseIterable, Sendable { case movie, tv, person }
    public enum SearchFeed: String, Codable, CaseIterable, Sendable { case day, week, popular }
    public struct SearchPerson: Codable, Hashable, Sendable, Identifiable {
        public let id: Int
        public let name: String
        public let profile: URL?
        public let department: String?
        public let works: [Item]
    }
    public struct Keyword: Codable, Hashable, Sendable, Identifiable {
        public let id: Int
        public let name: String
    }
    public struct SearchPage: Codable, Sendable {
        public let items: [Item]
        public let people: [SearchPerson]
        public let keywords: [Keyword]
        public let page: Int
        public let totalPages: Int
    }
    public struct Filter: Codable, Hashable, Sendable {
        public var kind: SearchKind = .movie
        public var genres: Set<Int> = []
        public var sort = "popularity.desc"
        public var from = ""
        public var to = ""
        public var originalLanguage = ""
        public var region = ""
        public var company = ""
        public var rating = 0
        public var votes = 0
        public var minRuntime = ""
        public var maxRuntime = ""
        public var keywords: [Keyword] = []
        public init() {}
        public var parameters: [String: String] {
            ["genres": genres.sorted().map(String.init).joined(separator: ","), "sort": sort, "from": from, "to": to,
             "originalLanguage": originalLanguage, "region": region, kind == .tv ? "networks" : "companies": company,
             "rating": String(rating), "votes": String(votes), "minRuntime": minRuntime, "maxRuntime": maxRuntime,
             "keywords": keywords.map { String($0.id) }.joined(separator: ",")]
        }
        public var isValid: Bool {
            func number(_ text: String, _ range: ClosedRange<Int>) -> Bool {
                text.isEmpty || (text.allSatisfy(\.isASCII) && text.allSatisfy(\.isNumber) && Int(text).map(range.contains) == true)
            }
            return number(from, 1870...2100) && number(to, 1870...2100)
                && number(minRuntime, 0...600) && number(maxRuntime, 0...600)
                && (from.isEmpty || to.isEmpty || Int(from)! <= Int(to)!)
                && (minRuntime.isEmpty || maxRuntime.isEmpty || Int(minRuntime)! <= Int(maxRuntime)!)
        }
    }

    public static func search(query: String = "", kind: SearchKind = .movie, page: Int = 1, feed: SearchFeed = .week,
                              filter: Filter? = nil, personID: Int? = nil, keywords: Bool = false,
                              language: String = TMDBMatch.language, session: URLSession = .shared) async throws -> SearchPage {
        var parts = URLComponents(url: TMDBMatch.base.appending(path: "catalog/search"), resolvingAgainstBaseURL: false)!
        let mode = personID != nil ? "person" : keywords ? "keywords" : filter != nil ? "discover" : query.isEmpty ? "recommend" : "search"
        var params = filter?.parameters ?? [:]
        params.merge(["mode": mode, "kind": (filter?.kind ?? kind).rawValue, "q": query, "page": String(page),
                      "feed": feed.rawValue, "language": language]) { _, new in new }
        if let personID { params["id"] = String(personID) }
        parts.queryItems = params.filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let (data, response) = try await session.data(for: URLRequest(url: parts.url!, timeoutInterval: 30))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw TMDBMatch.Failure(code: "http", message: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return try JSONDecoder().decode(SearchPage.self, from: data)
    }
}

extension TMDBCatalog {
    public struct PersonWork: Codable, Hashable, Sendable, Identifiable {
        public let item: Item
        public let date: String?
        public let roles: [String]
        public let departments: [String]
        public var id: String { item.key }
    }
    public struct PersonProfile: Codable, Sendable {
        public let id: Int
        public let name: String
        public let profile: URL?
        public let biography: String
        public let birthday: String?
        public let birthplace: String
        public let department: String
        public let instagram: String?
        public let works: [PersonWork]
    }
    public static func person(_ id: Int, language: String = TMDBMatch.language, session: URLSession = .shared) async throws -> PersonProfile {
        var parts = URLComponents(url: TMDBMatch.base.appending(path: "catalog/search"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "mode", value: "profile"), URLQueryItem(name: "id", value: String(id)), URLQueryItem(name: "language", value: language)]
        let (data, response) = try await session.data(for: URLRequest(url: parts.url!, timeoutInterval: 30))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(PersonProfile.self, from: data)
    }
}

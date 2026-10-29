import Foundation

/// Someone whose commits reached the app's main branch, as Settings lists them: most commits first.
public struct Contributor: Codable, Sendable, Equatable, Identifiable {
    public var login: String
    public var avatar: URL?
    public var profile: URL?
    public var commits: Int
    public var id: String { login }
    public init(login: String, avatar: URL? = nil, profile: URL? = nil, commits: Int) {
        self.login = login; self.avatar = avatar; self.profile = profile; self.commits = commits
    }

    /// The avatar at `points` on a 3x screen; GitHub's avatar addresses take a pixel size.
    public func avatar(points: Int) -> URL? {
        guard let avatar, var parts = URLComponents(url: avatar, resolvingAgainstBaseURL: false) else { return avatar }
        parts.queryItems = (parts.queryItems ?? []).filter { $0.name != "s" } + [URLQueryItem(name: "s", value: String(points * 3))]
        return parts.url ?? avatar
    }
}

/// The app's contributors over the last 30 days. The error-reports Worker (Services/error-reports) reads and
/// ranks GitHub's commits once an hour: asked directly, GitHub allows 60 requests an hour per IP address without a
/// token, shared by everyone on that network.
public struct Contributors: Decodable, Sendable, Equatable {
    public static let address = URL(string: "https://yingxia-reports.getmegaportal.com/v1/contributors")!
    public var days: Int
    public var contributors: [Contributor]

    public static func fetch(_ url: URL = address, session: URLSession = .shared) async throws -> Contributors {
        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 20))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw TVError.http(http.statusCode) }
        return try JSONDecoder().decode(Contributors.self, from: data)
    }
}

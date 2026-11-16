import Foundation
import Observation

/// A TMDB series the viewer follows (追剧, #1186): enough to list it and open its Discover page without asking TMDB.
public struct FollowedShow: Codable, Hashable, Sendable, Identifiable {
    public let id: Int
    public var name: String
    public var originalName: String
    public var year: Int?
    public var overview: String
    public var poster: URL?
    public var backdrop: URL?
    public var key: String { "tv:\(id)" }

    public init(id: Int, name: String, originalName: String = "", year: Int? = nil, overview: String = "", poster: URL? = nil, backdrop: URL? = nil) {
        self.id = id; self.name = name; self.originalName = originalName; self.year = year
        self.overview = overview; self.poster = poster; self.backdrop = backdrop
    }

    public init(item: TMDBCatalog.Item) {
        self.init(id: item.id, name: item.name, originalName: item.originalName, year: item.year, overview: item.overview,
                  poster: item.poster, backdrop: item.backdrop)
    }

    /// The Discover page's item for it.
    public var catalogItem: TMDBCatalog.Item {
        TMDBCatalog.Item(id: id, mediaType: .tv, name: name, originalName: originalName, year: year, overview: overview,
                         poster: poster, backdrop: backdrop, rating: nil, genreIDs: [])
    }
}

/// The series the viewer follows, newest first, kept in user defaults and synced through iCloud like favorites.
@MainActor @Observable public final class FollowedShows {
    public private(set) var shows: [FollowedShow] = []
    private let defaults: UserDefaults
    static let storageKey = "followedShows"
    /// Called after the viewer changes the list (not after `adopt`), for iCloud sync.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey), let saved = try? JSONDecoder().decode([FollowedShow].self, from: data) {
            var seen = Set<Int>()
            shows = saved.filter { seen.insert($0.id).inserted }
        }
    }

    public func contains(_ id: Int) -> Bool { shows.contains { $0.id == id } }

    /// Follows a series once: following it again keeps its place and only refreshes its name and artwork.
    public func follow(_ item: TMDBCatalog.Item) {
        guard item.mediaType == .tv else { return }
        let show = FollowedShow(item: item)
        if let index = shows.firstIndex(where: { $0.id == item.id }) {
            guard shows[index] != show else { return }
            shows[index] = show
        } else {
            shows.insert(show, at: 0)
        }
        persist()
        onChange?()
    }

    public func unfollow(_ id: Int) {
        guard let index = shows.firstIndex(where: { $0.id == id }) else { return }
        shows.remove(at: index)
        persist()
        onChange?()
    }

    public func toggle(_ item: TMDBCatalog.Item) {
        if contains(item.id) { unfollow(item.id) } else { follow(item) }
    }

    /// Every show by its key, as iCloud sync compares them.
    public var syncValues: [String: FollowedShow] { Dictionary(shows.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first }) }

    /// The list merged with other devices': the newest change first; shows changed at the same moment keep this device's order.
    public func adopt(_ synced: [CloudSyncItem<FollowedShow>]) {
        let rank = Dictionary(shows.enumerated().map { ($0.element.key, $0.offset) }, uniquingKeysWith: min)
        var seen = Set<Int>()
        shows = synced.sorted { lhs, rhs in
            if lhs.stamp != rhs.stamp { return lhs.stamp > rhs.stamp }
            return (rank[lhs.id] ?? Int.max, lhs.id) < (rank[rhs.id] ?? Int.max, rhs.id)
        }.map(\.value).filter { seen.insert($0.id).inserted }
        persist()
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(shows), forKey: Self.storageKey)
    }
}

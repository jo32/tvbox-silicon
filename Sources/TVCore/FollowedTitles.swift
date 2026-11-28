import Foundation
import Observation

/// A TMDB movie the viewer favorited from Discover (#2782): enough to list it and open its Discover page without
/// asking TMDB, and the title itself rather than one source's copy of it.
public struct FollowedTitle: Codable, Hashable, Sendable, Identifiable {
    public let id: Int
    public var name: String
    public var originalName: String
    public var year: Int?
    public var overview: String
    public var poster: URL?
    public var backdrop: URL?
    public var key: String { "movie:\(id)" }

    public init(id: Int, name: String, originalName: String = "", year: Int? = nil, overview: String = "", poster: URL? = nil, backdrop: URL? = nil) {
        self.id = id; self.name = name; self.originalName = originalName; self.year = year
        self.overview = overview; self.poster = poster; self.backdrop = backdrop
    }

    /// Fails for a series: `FollowedShows` keeps those, and its keys must not meet this list's.
    public init?(item: TMDBCatalog.Item) {
        guard item.mediaType == .movie else { return nil }
        self.init(id: item.id, name: item.name, originalName: item.originalName, year: item.year, overview: item.overview,
                  poster: item.poster, backdrop: item.backdrop)
    }

    /// The Discover page's item for it.
    public var catalogItem: TMDBCatalog.Item {
        TMDBCatalog.Item(id: id, mediaType: .movie, name: name, originalName: originalName, year: year, overview: overview,
                         poster: poster, backdrop: backdrop, rating: nil, genreIDs: [])
    }
}

/// The movies the viewer favorited, newest first, kept in user defaults and synced through iCloud like followed shows.
@MainActor @Observable public final class FollowedTitles {
    public private(set) var titles: [FollowedTitle] = []
    private let defaults: UserDefaults
    static let storageKey = "followedTitles"
    /// Called after the viewer changes the list (not after `adopt`), for iCloud sync.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey), let saved = try? JSONDecoder().decode([FollowedTitle].self, from: data) {
            var seen = Set<Int>()
            titles = saved.filter { seen.insert($0.id).inserted }
        }
    }

    public func contains(_ id: Int) -> Bool { titles.contains { $0.id == id } }

    /// Favorites a movie once: favoriting it again keeps its place and only refreshes its name and artwork.
    public func favorite(_ item: TMDBCatalog.Item) {
        guard let title = FollowedTitle(item: item) else { return }
        if let index = titles.firstIndex(where: { $0.id == item.id }) {
            guard titles[index] != title else { return }
            titles[index] = title
        } else {
            titles.insert(title, at: 0)
        }
        persist()
        onChange?()
    }

    public func unfavorite(_ id: Int) {
        guard let index = titles.firstIndex(where: { $0.id == id }) else { return }
        titles.remove(at: index)
        persist()
        onChange?()
    }

    public func toggle(_ item: TMDBCatalog.Item) {
        if contains(item.id) { unfavorite(item.id) } else { favorite(item) }
    }

    /// Every title by its key, as iCloud sync compares them.
    public var syncValues: [String: FollowedTitle] { Dictionary(titles.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first }) }

    /// The list merged with other devices': the newest change first; titles changed at the same moment keep this
    /// device's order.
    public func adopt(_ synced: [CloudSyncItem<FollowedTitle>]) {
        let rank = Dictionary(titles.enumerated().map { ($0.element.key, $0.offset) }, uniquingKeysWith: min)
        var seen = Set<Int>()
        titles = synced.sorted { lhs, rhs in
            if lhs.stamp != rhs.stamp { return lhs.stamp > rhs.stamp }
            return (rank[lhs.id] ?? Int.max, lhs.id) < (rank[rhs.id] ?? Int.max, rhs.id)
        }.map(\.value).filter { seen.insert($0.id).inserted }
        persist()
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(titles), forKey: Self.storageKey)
    }
}

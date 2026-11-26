import Foundation

/// A show saved to Favorites: its catalog identity and what its card shows. Episodes and their
/// addresses are left out, since they expire; opening the show loads its details from the source again.
public struct VideoFavorite: Identifiable, Codable, Hashable, Sendable {
    public let origin: URL
    public let sourceKey: String
    public let sourceName: String
    public let videoID: String
    public let name: String
    public let poster: URL?
    public let posterHeaders: [String: String]?
    public let year: String?
    public let remarks: String
    /// The same scope as the show's playback history, so a show is one favorite whichever page saved it.
    public var id: String { EpisodeSkipSettings.scope(origin: origin, source: sourceKey, video: videoID) }

    public init(origin: URL, site: Site, video: Video) {
        self.origin = site.origin(or: origin); sourceKey = site.sourceKey; sourceName = site.name
        videoID = video.id; name = video.name; poster = video.poster
        posterHeaders = video.posterHeaders.isEmpty ? nil : video.posterHeaders
        year = video.year; remarks = video.remarks
    }

    public static func id(origin: URL, site: Site, video: Video) -> String {
        EpisodeSkipSettings.scope(origin: site.origin(or: origin), source: site.sourceKey, video: video.id)
    }

    /// What the details page shows until the source answers.
    public var video: Video {
        Video(id: videoID, name: name, poster: poster, posterHeaders: posterHeaders ?? [:], year: year, remarks: remarks)
    }
}

/// Saved shows, newest first, kept on this device beside the favorite channels.
@MainActor public final class VideoFavorites: ObservableObject {
    public static let limit = 300
    @Published public private(set) var items: [VideoFavorite] = []
    private let defaults: UserDefaults
    private static let key = "videoFavorites"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let decoded = try? JSONDecoder().decode([VideoFavorite].self, from: data) {
            var seen = Set<String>()
            items = Array(decoded.filter { !$0.sourceKey.isEmpty && !$0.videoID.isEmpty && seen.insert($0.id).inserted }.prefix(Self.limit))
        }
    }

    public func contains(_ id: String) -> Bool { items.contains { $0.id == id } }

    public func toggle(_ favorite: VideoFavorite) {
        if contains(favorite.id) { return remove(favorite.id) }
        items = Array(([favorite] + items).prefix(Self.limit))
        persist()
    }

    public func remove(_ id: String) {
        items.removeAll { $0.id == id }
        persist()
    }

    private func persist() { defaults.set(try? JSONEncoder().encode(items), forKey: Self.key) }
}

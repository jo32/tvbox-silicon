import Foundation

/// What a music search looks for.
public enum MusicSearchKind: String, Codable, Sendable, CaseIterable, Hashable {
    /// `top` is songs, albums and playlists at once, for results in rows, as Music on the Mac and
    /// Spotify on Apple TV show them. `artists` is the songs of the artist the query names (#649).
    case songs, albums, playlists, top, artists
    /// One kind each; `top` is all of them.
    public static let filters: [MusicSearchKind] = [.songs, .artists, .albums, .playlists]
    public var name: String {
        switch self {
        case .top: L10n.text("All")
        case .songs: L10n.text("Songs")
        case .artists: L10n.text("Artists")
        case .albums: L10n.text("Albums")
        case .playlists: L10n.text("Playlists")
        }
    }
    public var collectionKind: MusicCollection.Kind? {
        switch self {
        case .songs, .top, .artists: nil
        case .albums: .album
        case .playlists: .playlist
        }
    }
}

/// An album or a playlist in one catalog. Its tracks are fetched when opened.
public struct MusicCollection: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable, Hashable { case album, playlist }
    public var kind: Kind
    public var platform: MusicPlatform
    public var collectionID: String
    public var title: String
    /// The artist of an album, the creator of a playlist.
    public var subtitle: String?
    public var artwork: URL?
    public var trackCount: Int?
    /// An album's release year.
    public var year: String?
    public init(kind: Kind, platform: MusicPlatform, collectionID: String, title: String, subtitle: String? = nil,
                artwork: URL? = nil, trackCount: Int? = nil, year: String? = nil) {
        self.kind = kind; self.platform = platform; self.collectionID = collectionID; self.title = title
        self.subtitle = subtitle.flatMap { $0.isEmpty ? nil : $0 }; self.artwork = artwork
        self.trackCount = trackCount.flatMap { $0 > 0 ? $0 : nil }; self.year = year.flatMap { $0.isEmpty ? nil : $0 }
    }
    public var id: String { platform.rawValue + ":" + kind.rawValue + ":" + collectionID }
}

/// Albums and playlists in a catalog: search, and their tracks.
public protocol MusicCollectionSource: Sendable {
    var platform: MusicPlatform { get }
    func searchCollections(_ query: String, kind: MusicCollection.Kind, page: Int) async throws -> [MusicCollection]
    /// The tracks in order, at most `MusicCollections.trackLimit`.
    func tracks(of collection: MusicCollection) async throws -> [MusicTrack]
}

public enum MusicCollections {
    /// A playlist can hold thousands of songs; a queue this long is plenty to play through.
    public static let trackLimit = 500

    /// Best first: the title the query names, then an artist or creator it names; ties keep catalog order.
    public static func rank(_ collections: [MusicCollection], query: String) -> [MusicCollection] {
        let core = MusicMatching.coreQuery(query)
        let scores: [Int] = collections.map { collection in
            let title = MusicMatching.normalize(collection.title)
            let owner = MusicMatching.normalize(collection.subtitle ?? "")
            var score = 0
            if title == core { score = 100 }
            else if !title.isEmpty && core.contains(title) && !owner.isEmpty && core.contains(owner) { score = 110 }
            else if !title.isEmpty && (core.contains(title) || title.contains(core)) { score = 60 }
            else if !owner.isEmpty && core.contains(owner) { score = 40 }
            return score
        }
        let order: [Int] = collections.indices.sorted { (a: Int, b: Int) -> Bool in scores[a] == scores[b] ? a < b : scores[a] > scores[b] }
        return order.map { collections[$0] }
    }
}

/// Catalog text sometimes carries search highlighting (`<em>…</em>`) and HTML entities.
enum MusicText {
    static func plain(_ text: String) -> String {
        entities(text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// QQ's lyrics escape apostrophes and the like.
    static func entities(_ text: String) -> String {
        var value = text
        for (entity, character) in [("&apos;", "'"), ("&#39;", "'"), ("&quot;", "\""), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&amp;", "&")] {
            value = value.replacingOccurrences(of: entity, with: character)
        }
        return value
    }
}

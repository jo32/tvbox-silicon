import Foundation
import Observation

/// One shelf on the Music page with nothing searched, as Discover has for video: charts, playlists or
/// albums. Shelves with the same `id` from different catalogs show as one row, their items taking turns.
public struct MusicBrowseSection: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var collections: [MusicCollection]
    public init(id: String, title: String, collections: [MusicCollection]) {
        self.id = id; self.title = title; self.collections = collections
    }
}

/// Where the shelves come from: a catalog's charts, recommended playlists and new albums. Opening one
/// fetches its tracks from the same catalog's `MusicCollectionSource`.
public protocol MusicBrowseSource: Sendable {
    var platform: MusicPlatform { get }
    /// The catalog's shelves, best first. Throws only when it has none to show.
    func browseSections() async throws -> [MusicBrowseSection]
    /// No shelves is an answer, not a failure: music extensions when none is imported.
    var mayBeEmpty: Bool { get }
}

extension MusicBrowseSource {
    public var mayBeEmpty: Bool { false }
}

public enum MusicBrowse {
    /// Shelf IDs the built-in catalogs share, so their charts land in one row, their playlists in another.
    public static let charts = "charts", playlists = "playlists", albums = "albums", moreCharts = "moreCharts"
    /// Items a catalog puts on one shelf.
    static let shelfSize = 30

    static func title(_ id: String) -> String {
        switch id {
        case charts: L10n.text("Top Charts")
        case playlists: L10n.text("Recommended Playlists")
        case albums: L10n.text("New Albums")
        default: L10n.text("More Charts")
        }
    }

    /// One row per shelf ID, in the order the sources first list them. A shelf several sources share
    /// takes one item from each in turn, so no catalog fills the start of the row; repeats are dropped.
    public static func merge(_ answers: [[MusicBrowseSection]]) -> [MusicBrowseSection] {
        var order: [String] = []
        var parts: [String: [MusicBrowseSection]] = [:]
        for answer in answers {
            for section in answer where !section.collections.isEmpty {
                if parts[section.id] == nil { order.append(section.id) }
                parts[section.id, default: []].append(section)
            }
        }
        return order.compactMap { id in
            guard let shelves = parts[id], let first = shelves.first else { return nil }
            var seen = Set<String>(), items: [MusicCollection] = []
            for index in 0..<(shelves.map(\.collections.count).max() ?? 0) {
                for shelf in shelves where index < shelf.collections.count {
                    let item = shelf.collections[index]
                    if seen.insert(item.id).inserted { items.append(item) }
                }
            }
            return MusicBrowseSection(id: id, title: first.title, collections: items)
        }
    }
}

/// The shelves, fetched when the Music page first shows with nothing searched and kept for the session.
/// A catalog that failed is asked again the next time the page shows; all of them after a few hours,
/// since charts change daily. Each catalog's shelves show as soon as it answers.
@MainActor @Observable public final class MusicBrowseModel {
    public private(set) var sections: [MusicBrowseSection] = []
    public private(set) var loading = false
    /// A catalog failed last time; its shelves are missing.
    public private(set) var incomplete = false
    private let sources: [any MusicBrowseSource]
    private var answers: [Int: [MusicBrowseSection]] = [:]
    private var loadedAt: Date?
    static let lifetime: TimeInterval = 6 * 60 * 60

    public init(sources: [any MusicBrowseSource]? = nil) {
        self.sources = sources ?? Self.defaultSources()
    }

    public nonisolated static func defaultSources(transport: MusicTransport = URLSessionMusicTransport()) -> [any MusicBrowseSource] {
        [QQMusicCatalog(transport: transport), NeteaseMusicCatalog(transport: transport)]
    }

    /// Fetches what is missing or stale; `refresh` fetches everything again. Shelves already shown stay
    /// until their catalog answers anew.
    public func load(refresh: Bool = false, now: Date = Date()) async {
        guard !loading else { return }
        let stale = refresh || loadedAt.map { now.timeIntervalSince($0) > Self.lifetime } == true
        let wanted = sources.indices.filter { stale || answers[$0] == nil }
        guard !wanted.isEmpty else { return }
        loading = true
        defer { loading = false }
        var failed = false
        await withTaskGroup(of: (Int, [MusicBrowseSection]?).self) { group in
            for index in wanted {
                let source = sources[index]
                group.addTask { (index, try? await source.browseSections()) }
            }
            for await (index, answer) in group {
                guard let answer, !answer.isEmpty || sources[index].mayBeEmpty else { failed = true; continue }
                answers[index] = answer
                sections = MusicBrowse.merge(sources.indices.compactMap { answers[$0] })
            }
        }
        // Leaving the page cancels the fetch; that is not a failure, and the next visit finishes it.
        guard !Task.isCancelled else { return }
        incomplete = failed
        // The clock runs from the last time every catalog was asked, not from a retry of one.
        if wanted.count == sources.count { loadedAt = now }
    }

    /// Fetches `platform`'s shelves again, the others staying: after music extensions were added or turned off.
    public func reload(_ platform: MusicPlatform) async {
        for index in sources.indices where sources[index].platform == platform { answers[index] = nil }
        sections = MusicBrowse.merge(sources.indices.compactMap { answers[$0] })
        await load()
    }
}

// MARK: - QQ Music

extension QQMusicCatalog: MusicBrowseSource {
    /// QQ's chart groups (巅峰榜 first, then by genre, region and network), the playlist square's
    /// popular lists and the mainland's new albums.
    public func browseSections() async throws -> [MusicBrowseSection] {
        async let charts = try? call(module: "musicToplist.ToplistInfoServer", method: "GetAll", param: [:])
        async let lists = try? call(module: "playlist.PlayListPlazaServer", method: "get_playlist_by_tag",
                                    param: ["id": 10_000_000, "sin": 0, "size": MusicBrowse.shelfSize, "order": 5, "cur_page": 1])
        async let albums = try? call(module: "newalbum.NewAlbumServer", method: "get_new_album_info",
                                     param: ["area": 1, "sin": 0, "num": MusicBrowse.shelfSize])
        let answers = await (charts, lists, albums)
        guard answers.0 != nil || answers.1 != nil || answers.2 != nil else {
            throw MusicProviderError.invalidResponse("QQ browse: no answer")
        }
        return Self.parseBrowse(charts: answers.0, playlists: answers.1, albums: answers.2)
    }

    /// A chart opens as a playlist whose ID is the chart's, marked so `tracks(of:)` asks for the chart.
    static let chartPrefix = "toplist:"
    static func chartID(_ collection: MusicCollection) -> Int? {
        collection.collectionID.hasPrefix(chartPrefix) ? Int(collection.collectionID.dropFirst(chartPrefix.count)) : nil
    }

    func chartTracks(_ topID: Int) async throws -> [MusicTrack] {
        let json = try await call(module: "musicToplist.ToplistInfoServer", method: "GetDetail",
                                  param: ["topId": topID, "offset": 0, "num": MusicCollections.trackLimit, "period": ""])
        return Self.parseChart(json)
    }

    static func parseChart(_ json: JSONValue) -> [MusicTrack] {
        (json[path: "req", "data", "songInfoList"]?.array ?? []).compactMap(track)
    }

    static func parseBrowse(charts: JSONValue?, playlists: JSONValue?, albums: JSONValue?) -> [MusicBrowseSection] {
        var top: [MusicCollection] = [], more: [MusicCollection] = []
        for group in charts?[path: "req", "data", "group"]?.array ?? [] {
            let lists = (group["toplist"]?.array ?? []).compactMap { chart -> MusicCollection? in
                guard let id = chart["topId"]?.int, let title = chart["title"]?.string, !title.isEmpty else { return nil }
                let cover = ["mbFrontPicUrl", "frontPicUrl", "headPicUrl"].lazy.compactMap { chart[$0]?.string }.first { !$0.isEmpty }
                return MusicCollection(kind: .playlist, platform: .qq, collectionID: chartPrefix + String(id), title: title,
                                       artwork: cover.flatMap(URL.init(string:)), trackCount: chart["totalNum"]?.int)
            }
            if group["groupId"]?.int == 0 { top += lists } else { more += lists }
        }
        let lists = (playlists?[path: "req", "data", "v_playlist"]?.array ?? []).compactMap { list -> MusicCollection? in
            guard let id = list["tid"]?.string, !id.isEmpty, id != "0", let title = list["title"]?.string, !title.isEmpty else { return nil }
            let cover = ["cover_url_medium", "cover_url_big", "cover_url_small"].lazy.compactMap { list[$0]?.string }.first { !$0.isEmpty }
            return MusicCollection(kind: .playlist, platform: .qq, collectionID: id, title: MusicText.plain(title),
                                   subtitle: list[path: "creator_info", "nick"]?.string.map(MusicText.plain),
                                   artwork: cover.flatMap(URL.init(string:)), trackCount: list["song_ids"]?.array?.count)
        }
        let newAlbums = (albums?[path: "req", "data", "albums"]?.array ?? []).compactMap { album -> MusicCollection? in
            guard let mid = album["mid"]?.string, !mid.isEmpty, let name = album["name"]?.string, !name.isEmpty else { return nil }
            let singers = (album["singers"]?.array ?? []).compactMap { $0["name"]?.string }
            return MusicCollection(kind: .album, platform: .qq, collectionID: mid, title: MusicText.plain(name),
                                   subtitle: singers.joined(separator: " / "),
                                   artwork: URL(string: "https://y.gtimg.cn/music/photo_new/T002R300x300M000\(mid).jpg"),
                                   year: album["release_time"]?.string.map { String($0.prefix(4)) })
        }
        return [(MusicBrowse.charts, top), (MusicBrowse.playlists, lists), (MusicBrowse.albums, newAlbums), (MusicBrowse.moreCharts, more)]
            .filter { !$0.1.isEmpty }
            .map { MusicBrowseSection(id: $0.0, title: MusicBrowse.title($0.0), collections: Array($0.1.prefix(MusicBrowse.shelfSize * 2))) }
    }
}

// MARK: - NetEase

extension NeteaseMusicCatalog: MusicBrowseSource {
    /// NetEase's charts (its official ones first), recommended playlists and new albums, from its own
    /// web API: none of it counts against GD Studio's budget. Charts are ordinary playlists there.
    public func browseSections() async throws -> [MusicBrowseSection] {
        async let charts = try? neteaseJSON(URL(string: "https://music.163.com/api/toplist")!)
        async let lists = try? neteaseJSON(MusicHTTP.url("https://music.163.com/api/personalized/playlist", [("limit", String(MusicBrowse.shelfSize))]))
        async let albums = try? neteaseJSON(MusicHTTP.url("https://music.163.com/api/album/new", [
            ("area", "ALL"), ("offset", "0"), ("limit", String(MusicBrowse.shelfSize)), ("total", "true"),
        ]))
        let answers = await (charts, lists, albums)
        guard answers.0 != nil || answers.1 != nil || answers.2 != nil else {
            throw MusicProviderError.invalidResponse("NetEase browse: no answer")
        }
        return Self.parseBrowse(charts: answers.0, playlists: answers.1, albums: answers.2)
    }

    static func parseBrowse(charts: JSONValue?, playlists: JSONValue?, albums: JSONValue?) -> [MusicBrowseSection] {
        var top: [MusicCollection] = [], more: [MusicCollection] = []
        for chart in charts?["list"]?.array ?? [] {
            guard let list = playlist(chart) else { continue }
            // The official charts (soaring, new, original, hot) carry a type; the rest are by genre or partner.
            if chart["ToplistType"]?.string?.isEmpty == false { top.append(list) } else { more.append(list) }
        }
        let lists = (playlists?["result"]?.array ?? []).compactMap(playlist)
        let newAlbums = (albums?["albums"]?.array ?? []).compactMap(album)
        return [(MusicBrowse.charts, top), (MusicBrowse.playlists, lists), (MusicBrowse.albums, newAlbums), (MusicBrowse.moreCharts, more)]
            .filter { !$0.1.isEmpty }
            .map { MusicBrowseSection(id: $0.0, title: MusicBrowse.title($0.0), collections: Array($0.1.prefix(MusicBrowse.shelfSize * 2))) }
    }
}

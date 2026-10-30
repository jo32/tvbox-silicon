import Foundation
import Observation

public enum FavoriteKind: String, Codable, Sendable {
    case live, video, episode, music, cloud
}

public struct FavoriteVideo: Codable, Hashable, Sendable {
    public var origin: URL
    public var sourceKey: String
    public var sourceName: String
    public var videoID: String
    public var videoName: String
    public var poster: URL?
    public var posterHeaders: [String: String]
    public var year: String?

    public init(origin: URL, sourceKey: String, sourceName: String, videoID: String, videoName: String, poster: URL?, posterHeaders: [String: String], year: String?) {
        self.origin = origin
        self.sourceKey = sourceKey
        self.sourceName = sourceName
        self.videoID = videoID
        self.videoName = videoName
        self.poster = poster
        self.posterHeaders = posterHeaders
        self.year = year
    }

    public init(origin fallback: URL, site: Site, video: Video) {
        self.init(origin: site.origin(or: fallback), sourceKey: site.sourceKey, sourceName: site.name, videoID: video.id, videoName: video.name, poster: video.poster, posterHeaders: video.posterHeaders, year: video.year)
    }

    /// Enough for the detail page to refetch this title. Playback addresses are not stored.
    public func listingVideo() -> Video? {
        var json: [String: JSONValue] = ["vod_id": .string(videoID), "vod_name": .string(videoName)]
        if let year { json["vod_year"] = .string(year) }
        if let poster { json["vod_pic"] = .string(posterField(poster)) }
        return Video(json: json, origin: origin)
    }

    /// `Video` reads artwork headers from the TVBox suffix on `vod_pic`.
    private func posterField(_ poster: URL) -> String {
        let headers = posterHeaders.filter { name, value in
            name.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil && !value.contains("\r") && !value.contains("\n")
        }
        guard !headers.isEmpty else { return poster.absoluteString }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(headers), let json = String(data: data, encoding: .utf8) else { return poster.absoluteString }
        return poster.absoluteString + "@Headers=" + json
    }
}

public struct FavoriteEpisode: Codable, Hashable, Sendable {
    public var video: FavoriteVideo
    public var episodeFlag: String
    public var episodeName: String
    public var episodeID: String

    public init(video: FavoriteVideo, episodeFlag: String, episodeName: String, episodeID: String) {
        self.video = video
        self.episodeFlag = episodeFlag
        self.episodeName = episodeName
        self.episodeID = episodeID
    }

    public func historyContext() -> PlaybackHistoryContext {
        var context = PlaybackHistoryContext(origin: video.origin, sourceKey: video.sourceKey, sourceName: video.sourceName, videoID: video.videoID, videoName: video.videoName, poster: video.poster, episodeID: episodeID, episodeName: episodeName, episodeFlag: episodeFlag)
        context.year = video.year
        context.posterHeaders = video.posterHeaders.isEmpty ? nil : video.posterHeaders
        return context
    }

    /// Continue Watching's position only when that entry is still this episode. A later episode of the same video starts at 0. A finished entry also starts at 0, matching `resumePosition`.
    public func resumePosition(in entries: [PlaybackHistoryEntry]) -> Double {
        guard let entry = entries.first(where: { item in
            item.context.origin == video.origin && item.context.sourceKey == video.sourceKey && item.context.videoID == video.videoID
                && item.context.episodeFlag == episodeFlag && item.context.episodeName == episodeName
        }) else { return 0 }
        return entry.resumePosition
    }
}

public struct FavoriteCloudFile: Codable, Hashable, Sendable {
    public var driveKey: String
    public var folderID: String
    public var folderName: String
    public var fileID: String
    public var fileName: String
    public var size: Int64

    public init(driveKey: String, folderID: String, folderName: String, fileID: String, fileName: String, size: Int64) {
        self.driveKey = driveKey
        self.folderID = folderID
        self.folderName = folderName
        self.fileID = fileID
        self.fileName = fileName
        self.size = size
    }
}

public enum FavoriteItem: Codable, Hashable, Sendable, Identifiable {
    case live(Channel)
    case video(FavoriteVideo)
    case episode(FavoriteEpisode)
    case music(MusicTrack)
    case cloud(FavoriteCloudFile)

    public var kind: FavoriteKind {
        switch self {
        case .live: .live
        case .video: .video
        case .episode: .episode
        case .music: .music
        case .cloud: .cloud
        }
    }

    public var key: String {
        switch self {
        case .live(let channel):
            if LiveCatalog.isRoom(channel.url) { return "live|" + channel.url.absoluteString }
            return "live|" + channel.id
        case .video(let video):
            return "video|" + EpisodeSkipSettings.scope(origin: video.origin, source: video.sourceKey, video: video.videoID)
        case .episode(let episode):
            let videoKey = EpisodeSkipSettings.scope(origin: episode.video.origin, source: episode.video.sourceKey, video: episode.video.videoID)
            return "episode|" + videoKey + "|" + episode.episodeFlag + "|" + episode.episodeName
        case .music(let track):
            return "music|" + track.id
        case .cloud(let file):
            return "cloud|" + file.driveKey + "|" + file.fileID
        }
    }

    public var id: String { key }

    public func matches(_ other: FavoriteItem) -> Bool {
        switch (self, other) {
        case (.live(let saved), .live(let channel)):
            return saved.id == channel.id || (LiveCatalog.isRoom(channel.url) && saved.url == channel.url)
        default:
            return key == other.key
        }
    }
}

struct FavoriteDocument: Codable {
    var version: Int
    var items: [FavoriteItem]
}

@MainActor @Observable public final class Favorites {
    public private(set) var items: [FavoriteItem] = []
    public private(set) var persistenceError: String?
    private let defaults: UserDefaults
    private static let storageKey = "favorites"
    /// Called after the viewer changes the list (not after `adopt`), for iCloud sync.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var migrated = false
        if let data = defaults.data(forKey: Self.storageKey) {
            if let document = try? JSONDecoder().decode(FavoriteDocument.self, from: data), document.version == 2 {
                items = document.items
            } else if let channels = try? JSONDecoder().decode([Channel].self, from: data) {
                items = channels.map { .live($0) }
                migrated = true
            }
        }
        if adoptVideoFavorites() { migrated = true }
        if migrated { persist() }
    }

    /// Shows saved by the earlier favorites list, once. Unfavoriting one afterwards stays removed.
    private func adoptVideoFavorites() -> Bool {
        let adopted = "videoFavorites.adopted.v1"
        guard !defaults.bool(forKey: adopted) else { return false }
        defaults.set(true, forKey: adopted)
        guard let data = defaults.data(forKey: "videoFavorites"),
              let shows = try? JSONDecoder().decode([VideoFavorite].self, from: data) else { return false }
        var added = false
        for show in shows.reversed() {
            let video = FavoriteVideo(origin: show.origin, sourceKey: show.sourceKey, sourceName: show.sourceName, videoID: show.videoID, videoName: show.name, poster: show.poster, posterHeaders: show.posterHeaders ?? [:], year: show.year)
            let item = FavoriteItem.video(video)
            guard !items.contains(where: { $0.matches(item) }) else { continue }
            items.insert(item, at: 0)
            added = true
        }
        return added
    }

    public func contains(_ item: FavoriteItem) -> Bool { items.contains { $0.matches(item) } }

    public func toggle(_ item: FavoriteItem) {
        if let index = items.firstIndex(where: { $0.matches(item) }) { items.remove(at: index) }
        else { items.insert(item, at: 0) }
        persist()
        onChange?()
    }

    /// Every item by its key, as iCloud sync compares them.
    public var syncValues: [String: FavoriteItem] { Dictionary(items.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first }) }

    /// The list merged with other devices': the newest change first; items changed at the same moment keep this device's order.
    public func adopt(_ synced: [CloudSyncItem<FavoriteItem>]) {
        let rank = Dictionary(items.enumerated().map { ($0.element.key, $0.offset) }, uniquingKeysWith: min)
        items = synced.sorted { lhs, rhs in
            if lhs.stamp != rhs.stamp { return lhs.stamp > rhs.stamp }
            return (rank[lhs.id] ?? Int.max, lhs.id) < (rank[rhs.id] ?? Int.max, rhs.id)
        }.map(\.value)
        persist()
    }

    public func items(_ kind: FavoriteKind) -> [FavoriteItem] { items.filter { $0.kind == kind } }

    public var liveChannels: [Channel] {
        items.compactMap { if case .live(let channel) = $0 { channel } else { nil } }
    }

    private func persist() {
        do {
            defaults.set(try JSONEncoder().encode(FavoriteDocument(version: 2, items: items)), forKey: Self.storageKey)
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
        }
    }
}

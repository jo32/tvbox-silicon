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
            if LiveCatalog.isRoomAddress(channel.url) { return "live|" + channel.url.absoluteString }
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
            return saved.id == channel.id || (LiveCatalog.isRoomAddress(channel.url) && saved.url == channel.url)
        default:
            return key == other.key
        }
    }
}

struct FavoriteDocument: Codable {
    var version: Int
    var items: [FavoriteItem]
    /// version 3 adds per-record environments, kept beside `items` so an old list decodes unchanged.
    var environments: [String: String]?
}

/// One favourite plus the environment it belongs to. `FavoriteItem` stays as-is; the environment
/// rides alongside in the document so an item's identity (its `key`) is never polluted.
struct FavoriteRecord: Codable, Hashable, Sendable {
    var item: FavoriteItem
    var environment: UUID?
}

@MainActor @Observable public final class Favorites {
    /// Every favourite, across all environments. The environment is stored per record, not per item,
    /// so `FavoriteItem` and its `key` stay untouched and sync keeps working.
    private var records: [FavoriteRecord] = []
    /// The environment whose favourites `items` exposes. The app keeps this in step with
    /// `Environments.activeID`; nil means "default environment" and matches records with no
    /// environment (everything saved before environments existed).
    public var activeEnvironmentID: UUID?
    public var defaultEnvironmentID: UUID?
    public private(set) var persistenceError: String?
    private let defaults: UserDefaults
    private static let storageKey = "favorites"
    /// Called after the viewer changes the list (not after `adopt`), for iCloud sync.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?

    /// The favourites of the active environment, in order.
    public var items: [FavoriteItem] {
        let active = activeEnvironmentID ?? defaultEnvironmentID
        return records.filter { ($0.environment ?? defaultEnvironmentID) == active }.map(\.item)
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var migrated = false
        if let data = defaults.data(forKey: Self.storageKey) {
            if let document = try? JSONDecoder().decode(FavoriteDocument.self, from: data), document.version >= 2 {
                let env = document.environments ?? [:]
                records = document.items.map { item in
                    FavoriteRecord(item: item, environment: env[item.key].flatMap(UUID.init(uuidString:)))
                }
            } else if let channels = try? JSONDecoder().decode([Channel].self, from: data) {
                records = channels.map { FavoriteRecord(item: .live($0), environment: nil) }
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
            guard !records.contains(where: { $0.item.matches(item) }) else { continue }
            records.insert(FavoriteRecord(item: item, environment: nil), at: 0)
            added = true
        }
        return added
    }

    public func contains(_ item: FavoriteItem) -> Bool { records.contains { $0.item.matches(item) && isActive($0) } }

    public func toggle(_ item: FavoriteItem) {
        if let index = records.firstIndex(where: { $0.item.matches(item) && isActive($0) }) {
            records.remove(at: index)
        } else {
            records.insert(FavoriteRecord(item: item, environment: activeEnvironmentID ?? defaultEnvironmentID), at: 0)
        }
        persist()
        onChange?()
    }

    private func isActive(_ record: FavoriteRecord) -> Bool {
        (record.environment ?? defaultEnvironmentID) == (activeEnvironmentID ?? defaultEnvironmentID)
    }

    /// Every item by its key, as iCloud sync compares them.
    public var syncValues: [String: FavoriteItem] { Dictionary(items.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first }) }

    /// The list merged with other devices': the newest change first; items changed at the same moment keep this device's order.
    public func adopt(_ synced: [CloudSyncItem<FavoriteItem>]) {
        let active = activeEnvironmentID ?? defaultEnvironmentID
        let rank = Dictionary(items.enumerated().map { ($0.element.key, $0.offset) }, uniquingKeysWith: min)
        let incoming = synced.sorted { lhs, rhs in
            if lhs.stamp != rhs.stamp { return lhs.stamp > rhs.stamp }
            return (rank[lhs.id] ?? Int.max, lhs.id) < (rank[rhs.id] ?? Int.max, rhs.id)
        }.map { FavoriteRecord(item: $0.value, environment: active) }
        let incomingKeys = Set(incoming.map { $0.item.key })
        records.removeAll { isActive($0) && incomingKeys.contains($0.item.key) }
        records.insert(contentsOf: incoming, at: 0)
        persist()
    }

    public func items(_ kind: FavoriteKind) -> [FavoriteItem] { items.filter { $0.kind == kind } }

    public var liveChannels: [Channel] {
        items.compactMap { if case .live(let channel) = $0 { channel } else { nil } }
    }

    private func persist() {
        do {
            var env: [String: String] = [:]
            for record in records {
                if let id = record.environment { env[record.item.key] = id.uuidString }
            }
            // version stays 2: `environments` is an additive optional field, so a v2 reader that
            // predates environments still decodes the items and simply ignores the mapping.
            defaults.set(try JSONEncoder().encode(FavoriteDocument(version: 2, items: records.map(\.item), environments: env)), forKey: Self.storageKey)
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
        }
    }
}

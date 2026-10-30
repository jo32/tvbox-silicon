import Foundation
import Observation

/// Catalog identity only: an expiring stream URL or its authorization headers must
/// never become the address used to resume a saved episode.
public struct PlaybackHistoryContext: Codable, Hashable, Sendable {
    public let origin: URL
    public let sourceKey: String
    public let sourceName: String
    public let videoID: String
    public let videoName: String
    public let poster: URL?
    public let episodeID: String
    public let episodeName: String
    public let episodeFlag: String
    public var year: String?
    /// Only validated public official pages are retained, never signed stream addresses.
    public var officialPage: URL?
    public var posterHeaders: [String: String]?
    public var id: String { EpisodeSkipSettings.scope(origin: origin, source: sourceKey, video: videoID) }

    public init(origin: URL, sourceKey: String, sourceName: String, videoID: String, videoName: String,
                poster: URL? = nil, episodeID: String, episodeName: String, episodeFlag: String) {
        self.origin = origin; self.sourceKey = sourceKey; self.sourceName = sourceName
        self.videoID = videoID; self.videoName = videoName; self.poster = poster
        self.episodeID = episodeID; self.episodeName = episodeName; self.episodeFlag = episodeFlag
    }

    public init(origin: URL, site: Site, video: Video, episode: Episode) {
        self.init(origin: site.origin(or: origin), sourceKey: site.sourceKey, sourceName: site.name, videoID: video.id,
                  videoName: video.name, poster: video.poster, episodeID: episode.id,
                  episodeName: episode.name, episodeFlag: episode.flag)
        year = video.year
        posterHeaders = video.posterHeaders.isEmpty ? nil : video.posterHeaders
        officialPage = OfficialVideoPage.validated(episode.address)
    }

    /// Names survive list reordering. Never silently resume a different episode
    /// just because a source now gives it the saved numeric index.
    public func episode(in episodes: [Episode]) -> Episode? {
        let matches = episodes.filter { $0.flag == episodeFlag && $0.name == episodeName }
        if let exact = matches.first(where: { $0.id == episodeID }) { return exact }
        return matches.count == 1 ? matches.first : nil
    }
}

public struct PlaybackHistoryEntry: Identifiable, Codable, Hashable, Sendable {
    public let context: PlaybackHistoryContext
    public let position: Double
    public let duration: Double
    public let updatedAt: Date
    public var id: String { context.id }
    public var completed: Bool { duration > 0 && position >= duration - 1 }
    public var resumePosition: Double { completed ? 0 : position }
    public var progress: Double { duration > 0 ? min(1, max(0, position / duration)) : 0 }

    public init(context: PlaybackHistoryContext, position: Double, duration: Double, updatedAt: Date) {
        self.context = context
        self.position = position
        self.duration = duration
        self.updatedAt = updatedAt
    }

    public static func resumeTarget(_ position: Double, duration: Double) -> Double? {
        guard position.isFinite, position >= 0, duration.isFinite, duration > 0 else { return nil }
        return min(position, max(0, duration - 0.25))
    }
}

extension PlaybackHistoryEntry {
    /// The favorite this row points at: the cloud file, or this episode. Not the whole video.
    public func favoriteItem() -> FavoriteItem {
        if context.sourceKey == CloudFiles.sourceKey {
            return .cloud(FavoriteCloudFile(driveKey: context.episodeFlag, folderID: context.videoID, folderName: context.videoName, fileID: context.episodeID, fileName: context.episodeName, size: 0))
        }
        let video = FavoriteVideo(origin: context.origin, sourceKey: context.sourceKey, sourceName: context.sourceName, videoID: context.videoID, videoName: context.videoName, poster: context.poster, posterHeaders: context.posterHeaders ?? [:], year: context.year)
        return .episode(FavoriteEpisode(video: video, episodeFlag: context.episodeFlag, episodeName: context.episodeName, episodeID: context.episodeID))
    }
}

/// Shared by the library and player, bounded and atomically persisted outside
/// UserDefaults so a growing history does not hit its size limit.
@MainActor @Observable public final class PlaybackHistory {
    public static let shared = PlaybackHistory()
    public static let limit = 200
    public private(set) var entries: [PlaybackHistoryEntry] = []
    public private(set) var persistenceError: String?
    private let file: URL
    private let cache: MediaCache
    private let defaults: UserDefaults
    /// Called after the history changes here (not after `adopt`), for iCloud sync.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?

    public init(file: URL? = nil, cache: MediaCache = .shared, defaults: UserDefaults = .standard) {
        self.cache = cache; self.defaults = defaults
        #if os(tvOS)
        let directory = URL.cachesDirectory
        #else
        let directory = URL.applicationSupportDirectory
        #endif
        self.file = file ?? directory.appending(path: "playback-history-v1.json")
        if let data = try? Data(contentsOf: self.file), data.count <= 2 * 1024 * 1024,
           let decoded = try? JSONDecoder().decode([PlaybackHistoryEntry].self, from: data) {
            var seen = Set<String>()
            entries = Array(decoded.filter { Self.valid($0) }.sorted { $0.updatedAt > $1.updatedAt }
                .filter { seen.insert($0.id).inserted }.prefix(Self.limit))
        }
        prioritizeCaches()
    }

    public func record(_ context: PlaybackHistoryContext, position: Double, duration: Double, now: Date = Date()) {
        guard position.isFinite, position >= 1, duration.isFinite, duration >= 0 else { return }
        let entry = PlaybackHistoryEntry(context: context, position: duration > 0 ? min(position, duration) : position,
                                         duration: duration, updatedAt: now)
        guard Self.valid(entry) else { return }
        if let old = entries.first(where: { $0.id == entry.id }), old.context == context,
           abs(old.position - entry.position) < 0.25, old.duration == duration { return }
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        let dropped = entries.dropFirst(Self.limit)
        for entry in dropped { clean(entry) }
        entries = Array(entries.prefix(Self.limit))
        prioritizeCaches()
        persist()
        onChange?()
    }

    /// Another device's merged history. An entry that is no longer in it loses its caches as if removed here.
    public func adopt(_ synced: [PlaybackHistoryEntry]) {
        var seen = Set<String>()
        let next = Array(synced.filter { Self.valid($0) }.sorted { $0.updatedAt > $1.updatedAt }
            .filter { seen.insert($0.id).inserted }.prefix(Self.limit))
        let kept = Set(next.map(\.id))
        for entry in entries where !kept.contains(entry.id) { clean(entry) }
        entries = next
        prioritizeCaches(); persist()
    }

    public func remove(_ id: String) { remove(Set([id])) }
    public func remove(_ ids: Set<String>) {
        for entry in entries where ids.contains(entry.id) { clean(entry) }
        entries.removeAll { ids.contains($0.id) }; prioritizeCaches(); persist(); onChange?()
    }
    public func clear() { for entry in entries { clean(entry) }; entries.removeAll(); prioritizeCaches(); persist(); onChange?() }
    private func prioritizeCaches() {
        cache.prioritize(Set(entries.flatMap { entry in
            [entry.id] + (entry.context.poster.map { [PosterResource.artworkScope($0)] } ?? [])
        }))
    }
    private func clean(_ entry: PlaybackHistoryEntry) {
        cache.remove(scope: entry.id)
        if let poster = entry.context.poster { cache.remove(scope: PosterResource.artworkScope(poster)) }
        EpisodeSkipSettings.remove(scope: entry.id, defaults: defaults)
    }

    private static func valid(_ entry: PlaybackHistoryEntry) -> Bool {
        !entry.context.sourceKey.isEmpty && !entry.context.videoID.isEmpty &&
        entry.position.isFinite && entry.position >= 0 && entry.duration.isFinite && entry.duration >= 0 &&
        entry.updatedAt.timeIntervalSince1970.isFinite
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(entries)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            persistenceError = nil
        } catch { persistenceError = error.localizedDescription }
    }
}

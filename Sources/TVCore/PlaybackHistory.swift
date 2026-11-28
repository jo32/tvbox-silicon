import Foundation
import Observation

/// Settings → Watch Now: History and Continue Watching add the file's size and picture quality to an episode's
/// number, read from its file name ("第1集 · 5.4GB · 2160p", #595). Off by default.
public enum HistoryFileDetails {
    public static let key = "showsHistoryFileDetails"
}

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

    /// A looser identity than `id` (#2064): the origin with its tail slash, fragment and query dropped
    /// and the host lowercased, plus the source and video, so a title that a second device or a
    /// re-addressed subscription saves under a cosmetically different origin collapses into one line.
    /// It never replaces `id` (the cloud sync and local caches key on that); it only merges near-dups.
    public var dedupKey: String {
        var parts = [String]()
        if let host = origin.host, !host.isEmpty {
            parts.append(host.lowercased())
            if let port = origin.port { parts.append("\(port)") }
        } else {
            parts.append(origin.absoluteString)
        }
        if let path = origin.path, !path.isEmpty { parts.append(path.hasSuffix("/") ? String(path.dropLast()) : path) }
        parts.append(sourceKey)
        parts.append(videoID)
        return parts.joined(separator: "␟")
    }

    /// The title the player shows: the video and its episode, except when the two
    /// are the same and would read twice ("第1集 · 第1集", #2363).
    public var displayName: String { Self.displayName(video: videoName, episode: episodeName) }

    /// "video · episode", or one of them when the other is empty or the two are the same name.
    public static func displayName(video: String, episode: String) -> String {
        let video = video.trimmingCharacters(in: .whitespacesAndNewlines)
        let episode = episode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !episode.isEmpty else { return video }
        guard video.lowercased() != episode.lowercased() else { return video }
        return video.isEmpty ? episode : "\(video) · \(episode)"
    }

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

    /// The same place under a subscription's new address (#982).
    public func moved(to origin: URL) -> Self {
        var context = PlaybackHistoryContext(origin: origin, sourceKey: sourceKey, sourceName: sourceName, videoID: videoID, videoName: videoName,
                                             poster: poster, episodeID: episodeID, episodeName: episodeName, episodeFlag: episodeFlag)
        context.year = year; context.officialPage = officialPage; context.posterHeaders = posterHeaders
        return context
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
    /// A looser identity than `id` for merging near-duplicates that the same title takes on across
    /// devices or subscription addresses (#2064): the origin with its tail slash, fragment and query
    /// dropped and host lowercased, plus the source and video. `id` (and the cloud sync that keys on
    /// it) is left untouched, so this only collapses near-duplicates locally.
    public var dedupKey: String { context.dedupKey }
    public var completed: Bool { duration > 0 && position >= duration - 1 }
    public var resumePosition: Double { completed ? 0 : position }
    public var progress: Double { duration > 0 ? min(1, max(0, position / duration)) : 0 }

    /// Where to start an episode again: the saved position when it is the episode this entry is about, so
    /// picking it from a list picks up where it stopped. Any other episode starts at 0, and so does an entry
    /// finished or barely started.
    public func resumePosition(for episode: Episode) -> Double? {
        guard context.episode(in: [episode]) != nil, resumePosition > 1 else { return nil }
        return resumePosition
    }

    /// Where `episode` starts when the viewer picks it from the video's `episodes`: as `resumePosition(for:)`, and also
    /// when it is this entry's episode on another of the video's lines (#1300), so a line too slow to watch, left for
    /// another, goes on from where it was instead of from the start. The same episode on another line has the same
    /// name there, else the same number (第01集, 第1集, 01); a film is each line's only video.
    public func resumePosition(for episode: Episode, among episodes: [Episode]) -> Double? {
        if let same = resumePosition(for: episode) { return same }
        guard resumePosition > 1, episode.flag != context.episodeFlag else { return nil }
        let line = episodes.filter { $0.flag == episode.flag }
        guard line.contains(episode) else { return nil }
        if episode.name == context.episodeName { return line.filter { $0.name == episode.name }.count == 1 ? resumePosition : nil }
        if let number = CatalogDanmakuMatcher.episodeNumber(episode.name), number == CatalogDanmakuMatcher.episodeNumber(context.episodeName) {
            return line.filter { CatalogDanmakuMatcher.episodeNumber($0.name) == number }.count == 1 ? resumePosition : nil
        }
        return line.count == 1 && episodes.filter { $0.flag == context.episodeFlag }.count <= 1 ? resumePosition : nil
    }

    /// What Continue plays on the video's page: the episode watched last, or, once that one is finished, the next
    /// one on its line. Nil when the details no longer list it or a finished episode was the line's last, so
    /// Play starts the line instead.
    public func continuation(in episodes: [Episode]) -> Episode? {
        completed ? EpisodePlaylist(episodes).next(after: context) : context.episode(in: episodes)
    }

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
    /// The favorite this row points at: the cloud file, or the whole video (matching the watch/detail page).
    public func favoriteItem() -> FavoriteItem {
        if context.sourceKey == CloudFiles.sourceKey {
            return .cloud(FavoriteCloudFile(driveKey: context.episodeFlag, folderID: context.videoID, folderName: context.videoName, fileID: context.episodeID, fileName: context.episodeName, size: 0))
        }
        return .video(FavoriteVideo(origin: context.origin, sourceKey: context.sourceKey, sourceName: context.sourceName, videoID: context.videoID, videoName: context.videoName, poster: context.poster, posterHeaders: context.posterHeaders ?? [:], year: context.year))
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
    @ObservationIgnored private let persistence: PlaybackHistoryPersistence
    @ObservationIgnored private var persistenceRevision: UInt64 = 0
    @ObservationIgnored private var entriesRevision: UInt64 = 0
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
        self.persistence = PlaybackHistoryPersistence.writer(for: self.file)
        if let latest = persistence.latestEntries {
            entries = latest; entriesRevision = persistence.latestRevision
        } else if let data = try? Data(contentsOf: self.file), data.count <= 2 * 1024 * 1024,
           let decoded = try? JSONDecoder().decode([PlaybackHistoryEntry].self, from: data) {
            entries = Self.deduplicate(Array(decoded.filter { Self.valid($0) }))
        }
        prioritizeCaches()
    }

    /// Collapse near-duplicates saved under a cosmetically different origin (#2064), keeping the newest of
    /// each `dedupKey`. The persisted file may still hold the older exact-`id` lines; this trims them in memory.
    private static func deduplicate(_ entries: [PlaybackHistoryEntry]) -> [PlaybackHistoryEntry] {
        var seenExact = Set<String>()
        var kept = [String: PlaybackHistoryEntry]()
        let ordered = entries.sorted { ($0.updatedAt, $0.position) > ($1.updatedAt, $1.position) }
        let next = ordered.compactMap { entry -> PlaybackHistoryEntry? in
            guard seenExact.insert(entry.id).inserted else { return nil }
            if let existing = kept[entry.dedupKey], existing.updatedAt >= entry.updatedAt { return nil }
            kept[entry.dedupKey] = entry
            return entry
        }
        return Array(next.prefix(limit))
    }

    public func record(_ context: PlaybackHistoryContext, position: Double, duration: Double, now: Date = Date()) {
        refreshPendingEntries()
        guard position.isFinite, position >= 1, duration.isFinite, duration >= 0 else { return }
        // A real local playback change follows the history already seen, even when this device's clock is behind.
        // Sync uses this date, not the later time at which a delayed upload happens.
        let previous = entries.first { $0.id == context.id }
        let changedAt = previous.map { max(now, $0.updatedAt.addingTimeInterval(0.001)) } ?? now
        let entry = PlaybackHistoryEntry(context: context, position: duration > 0 ? min(position, duration) : position,
                                         duration: duration, updatedAt: changedAt)
        guard Self.valid(entry) else { return }
        if let old = previous, old.context == context,
           abs(old.position - entry.position) < 0.25, old.duration == duration { return }
        entries.removeAll { $0.id == entry.id }
        // A near-duplicate saved under a cosmetically different origin (a second device, or a
        // re-addressed subscription, #2064) loses to the one just recorded; its caches are dropped.
        entries.removeAll { item in
            guard item.dedupKey == entry.dedupKey, item.id != entry.id else { return false }
            clean(item)
            return true
        }
        entries.insert(entry, at: 0)
        let dropped = entries.dropFirst(Self.limit)
        for entry in dropped { clean(entry) }
        entries = Array(entries.prefix(Self.limit))
        persist()
        onChange?()
    }

    /// Another device's merged history. An entry that is no longer in it loses its caches as if removed here.
    public func adopt(_ synced: [PlaybackHistoryEntry]) {
        refreshPendingEntries()
        var seen = Set<String>()
        var seenNear = [String: PlaybackHistoryEntry]()
        let next = Array(synced.filter { Self.valid($0) }
            .sorted { ($0.updatedAt, $0.position) > ($1.updatedAt, $1.position) }
            .compactMap { entry in
                guard seen.insert(entry.id).inserted else { return nil }
                // Across devices the same title can sit under a cosmetically different origin (#2064);
                // keep the most recent of each near-duplicate and drop the rest, as if removed here.
                if let kept = seenNear[entry.dedupKey], kept.updatedAt >= entry.updatedAt { return nil }
                if let kept = seenNear[entry.dedupKey] { clean(kept) }
                seenNear[entry.dedupKey] = entry
                return entry
            }.prefix(Self.limit))
        let kept = Set(next.map(\.id))
        for entry in entries where !kept.contains(entry.id) { clean(entry) }
        entries = next
        persist()
    }

    /// Continue Watching of a subscription whose address changed (#982), under the new address.
    public func moveOrigin(from old: URL, to new: URL) {
        refreshPendingEntries()
        guard entries.contains(where: { $0.context.origin.absoluteString == old.absoluteString }) else { return }
        var seen = Set<String>()
        entries = entries.map { entry in
            guard entry.context.origin.absoluteString == old.absoluteString else { return entry }
            return PlaybackHistoryEntry(context: entry.context.moved(to: new), position: entry.position,
                                        duration: entry.duration, updatedAt: entry.updatedAt)
        }.filter { seen.insert($0.id).inserted }
        persist(); onChange?()
    }

    public func remove(_ id: String) { remove(Set([id])) }
    public func remove(_ ids: Set<String>) {
        refreshPendingEntries()
        for entry in entries where ids.contains(entry.id) { clean(entry) }
        entries.removeAll { ids.contains($0.id) }; persist(); onChange?()
    }
    public func clear() { refreshPendingEntries(); for entry in entries { clean(entry) }; entries.removeAll(); persist(); onChange?() }

    /// Watched titles whose source is not hidden.
    public func visibleEntries(hiding hidden: HiddenSources) -> [PlaybackHistoryEntry] {
        guard !hidden.isEmpty else { return entries }
        return entries.filter { !hidden.contains($0.context) }
    }
    private func prioritizeCaches() {
        persistence.prioritize(entries, cache: cache)
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
        persistenceRevision = persistence.enqueue(entries, cache: cache) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.persistenceRevision == result.revision,
                      self.persistence.latestRevision == result.revision else { return }
                self.persistenceError = result.error
            }
        }
        entriesRevision = persistenceRevision
    }

    private func refreshPendingEntries() {
        let revision = persistence.latestRevision
        guard revision != entriesRevision, let latest = persistence.latestEntries else { return }
        entries = latest
        entriesRevision = revision
    }

    /// Blocks until the snapshots submitted so far are written (or failed): for a Mac app that is quitting, which
    /// can't await `flushPersistence()`. Doesn't retry a failed write or update `persistenceError`.
    public func waitForPendingWrites() { persistence.waitForWrites() }

    /// Close/background/restore callers can await durable latest state without blocking rendering.
    /// Entries change immediately; `persistenceError` is updated when this drain completes.
    @discardableResult public func flushPersistence() async -> Bool {
        while true {
            let result = await persistence.flush()
            // A newer mutation may arrive before the main actor resumes after the drain.
            guard persistence.latestRevision == result.revision else { continue }
            persistenceError = result.error
            return result.error == nil
        }
    }
}

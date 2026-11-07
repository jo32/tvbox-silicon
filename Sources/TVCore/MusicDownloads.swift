import CryptoKit
import Foundation
import Observation

/// A song kept for listening offline: the audio from the channel that played it best, with its
/// lyrics and its cover.
public struct MusicDownload: Codable, Identifiable, Hashable, Sendable {
    public let track: MusicTrack
    public let created: Date
    public internal(set) var status: DownloadItem.Status = .queued
    public internal(set) var failure: String?
    public internal(set) var received: Int64 = 0
    public internal(set) var expected: Int64?
    /// Where the audio came from and what it is, read from the file as for streaming.
    public internal(set) var candidate: MusicCandidate?
    public internal(set) var probe: MusicProbeResult?
    /// The audio file, relative to the song's folder.
    public internal(set) var media: String?
    /// Bytes on disk once finished.
    public internal(set) var size: Int64 = 0
    public internal(set) var finished: Date?

    public var id: String { track.id }
    /// 0...1 by bytes; 0 until the size is known.
    public var fraction: Double {
        if status == .completed { return 1 }
        guard let expected, expected > 0 else { return 0 }
        return min(1, Double(received) / Double(expected))
    }
    public var isActive: Bool { status == .downloading || status == .finishing }
    /// Not finished: running, waiting or failed.
    public var isPending: Bool { status != .completed }
}

/// An album or playlist downloaded as a whole: its songs in their order, so Downloaded Songs can
/// list it again. A song kept by two of them is saved once.
public struct MusicDownloadedCollection: Codable, Identifiable, Hashable, Sendable {
    public internal(set) var collection: MusicCollection
    public internal(set) var trackIDs: [String]
    public internal(set) var added: Date
    public var id: String { collection.id }
}

/// Downloaded songs and the queue that fetches them, beside the episode downloads. Each song is
/// resolved as playing it would be (best channel, lossless first) and saved by the same transfer
/// as an episode, so a stopped download continues and an expired link is resolved again.
@MainActor @Observable public final class MusicDownloadLibrary {
    public static let shared = MusicDownloadLibrary()
    /// A song is one file, so a couple at a time is enough to keep the connection busy.
    static let simultaneous = 2

    public private(set) var items: [MusicDownload] = []
    /// Albums and playlists downloaded from their pages, most recent first.
    public private(set) var collections: [MusicDownloadedCollection] = []
    public let root: URL
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var running: [String: (run: UUID, task: Task<Void, Never>, meter: DownloadMeter)] = [:]
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var savedAt = Date.distantPast
    /// Called each time a download starts running. The iOS app uses it to keep downloads going in the background.
    @ObservationIgnored public var onStart: (@MainActor () -> Void)?

    public init(root: URL = MusicDownloadLibrary.defaultRoot) {
        self.root = root
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #if os(iOS)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var folder = root; try? folder.setResourceValues(values)
        #endif
        load()
        Task { @MainActor in self.schedule() }
    }

    /// Inside the episode downloads' folder, so the system keeps (or on tvOS clears) both alike.
    public nonisolated static var defaultRoot: URL { DownloadLibrary.defaultRoot.appending(path: "Music") }

    public var completed: [MusicDownload] { items.filter { $0.status == .completed } }
    public var pending: [MusicDownload] { items.filter(\.isPending) }
    /// Bytes the finished songs take.
    public var size: Int64 { completed.reduce(0) { $0 + $1.size } }

    public func item(for track: MusicTrack) -> MusicDownload? { item(id: track.id) }
    public func item(id: String) -> MusicDownload? { items.first { $0.id == id } }
    public func collection(id: String) -> MusicDownloadedCollection? { collections.first { $0.id == id } }
    /// An album's or playlist's songs that are saved or on their way, in its order.
    public func items(in collection: MusicDownloadedCollection) -> [MusicDownload] { collection.trackIDs.compactMap { item(id: $0) } }
    /// Songs on their way that are paused, and none running or waiting: Resume All rather than Pause All.
    public var isPaused: Bool {
        pending.contains { $0.status == .paused } && !pending.contains { $0.status == .queued || $0.isActive }
    }

    // MARK: Queue

    /// Queues the songs not saved yet, in order; failed and paused ones are tried again. Songs from an
    /// album's or playlist's page remember it, so Downloaded Songs lists it with them.
    public func download(_ tracks: [MusicTrack], from collection: MusicCollection? = nil) {
        if let collection {
            collections.removeAll { $0.id == collection.id }
            collections.insert(MusicDownloadedCollection(collection: collection, trackIDs: tracks.map(\.id), added: Date()), at: 0)
            saveCollections()
        }
        for track in tracks {
            if let existing = item(for: track) {
                if existing.status == .failed || existing.status == .paused { update(existing.id) { $0.status = .queued; $0.failure = nil } }
                continue
            }
            items.append(MusicDownload(track: track, created: Date()))
        }
        save(); schedule()
    }

    /// Puts a failed download back in the queue.
    public func retry(_ id: String) {
        guard let item = item(id: id), item.status == .failed || item.status == .paused else { return }
        update(id) { $0.status = .queued; $0.failure = nil }
        save(); schedule()
    }

    /// Stops and deletes songs, saved or not, with covers no other saved song shows.
    public func remove(_ ids: [String]) {
        let covers = Set(items.filter { ids.contains($0.id) }.compactMap(\.track.artwork))
        for id in ids {
            stop(id)
            try? FileManager.default.removeItem(at: folder(id))
        }
        items.removeAll { ids.contains($0.id) }
        let kept = Set(items.compactMap(\.track.artwork))
        for cover in covers.subtracting(kept) { try? FileManager.default.removeItem(at: Self.artworkFile(for: cover)) }
        // An album or playlist goes once none of its songs is left.
        let removed = Set(ids)
        collections = collections.compactMap { entry in
            var entry = entry
            entry.trackIDs.removeAll { removed.contains($0) }
            return entry.trackIDs.isEmpty ? nil : entry
        }
        save(); saveCollections(); schedule()
    }

    /// Removes an album or playlist with its songs, except those another saved one also keeps.
    public func remove(collection id: String) {
        guard let entry = collection(id: id) else { return }
        collections.removeAll { $0.id == id }
        let shared = Set(collections.flatMap(\.trackIDs))
        remove(entry.trackIDs.filter { !shared.contains($0) })
    }

    /// Forgets saved songs whose file is gone: deleted or moved away in Finder, or cleared by tvOS to
    /// free space. They play from the network again and can be downloaded again.
    public func forgetMissing() {
        let missing = items.filter { $0.status == .completed && !hasMedia($0) }.map(\.id)
        if !missing.isEmpty { remove(missing) }
    }

    /// Stops every song on its way and keeps it paused, also after a relaunch, until `resumeAll()`.
    public func pauseAll() {
        for item in items where item.status == .queued || item.isActive {
            stop(item.id)
            update(item.id) { $0.status = .paused }
        }
        save(); schedule()
    }

    /// Puts every failed song back in the queue.
    public func retryFailed() {
        for item in items where item.status == .failed { update(item.id) { $0.status = .queued; $0.failure = nil } }
        save(); schedule()
    }

    /// Puts paused songs back in the queue; they continue from where they stopped.
    public func resumeAll() {
        for item in items where item.status == .paused { update(item.id) { $0.status = .queued } }
        save(); schedule()
    }

    /// Stops running downloads without failing them, for when the app goes to the background:
    /// they continue from where they were on `wake()`.
    public func suspend() {
        for id in running.keys { stop(id); update(id) { $0.status = .queued } }
        save()
    }
    public func wake() { schedule() }

    private func schedule() {
        for item in items where item.status == .queued {
            guard running.count < Self.simultaneous else { break }
            start(item.id)
        }
        if running.isEmpty { ticker?.cancel(); ticker = nil }
        else if ticker == nil {
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    self?.tick()
                }
            }
        }
    }

    private func start(_ id: String) {
        guard let track = item(id: id)?.track else { return }
        let run = UUID(), meter = DownloadMeter(), folder = folder(id)
        update(id) { $0.status = .downloading; $0.failure = nil }
        let transfer = Transfer(folder: folder, meter: meter, session: session, resolve: { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.resolve(id, run: run)
        }, note: { [weak self] note in
            await self?.apply(note, to: id, run: run)
        })
        let task = Task { [weak self] in
            do {
                let media = try await transfer.run()
                // Lyrics and the cover are extras: the song is saved without them if they fail.
                let platform = self?.item(id: id)?.candidate?.platform
                if let lyrics = await MusicLyricsLoader().lyrics(for: track, playing: platform), let data = try? JSONEncoder().encode(lyrics) {
                    try? data.write(to: folder.appending(path: "lyrics.json"), options: .atomic)
                }
                await Self.saveArtwork(track.artwork)
                let size = DownloadLibrary.allocatedSize(folder)
                self?.finish(id, run: run) { $0.status = .completed; $0.media = media; $0.size = size; $0.finished = Date(); $0.received = size }
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                Diagnostics.shared.failure("music", "download failed", error)
                self?.finish(id, run: run) { $0.status = .failed; $0.failure = error.localizedDescription }
            }
        }
        running[id] = (run, task, meter)
        onStart?()
    }

    /// Finds the song's channel now, as playing it would, and remembers which it was. The
    /// transfer asks again when the address expires.
    private func resolve(_ id: String, run: UUID) async throws -> Channel {
        guard let track = item(id: id)?.track else { throw CancellationError() }
        let preferences = MusicPreferences.load()
        let selection = try await MusicResolver(preferences: preferences).select(track, preference: preferences.quality)
        guard running[id]?.run == run else { throw CancellationError() }
        update(id) { $0.candidate = selection.candidate; $0.probe = selection.probe }
        Diagnostics.shared.record(.info, "music", "download \(selection.candidate.provider.rawValue) \(selection.probe.format.label)")
        return Channel(name: track.title, url: selection.stream.url, headers: selection.stream.headers)
    }

    private func apply(_ note: TransferNote, to id: String, run: UUID) {
        guard running[id]?.run == run else { return }
        switch note {
        case .prepared(let plan): update(id) { $0.expected = plan.expected }; tick()
        case .finishing: update(id) { $0.status = .finishing }
        }
    }

    private func finish(_ id: String, run: UUID, _ change: (inout MusicDownload) -> Void) {
        guard running[id]?.run == run else { return }
        tick()
        running[id] = nil
        update(id, change)
        save(); schedule()
    }

    private func stop(_ id: String) {
        running[id]?.task.cancel()
        running[id] = nil
    }

    private func tick() {
        for (id, entry) in running {
            let value = entry.meter.snapshot
            update(id) { item in
                item.received = value.received
                if let expected = value.expected { item.expected = expected }
            }
        }
        if Date().timeIntervalSince(savedAt) > 5 { save() }
    }

    private func update(_ id: String, _ change: (inout MusicDownload) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    // MARK: Playback

    /// The saved file as the song's channel, when it is on this device.
    public func localSelection(for track: MusicTrack) -> MusicPlaybackSelection? {
        guard let item = item(for: track), item.status == .completed, let media = item.media,
              let candidate = item.candidate, let probe = item.probe else { return nil }
        let file = folder(item.id).appending(path: media)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return MusicPlaybackSelection(track: track, candidate: candidate, stream: ResolvedMusicStream(url: file), probe: probe,
                                      degraded: !probe.format.isLossless, attempts: [], untried: [])
    }

    /// The lyrics saved with a song, if it had any.
    public func lyrics(for track: MusicTrack) -> MusicLyrics? {
        guard item(for: track)?.status == .completed,
              let data = try? Data(contentsOf: folder(track.id).appending(path: "lyrics.json")) else { return nil }
        return try? JSONDecoder().decode(MusicLyrics.self, from: data)
    }

    /// Where a saved song's cover is kept, by its address; the artwork loader looks here before
    /// the network. Songs of one album share it.
    public nonisolated static func artworkFile(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return defaultRoot.appending(path: "Artwork").appending(path: digest)
    }

    private nonisolated static func saveArtwork(_ url: URL?) async {
        guard let url else { return }
        let file = artworkFile(for: url)
        guard !FileManager.default.fileExists(atPath: file.path), let data = try? await HTTPClient().get(url).0 else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    // MARK: Persistence

    /// Song IDs hold ":"; the folder name keeps only letters and digits plain.
    func folder(_ id: String) -> URL { root.appending(path: id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id) }
    private var index: URL { root.appending(path: "music-downloads.json") }
    private var collectionIndex: URL { root.appending(path: "music-collections.json") }
    private func hasMedia(_ item: MusicDownload) -> Bool {
        guard let media = item.media else { return false }
        return FileManager.default.fileExists(atPath: folder(item.id).appending(path: media).path)
    }

    private func load() {
        if let data = try? Data(contentsOf: collectionIndex), let stored = try? JSONDecoder().decode([MusicDownloadedCollection].self, from: data) {
            collections = stored
        }
        guard let data = try? Data(contentsOf: index), let stored = try? JSONDecoder().decode([MusicDownload].self, from: data) else { return }
        items = stored.compactMap { item in
            var item = item
            if item.status == .completed {
                // tvOS may have cleared the folder to free space, or the file was moved away.
                guard hasMedia(item) else { return nil }
            } else if item.isActive {
                item.status = .queued
            }
            return item
        }
        let kept = Set(items.map(\.id))
        collections = collections.compactMap { entry in
            var entry = entry
            entry.trackIDs.removeAll { !kept.contains($0) }
            return entry.trackIDs.isEmpty ? nil : entry
        }
    }

    private func save() {
        savedAt = Date()
        guard let data = try? JSONEncoder().encode(items) else { return }
        // The folder itself may have been deleted in Finder.
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: index, options: .atomic)
    }

    private func saveCollections() {
        guard let data = try? JSONEncoder().encode(collections) else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: collectionIndex, options: .atomic)
    }
}

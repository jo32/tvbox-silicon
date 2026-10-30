import Foundation
import Observation

/// Where a download came from: enough to resolve the episode again when its links expire.
public struct DownloadSource: Codable, Hashable, Sendable {
    public let siteKey: String
    public let siteName: String
    public let videoID: String
    public let episodeID: String
    public let episodeName: String
    public let address: String
    public let flag: String
    public let detailID: String?
    public init(site: Site, videoID: String, episode: Episode) {
        siteKey = site.key; siteName = site.name; self.videoID = videoID
        episodeID = episode.id; episodeName = episode.name; address = episode.address; flag = episode.flag; detailID = episode.videoID
    }
    public var episode: Episode { Episode(id: episodeID, name: episodeName, address: address, flag: flag, videoID: detailID) }
    /// The same episode, on the same source and line.
    public var key: String { [siteKey, videoID, flag, episodeID].joined(separator: "\u{1F}") }
}

public struct DownloadItem: Codable, Identifiable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// Waiting for a free slot in the queue.
        case queued
        case downloading
        /// Joining or writing the final file.
        case finishing
        case paused, completed, failed
    }
    public enum Kind: String, Codable, Sendable { case file, hls, dash }
    public let id: String
    public let title: String
    public let episode: String
    public let poster: URL?
    public let posterHeaders: [String: String]
    public let source: DownloadSource
    public let created: Date
    public internal(set) var status: Status = .queued
    public internal(set) var failure: String?
    public internal(set) var kind: Kind?
    /// Quality label ("1080P") when the source names one.
    public internal(set) var quality: String?
    public internal(set) var received: Int64 = 0
    /// Total bytes: exact for files, estimated from finished segments for HLS.
    public internal(set) var expected: Int64?
    public internal(set) var completedParts = 0
    public internal(set) var totalParts = 0
    /// The playable file, relative to the download's folder.
    public internal(set) var media: String?
    /// Bytes on disk once finished.
    public internal(set) var size: Int64 = 0
    public internal(set) var finished: Date?
    public internal(set) var cid: String?
    public internal(set) var duration: Double?

    /// 0...1, by bytes where the total is known, else by pieces.
    public var fraction: Double {
        if status == .completed { return 1 }
        if kind != .hls, let expected, expected > 0 { return min(1, Double(received) / Double(expected)) }
        return totalParts > 0 ? Double(completedParts) / Double(totalParts) : 0
    }
    public var isActive: Bool { status == .downloading || status == .finishing }
    /// Not finished: running, waiting, paused or failed.
    public var isPending: Bool { status != .completed }
}

/// Downloaded episodes and the queue that fetches them. A fixed number of downloads run at once
/// (`simultaneous`); the rest wait in order. Progress survives pausing, quitting and expired links:
/// each download keeps its finished pieces on disk and resolves the episode again when needed.
@MainActor @Observable public final class DownloadLibrary {
    public static let shared = DownloadLibrary()
    /// Addresses of downloaded episodes for the player: `tvbox-download://<id>`.
    public static let scheme = "tvbox-download"

    public private(set) var items: [DownloadItem] = []
    /// Bytes per second for each running download, smoothed over a few seconds.
    public private(set) var rates: [String: Double] = [:]
    /// Disk use, refreshed by `measure()`.
    public private(set) var usage = Usage()
    public struct Usage: Sendable, Equatable {
        public var downloads: Int64 = 0
        public var available: Int64?
        public var capacity: Int64?
    }
    /// How many downloads run at once, 1 to 4.
    public var simultaneous: Int {
        didSet {
            // @Observable runs didSet again for an assignment made inside it, so only assign when clamping.
            let clamped = min(max(simultaneous, 1), 4)
            guard clamped == simultaneous else { simultaneous = clamped; return }
            defaults.set(simultaneous, forKey: "downloadsSimultaneous")
            schedule()
        }
    }
    /// Resolves an episode to its current media address; set by the app, which knows the sources.
    @ObservationIgnored public var resolver: (@MainActor @Sendable (DownloadItem) async throws -> Channel)?

    public let root: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var running: [String: (run: UUID, task: Task<Void, Never>, meter: DownloadMeter)] = [:]
    @ObservationIgnored private var samples: [String: (date: Date, bytes: Int64)] = [:]
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var savedAt = Date.distantPast

    public init(root: URL = DownloadLibrary.defaultRoot, defaults: UserDefaults = .standard) {
        self.root = root; self.defaults = defaults
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
        let stored = defaults.integer(forKey: "downloadsSimultaneous")
        simultaneous = stored > 0 ? min(stored, 4) : 2
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #if os(iOS)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var folder = root; try? folder.setResourceValues(values)
        #endif
        load()
        // Downloads that were running when the app quit wait for the app to set `resolver`.
        Task { @MainActor in self.schedule() }
    }

    /// tvOS gives apps no lasting storage besides Caches, which the system may clear when space runs low.
    public nonisolated static var defaultRoot: URL {
        #if os(tvOS)
        URL.cachesDirectory.appending(path: "Downloads")
        #elseif os(macOS)
        URL.applicationSupportDirectory.appending(path: Bundle.main.bundleIdentifier ?? "Yingxia").appending(path: "Downloads")
        #else
        URL.applicationSupportDirectory.appending(path: "Downloads")
        #endif
    }

    // MARK: Queue

    /// Adds an episode to the queue. Already downloaded or queued episodes are left as they are;
    /// a failed one is retried. Returns the episode's download.
    @discardableResult
    public func download(_ source: DownloadSource, title: String, poster: URL?, posterHeaders: [String: String] = [:]) -> DownloadItem {
        if let existing = item(for: source) {
            if existing.status == .failed || existing.status == .paused { resume(existing.id) }
            return existing
        }
        let item = DownloadItem(id: UUID().uuidString.lowercased(), title: title, episode: source.episodeName, poster: poster,
                                posterHeaders: posterHeaders, source: source, created: Date())
        items.append(item)
        save()
        schedule()
        return item
    }

    public func item(for source: DownloadSource) -> DownloadItem? { items.first { $0.source.key == source.key } }
    public func item(id: String) -> DownloadItem? { items.first { $0.id == id } }

    public func pause(_ id: String) {
        guard let item = item(id: id), item.isPending, item.status != .failed else { return }
        stop(id)
        update(id) { $0.status = .paused }
        save(); schedule()
    }

    /// Puts a paused or failed download back in the queue.
    public func resume(_ id: String) {
        guard let item = item(id: id), item.status == .paused || item.status == .failed else { return }
        update(id) { $0.status = .queued; $0.failure = nil }
        save(); schedule()
    }

    /// Moves a waiting download to the front of the queue.
    public func prioritize(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].status == .queued,
              let first = items.firstIndex(where: { $0.status == .queued }), first < index else { return }
        items.insert(items.remove(at: index), at: first)
        save()
    }

    public func remove(_ ids: [String]) {
        for id in ids {
            stop(id)
            try? FileManager.default.removeItem(at: folder(id))
        }
        items.removeAll { ids.contains($0.id) }
        save(); schedule()
        Task { await measure() }
    }

    public func pauseAll() {
        for item in items where item.status == .queued || item.isActive { stop(item.id); update(item.id) { $0.status = .paused } }
        save()
    }

    public func resumeAll() {
        for item in items where item.status == .paused || item.status == .failed { update(item.id) { $0.status = .queued; $0.failure = nil } }
        save(); schedule()
    }

    /// Stops running downloads without pausing them, for when the app goes to the background:
    /// they continue from where they were on `wake()`.
    public func suspend() {
        for id in running.keys { stop(id); update(id) { $0.status = .queued } }
        save()
    }
    public func wake() { schedule() }

    /// Starts waiting downloads, oldest first, while fewer than `simultaneous` run.
    private func schedule() {
        guard resolver != nil else { return }
        for item in items where item.status == .queued {
            guard running.count < simultaneous else { break }
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
        let run = UUID(), meter = DownloadMeter()
        update(id) { $0.status = .downloading; $0.failure = nil }
        let folder = folder(id)
        let transfer = Transfer(folder: folder, meter: meter, session: session, resolve: { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.resolve(id)
        }, note: { [weak self] note in
            await self?.apply(note, to: id, run: run)
        })
        let task = Task { [weak self] in
            do {
                let media = try await transfer.run()
                let size = Self.allocatedSize(folder)
                self?.finish(id, run: run) { $0.status = .completed; $0.media = media; $0.size = size; $0.finished = Date(); $0.received = size }
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                Diagnostics.shared.failure("download", "failed id=\(id)", error)
                self?.finish(id, run: run) { $0.status = .failed; $0.failure = error.localizedDescription }
            }
        }
        running[id] = (run, task, meter)
    }

    private func resolve(_ id: String) async throws -> Channel {
        guard let resolver, let item = item(id: id) else { throw CancellationError() }
        return try await resolver(item)
    }

    private func apply(_ note: TransferNote, to id: String, run: UUID) {
        guard running[id]?.run == run else { return }
        switch note {
        case .prepared(let plan):
            update(id) {
                $0.kind = DownloadItem.Kind(rawValue: plan.kind.rawValue)
                $0.quality = plan.label; $0.cid = plan.cid; $0.duration = plan.duration
                $0.expected = plan.expected
            }
            tick()
        case .finishing:
            update(id) { $0.status = .finishing }
        }
    }

    private func finish(_ id: String, run: UUID, _ change: (inout DownloadItem) -> Void) {
        guard running[id]?.run == run else { return }
        tick()
        running[id] = nil; samples[id] = nil; rates[id] = nil
        update(id, change)
        save(); schedule()
        Task { await measure() }
    }

    private func stop(_ id: String) {
        running[id]?.task.cancel()
        running[id] = nil; samples[id] = nil; rates[id] = nil
    }

    /// Copies running downloads' counters into their items and works out speeds.
    private func tick() {
        let now = Date()
        for (id, entry) in running {
            let value = entry.meter.snapshot
            update(id) { item in
                item.received = value.received; item.completedParts = value.parts; item.totalParts = value.total
                if item.kind == .hls, value.parts > 0, value.total > 0 {
                    item.expected = Int64(Double(value.received) / Double(value.parts) * Double(value.total))
                } else if let expected = value.expected { item.expected = expected }
            }
            if let last = samples[id], now.timeIntervalSince(last.date) > 0.5 {
                let rate = max(0, Double(value.received - last.bytes) / now.timeIntervalSince(last.date))
                rates[id] = rates[id].map { $0 * 0.6 + rate * 0.4 } ?? rate
            }
            samples[id] = (now, value.received)
        }
        if now.timeIntervalSince(savedAt) > 5 { save() }
    }

    private func update(_ id: String, _ change: (inout DownloadItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    // MARK: Playback

    /// What the player opens for a finished download.
    public func channel(for item: DownloadItem) -> Channel {
        Channel(name: "\(item.title) · \(item.episode)", group: L10n.text("Downloads"), url: URL(string: "\(Self.scheme)://\(item.id)")!)
    }

    /// The file (or, for HLS, the loopback address) that plays a `tvbox-download://` address. An HDR MKV saved
    /// before downloads became MP4s is rewrapped first, which `progress` follows (0...1).
    public func playbackAddress(for url: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        guard url.scheme == Self.scheme, let id = url.host(), let item = item(id: id), item.status == .completed, var media = item.media else {
            throw TVError.unsupported(L10n.text("This download is no longer on this device."))
        }
        var file = folder(id).appending(path: media)
        guard FileManager.default.fileExists(atPath: file.path) else {
            // Deleted or moved away in Finder: stop listing it as downloaded.
            remove([id])
            throw TVError.unsupported(L10n.text("This download is no longer on this device."))
        }
        if Remux.handles(name: media) {
            let rewrapped = await Self.rewrap(media, in: folder(id), progress: progress)
            try Task.checkCancellation()
            if rewrapped != media {
                media = rewrapped
                file = folder(id).appending(path: media)
                let size = Self.allocatedSize(folder(id))
                update(id) { $0.media = rewrapped; $0.size = size }
                save()
            }
        }
        if let cid = item.cid { DanmakuSource.register(url, bilibiliCID: cid, duration: item.duration) }
        if media.hasSuffix(".m3u8") { return try await LocalMediaServer.shared.address(of: file, root: root) }
        return file
    }

    // MARK: Storage

    /// A finished download's playable file, for showing it in Finder.
    public func file(for item: DownloadItem) -> URL? {
        guard item.status == .completed, let media = item.media else { return nil }
        return folder(item.id).appending(path: media)
    }

    /// Forgets finished downloads whose file is gone: deleted or moved away in Finder, or cleared by
    /// tvOS to free space. They would otherwise stay listed and fail to play.
    public func forgetMissing() {
        let missing = items.filter { $0.status == .completed && !hasMedia($0) }.map(\.id)
        if !missing.isEmpty { remove(missing) }
    }

    /// Measures the downloads on disk and the space left on the device.
    public func measure() async {
        forgetMissing()
        let root = root, ids = items.map(\.id)
        let sizes = await Task.detached { ids.map { (id: $0, size: Self.allocatedSize(root.appending(path: $0))) } }.value
        for entry in sizes {
            if let item = item(id: entry.id), item.status == .completed { update(entry.id) { $0.size = entry.size } }
        }
        let values = try? root.resourceValues(forKeys: [.volumeTotalCapacityKey])
        usage = Usage(downloads: sizes.reduce(0) { $0 + $1.size }, available: Self.availableCapacity(at: root),
                      capacity: values?.volumeTotalCapacity.map(Int64.init))
    }

    nonisolated static func availableCapacity(at url: URL) -> Int64? {
        var url = url
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 { url.deleteLastPathComponent() }
        #if os(tvOS)
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity).map(Int64.init)
        #else
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? values?.volumeAvailableCapacity.map(Int64.init)
        #endif
    }

    /// Keeps a downloaded HDR MKV as an MP4 that AVPlayer opens itself (see `Rewrap`) and returns the playable
    /// file's name. The MKV stays when no MP4 is needed, there is no room for one, or writing it fails.
    nonisolated static func rewrap(_ name: String, in folder: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async -> String {
        guard Remux.handles(name: name) else { return name }
        let source = folder.appending(path: name), target = folder.appending(path: rewrappedName)
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let began = Date()
        do {
            if let free = availableCapacity(at: folder), size + (64 << 20) > free {
                // Probed first: an SDR file needs no room.
                guard try await Rewrap.needed(source) else { return name }
                Diagnostics.shared.record(.warning, "download", "rewrap skipped size=\(size) free=\(free)")
                return name
            }
            guard let selection = try await Rewrap.run(source, to: target, progress: progress) else { return name }
            try FileManager.default.removeItem(at: source)
            Diagnostics.shared.record(.info, "download", "rewrap mp4 streams=\(selection.streams.map(\.codec)) dropped=\(selection.dropped.map(\.codec)) size=\(size) s=\(Int(Date().timeIntervalSince(began)))")
            return rewrappedName
        } catch {
            try? FileManager.default.removeItem(at: target)
            if !(error is CancellationError) { Diagnostics.shared.failure("download", "rewrap", error) }
            return name
        }
    }
    /// The MP4 a downloaded MKV becomes.
    nonisolated static let rewrappedName = "media.mp4"

    nonisolated static func allocatedSize(_ folder: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            let values = try? file.resourceValues(forKeys: Set(keys))
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }

    // MARK: Persistence

    private func folder(_ id: String) -> URL { root.appending(path: id) }
    private var index: URL { root.appending(path: "downloads.json") }
    private func hasMedia(_ item: DownloadItem) -> Bool {
        guard let media = item.media else { return false }
        return FileManager.default.fileExists(atPath: folder(item.id).appending(path: media).path)
    }

    private func load() {
        guard let data = try? Data(contentsOf: index), let stored = try? JSONDecoder().decode([DownloadItem].self, from: data) else { return }
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
    }

    private func save() {
        savedAt = Date()
        guard let data = try? JSONEncoder().encode(items) else { return }
        // The folder itself may have been deleted in Finder.
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: index, options: .atomic)
    }
}

import Foundation
import Observation

/// The songs to play, in order, and where playback is in them: one song from search, or an album
/// or playlist from the chosen track on.
public struct MusicQueue: Codable, Equatable, Sendable {
    public private(set) var tracks: [MusicTrack]
    public private(set) var index: Int
    /// What the queue was started from, such as an album's title; nil for a single song.
    public var source: String?
    /// The album or playlist it plays, which the history records instead of each song.
    public var collection: MusicCollection?

    public init(tracks: [MusicTrack], start: Int = 0, source: String? = nil, collection: MusicCollection? = nil) {
        self.tracks = tracks
        index = tracks.isEmpty ? 0 : min(max(0, start), tracks.count - 1)
        self.source = source ?? collection?.title
        self.collection = collection
    }

    /// The same tracks in random order, starting with `first` when given.
    public static func shuffled(_ tracks: [MusicTrack], first: MusicTrack? = nil, source: String? = nil, collection: MusicCollection? = nil) -> MusicQueue {
        var order = tracks.shuffled()
        if let first, let at = order.firstIndex(of: first) { order.swapAt(0, at) }
        return MusicQueue(tracks: order, start: 0, source: source, collection: collection)
    }

    public var current: MusicTrack? { tracks.indices.contains(index) ? tracks[index] : nil }
    public var hasNext: Bool { index + 1 < tracks.count }
    public var hasPrevious: Bool { index > 0 }

    @discardableResult public mutating func advance() -> MusicTrack? {
        guard hasNext else { return nil }
        index += 1
        return current
    }

    @discardableResult public mutating func back() -> MusicTrack? {
        guard hasPrevious else { return nil }
        index -= 1
        return current
    }

    @discardableResult public mutating func jump(to position: Int) -> MusicTrack? {
        guard tracks.indices.contains(position) else { return nil }
        index = position
        return current
    }

    /// Puts `new` right after the current song.
    public mutating func insertNext(_ new: [MusicTrack]) {
        tracks.insert(contentsOf: new, at: tracks.isEmpty ? 0 : index + 1)
    }

    /// Puts `new` at the end.
    public mutating func append(_ new: [MusicTrack]) { tracks.append(contentsOf: new) }

    /// After a song that would not play, move on, unless several in a row failed: then the
    /// channels are down, and skipping on would only spend requests.
    public static let failuresBeforeStopping = 3
    /// `wraps` when the whole queue repeats: the last song's failure moves on to the first.
    public func skipsAfterFailure(consecutive failures: Int, wraps: Bool = false) -> Bool {
        (hasNext || wraps && tracks.count > 1) && failures < Self.failuresBeforeStopping
    }

    /// The same for one failure. With no channel at all (`noChannels` and nothing was asked) every song fails the same
    /// way, so the queue stops at once. When LX Music sources were asked and had nothing for this song, the next song may
    /// well play: move on, and the limit above still stops a set of sources that are all down (#1206).
    public func skipsAfterFailure(_ error: MusicProviderError, consecutive failures: Int, channelsAsked: Bool, wraps: Bool = false) -> Bool {
        (error != .noChannels || channelsAsked) && skipsAfterFailure(consecutive: failures, wraps: wraps)
    }

    /// A song that channels turned down only because their request budgets ran out plays once the budgets free up, a few
    /// seconds to a few minutes later. Skipping it, as before, spent three songs in a row on the same wait and then
    /// stopped the queue (#1309). How long to wait before asking again, or nil to treat it as any other failure: the
    /// wait would be too long, or the song already waited `budgetRetries` times.
    public static let longestBudgetWait: TimeInterval = 90
    public static let budgetRetries = 2
    public static func budgetWait(after error: MusicProviderError, retries: Int, now: Date = Date()) -> TimeInterval? {
        guard case .rateLimited(let until) = error, retries < budgetRetries else { return nil }
        // A channel that gave no time is asked again after half a minute.
        let wait = max(2, (until ?? now.addingTimeInterval(30)).timeIntervalSince(now) + 1)
        return wait <= longestBudgetWait ? wait : nil
    }

    /// "Previous" restarts the song once it has played a few seconds, as players do.
    public static let restartThreshold: Double = 3
}

/// Whether the queue plays once, again from the top, or the same song again; stored by the player.
public enum MusicRepeatMode: String, CaseIterable, Sendable {
    case off, all, one
    public var next: MusicRepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }
    public var symbol: String { self == .one ? "repeat.1" : "repeat" }
    public var label: String {
        switch self {
        case .off: L10n.text("Repeat Off")
        case .all: L10n.text("Repeat All")
        case .one: L10n.text("Repeat One")
        }
    }
}

/// Where listening stopped, to continue from: the queue and the second within its current song.
public struct MusicResumePoint: Codable, Equatable, Sendable {
    public var queue: MusicQueue
    public var position: Double
    public var savedAt: Date
    public init(queue: MusicQueue, position: Double, savedAt: Date = Date()) {
        self.queue = queue; self.position = position; self.savedAt = savedAt
    }
}

/// A song played on its own, or an album or playlist played from its page.
public struct MusicHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public var track: MusicTrack?
    public var collection: MusicCollection?
    public var playedAt: Date
    public var id: String { collection?.id ?? track?.id ?? "" }
}

/// Songs played recently, newest first, and where to continue: kept in one file.
@MainActor @Observable public final class MusicLibrary {
    public static let shared = MusicLibrary(file: MusicLibrary.directory.appending(path: "music-library.json"))
    /// tvOS only keeps app files in Caches, as for subscriptions.
    static var directory: URL {
        #if os(tvOS)
        URL.cachesDirectory
        #else
        URL.applicationSupportDirectory
        #endif
    }
    public static let historyLimit = 200

    public private(set) var history: [MusicHistoryEntry] = []
    public private(set) var resumePoint: MusicResumePoint?
    private let file: URL?
    private var saveTask: Task<Void, Never>?

    private struct Saved: Codable {
        var history: [MusicHistoryEntry]
        var resumePoint: MusicResumePoint?
    }

    public init(file: URL?) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            history = saved.history; resumePoint = saved.resumePoint
        }
    }

    /// A song started playing on its own: it moves to the top, once.
    public func recordPlay(_ track: MusicTrack, at date: Date = Date()) {
        record(MusicHistoryEntry(track: track, playedAt: date))
    }

    /// A song of an album or playlist started playing: the album or playlist moves to the top.
    public func recordPlay(_ collection: MusicCollection, at date: Date = Date()) {
        record(MusicHistoryEntry(collection: collection, playedAt: date))
    }

    private func record(_ entry: MusicHistoryEntry) {
        history.removeAll { $0.id == entry.id }
        history.insert(entry, at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        scheduleSave()
    }

    public func remove(_ entry: MusicHistoryEntry) {
        history.removeAll { $0.id == entry.id }
        scheduleSave()
    }

    /// Clears what the Music page lists as recent: the played entries and the Continue Playing card above them (#718).
    public func clearHistory() {
        history = []
        resumePoint = nil
        scheduleSave()
    }

    public func saveResumePoint(_ point: MusicResumePoint?) {
        guard point != resumePoint else { return }
        resumePoint = point
        scheduleSave()
    }

    /// Writes after a short pause, so frequent position updates save once.
    private func scheduleSave() {
        guard let file, saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            self.saveTask = nil
            self.saveNow(to: file)
        }
    }

    /// For leaving the app, when a delayed write might not happen.
    public func flush() {
        saveTask?.cancel(); saveTask = nil
        if let file { saveNow(to: file) }
    }

    private func saveNow(to file: URL) {
        guard let data = try? JSONEncoder().encode(Saved(history: history, resumePoint: resumePoint)) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

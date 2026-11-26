import Foundation

/// One utility worker per file. The lock only protects snapshots/revisions, never encoding,
/// cache locks or disk I/O. At most one running and one latest pending snapshot are retained.
final class PlaybackHistoryPersistence: @unchecked Sendable {
    struct Result: Sendable { let revision: UInt64; let error: String? }
    private struct Save: Sendable {
        let revision: UInt64
        let entries: [PlaybackHistoryEntry]
        let cache: MediaCache
        let completed: @Sendable (Result) -> Void
    }
    private final class WeakWriter {
        weak var value: PlaybackHistoryPersistence?
        init(_ value: PlaybackHistoryPersistence) { self.value = value }
    }
    @MainActor private static var writers: [URL: WeakWriter] = [:]
    @MainActor static func writer(for file: URL) -> PlaybackHistoryPersistence {
        let key = file.standardizedFileURL
        if let writer = writers[key]?.value { return writer }
        writers = writers.filter { $0.value.value != nil }
        let writer = PlaybackHistoryPersistence(file: key)
        writers[key] = WeakWriter(writer)
        return writer
    }

    private let file: URL
    private let queue = DispatchQueue(label: "tvbox.history.persistence", qos: .utility)
    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var latest: Save?
    private var pending: Save?
    private var running = false
    private var result = Result(revision: 0, error: nil)
    private var waiters: [CheckedContinuation<Result, Never>] = []
    // Accessed only on the utility queue, including initial cache prioritization.
    private var prioritized: [ObjectIdentifier: Set<String>] = [:]
    private init(file: URL) { self.file = file }

    /// An instance opened during an asynchronous save must see the newest in-process state.
    var latestEntries: [PlaybackHistoryEntry]? { lock.withLock { latest?.entries } }
    var latestRevision: UInt64 { lock.withLock { revision } }
    func prioritize(_ entries: [PlaybackHistoryEntry], cache: MediaCache) {
        queue.async { self.updatePriority(self.latestEntries ?? entries, cache: cache) }
    }
    @discardableResult func enqueue(_ entries: [PlaybackHistoryEntry], cache: MediaCache,
                                   completed: @escaping @Sendable (Result) -> Void) -> UInt64 {
        let (submittedRevision, start): (UInt64, Bool) = lock.withLock {
            revision &+= 1
            let save = Save(revision: revision, entries: entries, cache: cache, completed: completed)
            latest = save; pending = save
            let start = !running; running = true
            return (revision, start)
        }
        if start { queue.async { self.drain() } }
        return submittedRevision
    }
    /// Waits until the shared file writer is idle, including newer saves submitted while waiting.
    /// A failed idle snapshot is retried once per explicit flush; no unbounded retry loop.
    func flush() async -> Result {
        await withCheckedContinuation { continuation in
            let start = lock.withLock {
                if !running, result.error == nil { continuation.resume(returning: result); return false }
                waiters.append(continuation)
                guard !running, let latest else { return false }
                pending = latest; running = true
                return true
            }
            if start { queue.async { self.drain() } }
        }
    }
    /// Blocks until every save submitted before this call is on disk or failed. `enqueue` starts a drain on
    /// `queue` unless one is running, and a running drain takes the newest pending save before it ends, so an
    /// empty block queued behind them runs after the last write. Never call on `queue`.
    func waitForWrites() { queue.sync {} }
    private func updatePriority(_ entries: [PlaybackHistoryEntry], cache: MediaCache) {
        let scopes = Set(entries.flatMap { entry in
            [entry.context.id] + (entry.context.poster.map { [PosterResource.artworkScope($0)] } ?? [])
        })
        let key = ObjectIdentifier(cache)
        guard prioritized[key] != scopes else { return }
        cache.prioritize(scopes)
        prioritized[key] = scopes
    }
    private func drain() {
        while true {
            let save: Save? = lock.withLock {
                guard let save = pending else { return nil }
                pending = nil
                return save
            }
            guard let save else {
                let finished: ([CheckedContinuation<Result, Never>], Result)? = lock.withLock {
                    // A newer mutation may arrive between taking the snapshot and this lock.
                    guard pending == nil else { return nil }
                    running = false
                    let values = waiters; waiters.removeAll()
                    return (values, result)
                }
                guard let (waiters, result) = finished else { continue }
                for waiter in waiters { waiter.resume(returning: result) }
                return
            }
            updatePriority(save.entries, cache: save.cache)
            let outcome: Result
            do {
                let data = try JSONEncoder().encode(save.entries)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
                outcome = Result(revision: save.revision, error: nil)
            } catch { outcome = Result(revision: save.revision, error: error.localizedDescription) }
            lock.withLock { result = outcome }
            save.completed(outcome)
        }
    }
}

import Foundation

/// One independent continuation per reader; only the final departure cancels shared work. Cancelled
/// workers retain their slot until they actually finish, so a quick re-request cannot exceed the cap.
actor MangaImageWork {
    private struct Flight {
        let id: UUID
        let page: Bool
        /// The most urgent waiter's: a page on screen (its view's task) goes before prefetched pages (`.utility`).
        var priority: TaskPriority
        let operation: @Sendable () async throws -> Data
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<Data, Error>]
    }
    private var pending: [String: Flight] = [:]
    private var queue: [(key: String, id: UUID)] = []
    private var running = 0
    static let slots = 6

    func data(key: String, page: Bool, operation: @escaping @Sendable () async throws -> Data) async throws -> Data {
        try Task.checkCancellation()
        let waiter = UUID(), priority = Task.currentPriority
        return try await withTaskCancellationHandler {
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if var flight = pending[key] {
                    flight.waiters[waiter] = continuation
                    if priority > flight.priority { flight.priority = priority }
                    pending[key] = flight
                } else {
                    let id = UUID()
                    pending[key] = Flight(id: id, page: page, priority: priority, operation: operation, waiters: [waiter: continuation])
                    queue.append((key, id))
                    drain()
                }
            }
            try Task.checkCancellation()
            return data
        } onCancel: { Task { await self.cancel(key, waiter: waiter) } }
    }

    /// For tests: how many callers wait on `key`, what waits for a slot, and how many slots are taken.
    func waiters(for key: String) -> Int { pending[key]?.waiters.count ?? 0 }
    func isQueued(_ key: String) -> Bool { queue.contains { $0.key == key } }
    var queuedCount: Int { queue.count }
    var busySlots: Int { running }

    private func cancel(_ key: String, waiter: UUID) {
        guard var flight = pending[key], let continuation = flight.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(throwing: CancellationError())
        if flight.waiters.isEmpty {
            pending[key] = nil
            queue.removeAll { $0.id == flight.id }
            flight.task?.cancel()
        } else { pending[key] = flight }
    }

    private func drain() {
        while running < Self.slots, !queue.isEmpty {
            // The most urgent first; at one priority, reader pages before covers, then in the order asked.
            var best = queue.startIndex
            for index in queue.indices.dropFirst() {
                guard let flight = pending[queue[index].key], let chosen = pending[queue[best].key] else { continue }
                if (flight.priority.rawValue, flight.page ? 1 : 0) > (chosen.priority.rawValue, chosen.page ? 1 : 0) { best = index }
            }
            let next = queue.remove(at: best)
            guard var flight = pending[next.key], flight.id == next.id else { continue }
            running += 1
            let operation = flight.operation
            flight.task = Task.detached(priority: flight.priority) {
                let result: Result<Data, Error>
                do { try Task.checkCancellation(); result = .success(try await operation()) }
                catch { result = .failure(error) }
                await self.finish(next.key, id: next.id, result: result)
            }
            pending[next.key] = flight
        }
    }

    private func finish(_ key: String, id: UUID, result: Result<Data, Error>) {
        running -= 1
        defer { drain() }
        // A cancelled flight may finish after another request for the same image was queued.
        guard let flight = pending[key], flight.id == id else { return }
        pending[key] = nil
        for continuation in flight.waiters.values { continuation.resume(with: result) }
    }
}

struct MangaImageRequest: Hashable, Sendable {
    let source: String
    let url: String
    let page: Bool
    let comic: String?
    let chapter: String?
    var maximumBytes: Int { page ? 64 << 20 : 8 << 20 }
    /// The cache's key, as before: pages under keys of their own since #836 (some kept before then were stored
    /// still scrambled), covers by source and address.
    var key: String { (page ? "page\n" : "") + source + "\n" + url }
}

import Foundation

/// One independent continuation per reader; only the final departure cancels shared work. Cancelled
/// workers retain their slot until they actually finish, so a quick re-request cannot exceed the cap.
actor MangaImageWork {
    private struct Flight {
        let id: UUID
        let page: Bool
        let operation: @Sendable () async throws -> Data
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<Data, Error>]
    }
    private var pending: [String: Flight] = [:]
    private var queue: [(key: String, id: UUID)] = []
    private var running = 0

    func data(key: String, page: Bool, operation: @escaping @Sendable () async throws -> Data) async throws -> Data {
        try Task.checkCancellation()
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if var flight = pending[key] {
                    flight.waiters[waiter] = continuation
                    pending[key] = flight
                } else {
                    let id = UUID()
                    pending[key] = Flight(id: id, page: page, operation: operation, waiters: [waiter: continuation])
                    queue.append((key, id))
                    drain()
                }
            }
            try Task.checkCancellation()
            return data
        } onCancel: { Task { await self.cancel(key, waiter: waiter) } }
    }
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
        while running < 6, !queue.isEmpty {
            let index = queue.firstIndex { pending[$0.key]?.page == true } ?? queue.startIndex
            let next = queue.remove(at: index)
            guard var flight = pending[next.key], flight.id == next.id else { continue }
            running += 1
            let operation = flight.operation
            flight.task = Task.detached(priority: .utility) {
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
    var key: String {
        // Lengths/escaping are unambiguous even when a provider puts newlines in an identifier.
        let parts: [String?] = [source, url, page ? "page" : "cover", comic, chapter]
        return String(decoding: try! JSONEncoder().encode(parts), as: UTF8.self)
    }
    func check(_ data: Data) throws {
        guard data.count <= maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
    }
}

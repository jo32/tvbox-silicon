import Foundation

/// Bounds decoded response bytes while retaining the caller's connection pool, cookies, cache and
/// delegate. AsyncBytes owns the response delivery; replacing a task's delegate does not receive
/// URLSessionDataDelegate callbacks on all supported systems.
enum BoundedHTTPData {
    static func load(_ request: URLRequest, session: URLSession, maximumBytes: Int) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        let limit = max(0, maximumBytes)
        let (bytes, response) = try await session.bytes(for: request)
        // Also cancel on a rejected header or an early exit, before draining the response.
        defer { bytes.task.cancel() }
        guard response.expectedContentLength <= limit else { throw URLError(.dataLengthExceedsMaximum) }
        return try await withTaskCancellationHandler {
            var data = Data()
            data.reserveCapacity(min(limit, 64 * 1024))
            for try await byte in bytes {
                guard data.count < limit else { throw URLError(.dataLengthExceedsMaximum) }
                data.append(byte)
            }
            try Task.checkCancellation()
            return (data, response)
        } onCancel: { bytes.task.cancel() }
    }
}

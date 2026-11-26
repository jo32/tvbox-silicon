import Foundation

/// Bounds decoded response bytes while retaining the caller's connection pool, cookies, cache and
/// delegate. AsyncBytes owns the response delivery; replacing a task's delegate does not receive
/// URLSessionDataDelegate callbacks on all supported systems.
enum BoundedHTTPData {
    /// Bytes gathered before each append to the result: appending AsyncBytes one byte at a time to `Data`
    /// took 0.7 s for 60 MB on an M5, against 0.2 s this way.
    static let chunk = 64 * 1024

    /// `validate` sees the response before its body, so a refused request reports its status, not its size.
    static func load(_ request: URLRequest, session: URLSession, maximumBytes: Int,
                     validate: ((URLResponse) throws -> Void)? = nil) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        let limit = max(0, maximumBytes)
        let (bytes, response) = try await session.bytes(for: request)
        // Also cancel on a rejected header or an early exit, before draining the response.
        defer { bytes.task.cancel() }
        try validate?(response)
        guard response.expectedContentLength <= limit else { throw URLError(.dataLengthExceedsMaximum) }
        return try await withTaskCancellationHandler {
            var data = Data()
            data.reserveCapacity(response.expectedContentLength > 0 ? Int(response.expectedContentLength) : min(limit, chunk))
            var buffer = [UInt8]()
            buffer.reserveCapacity(chunk)
            // A buffer fills at most to one byte past the limit, so the first byte too many stops the read.
            var flushAt = min(chunk, limit + 1)
            for try await byte in bytes {
                buffer.append(byte)
                guard buffer.count == flushAt else { continue }
                guard data.count + buffer.count <= limit else { throw URLError(.dataLengthExceedsMaximum) }
                data.append(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                flushAt = min(chunk, limit - data.count + 1)
            }
            data.append(contentsOf: buffer)
            try Task.checkCancellation()
            return (data, response)
        } onCancel: { bytes.task.cancel() }
    }
}

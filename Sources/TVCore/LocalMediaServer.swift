import Foundation
import Network

/// Serves downloaded HLS to AVPlayer over loopback. AVPlayer plays HLS only over HTTP(S), not from
/// file URLs, so a downloaded playlist and its segments are read from disk through here. Only files
/// under the downloads folder are served, behind a per-launch token.
public actor LocalMediaServer {
    public static let shared = LocalMediaServer()
    private let token = UUID().uuidString.lowercased()
    private let queue = DispatchQueue(label: "tvbox.downloads.server")
    private var listener: NWListener?
    private var base: URL?
    private var starting: Task<URL, Error>?
    private var root: URL?

    /// The loopback address of `file`, which lies under `root`.
    public func address(of file: URL, root: URL) async throws -> URL {
        let root = root.standardizedFileURL
        let path = file.standardizedFileURL.path
        guard path.hasPrefix(root.path + "/") else { throw TVError.invalidURL }
        self.root = root
        let base = try await start(root: root)
        return base.appending(path: String(path.dropFirst(root.path.count + 1)))
    }

    /// Whether `url` is one of this server's addresses: loopback, behind its token.
    public nonisolated func serves(_ url: URL) -> Bool {
        url.scheme == "http" && url.host() == "127.0.0.1" && url.pathComponents.dropFirst().first == token
    }

    /// `stale` on a new listener, on a new port: iOS and tvOS take back a suspended app's listening sockets, and the
    /// old listener may still say it is ready while it refuses AVPlayer (-1004), so every saved download would
    /// fail until the app was quit (#1761, #1905). Addresses that fail together share one new listener. Nil when
    /// `stale` isn't one of this server's addresses.
    public func relisten(_ stale: URL) async throws -> URL? {
        guard serves(stale), let root else { return nil }
        if starting == nil, base == nil || base?.port == stale.port {
            listener?.cancel(); listener = nil; base = nil
        }
        let fresh = try await start(root: root)
        var address = URLComponents(url: stale, resolvingAgainstBaseURL: false)
        address?.port = fresh.port
        return address?.url
    }

    private func start(root: URL) async throws -> URL {
        // A suspended iOS app loses its sockets; a listener that is no longer ready is replaced.
        if let base, listener?.state == .ready { return base }
        if let starting { return try await starting.value }
        listener?.cancel(); listener = nil; base = nil
        let task = Task { try await self.listen(root: root) }
        starting = task
        defer { starting = nil }
        let address = try await task.value
        base = address
        return address
    }

    private func listen(root: URL) async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = try NWListener(using: parameters)
        listener = server
        let token = token
        server.newConnectionHandler = { connection in
            connection.start(queue: .global(qos: .userInitiated))
            Self.receive(connection, buffer: Data(), root: root, token: token)
        }
        let ready = OneShot<URL>()
        return try await withCheckedThrowingContinuation { continuation in
            ready.set(continuation)
            server.stateUpdateHandler = { [token] state in
                switch state {
                case .ready:
                    guard let port = server.port else { return }
                    ready.resume(.success(URL(string: "http://127.0.0.1:\(port.rawValue)/\(token)/")!))
                case .failed(let error): ready.resume(.failure(error))
                case .cancelled: ready.resume(.failure(CancellationError()))
                default: break
                }
            }
            server.start(queue: queue)
        }
    }

    private nonisolated static func receive(_ connection: NWConnection, buffer: Data, root: URL, token: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, complete, error in
            var bytes = buffer
            if let data { bytes.append(data) }
            if bytes.range(of: Data("\r\n\r\n".utf8)) != nil { serve(connection, request: bytes, root: root, token: token) }
            else if error != nil || complete || bytes.count > 16384 { connection.cancel() }
            else { receive(connection, buffer: bytes, root: root, token: token) }
        }
    }

    private nonisolated static func serve(_ connection: NWConnection, request: Data, root: URL, token: String) {
        let lines = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n")
        let fields = (lines.first ?? "").split(separator: " ")
        guard fields.count >= 2, fields[0] == "GET" || fields[0] == "HEAD" else { send(connection, status: 405); return }
        let path = String(fields[1]).components(separatedBy: "?")[0].removingPercentEncoding ?? ""
        var parts = path.split(separator: "/").map(String.init)
        guard parts.first == token, parts.count > 1, !parts.contains("..") else { send(connection, status: 404); return }
        parts.removeFirst()
        let file = parts.reduce(root) { $0.appending(path: $1) }.standardizedFileURL
        guard file.path.hasPrefix(root.path + "/") else { send(connection, status: 404); return }
        let header = lines.first { $0.lowercased().hasPrefix("range: bytes=") }
        let head = fields[0] == "HEAD"
        // A download still being fetched, played meanwhile (#1264): a file comes chunk by chunk, from disk or its
        // source; a playlist or piece that isn't on disk yet comes from the download's plan or its source.
        if let pending = DownloadStream.file(file) {
            Task { await stream(connection, pending, header: header, head: head) }
            return
        }
        guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init),
              let handle = try? FileHandle(forReadingFrom: file) else {
            Task {
                guard let data = await DownloadStream.missing(file) else { send(connection, status: 404); return }
                answer(connection, size: Int64(data.count), header: header, head: head, name: file.pathExtension) { range in
                    Data(data[data.startIndex + Int(range.lowerBound)...data.startIndex + Int(range.upperBound)])
                }
            }
            return
        }
        defer { try? handle.close() }
        answer(connection, size: size, header: header, head: head, name: file.pathExtension) { range in
            try? handle.seek(toOffset: UInt64(range.lowerBound))
            return (try? handle.read(upToCount: Int(range.count))) ?? Data()
        }
    }

    /// The bytes a `Range` header asks for out of `size`, and the status that answers it; nil when it asks for none.
    nonisolated static func span(_ header: String?, size: Int64) -> (range: ClosedRange<Int64>, status: Int)? {
        guard let header, size > 0 else { return (0...max(0, size - 1), 200) }
        let spec = header.dropFirst("range: bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
        guard spec.count == 2 else { return (0...size - 1, 200) }
        let low = Int64(spec[0]), high = Int64(spec[1])
        let start = low ?? max(0, size - (high ?? 0)), end = low == nil ? size - 1 : min(high ?? size - 1, size - 1)
        guard start <= end, start < size else { return nil }
        return (start...end, 206)
    }

    private nonisolated static func answer(_ connection: NWConnection, size: Int64, header: String?, head: Bool, name: String, read: (ClosedRange<Int64>) -> Data) {
        guard let (range, status) = span(header, size: size) else { send(connection, status: 416, extra: "Content-Range: bytes */\(size)\r\n"); return }
        let body = !head && size > 0 ? read(range) : Data()
        let extra = status == 206 ? "Content-Range: bytes \(range.lowerBound)-\(range.upperBound)/\(size)\r\n" : ""
        send(connection, status: status, body: body, length: size == 0 ? 0 : range.count, mime: mime(name), extra: extra)
    }

    /// An unfinished file, sent as it is read: the player may ask for all of it from wherever it is.
    private nonisolated static func stream(_ connection: NWConnection, _ file: PendingFile, header: String?, head: Bool) async {
        guard let (range, status) = span(header, size: file.length) else { send(connection, status: 416, extra: "Content-Range: bytes */\(file.length)\r\n"); return }
        let extra = status == 206 ? "Content-Range: bytes \(range.lowerBound)-\(range.upperBound)/\(file.length)\r\n" : ""
        let reason = status == 206 ? "Partial Content" : "OK"
        let top = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(mime(file.fileExtension))\r\nContent-Length: \(range.count)\r\nAccept-Ranges: bytes\r\n\(extra)Connection: close\r\n\r\n"
        defer { connection.cancel() }
        guard await write(connection, Data(top.utf8)), !head else { return }
        var position = range.lowerBound
        while position <= range.upperBound {
            // Short pieces: a player that jumps elsewhere closes the connection, and the next write says so.
            guard let data = try? await file.read(position...min(range.upperBound, position + (1 << 19) - 1)), !data.isEmpty,
                  await write(connection, data) else { return }
            position += Int64(data.count)
        }
    }

    private nonisolated static func write(_ connection: NWConnection, _ data: Data) async -> Bool {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in continuation.resume(returning: error == nil) })
        }
    }

    private nonisolated static func mime(_ name: String) -> String {
        switch name.lowercased() {
        case "m3u8": "application/vnd.apple.mpegurl"
        case "ts": "video/mp2t"
        case "aac": "audio/aac"
        case "m4a", "cmfa": "audio/mp4"
        case "mp3": "audio/mpeg"
        case "vtt", "webvtt": "text/vtt"
        case "mp4", "m4s", "m4v", "cmfv": "video/mp4"
        case "mov": "video/quicktime"
        default: "application/octet-stream"
        }
    }

    private nonisolated static func send(_ connection: NWConnection, status: Int, body: Data = Data(), length: Int? = nil, mime: String = "text/plain", extra: String = "") {
        let reason = [200: "OK", 206: "Partial Content", 404: "Not Found", 405: "Method Not Allowed", 416: "Range Not Satisfiable"][status] ?? "Error"
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(mime)\r\nContent-Length: \(length ?? body.count)\r\nAccept-Ranges: bytes\r\n\(extra)Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// A continuation resumed at most once, from whichever callback comes first.
final class OneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    func set(_ continuation: CheckedContinuation<Value, Error>) { lock.withLock { self.continuation = continuation } }
    func resume(_ result: Result<Value, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Value, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }
}

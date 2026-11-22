import Foundation
import Network

/// Lets a TV play what only this app can fetch: a stream that needs request headers (a Referer, a browser's
/// User-Agent, cookies), or a plugin's proxy on this device's loopback (#749). The TV fetches from this device on the
/// local network instead, and each request goes on with the headers the source needs.
///
/// Only addresses registered here are served, behind a per-launch token: it is not an open proxy. HLS playlists are
/// rewritten so their variants, keys and segments come through here too. The relay lives as long as the app runs;
/// a suspended iPhone app loses its sockets, so the TV stalls until Yingxia is open again.
public actor CastRelay {
    public static let shared = CastRelay()

    struct Route: Sendable {
        let url: URL
        let headers: [String: String]
        var playlist: Bool
    }

    /// The most routes kept: a live playlist adds its new segments every few seconds.
    static let capacity = 4096
    private let token = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    private var routes: [String: Route] = [:]
    private var ids: [String: String] = [:]
    private var order: [String] = []
    private var next = 0
    private var listener: NWListener?
    private var port: UInt16?
    private let queue = DispatchQueue(label: "tvbox.cast.relay")
    private nonisolated let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// The address a TV at `host` fetches `url` from, registered with the headers it needs.
    public func address(for url: URL, headers: [String: String], playlist: Bool, towards host: String?) async throws -> URL {
        let port = try await start()
        guard let local = DLNA.localInterface(towards: host)?.address else { throw URLError(.notConnectedToInternet) }
        let path = register(url, headers: headers, playlist: playlist)
        guard let address = URL(string: "http://\(local):\(port)\(path)") else { throw URLError(.badURL) }
        return address
    }

    /// Forgets every route; the next cast starts afresh.
    public func reset() {
        routes = [:]; ids = [:]; order = []
    }

    private func start() async throws -> UInt16 {
        if let port, listener?.state == .ready { return port }
        listener?.cancel(); listener = nil; port = nil
        let listener = try NWListener(using: .tcp)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let ready: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready: if let port = listener?.port?.rawValue { once.run { continuation.resume(returning: port) } }
                case .failed(let error): once.run { continuation.resume(throwing: error) }
                case .cancelled: once.run { continuation.resume(throwing: CancellationError()) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        self.listener = listener
        port = ready
        Diagnostics.shared.record(.info, "cast", "relay listening port=\(ready)")
        return ready
    }

    /// The path a route is served at: the token, its id and a name that keeps the extension, which some TVs go by.
    @discardableResult
    func register(_ url: URL, headers: [String: String], playlist: Bool) -> String {
        let key = url.absoluteString
        let id: String
        if let known = ids[key] {
            id = known
            if playlist { routes[id]?.playlist = true }
        } else {
            next += 1
            id = String(next, radix: 36)
            ids[key] = id
            routes[id] = Route(url: url, headers: headers, playlist: playlist)
            order.append(id)
            if order.count > Self.capacity {
                let dropped = order.removeFirst()
                if let route = routes.removeValue(forKey: dropped) { ids[route.url.absoluteString] = nil }
            }
        }
        return "/\(token)/\(id)/\(Self.name(for: url, playlist: playlist))"
    }

    func route(_ id: String) -> Route? { routes[id] }

    /// A playlist with every address it names registered here, given as paths on this server.
    func rewrite(_ text: String, base: URL, headers: [String: String]) -> String {
        Self.rewrite(text, base: base) { url, playlist in register(url, headers: headers, playlist: playlist) }
    }

    static func name(for url: URL, playlist: Bool) -> String {
        let last = url.lastPathComponent
        // ASCII only: some TVs mangle other characters in an address.
        let clean = String(String.UnicodeScalarView(last.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }).prefix(60))
        if playlist { return clean.lowercased().hasSuffix(".m3u8") ? clean : "index.m3u8" }
        return clean.contains(".") ? clean : (clean.isEmpty ? "media" : clean) + ".mp4"
    }

    /// Rewrites each URI in an HLS playlist with `register`, which is told whether the address is itself a playlist
    /// (a variant or a rendition) rather than a segment, key or init section.
    static func rewrite(_ text: String, base: URL, register: (URL, Bool) -> String) -> String {
        let pattern = try! NSRegularExpression(pattern: "URI=\"([^\"]*)\"")
        var variantNext = false
        var lines: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { lines.append(line); continue }
            if trimmed.hasPrefix("#") {
                variantNext = trimmed.hasPrefix("#EXT-X-STREAM-INF")
                let isPlaylist = trimmed.hasPrefix("#EXT-X-MEDIA") || trimmed.hasPrefix("#EXT-X-I-FRAME-STREAM-INF")
                var rewritten = line
                for match in pattern.matches(in: line, range: NSRange(line.startIndex..., in: line)).reversed() {
                    guard let range = Range(match.range(at: 1), in: line), let url = URL(string: String(line[range]), relativeTo: base)?.absoluteURL,
                          url.scheme == "http" || url.scheme == "https",
                          let target = Range(match.range(at: 1), in: rewritten) else { continue }
                    rewritten.replaceSubrange(target, with: register(url, isPlaylist))
                }
                lines.append(rewritten)
                continue
            }
            if let url = URL(string: trimmed, relativeTo: base)?.absoluteURL, url.scheme == "http" || url.scheme == "https" {
                lines.append(register(url, variantNext))
            } else {
                lines.append(line)
            }
            variantNext = false
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Serving

    private nonisolated func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        readHead(connection, buffer: Data())
    }

    private nonisolated func readHead(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 << 10) { [weak self] chunk, _, complete, error in
            var buffer = buffer
            if let chunk { buffer.append(chunk) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                Task { await self?.serve(connection, head: head) }
                return
            }
            guard !complete, error == nil, buffer.count < 16 << 10 else { return connection.cancel() }
            self?.readHead(connection, buffer: buffer)
        }
    }

    private func serve(_ connection: NWConnection, head: String) async {
        let lines = head.components(separatedBy: "\r\n")
        let request = lines.first?.split(separator: " ") ?? []
        guard request.count >= 2 else { return Self.reply(connection, status: "400 Bad Request") }
        let method = String(request[0]), parts = request[1].split(separator: "/", omittingEmptySubsequences: true)
        guard method == "GET" || method == "HEAD" else { return Self.reply(connection, status: "405 Method Not Allowed") }
        guard parts.count >= 2, parts[0] == token, let route = routes[String(parts[1])] else { return Self.reply(connection, status: "404 Not Found") }
        let range = lines.dropFirst().first { $0.lowercased().hasPrefix("range:") }
            .map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        var upstream = URLRequest(url: route.url, timeoutInterval: 30)
        for (name, value) in route.headers { upstream.setValue(value, forHTTPHeaderField: name) }
        if let range, !route.playlist { upstream.setValue(range, forHTTPHeaderField: "Range") }
        if route.playlist || route.url.pathExtension.lowercased() == "m3u8" {
            await servePlaylist(connection, request: upstream, route: route, head: method == "HEAD")
        } else {
            await serveMedia(connection, request: upstream, route: route, head: method == "HEAD")
        }
    }

    private func servePlaylist(_ connection: NWConnection, request: URLRequest, route: Route, head: Bool) async {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                Diagnostics.shared.record(.warning, "cast", "relay playlist status=\((response as? HTTPURLResponse)?.statusCode ?? 0) host=\(route.url.host() ?? "-")")
                return Self.reply(connection, status: "502 Bad Gateway")
            }
            let text = rewrite(String(decoding: data, as: UTF8.self), base: http.url ?? route.url, headers: route.headers)
            let body = Data(text.utf8)
            let header = Self.header(status: "200 OK", fields: [("Content-Type", "application/vnd.apple.mpegurl"),
                                                               ("Content-Length", String(body.count)), ("Cache-Control", "no-cache")])
            connection.send(content: head ? header : header + body, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
        } catch {
            Diagnostics.shared.record(.warning, "cast", "relay playlist failed host=\(route.url.host() ?? "-") \(error.localizedDescription)")
            Self.reply(connection, status: "502 Bad Gateway")
        }
    }

    private func serveMedia(_ connection: NWConnection, request: URLRequest, route: Route, head: Bool) async {
        let upstream = Upstream(session: session, request: request)
        defer { upstream.cancel() }
        do {
            let response = try await upstream.start()
            guard (200..<300).contains(response.statusCode) else {
                Diagnostics.shared.record(.warning, "cast", "relay media status=\(response.statusCode) host=\(route.url.host() ?? "-")")
                return Self.reply(connection, status: response.statusCode == 416 ? "416 Range Not Satisfiable" : "502 Bad Gateway")
            }
            let type = response.value(forHTTPHeaderField: "Content-Type") ?? DLNA.mime(for: route.url)
            var iterator = upstream.chunks.makeAsyncIterator()
            var first = try await iterator.next() ?? Data()
            // An address that turns out to be a playlist (no extension, a plugin's route) is rewritten as one.
            if type.lowercased().contains("mpegurl") || first.starts(with: Data("#EXTM3U".utf8)) {
                while first.count < 4 << 20, let more = try await iterator.next() { first.append(more) }
                let text = rewrite(String(decoding: first, as: UTF8.self), base: response.url ?? route.url, headers: route.headers)
                let body = Data(text.utf8)
                let header = Self.header(status: "200 OK", fields: [("Content-Type", "application/vnd.apple.mpegurl"), ("Content-Length", String(body.count))])
                try await Self.send(connection, head ? header : header + body)
                return connection.cancel()
            }
            var fields: [(String, String)] = [("Content-Type", type), ("Accept-Ranges", "bytes"),
                                              ("transferMode.dlna.org", "Streaming"),
                                              ("contentFeatures.dlna.org", "DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000")]
            if response.expectedContentLength >= 0 { fields.append(("Content-Length", String(response.expectedContentLength))) }
            if let range = response.value(forHTTPHeaderField: "Content-Range") { fields.append(("Content-Range", range)) }
            let status = response.statusCode == 206 ? "206 Partial Content" : "200 OK"
            try await Self.send(connection, Self.header(status: status, fields: fields))
            if head { return connection.cancel() }
            upstream.consumed(first.count)
            try await Self.send(connection, first)
            while let chunk = try await iterator.next() {
                // Each piece goes out before the next is taken, so a slow TV slows the download instead of filling memory.
                try await Self.send(connection, chunk)
                upstream.consumed(chunk.count)
            }
            connection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
        } catch {
            // The TV closing a connection to seek elsewhere is the usual end; nothing to report.
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled, (error as? NWError) == nil {
                Diagnostics.shared.record(.warning, "cast", "relay media failed host=\(route.url.host() ?? "-") \(error.localizedDescription)")
            }
            connection.cancel()
        }
    }

    private static func header(status: String, fields: [(String, String)]) -> Data {
        let lines = ["HTTP/1.1 \(status)"] + fields.map { "\($0.0): \($0.1)" } + ["Connection: close", "", ""]
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    private static func reply(_ connection: NWConnection, status: String) {
        connection.send(content: header(status: status, fields: [("Content-Length", "0")]), isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}

/// Runs a closure at most once, for continuations several callbacks race to resume.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock(); let first = !done; done = true; lock.unlock()
        if first { body() }
    }
}

/// One upstream download, read piece by piece. It pauses while the TV is behind, so a long video never sits in memory.
private final class Upstream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let chunks: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let task: URLSessionDataTask
    private let lock = NSLock()
    private var answer: CheckedContinuation<HTTPURLResponse, Error>?
    private var answered = false
    private var pending = 0
    private var paused = false
    private static let high = 8 << 20, low = 2 << 20

    init(session: URLSession, request: URLRequest) {
        (chunks, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        task = session.dataTask(with: request)
        super.init()
        task.delegate = self
    }

    func start() async throws -> HTTPURLResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { answer = continuation }
            task.resume()
        }
    }

    func consumed(_ count: Int) {
        lock.withLock {
            pending -= count
            if paused, pending < Self.low { paused = false; task.resume() }
        }
    }

    func cancel() { task.cancel(); continuation.finish() }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let waiting: CheckedContinuation<HTTPURLResponse, Error>? = lock.withLock {
            defer { answer = nil; answered = true }
            return answered ? nil : answer
        }
        if let http = response as? HTTPURLResponse { waiting?.resume(returning: http) } else { waiting?.resume(throwing: URLError(.badServerResponse)) }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock {
            pending += data.count
            if !paused, pending > Self.high { paused = true; task.suspend() }
        }
        continuation.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let waiting: CheckedContinuation<HTTPURLResponse, Error>? = lock.withLock {
            defer { answer = nil; answered = true }
            return answered ? nil : answer
        }
        waiting?.resume(throwing: error ?? URLError(.badServerResponse))
        continuation.finish(throwing: error)
    }
}

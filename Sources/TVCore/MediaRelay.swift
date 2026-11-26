import Foundation
import Network

/// The loopback server between AVPlayer and a link it gave up on (`PlaybackRescue`), behind a per-launch token. Each
/// rescued link is a `RelaySession` whose routes are the addresses it reached: an HLS playlist is fetched on every
/// request (a live one reloads) with each address in it sent back through here; a segment, key or file passes through
/// as it arrives, byte ranges and all, or from a copy kept as it downloads (`RelaySpool`) when its server ignores
/// ranges. Only addresses found this way are served: it is not an open proxy.
actor MediaRelay {
    static let shared = MediaRelay()
    nonisolated let token = UUID().uuidString.lowercased()
    private let queue = DispatchQueue(label: "tvbox.rescue.relay")
    private var listener: NWListener?
    private var address: URL?
    private var starting: Task<URL, Error>?
    private nonisolated let store = RelayStore()

    /// Serves `session`, with `entry` as its first route, and returns the address AVPlayer opens.
    func add(_ session: RelaySession, entry: URL, kind: RelaySession.Kind, fileExtension: String) async throws -> URL {
        store.add(session)
        let base = try await base()
        return base.appending(path: "\(session.id)/\(session.register(entry, kind: kind, fileExtension: fileExtension))")
    }

    /// Stops serving a session and closes what it has open.
    nonisolated func remove(_ id: String) { store.remove(id)?.close() }

    /// Whether `url` is one of this server's addresses.
    nonisolated func serves(_ url: URL) -> Bool {
        url.scheme == "http" && url.host() == "127.0.0.1" && url.pathComponents.dropFirst().first == token
    }

    /// `url` on a new listener, on a new port: iOS takes back a suspended app's listening sockets. Nil when its
    /// session was closed.
    func relisten(_ url: URL) async throws -> URL? {
        let parts = url.pathComponents.dropFirst()
        guard serves(url), parts.count == 3, store.session(parts[parts.startIndex + 1]) != nil else { return nil }
        if starting == nil, address == nil || address?.port == url.port {
            listener?.cancel(); listener = nil; address = nil
            // Its own port first: a repackager reading from the relay keeps the address it was given.
            if let port = url.port, let fresh = try? await base(port: port) { return fresh == base(of: url) ? url : nil }
        }
        let fresh = try await base()
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.port = fresh.port
        return components?.url
    }

    private nonisolated func base(of url: URL) -> URL? { URL(string: "http://127.0.0.1:\(url.port ?? 0)/\(token)/") }

    private func base(port: Int? = nil) async throws -> URL {
        if let address, listener?.state == .ready { return address }
        if let starting { return try await starting.value }
        listener?.cancel(); listener = nil; address = nil
        let task = Task { try await self.listen(port: port) }
        starting = task
        defer { starting = nil }
        let value = try await task.value
        address = value
        return value
    }

    private func listen(port: Int?) async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port.flatMap { NWEndpoint.Port(rawValue: UInt16($0)) } ?? .any)
        let server = try NWListener(using: parameters)
        listener = server
        let token = token, store = store
        server.newConnectionHandler = { connection in
            connection.start(queue: .global(qos: .userInitiated))
            Self.receive(connection, buffer: Data(), token: token, store: store)
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

    private nonisolated static func receive(_ connection: NWConnection, buffer: Data, token: String, store: RelayStore) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, complete, error in
            var bytes = buffer
            if let data { bytes.append(data) }
            if bytes.range(of: Data("\r\n\r\n".utf8)) != nil { serve(connection, request: bytes, token: token, store: store) }
            else if error != nil || complete || bytes.count > 16384 { connection.cancel() }
            else { receive(connection, buffer: bytes, token: token, store: store) }
        }
    }

    private nonisolated static func serve(_ connection: NWConnection, request: Data, token: String, store: RelayStore) {
        let lines = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n")
        let fields = (lines.first ?? "").split(separator: " ")
        guard fields.count >= 2, fields[0] == "GET" || fields[0] == "HEAD" else { return RelayHTTP.send(connection, status: 405) }
        let parts = String(fields[1]).components(separatedBy: "?")[0].split(separator: "/").map(String.init)
        guard parts.count == 3, parts[0] == token, let session = store.session(parts[1]) else { return RelayHTTP.send(connection, status: 404) }
        let range = lines.first { $0.lowercased().hasPrefix("range:") }.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        let head = fields[0] == "HEAD"
        Task { await session.serve(key: parts[2], range: range, head: head, to: connection) }
    }
}

final class RelayStore: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [String: RelaySession] = [:]
    func add(_ session: RelaySession) { lock.withLock { sessions[session.id] = session } }
    func session(_ id: String) -> RelaySession? { lock.withLock { sessions[id] } }
    func remove(_ id: String) -> RelaySession? { lock.withLock { sessions.removeValue(forKey: id) } }
}

/// One rescued link and the addresses it led to.
final class RelaySession: @unchecked Sendable {
    enum Kind: Sendable { case playlist, media }

    final class Route: @unchecked Sendable {
        let url: URL
        let kind: Kind
        let mime: String
        /// The copy that answers ranges for a server that answers none.
        var spool: RelaySpool?
        init(url: URL, kind: Kind, mime: String) { self.url = url; self.kind = kind; self.mime = mime }
    }

    let id = UUID().uuidString.lowercased()
    let headers: [String: String]
    /// The certificate of the link's own host is accepted whatever it is, and an older TLS on it.
    let trusting: Bool
    /// The link's own host: the one AVPlayer refused, the only one `trusting` applies to.
    let host: String?
    private let lock = NSLock()
    private var routes: [String: Route] = [:]
    private var keys: [URL: String] = [:]
    private var closed = false

    init(origin: URL, headers: [String: String], trusting: Bool) {
        self.headers = headers; self.trusting = trusting; host = origin.host()?.lowercased()
    }

    static let configuration: URLSessionConfiguration = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return configuration
    }()

    /// Without a certificate it accepts, some such servers speak an older TLS too.
    static let trustingConfiguration: URLSessionConfiguration = {
        let trusting = RelaySession.configuration.copy() as! URLSessionConfiguration
        trusting.tlsMinimumSupportedProtocolVersion = .TLSv10
        return trusting
    }()

    /// The route name of `url` (one per address, so a live playlist names its segments the same way each reload).
    func register(_ url: URL, kind: Kind, fileExtension: String) -> String {
        lock.withLock {
            if let key = keys[url] { return key }
            let key = "\(routes.count).\(fileExtension)"
            routes[key] = Route(url: url, kind: kind, mime: Self.mime(fileExtension))
            keys[url] = key
            return key
        }
    }

    func close() {
        let spools: [RelaySpool] = lock.withLock {
            closed = true
            return routes.values.compactMap(\.spool)
        }
        spools.forEach { $0.close() }
    }

    /// Whether a certificate `host` presents is accepted whatever it is: only the link's own host's, and only for a
    /// link AVPlayer refused over it. A host its playlists name or it redirects to is checked as usual.
    func trusts(_ host: String) -> Bool { trusting && host.lowercased() == self.host }

    private func request(_ url: URL, range: String? = nil, timeout: TimeInterval = 30) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }

    private func open(_ request: URLRequest) async throws -> RelayUpstream {
        let own = request.url?.host()?.lowercased() == host
        return try await RelayUpstream.open(request, configuration: trusting && own ? Self.trustingConfiguration : Self.configuration,
                                            trusts: { [weak self] in self?.trusts($0) ?? false })
    }

    /// The link's first bytes, as it answers a plain request.
    func probe(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        let upstream = try await open(request(url, timeout: 10))
        defer { upstream.close() }
        guard let response = upstream.response, (200..<300).contains(response.statusCode) else { throw TVError.http(upstream.status) }
        var head = Data()
        while head.count < 4096, let data = try await upstream.next() { head.append(data) }
        return (head, response)
    }

    // MARK: Serving

    func serve(key: String, range: String?, head: Bool, to connection: NWConnection) async {
        guard let route = lock.withLock({ closed ? nil : routes[key] }) else { return RelayHTTP.send(connection, status: 404) }
        switch route.kind {
        case .playlist:
            do {
                let data = try await playlist(route)
                RelayHTTP.send(connection, status: 200, body: head ? Data() : data, length: data.count, mime: route.mime)
            } catch {
                Diagnostics.shared.record(.warning, "rescue", "playlist host=\(route.url.host() ?? "-") \(Diagnostics.describe(error))")
                RelayHTTP.send(connection, status: Self.status(error))
            }
        case .media:
            await media(route, range: range, head: head, to: connection)
        }
    }

    private static func status(_ error: Error) -> Int {
        if case TVError.http(let code) = error, (400..<600).contains(code) { return code }
        return 502
    }

    /// A playlist from its server, with every address in it sent back through the relay.
    private func playlist(_ route: Route) async throws -> Data {
        let upstream = try await open(request(route.url))
        defer { upstream.close() }
        guard (200..<300).contains(upstream.status) else { throw TVError.http(upstream.status) }
        var data = Data()
        while let chunk = try await upstream.next() {
            data.append(chunk)
            guard data.count < 16 << 20 else { throw TVError.unsupported("playlist too large") }
        }
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else { throw TVError.unsupported("not a playlist") }
        let origin = upstream.response?.url ?? route.url
        return Data(Self.rewrite(text, origin: origin) { url, kind, fileExtension in self.register(url, kind: kind, fileExtension: fileExtension) }.utf8)
    }

    /// A playlist with each HTTP(S) address in it (variants, renditions, segments, keys, initialization sections)
    /// replaced by its route name, relative to the playlist's own address on the relay.
    static func rewrite(_ text: String, origin: URL, register: (URL, Kind, String) -> String) -> String {
        let master = text.contains("#EXT-X-STREAM-INF")
        func address(_ value: String, kind: Kind, fileExtension: String? = nil) -> String? {
            guard let url = URL(string: value, relativeTo: origin)?.absoluteURL, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return register(url, kind, kind == .playlist ? "m3u8" : fileExtension ?? mediaExtension(url))
        }
        return text.components(separatedBy: .newlines).map { raw -> String in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return line }
            if !line.hasPrefix("#") { return address(line, kind: master ? .playlist : .media) ?? line }
            guard line.contains("URI=\"") else { return line }
            let playlist = ["#EXT-X-MEDIA:", "#EXT-X-I-FRAME-STREAM-INF:", "#EXT-X-RENDITION-REPORT:"].contains { line.hasPrefix($0) }
            let key = line.hasPrefix("#EXT-X-KEY:") || line.hasPrefix("#EXT-X-SESSION-KEY:")
            var result = line
            for match in line.matches(of: /URI="([^"]+)"/).reversed() {
                guard let replaced = address(String(match.1), kind: playlist ? .playlist : .media, fileExtension: key ? "key" : nil) else { continue }
                result.replaceSubrange(match.1.startIndex..<match.1.endIndex, with: replaced)
            }
            return result
        }.joined(separator: "\n")
    }

    /// The extension a segment's route is given: its own when it is a media one.
    static func mediaExtension(_ url: URL) -> String {
        let name = url.pathExtension.lowercased()
        let pages = ["php", "html", "htm", "asp", "aspx", "jsp", "cgi", "do", "action"]
        return name.wholeMatch(of: /[a-z0-9]{1,5}/) != nil && !pages.contains(name) ? name : "ts"
    }

    static func mime(_ fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "m3u8": "application/vnd.apple.mpegurl"
        case "ts": "video/mp2t"
        case "mp4", "m4s", "m4v", "cmfv": "video/mp4"
        case "mov": "video/quicktime"
        case "aac": "audio/aac"
        case "m4a", "cmfa": "audio/mp4"
        case "mp3": "audio/mpeg"
        case "vtt", "webvtt": "text/vtt"
        default: "application/octet-stream"
        }
    }

    /// The bytes a Range value (`bytes=a-b`, `bytes=a-`, `bytes=-n`) asks for out of `length`: all of them without
    /// one, nil when it asks for none that exist.
    static func span(_ range: String?, length: Int64) -> ClosedRange<Int64>? {
        guard length > 0 else { return nil }
        guard let range, range.lowercased().hasPrefix("bytes=") else { return 0...length - 1 }
        let spec = (range.dropFirst(6).split(separator: ",").first ?? "").split(separator: "-", omittingEmptySubsequences: false)
        guard spec.count == 2 else { return 0...length - 1 }
        let low = Int64(spec[0].trimmingCharacters(in: .whitespaces)), high = Int64(spec[1].trimmingCharacters(in: .whitespaces))
        let start: Int64, end: Int64
        if let low { start = low; end = min(high ?? length - 1, length - 1) }
        else if let high, high > 0 { start = max(0, length - high); end = length - 1 }
        else { return nil }
        guard start <= end, start < length else { return nil }
        return start...end
    }

    /// A segment, key or file: passed through as it arrives, or from the copy of a server that ignores ranges.
    private func media(_ route: Route, range: String?, head: Bool, to connection: NWConnection) async {
        if let spool = lock.withLock({ route.spool }) { return await answer(route, from: spool, range: range, head: head, to: connection) }
        let upstream: RelayUpstream
        do { upstream = try await open(request(route.url, range: range)) }
        catch {
            Diagnostics.shared.record(.warning, "rescue", "media host=\(route.url.host() ?? "-") \(Diagnostics.describe(error))")
            return RelayHTTP.send(connection, status: 502)
        }
        let status = upstream.status
        if status == 200, range != nil {
            // The server ignores ranges: one copy, kept as it downloads, answers them all from now on.
            let spool: RelaySpool
            do {
                spool = try lock.withLock { () throws -> RelaySpool in
                    if let spool = route.spool { upstream.close(); return spool }
                    let spool = try RelaySpool(upstream)
                    route.spool = spool
                    if closed { spool.close() }
                    return spool
                }
            } catch {
                upstream.close()
                return RelayHTTP.send(connection, status: 502)
            }
            Diagnostics.shared.record(.info, "rescue", "no byte ranges host=\(route.url.host() ?? "-") length=\(upstream.length); keeping a copy")
            return await answer(route, from: spool, range: range, head: head, to: connection)
        }
        guard status == 200 || status == 206 else {
            upstream.close()
            return RelayHTTP.send(connection, status: (400..<600).contains(status) ? status : 502)
        }
        var fields = [("Content-Type", Self.type(upstream.response?.mimeType, route: route)), ("Accept-Ranges", "bytes")]
        if upstream.length >= 0 { fields.append(("Content-Length", "\(upstream.length)")) }
        if status == 206, let span = upstream.header("Content-Range") { fields.append(("Content-Range", span)) }
        defer { upstream.close(); connection.cancel() }
        do {
            try await RelayHTTP.write(RelayHTTP.header(status: status, fields: fields), to: connection)
            guard !head else { return }
            while let data = try await upstream.next() { try await RelayHTTP.write(data, to: connection) }
        } catch {}
    }

    /// What a segment or file is called to AVPlayer: its server's media type, unless it names none (a `.php` relay's
    /// `text/html`), then the route's own.
    private static func type(_ upstream: String?, route: Route) -> String {
        guard let upstream, upstream.hasPrefix("video/") || upstream.hasPrefix("audio/") || upstream.contains("mpegurl") else { return route.mime }
        return upstream
    }

    private func answer(_ route: Route, from spool: RelaySpool, range: String?, head: Bool, to connection: NWConnection) async {
        let length: Int64
        do { length = try await spool.totalLength() }
        catch {
            // A copy that can't be made is an error AVPlayer reports, not a connection that drops.
            Diagnostics.shared.record(.warning, "rescue", "copy host=\(route.url.host() ?? "-") \(Diagnostics.describe(error))")
            return RelayHTTP.send(connection, status: 502)
        }
        defer { connection.cancel() }
        do {
            guard let span = Self.span(range, length: length) else {
                return RelayHTTP.send(connection, status: 416, fields: [("Content-Range", "bytes */\(length)")])
            }
            var fields = [("Content-Type", route.mime), ("Accept-Ranges", "bytes"), ("Content-Length", "\(span.count)")]
            if range != nil { fields.append(("Content-Range", "bytes \(span.lowerBound)-\(span.upperBound)/\(length)")) }
            try await RelayHTTP.write(RelayHTTP.header(status: range == nil ? 200 : 206, fields: fields), to: connection)
            guard !head else { return }
            var position = span.lowerBound
            while position <= span.upperBound {
                let available = try await spool.wait(beyond: position)
                let end = min(available - 1, span.upperBound, position + (512 << 10) - 1)
                try await RelayHTTP.write(try spool.read(position...end), to: connection)
                position = end + 1
            }
        } catch {
            if !(error is CancellationError) { Diagnostics.shared.record(.debug, "rescue", "copy \(Diagnostics.describe(error))") }
        }
    }
}

enum RelayHTTP {
    static func header(status: Int, fields: [(String, String)]) -> Data {
        let reason = [200: "OK", 206: "Partial Content", 404: "Not Found", 405: "Method Not Allowed", 416: "Range Not Satisfiable"][status] ?? "Error"
        var text = "HTTP/1.1 \(status) \(reason)\r\n"
        for (name, value) in fields { text += "\(name): \(value)\r\n" }
        text += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        return Data(text.utf8)
    }

    static func write(_ data: Data, to connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    static func send(_ connection: NWConnection, status: Int, body: Data = Data(), length: Int? = nil, mime: String = "text/plain", fields: [(String, String)] = []) {
        var response = header(status: status, fields: [("Content-Type", mime), ("Content-Length", "\(length ?? body.count)")] + fields)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// One upstream response read as it arrives. It pauses while far ahead of its reader, so a player that stops
/// reading doesn't pull a whole file into memory.
final class RelayUpstream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let high = 4 << 20, low = 1 << 20
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var opening: CheckedContinuation<Void, Error>?
    private var chunks: [Data] = []
    private var buffered = 0
    private var paused = false
    private var finished = false
    private var failure: Error?
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var response: HTTPURLResponse?
    private let trusts: @Sendable (String) -> Bool

    private init(trusts: @escaping @Sendable (String) -> Bool) { self.trusts = trusts }

    /// The response to `request`, once its headers arrived.
    static func open(_ request: URLRequest, configuration: URLSessionConfiguration, trusts: @escaping @Sendable (String) -> Bool) async throws -> RelayUpstream {
        let upstream = RelayUpstream(trusts: trusts)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let session = URLSession(configuration: configuration, delegate: upstream, delegateQueue: nil)
                let task = session.dataTask(with: request)
                let cancelled = upstream.lock.withLock {
                    if upstream.finished { return true }
                    upstream.opening = continuation; upstream.session = session; upstream.task = task
                    return false
                }
                if cancelled { session.invalidateAndCancel(); continuation.resume(throwing: CancellationError()) }
                else { task.resume() }
            }
        } onCancel: { upstream.close() }
        return upstream
    }

    var status: Int { response?.statusCode ?? 0 }
    /// The Content-Length, or -1.
    var length: Int64 { response?.expectedContentLength ?? -1 }
    func header(_ name: String) -> String? { response?.value(forHTTPHeaderField: name) }

    /// The next bytes, nil at the end.
    func next() async throws -> Data? {
        while true {
            try Task.checkCancellation()
            var resume: URLSessionDataTask?
            let step: (data: Data?, done: Bool, failure: Error?) = lock.withLock {
                if !chunks.isEmpty {
                    let data = chunks.removeFirst()
                    buffered -= data.count
                    if paused, buffered < Self.low { paused = false; resume = task }
                    return (data, false, nil)
                }
                return (nil, finished, failure)
            }
            resume?.resume()
            if let data = step.data { return data }
            if step.done {
                if let failure = step.failure { throw failure }
                return nil
            }
            await arrival()
        }
    }

    private func arrival() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let ready = lock.withLock {
                    if !chunks.isEmpty || finished || Task.isCancelled { return true }
                    waiter = continuation
                    return false
                }
                if ready { continuation.resume() }
            }
        } onCancel: {
            lock.withLock { () -> CheckedContinuation<Void, Never>? in defer { waiter = nil }; return waiter }?.resume()
        }
    }

    func close() {
        let session = lock.withLock { () -> URLSession? in
            if !finished { failure = CancellationError() }
            finished = true
            chunks = []; buffered = 0
            return self.session
        }
        session?.invalidateAndCancel()
        end(CancellationError())
    }

    private func end(_ error: Error?) {
        let (opening, waiter) = lock.withLock { () -> (CheckedContinuation<Void, Error>?, CheckedContinuation<Void, Never>?) in
            if !finished, let error { failure = error }
            finished = true
            defer { self.opening = nil; self.waiter = nil }
            return (self.opening, self.waiter)
        }
        opening?.resume(throwing: error ?? TVError.unsupported("no response"))
        waiter?.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let opening = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            self.response = response as? HTTPURLResponse
            defer { self.opening = nil }
            return self.opening
        }
        completionHandler(.allow)
        opening?.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard !finished else { return nil }
            chunks.append(data); buffered += data.count
            if !paused, buffered > Self.high { paused = true; dataTask.suspend() }
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        end(error)
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust, trusts(challenge.protectionSpace.host) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

/// A file whose server ignores byte ranges, downloaded once to a temporary file that answers ranges as far as it
/// got. A jump ahead waits for the download to get there, as it would in a player that can't ask for ranges either.
final class RelaySpool: @unchecked Sendable {
    /// A file is copied up to this size, with this much room left on the disk.
    static let limit: Int64 = 4 << 30, margin: Int64 = 1 << 30
    /// A file whose server names no length is copied only when it is small, and all of it arrives soon: until then
    /// nothing can be answered (AVPlayer needs the length), and an endless stream never ends.
    static let unknownLimit: Int64 = 64 << 20, unknownTime: Duration = .seconds(20)
    let file: URL
    private let lock = NSLock()
    private let upstream: RelayUpstream
    private let declared: Int64?
    private var written: Int64 = 0
    private var finished = false
    private var failure: Error?
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var drain: Task<Void, Never>?

    init(_ upstream: RelayUpstream) throws {
        guard upstream.length <= Self.limit else { throw TVError.unsupported("file too large to copy") }
        if let room = Self.room(), max(upstream.length, Self.unknownLimit) + Self.margin > room { throw TVError.unsupported("no room for a copy") }
        self.upstream = upstream
        declared = upstream.length > 0 ? upstream.length : nil
        let cap = declared == nil ? Self.unknownLimit : Self.limit
        let deadline: ContinuousClock.Instant? = declared == nil ? .now + Self.unknownTime : nil
        file = FileManager.default.temporaryDirectory.appending(path: "rescue-\(UUID().uuidString).bin")
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw TVError.unsupported("no room for a copy") }
        let writer = try FileHandle(forWritingTo: file)
        drain = Task.detached(priority: .userInitiated) { [weak self, upstream] in
            var failure: Error?
            do {
                while let data = try await upstream.next() {
                    try writer.write(contentsOf: data)
                    guard let self else { throw CancellationError() }
                    let total = self.grew(by: data.count)
                    if total > cap { throw TVError.unsupported("file too large to copy") }
                    if let deadline, ContinuousClock.now > deadline { throw TVError.unsupported("a file of no length still arriving") }
                }
            } catch { failure = error }
            try? writer.close()
            self?.finish(failure)
        }
    }

    /// The free space where the copy goes.
    private static func room() -> Int64? {
        let folder = FileManager.default.temporaryDirectory
        #if os(tvOS)
        return (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity.map(Int64.init)
        #else
        return (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        #endif
    }

    private func grew(by count: Int) -> Int64 {
        let (total, waiters) = lock.withLock { () -> (Int64, [CheckedContinuation<Void, Never>]) in
            written += Int64(count)
            defer { self.waiters = [:] }
            return (written, Array(self.waiters.values))
        }
        waiters.forEach { $0.resume() }
        return total
    }

    private func finish(_ error: Error?) {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            finished = true; failure = error
            defer { self.waiters = [:] }
            return Array(self.waiters.values)
        }
        waiters.forEach { $0.resume() }
        if let error, !(error is CancellationError) { Diagnostics.shared.record(.warning, "rescue", "copy stopped at=\(lock.withLock { written }) \(Diagnostics.describe(error))") }
    }

    /// The file's length: its server's Content-Length, or once it all arrived.
    func totalLength() async throws -> Int64 {
        if let declared { return declared }
        while true {
            try Task.checkCancellation()
            let (total, done, failure) = lock.withLock { (written, finished, self.failure) }
            if done {
                if let failure { throw failure }
                return total
            }
            await change(since: total)
        }
    }

    /// How many bytes are copied once there are more than `offset`. Throws when the copy ended before that.
    func wait(beyond offset: Int64) async throws -> Int64 {
        while true {
            try Task.checkCancellation()
            let (total, done, failure) = lock.withLock { (written, finished, self.failure) }
            if total > offset { return total }
            if done { throw failure ?? TVError.unsupported("the file ended early") }
            await change(since: total)
        }
    }

    private func change(since seen: Int64) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let ready = lock.withLock {
                    if written != seen || finished || Task.isCancelled { return true }
                    waiters[id] = continuation
                    return false
                }
                if ready { continuation.resume() }
            }
        } onCancel: {
            lock.withLock { waiters.removeValue(forKey: id) }?.resume()
        }
    }

    func read(_ range: ClosedRange<Int64>) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(range.lowerBound))
        return try handle.read(upToCount: Int(range.count)) ?? Data()
    }

    func close() {
        drain?.cancel()
        upstream.close()
        try? FileManager.default.removeItem(at: file)
    }
}

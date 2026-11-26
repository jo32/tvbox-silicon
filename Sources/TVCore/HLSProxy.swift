import Foundation
import Network

/// A private loopback endpoint between AVPlayer and an HLS stream. Only URLs found in this playback's playlists are
/// registered; it is not an open web proxy. The Mac plays every HLS stream through it; iPhone, iPad and Apple TV
/// when a stream played directly failed in a way it gets past (`recovers`).
///
/// What it does that AVPlayer alone doesn't, as players built on FFmpeg or ExoPlayer do:
/// - waits for a slow first playlist, and asks again for one that doesn't come (AVPlayer gives up after 20 s with
///   -1008/-12884; ExoPlayer asks again), within a time budget for the whole start;
/// - repairs playlists AVPlayer refuses (`HLSSanitizer`) and cuts spliced-in ads (`AdSkip`);
/// - drops the picture some hosts put before each MPEG-TS segment (`MediaPayload`);
/// - asks once more after a dropped connection or a 502, 503 or 504, and otherwise passes the server's own status on.
///
/// Memory stays bounded: a playlist is read to at most 16 MB and given up on as soon as its first bytes are a stream
/// (an `.m3u8` address that sends endless MPEG-TS), and segments are passed through as they come, not held whole.
public actor HLSProxy {
    /// Upstream transfer counters for the player's loading card, and the last upstream failure: AVPlayer only hears
    /// the status the proxy answers, so speed and the real reason must come from here.
    public final class Stats: @unchecked Sendable {
        public struct Snapshot {
            public var received: Int64 = 0
            public var host: String?
            public var status: Int?
            public var failure: String?
            /// The `URLError` code of the last upstream failure that wasn't an HTTP answer. A certificate the system
            /// refused is -1200…-1206 (AVPlayer is answered 495 for it; see `gatewayStatus(for:)`).
            public var code: Int?
        }
        private let lock = NSLock()
        private var value = Snapshot()
        public var snapshot: Snapshot { lock.withLock { value } }
        func received(_ count: Int, from host: String?) {
            guard count > 0 else { return }
            lock.withLock { value.received += Int64(count); value.host = host ?? value.host; value.status = nil; value.failure = nil; value.code = nil }
        }
        func failed(_ host: String?, status: Int?, message: String?, code: Int? = nil) {
            lock.withLock { value.host = host ?? value.host; value.status = status; value.failure = message; value.code = code }
        }
    }

    /// Why the proxy can't serve a stream.
    public enum Failure: LocalizedError, Equatable {
        /// The address sends a stream (MPEG-TS, FLV, MP4…), not a playlist: there is nothing to repair, and it is
        /// not read on.
        case notPlaylist(String)
        /// A "playlist" over 16 MB.
        case tooLarge
        /// The first playlist's server answered this status.
        case status(Int)
        public var errorDescription: String? {
            switch self {
            case .notPlaylist(let kind): "not an HLS playlist (\(kind))"
            case .tooLarge: "playlist over 16 MB"
            case .status(let status): "HTTP \(status)"
            }
        }
    }

    /// How long `start` may take before AVPlayer is given the stream.
    public enum Patience: Sendable {
        /// The stream's own start (the Mac plays every HLS stream through the proxy): up to 45 s in all, a second
        /// request for the first playlist after 10 s.
        case opening
        /// A retry after AVPlayer already gave up on the stream (it waited up to 20 s): up to 30 s in all, a second
        /// request after 8 s, and any failure of the first playlist is thrown, so the player reports the first
        /// failure and moves on to the next line.
        case retry
        var budget: Duration { self == .opening ? .seconds(45) : .seconds(30) }
        var hedge: Duration { self == .opening ? .seconds(10) : .seconds(8) }
    }

    public nonisolated let stats = Stats()
    /// What was repaired for this stream so far (`HLSSanitizer`'s fixes, `image-header`, `retry`, `slow-playlist`).
    public private(set) var repairs: [String] = []
    private let token = UUID().uuidString
    private let headers: [String: String]
    private let queue = DispatchQueue(label: "tvbox.hls")
    private var listener: NWListener?
    private var routes: [String: URL] = [:]
    /// The key each upstream URL was given. A live playlist is fetched again every few seconds and
    /// must name its segments the same way each time; fresh names make AVPlayer fail (-12312).
    private var keys: [URL: String] = [:]
    private var base: URL?
    private var startup: CheckedContinuation<Void, Error>?
    /// Playlists fetched before AVPlayer asked for them, each served once while fresh.
    private var prefetched: [String: (reply: Upstream, at: Date)] = [:]
    static let playlistLimit = 16 << 20
    /// How much of a segment is looked at before it is passed on: enough to find a picture put before it.
    static let headLimit = 64 << 10
    #if DEBUG
    private var qaDropped = false
    #endif
    public init(headers: [String: String]) { self.headers = headers }

    /// The loopback address of `url`'s playlist, once that playlist (and a master playlist's variants) is in: AVPlayer's
    /// own wait for it starts only then.
    public func start(url: URL, patience: Patience = .opening) async throws -> URL {
        try await bind()
        let address = register(url, kind: .playlist)
        let clock = ContinuousClock()
        let deadline = clock.now + patience.budget
        let started = clock.now
        do {
            let first = try await firstPlaylist(url, until: deadline, hedge: patience.hedge)
            guard (200..<300).contains(first.status) || patience == .opening else { throw Failure.status(first.status) }
            prefetched[address.lastPathComponent] = (first, .now)
            await prefetchVariants(of: first, until: deadline)
            let seconds = (clock.now - started).components.seconds
            if seconds > 15 { repaired("slow-playlist", host: url.host(), detail: "seconds=\(seconds)") }
        } catch {
            if Task.isCancelled { stop(); throw CancellationError() }
            var status: Int?
            if case .status(let code)? = error as? Failure { status = code }
            stats.failed(url.host(), status: status, message: error.localizedDescription, code: (error as? URLError)?.code.rawValue)
            // A stream that isn't a playlist plays without the proxy; a retry reports the stream's first failure.
            if patience == .retry || error is Failure { stop(); throw error }
            // AVPlayer hears of it at once, rather than after another wait for the same server.
            prefetched[address.lastPathComponent] = (Upstream(status: Self.gatewayStatus(for: error), data: Data(), url: url,
                                                              failure: error.localizedDescription, code: (error as? URLError)?.code.rawValue), .now)
        }
        #if DEBUG
        dropForQA()
        #endif
        return address
    }

    /// Whether `url` is one of this proxy's addresses.
    public nonisolated func serves(_ url: URL) -> Bool {
        url.scheme == "http" && url.host() == "127.0.0.1" && url.pathComponents.dropFirst().first == token
    }

    /// `url` (one of this proxy's addresses) on a new listener. iOS and tvOS take back a suspended app's listening
    /// sockets, and AVPlayer is then refused (-1004): the same stream, with the same names, listens again.
    public func relisten(_ url: URL) async throws -> URL {
        let key = url.lastPathComponent
        guard serves(url), routes[key] != nil else { throw URLError(.cannotConnectToHost) }
        listener?.cancel(); listener = nil
        try await bind()
        Diagnostics.shared.record(.info, "player", "hls proxy relisten host=\(routes[key]?.host() ?? "-")")
        return base!.appendingPathComponent(key)
    }

    private func bind() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = try NWListener(using: parameters)
        listener = server
        server.newConnectionHandler = { [weak self] connection in
            connection.start(queue: DispatchQueue.global(qos: .userInitiated))
            Task { await self?.receive(connection, buffer: Data()) }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            startup = continuation
            let id = ObjectIdentifier(server)
            server.stateUpdateHandler = { [weak self] state in Task { await self?.stateChanged(state, of: id) } }
            server.start(queue: queue)
        }
    }
    private func stateChanged(_ state: NWListener.State, of id: ObjectIdentifier) {
        // A listener that was replaced (`relisten`) says it was cancelled: that isn't the new one's start.
        guard let listener, ObjectIdentifier(listener) == id, let continuation = startup else { return }
        switch state {
        case .ready:
            guard let port = listener.port else { return }
            base = URL(string: "http://127.0.0.1:\(port.rawValue)/\(token)/")!
            startup = nil
            continuation.resume()
        case .failed(let error): startup = nil; continuation.resume(throwing: error)
        case .cancelled: startup = nil; continuation.resume(throwing: CancellationError())
        default: break
        }
    }
    public func stop() {
        listener?.cancel(); listener = nil; routes.removeAll(); keys.removeAll(); prefetched.removeAll()
        startup?.resume(throwing: CancellationError()); startup = nil
    }

    #if DEBUG
    /// QA: `-qaProxyDropAfter <seconds>` stops the listener once, that long after the stream started, as iOS does to
    /// a suspended app's listening sockets.
    private func dropForQA() {
        let seconds = UserDefaults.standard.double(forKey: "qaProxyDropAfter")
        guard seconds > 0, !qaDropped else { return }
        qaDropped = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            await self?.dropListener()
        }
    }
    private func dropListener() {
        Diagnostics.shared.record(.info, "player", "hls proxy qa drop")
        listener?.cancel(); listener = nil
    }
    #endif

    enum Kind { case playlist, segment }
    /// Media names keep their extension, which AVPlayer may go by; anything else is called a transport stream.
    private static let mediaExtensions: Set<String> = ["ts", "m4s", "mp4", "m4a", "m4v", "aac", "mp3", "ac3", "ec3", "vtt", "webvtt", "key"]
    private func register(_ url: URL, kind: Kind) -> URL {
        if let key = keys[url] { return base!.appendingPathComponent(key) }
        let given = url.pathExtension.lowercased()
        let extensionName = kind == .playlist || given == "m3u8" ? "m3u8" : Self.mediaExtensions.contains(given) ? given : "ts"
        let key = UUID().uuidString + "." + extensionName
        routes[key] = url
        keys[url] = key
        return base!.appendingPathComponent(key)
    }

    // MARK: Upstream

    struct Upstream: Sendable {
        var status: Int
        var data: Data
        var mime: String?
        var url: URL
        var contentRange: String?
        /// For an answer the proxy made up because the server couldn't be reached: why, and the `URLError` code.
        var failure: String?
        var code: Int?
    }

    /// The first playlist, within `deadline`: a second request goes out after `hedge` while the first still waits
    /// (a connection that hangs), or 0.4 s after the first failed in a way that may pass; the first answer wins, so a
    /// server that is only slow still counts. AVPlayer itself gives up after 20 s and never asks again.
    private func firstPlaylist(_ url: URL, until deadline: ContinuousClock.Instant, hedge: Duration) async throws -> Upstream {
        enum Attempt: Sendable { case reply(Upstream), failed(Error), hedge, deadline }
        let timeout = Self.seconds(deadline - .now)
        return try await withThrowingTaskGroup(of: Attempt.self) { group in
            var started = 0, running = 0
            func launch(after delay: Duration) {
                started += 1; running += 1
                group.addTask {
                    if delay > .zero { try await Task.sleep(for: delay) }
                    do { return .reply(try await self.download(url, timeout: timeout)) } catch { return .failed(error) }
                }
            }
            launch(after: .zero)
            group.addTask { try await Task.sleep(for: hedge); return .hedge }
            group.addTask { try await Task.sleep(until: deadline); return .deadline }
            var lastError: Error = Self.timedOut
            var lastReply: Upstream?
            while let attempt = try await group.next() {
                switch attempt {
                case .reply(let reply) where !Self.transient(status: reply.status):
                    group.cancelAll(); return reply
                case .reply(let reply):
                    running -= 1; lastReply = reply
                    repaired("retry", host: url.host(), detail: "status=\(reply.status)")
                case .failed(let error):
                    running -= 1; lastError = error
                    guard Self.transient(error), !(error is CancellationError) else { group.cancelAll(); throw error }
                    repaired("retry", host: url.host(), detail: "code=\((error as? URLError)?.code.rawValue ?? 0)")
                case .hedge:
                    if started < 2 { repaired("retry", host: url.host(), detail: "waited=\(hedge.components.seconds)s"); launch(after: .zero) }
                    continue
                case .deadline:
                    group.cancelAll()
                    if let lastReply { return lastReply }
                    throw Self.timedOut
                }
                if running == 0 {
                    if started < 2 { launch(after: .milliseconds(400)); continue }
                    group.cancelAll()
                    if let lastReply { return lastReply }
                    throw lastError
                }
            }
            throw lastError
        }
    }

    /// A playlist AVPlayer asks for itself (a live reload, a variant): two tries of 8 s, as it waits up to 20 s.
    private func fetchPlaylist(_ url: URL) async throws -> Upstream {
        var attempt = 0
        while true {
            attempt += 1
            do {
                let reply = try await download(url, timeout: 8)
                guard Self.transient(status: reply.status), attempt < 2 else { return reply }
                repaired("retry", host: url.host(), detail: "status=\(reply.status)")
            } catch {
                if Task.isCancelled || error is CancellationError { throw error }
                guard Self.transient(error), attempt < 2 else { throw error }
                repaired("retry", host: url.host(), detail: "code=\((error as? URLError)?.code.rawValue ?? 0)")
            }
            try await Task.sleep(for: .milliseconds(400 * attempt))
        }
    }

    /// A playlist, whole: at most 16 MB, and given up on as soon as its first kilobyte is a stream instead of text.
    private func download(_ url: URL, timeout: TimeInterval) async throws -> Upstream {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (stream, reply) = try await URLSession.shared.bytes(for: request)
        guard let response = reply as? HTTPURLResponse else { stream.task.cancel(); throw URLError(.badServerResponse) }
        guard (200..<300).contains(response.statusCode) else {
            stream.task.cancel()
            stats.failed(url.host(), status: response.statusCode, message: nil)
            return Upstream(status: response.statusCode, data: Data(), mime: response.mimeType, url: response.url ?? url)
        }
        var raw = Data()
        var pending = 0
        do {
            for try await byte in stream {
                raw.append(byte); pending += 1
                if raw.count == 1024, let kind = Self.binary(raw) { throw Failure.notPlaylist(kind) }
                if raw.count > Self.playlistLimit { throw Failure.tooLarge }
                if pending == 32 << 10 { stats.received(pending, from: url.host()); pending = 0 }
            }
        } catch {
            stream.task.cancel()
            throw error
        }
        stats.received(pending, from: url.host())
        return Upstream(status: response.statusCode, data: raw, mime: response.mimeType, url: response.url ?? url,
                        contentRange: response.value(forHTTPHeaderField: "Content-Range"))
    }

    /// A segment's answer, up to its headers: two tries of 20 s for a connection that drops or a 502, 503 or 504.
    private func open(_ url: URL, range: String?) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        var attempt = 0
        while true {
            attempt += 1
            do {
                var request = URLRequest(url: url, timeoutInterval: 20)
                headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
                if let range { request.setValue(range, forHTTPHeaderField: "Range") }
                let (stream, reply) = try await URLSession.shared.bytes(for: request)
                guard let response = reply as? HTTPURLResponse else { stream.task.cancel(); throw URLError(.badServerResponse) }
                guard Self.transient(status: response.statusCode), attempt < 2 else { return (stream, response) }
                stream.task.cancel()
                repaired("retry", host: url.host(), detail: "status=\(response.statusCode)")
            } catch {
                if Task.isCancelled || error is CancellationError { throw error }
                guard Self.transient(error), attempt < 2 else { throw error }
                repaired("retry", host: url.host(), detail: "code=\((error as? URLError)?.code.rawValue ?? 0)")
            }
            try await Task.sleep(for: .milliseconds(400 * attempt))
        }
    }

    /// A master playlist's variants and renditions are what AVPlayer asks for next; fetched now, while it waits for
    /// nothing, a slow server holds up only the start, and never past `deadline`.
    private func prefetchVariants(of master: Upstream, until deadline: ContinuousClock.Instant) async {
        guard (200..<300).contains(master.status), let text = HLSSanitizer.text(master.data) else { return }
        let playlist = HLSSanitizer.sanitize(text).text
        guard playlist.contains("#EXT-X-STREAM-INF") else { return }
        let remaining = deadline - .now
        guard remaining > .seconds(2) else { return }
        let addresses = Array(Self.addresses(in: playlist, origin: master.url).filter { $0.playlist }.map(\.url).prefix(6))
        var keyed: [(String, URL)] = []
        for url in addresses { keyed.append((register(url, kind: .playlist).lastPathComponent, url)) }
        let timeout = Self.seconds(remaining)
        let replies = await withTaskGroup(of: (String, Upstream?)?.self) { group in
            for (key, url) in keyed { group.addTask { (key, try? await self.download(url, timeout: timeout)) } }
            group.addTask { try? await Task.sleep(until: deadline); return nil }
            var all: [(String, Upstream?)] = []
            for await reply in group {
                guard let reply else { break }
                all.append(reply)
                if all.count == keyed.count { break }
            }
            group.cancelAll()
            return all
        }
        for case let (key, reply?) in replies { prefetched[key] = (reply, .now) }
    }

    // MARK: Serving

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
            var bytes = buffer
            if let data { bytes.append(data) }
            let request = bytes
            Task {
                guard let self else { connection.cancel(); return }
                if bytes.range(of: Data("\r\n\r\n".utf8)) != nil { await self.serve(connection, request: request) }
                else if error != nil || complete || bytes.count > 16384 { connection.cancel() }
                else { await self.receive(connection, buffer: request) }
            }
        }
    }
    private func serve(_ connection: NWConnection, request: Data) async {
        guard let text = String(data: request, encoding: .utf8), let line = text.components(separatedBy: "\r\n").first else { connection.cancel(); return }
        let fields = line.split(separator: " ")
        guard fields.count >= 2, fields[0] == "GET" || fields[0] == "HEAD" else { send(connection, code: 405, data: Data()); return }
        let path = String(fields[1]).components(separatedBy: "?")[0]
        let parts = path.split(separator: "/")
        guard parts.count == 2, parts[0] == token, let url = routes[String(parts[1])] else { send(connection, code: 404, data: Data()); return }
        let key = String(parts[1])
        let head = fields[0] == "HEAD"
        let range = text.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("range: bytes=") }
            .map { String($0.drop { $0 != "=" }.dropFirst()) }
        if let early = prefetched.removeValue(forKey: key), Date().timeIntervalSince(early.at) < 20 {
            respond(connection, reply: early.reply, url: url, range: range, head: head); return
        }
        guard key.hasSuffix(".m3u8") else { await relay(connection, url: url, range: range, head: head); return }
        do { respond(connection, reply: try await fetchPlaylist(url), url: url, range: range, head: head) }
        catch { fail(connection, url: url, error) }
    }

    private func fail(_ connection: NWConnection, url: URL, _ error: Error) {
        stats.failed(url.host(), status: nil, message: error.localizedDescription, code: (error as? URLError)?.code.rawValue)
        send(connection, code: Self.gatewayStatus(for: error), data: Data())
    }

    /// A whole answer: a playlist, sanitized and pointing here, or the body as it came.
    private func respond(_ connection: NWConnection, reply: Upstream, url: URL, range: String?, head: Bool) {
        guard (200..<300).contains(reply.status) else {
            // Pass the real status on, so AVPlayer and the loading card can tell an expired link from a dead server.
            if reply.failure != nil { stats.failed(url.host(), status: nil, message: reply.failure, code: reply.code) }
            else { stats.failed(url.host(), status: reply.status, message: nil) }
            send(connection, code: (400..<600).contains(reply.status) ? reply.status : 502, data: Data()); return
        }
        if reply.status == 206, let contentRange = reply.contentRange {
            send(connection, code: 206, data: reply.data, mime: reply.mime ?? "application/octet-stream",
                 extra: "Content-Range: \(contentRange)\r\n", head: head); return
        }
        var data = reply.data
        var mime = reply.mime ?? "application/octet-stream"
        if let original = HLSSanitizer.text(data) {
            mime = "application/vnd.apple.mpegurl"
            let sanitized = HLSSanitizer.sanitize(original)
            for fix in sanitized.fixes { repaired(fix, host: url.host(), detail: nil) }
            var playlistText = sanitized.text
            if AdSkip.enabled, let cleaned = AdSkip.clean(playlistText, origin: reply.url) {
                Diagnostics.shared.record(.info, "player", "ads removed runs=\(cleaned.runs) seconds=\(Int(cleaned.seconds)) host=\(cleaned.host)")
                playlistText = cleaned.text
            }
            data = Data(rewrite(playlistText, origin: reply.url).utf8)
        } else {
            let cleaned = MediaPayload.transportStream(data)
            if cleaned.count != data.count { mime = "video/mp2t"; repaired("image-header", host: url.host(), detail: "bytes=\(data.count - cleaned.count)") }
            data = cleaned
        }
        var extra = ""
        var code = 200
        if let range, let low = Int(range.components(separatedBy: "-")[0]), low >= 0, low < data.count {
            let high = min(Int(range.components(separatedBy: "-").last ?? "") ?? (data.count - 1), data.count - 1)
            if high >= low { extra = "Content-Range: bytes \(low)-\(high)/\(data.count)\r\n"; data = Data(data[low...high]); code = 206 }
        }
        send(connection, code: code, data: data, mime: mime, extra: extra, head: head)
    }

    /// A segment, passed on as it comes. Its first 64 KB are looked at first: a picture before the MPEG-TS is dropped
    /// (and the length told AVPlayer shortened by as much), and a playlist under a segment's name is served as one.
    private func relay(_ connection: NWConnection, url: URL, range: String?, head: Bool) async {
        // A segment's byte range (`#EXT-X-BYTERANGE`) is asked of the server: not the whole file each time.
        let forwarded = range == nil || range == "0-" ? nil : range.map { "bytes=" + $0 }
        let stream: URLSession.AsyncBytes, response: HTTPURLResponse
        do { (stream, response) = try await open(url, range: forwarded) }
        catch { fail(connection, url: url, error); return }
        let host = url.host()
        guard (200..<300).contains(response.statusCode) else {
            stream.task.cancel()
            stats.failed(host, status: response.statusCode, message: nil)
            send(connection, code: (400..<600).contains(response.statusCode) ? response.statusCode : 502, data: Data()); return
        }
        var iterator = stream.makeAsyncIterator()
        var first = Data()
        var ended = false
        do {
            while first.count < Self.headLimit {
                guard let byte = try await iterator.next() else { ended = true; break }
                first.append(byte)
            }
        } catch { stream.task.cancel(); fail(connection, url: url, error); return }
        stats.received(first.count, from: host)
        let contentRange = response.value(forHTTPHeaderField: "Content-Range")
        let reply = { (data: Data) in Upstream(status: response.statusCode, data: data, mime: response.mimeType, url: response.url ?? url, contentRange: contentRange) }
        if Self.binary(first) == nil, Self.startsPlaylist(first) || response.mimeType?.lowercased().contains("mpegurl") == true {
            var data = first
            do {
                while !ended, let byte = try await iterator.next() {
                    data.append(byte)
                    if data.count > Self.playlistLimit { throw Failure.tooLarge }
                }
            } catch { stream.task.cancel(); fail(connection, url: url, error); return }
            respond(connection, reply: reply(data), url: url, range: range, head: head); return
        }
        let expected = response.expectedContentLength > 0 ? Int(response.expectedContentLength) : nil
        if response.statusCode == 206, let contentRange {
            let header = Self.header(code: 206, length: expected, mime: response.mimeType ?? "application/octet-stream", extra: "Content-Range: \(contentRange)\r\n")
            await pipe(connection, header: header, first: first, rest: ended ? nil : iterator, task: stream.task, skip: 0, limit: nil, head: head, host: host)
            return
        }
        var body = first
        var mime = response.mimeType ?? "application/octet-stream"
        let cleaned = MediaPayload.transportStream(first)
        let dropped = first.count - cleaned.count
        if dropped > 0 { body = cleaned; mime = "video/mp2t"; repaired("image-header", host: host, detail: "bytes=\(dropped)") }
        let total: Int? = ended ? body.count : expected.map { $0 - dropped }
        var code = 200, extra = "", skip = 0, length = total, limit: Int?
        if let range, let low = Int(range.components(separatedBy: "-")[0]), low >= 0 {
            if let total, low < total {
                let high = min(Int(range.components(separatedBy: "-").last ?? "") ?? (total - 1), total - 1)
                if high >= low {
                    code = 206; extra = "Content-Range: bytes \(low)-\(high)/\(total)\r\n"
                    skip = low; length = high - low + 1; limit = high - low + 1
                }
            } else if total == nil, low > 0 {
                // The server ignored the range and didn't say how long the file is: no part can be cut from it.
                stream.task.cancel()
                stats.failed(host, status: nil, message: "range ignored")
                send(connection, code: 502, data: Data()); return
            }
        }
        let header = Self.header(code: code, length: length, mime: mime, extra: extra)
        await pipe(connection, header: header, first: body, rest: ended ? nil : iterator, task: stream.task, skip: skip, limit: limit, head: head, host: host)
    }

    /// Writes `header`, then `first` and the rest of the upstream body in 64 KB pieces, each after the last was taken,
    /// leaving out `skip` bytes and stopping after `limit`. A reader that went away stops the upstream transfer.
    private func pipe(_ connection: NWConnection, header: Data, first: Data, rest: URLSession.AsyncBytes.AsyncIterator?,
                      task: URLSessionDataTask, skip: Int, limit: Int?, head: Bool, host: String?) async {
        guard await write(connection, header), !head else { task.cancel(); finish(connection); return }
        var skipping = skip, left = limit ?? Int.max
        func take(_ data: Data) -> Data {
            var part = data
            if skipping > 0 { let cut = min(skipping, part.count); part = part.dropFirst(cut); skipping -= cut }
            if part.count > left { part = part.prefix(left) }
            left -= part.count
            return Data(part)
        }
        let opening = take(first)
        guard await write(connection, opening) else { task.cancel(); connection.cancel(); return }
        if var rest, left > 0 {
            var chunk = Data()
            chunk.reserveCapacity(64 << 10)
            do {
                while left > 0, let byte = try await rest.next() {
                    chunk.append(byte)
                    if chunk.count == 64 << 10 {
                        stats.received(chunk.count, from: host)
                        let part = take(chunk)
                        chunk.removeAll(keepingCapacity: true)
                        guard await write(connection, part) else { task.cancel(); connection.cancel(); return }
                    }
                }
                stats.received(chunk.count, from: host)
                let part = take(chunk)
                guard await write(connection, part) else { task.cancel(); connection.cancel(); return }
            } catch {
                // The server dropped the segment midway: AVPlayer sees it end early and asks again.
                stats.failed(host, status: nil, message: error.localizedDescription, code: (error as? URLError)?.code.rawValue)
                task.cancel(); connection.cancel(); return
            }
        }
        task.cancel()
        finish(connection)
    }

    private func write(_ connection: NWConnection, _ data: Data) async -> Bool {
        guard !data.isEmpty else { return true }
        return await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in continuation.resume(returning: error == nil) })
        }
    }
    private func finish(_ connection: NWConnection) {
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// The playlist with every http(s) address in it pointing here.
    private func rewrite(_ text: String, origin: URL) -> String {
        let master = text.contains("#EXT-X-STREAM-INF")
        return text.components(separatedBy: "\n").map { line in
            let value = line.trimmingCharacters(in: .whitespaces)
            if value.isEmpty { return line }
            if !value.hasPrefix("#") {
                guard let url = Self.web(value, origin: origin) else { return line }
                return register(url, kind: master ? .playlist : .segment).absoluteString
            }
            guard let address = HLSSanitizer.attribute("URI", in: value), let url = Self.web(address, origin: origin) else { return line }
            let kind: Kind = value.hasPrefix("#EXT-X-MEDIA:") || value.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") ? .playlist : .segment
            return value.replacingOccurrences(of: "URI=\"\(address)\"", with: "URI=\"\(register(url, kind: kind).absoluteString)\"")
        }.joined(separator: "\n")
    }

    /// An address of the playlist that this proxy fetches: http or https. A `data:` key or an `skd:` one stays as it is.
    private static func web(_ address: String, origin: URL) -> URL? {
        guard let url = URL(string: address, relativeTo: origin)?.absoluteURL, ["http", "https"].contains(url.scheme?.lowercased()) else { return nil }
        return url
    }

    /// The http(s) addresses a playlist names, and whether each is a playlist itself.
    static func addresses(in text: String, origin: URL) -> [(url: URL, playlist: Bool)] {
        let master = text.contains("#EXT-X-STREAM-INF")
        return text.components(separatedBy: "\n").compactMap { line -> (url: URL, playlist: Bool)? in
            let value = line.trimmingCharacters(in: .whitespaces)
            if value.isEmpty { return nil }
            if !value.hasPrefix("#") { return web(value, origin: origin).map { ($0, master) } }
            guard let address = HLSSanitizer.attribute("URI", in: value), let url = web(address, origin: origin) else { return nil }
            return (url, value.hasPrefix("#EXT-X-MEDIA:") || value.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:"))
        }
    }

    private static let reasons = [200: "OK", 206: "Partial Content", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
                                  495: "SSL Certificate Error", 502: "Bad Gateway", 504: "Gateway Timeout"]
    /// A response's head; with no length the body ends when the connection closes.
    static func header(code: Int, length: Int?, mime: String, extra: String = "") -> Data {
        Data(("HTTP/1.1 \(code) \(reasons[code] ?? "Response")\r\nContent-Type: \(mime)\r\n"
              + (length.map { "Content-Length: \($0)\r\n" } ?? "") + "\(extra)Connection: close\r\n\r\n").utf8)
    }
    private func send(_ connection: NWConnection, code: Int, data: Data, mime: String = "text/plain", extra: String = "", head: Bool = false) {
        var response = Self.header(code: code, length: data.count, mime: mime, extra: extra)
        if !head { response.append(data) }
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Notes a repair once per kind for this stream.
    private func repaired(_ kind: String, host: String?, detail: String?) {
        guard !repairs.contains(kind) else { return }
        repairs.append(kind)
        Diagnostics.shared.record(.info, "player", "hls proxy \(kind) host=\(host ?? "-")\(detail.map { " " + $0 } ?? "")")
    }

    // MARK: Policy

    /// What a body that should be text is, when its first bytes are a stream instead: nil for text.
    static func binary(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(1024))
        if bytes.count >= 377, bytes[0] == 0x47, bytes[188] == 0x47, bytes[376] == 0x47 { return "mpeg-ts" }
        if bytes.starts(with: Array("FLV".utf8)) { return "flv" }
        if bytes.count >= 8, Array(bytes[4..<8]) == Array("ftyp".utf8) { return "mp4" }
        if bytes.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) { return "matroska" }
        return bytes.contains(0) ? "binary" : nil
    }
    /// Whether a body starts as a playlist does (after a byte-order mark).
    static func startsPlaylist(_ data: Data) -> Bool {
        let bom = Data([0xEF, 0xBB, 0xBF])
        return (data.starts(with: bom) ? data.dropFirst(3) : data[...]).starts(with: Data("#EXTM3U".utf8))
    }

    /// Failures of an HLS stream played directly that a second try through the proxy can get past: a first playlist
    /// that didn't come in 20 s (-12884), one AVPlayer can't read (-1002, -12642, -12645, -16170, -12646, -15517,
    /// -15519), a master playlist too slow before its long download timer (-16839), or an HTTP 400 for an address
    /// AVPlayer sent with a space or a Chinese character in it (-16845).
    public static func recovers(_ error: Error?) -> Bool {
        let codes: Set<Int> = [-12884, -1002, -12642, -12645, -16170, -12646, -15517, -15519, -16839]
        var current = error as NSError?
        while let error = current {
            if ["CoreMediaErrorDomain", NSOSStatusErrorDomain].contains(error.domain), codes.contains(error.code) { return true }
            if error.domain == "CoreMediaErrorDomain", error.code == -16845, error.localizedDescription.contains("HTTP 400") { return true }
            if error.domain == NSURLErrorDomain, error.code == NSURLErrorUnsupportedURL { return true }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// A server that answered 502, 503 or 504 (CoreMedia -16848, -16849, -16850): behind a plugin's loopback
    /// address, the plugin's own fetch failed, which may work the next time.
    public static func gatewayFailure(_ error: Error?) -> Bool {
        var current = error as NSError?
        while let error = current {
            if error.domain == "CoreMediaErrorDomain", [-16848, -16849, -16850].contains(error.code) { return true }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// A connection that dropped, timed out or couldn't be made, which may work the next time.
    static func transient(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed, .cannotFindHost, .badServerResponse].contains(error.code)
    }
    /// An answer from a busy or briefly broken server.
    static func transient(status: Int) -> Bool { [408, 500, 502, 503, 504].contains(status) }
    /// A certificate or TLS failure: `URLError` -1200 (secure connection failed) through -1206.
    public static func certificate(_ code: Int?) -> Bool { code.map { (-1206 ... -1200).contains($0) } ?? false }
    /// What AVPlayer is told when the server couldn't be reached: it waited too long (504), the certificate was refused
    /// (495, so the player can tell it from a dead server: AVPlayer reports CoreMedia -16845 "HTTP 495", and
    /// `stats.snapshot.code` holds the `URLError` code), or it got nothing (502).
    static func gatewayStatus(for error: Error) -> Int {
        guard let error = error as? URLError else { return 502 }
        if error.code == .timedOut { return 504 }
        return certificate(error.code.rawValue) ? 495 : 502
    }
    /// The start's time budget ran out, in the words the system uses for a request that timed out.
    static let timedOut = URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: "The request timed out."])
    static func seconds(_ duration: Duration) -> TimeInterval {
        max(1, Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
    }
}

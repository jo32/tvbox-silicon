import Foundation
import Network

/// A private loopback endpoint between AVPlayer and an HLS stream. Only URLs found in this playback's playlists are
/// registered; it is not an open web proxy. The Mac plays every HLS stream through it; iPhone, iPad and Apple TV
/// when a stream played directly failed in a way it gets past (`recovers`).
///
/// What it does that AVPlayer alone doesn't, as players built on FFmpeg or ExoPlayer do:
/// - waits for a slow first playlist, and asks again for one that doesn't come (AVPlayer gives up after 20 s with
///   -1008/-12884; ExoPlayer asks again);
/// - repairs playlists AVPlayer refuses (`HLSSanitizer`) and cuts spliced-in ads (`AdSkip`);
/// - drops the picture some hosts put before each MPEG-TS segment (`MediaPayload`);
/// - asks once more after a dropped connection or a 502, 503 or 504, and otherwise passes the server's own status on.
public actor HLSProxy {
    /// Upstream transfer counters for the player's loading card. AVPlayer only sees a segment once
    /// the proxy has all of it, so live speed and upstream errors must come from here.
    public final class Stats: @unchecked Sendable {
        public struct Snapshot { public var received: Int64 = 0; public var host: String?; public var status: Int?; public var failure: String? }
        private let lock = NSLock()
        private var value = Snapshot()
        public var snapshot: Snapshot { lock.withLock { value } }
        func received(_ count: Int, from host: String?) {
            lock.withLock { value.received += Int64(count); value.host = host ?? value.host; value.status = nil; value.failure = nil }
        }
        func failed(_ host: String?, status: Int?, message: String?) {
            lock.withLock { value.host = host ?? value.host; value.status = status; value.failure = message }
        }
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
    private var startup: CheckedContinuation<URL, Error>?
    private var firstURL: URL?
    /// Playlists fetched before AVPlayer asked for them, each served once while fresh.
    private var prefetched: [String: (reply: Upstream, at: Date)] = [:]
    public init(headers: [String: String]) { self.headers = headers }

    /// The loopback address of `url`'s playlist, once that playlist (and a master playlist's variants) is in: AVPlayer's
    /// own wait for it starts only then.
    public func start(url: URL) async throws -> URL {
        let address = try await listen(url)
        let started = Date()
        do {
            let first = try await fetch(url, range: nil, policy: .firstPlaylist)
            prefetched[address.lastPathComponent] = (first, .now)
            await prefetchVariants(of: first)
            let seconds = Date().timeIntervalSince(started)
            if seconds > 15 { repaired("slow-playlist", host: url.host(), detail: "seconds=\(Int(seconds))") }
        } catch {
            // AVPlayer hears of it at once, rather than after another wait for the same server.
            if !Task.isCancelled {
                stats.failed(url.host(), status: nil, message: error.localizedDescription)
                prefetched[address.lastPathComponent] = (Upstream(status: Self.gatewayStatus(for: error), data: Data(), url: url), .now)
            }
        }
        return address
    }

    private func listen(_ url: URL) async throws -> URL {
        firstURL = url
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = try NWListener(using: parameters)
        listener = server
        server.newConnectionHandler = { [weak self] connection in
            connection.start(queue: DispatchQueue.global(qos: .userInitiated))
            Task { await self?.receive(connection, buffer: Data()) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            startup = continuation
            server.stateUpdateHandler = { [weak self] state in Task { await self?.stateChanged(state) } }
            server.start(queue: queue)
        }
    }
    private func stateChanged(_ state: NWListener.State) {
        guard let continuation = startup else { return }
        switch state {
        case .ready:
            guard let port = listener?.port, let firstURL else { return }
            base = URL(string: "http://127.0.0.1:\(port.rawValue)/\(token)/")!
            startup = nil
            continuation.resume(returning: register(firstURL, kind: .playlist))
        case .failed(let error): startup = nil; continuation.resume(throwing: error)
        case .cancelled: startup = nil; continuation.resume(throwing: CancellationError())
        default: break
        }
    }
    public func stop() { listener?.cancel(); listener = nil; routes.removeAll(); keys.removeAll(); prefetched.removeAll() }

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
    }
    enum Policy {
        /// The playlist the stream opens with, before AVPlayer waits for it: a try of 10 s, for a connection that hangs,
        /// then one of 30 s, for a server that is only slow (AVPlayer itself gives up after 20 s).
        case firstPlaylist
        /// A live playlist's reload, or a variant: AVPlayer waits for it, so two tries of 8 s.
        case playlist
        case media
        var attempts: Int { 2 }
        func timeout(_ attempt: Int) -> TimeInterval {
            switch self { case .firstPlaylist: attempt == 1 ? 10 : 30; case .playlist: 8; case .media: 20 }
        }
    }

    private func fetch(_ url: URL, range: String?, policy: Policy) async throws -> Upstream {
        var attempt = 0
        while true {
            attempt += 1
            do {
                let reply = try await download(url, range: range, policy: policy, timeout: policy.timeout(attempt))
                guard Self.transient(status: reply.status), attempt < policy.attempts else { return reply }
                repaired("retry", host: url.host(), detail: "status=\(reply.status)")
            } catch {
                if Task.isCancelled || error is CancellationError { throw error }
                guard Self.transient(error), attempt < policy.attempts else { throw error }
                repaired("retry", host: url.host(), detail: "code=\((error as? URLError)?.code.rawValue ?? 0)")
            }
            try await Task.sleep(for: .milliseconds(400 * attempt))
        }
    }

    private func download(_ url: URL, range: String?, policy: Policy, timeout: TimeInterval) async throws -> Upstream {
        var upstream = URLRequest(url: url, timeoutInterval: timeout)
        if policy != .media { upstream.cachePolicy = .reloadIgnoringLocalCacheData }
        headers.forEach { upstream.setValue($1, forHTTPHeaderField: $0) }
        if let range { upstream.setValue(range, forHTTPHeaderField: "Range") }
        let (stream, reply) = try await URLSession.shared.bytes(for: upstream)
        guard let response = reply as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(response.statusCode) else {
            stats.failed(url.host(), status: response.statusCode, message: nil)
            return Upstream(status: response.statusCode, data: Data(), mime: response.mimeType, url: response.url ?? url)
        }
        var raw = Data()
        if response.expectedContentLength > 0 { raw.reserveCapacity(Int(min(response.expectedContentLength, 64 << 20))) }
        var pending = 0
        for try await byte in stream {
            raw.append(byte); pending += 1
            if pending == 32 << 10 { stats.received(pending, from: url.host()); pending = 0 }
        }
        stats.received(pending, from: url.host())
        return Upstream(status: response.statusCode, data: raw, mime: response.mimeType, url: response.url ?? url,
                        contentRange: response.value(forHTTPHeaderField: "Content-Range"))
    }

    /// A master playlist's variants and renditions are what AVPlayer asks for next; fetched now, while it waits for
    /// nothing, a slow server holds up only the start.
    private func prefetchVariants(of master: Upstream) async {
        guard (200..<300).contains(master.status), let text = HLSSanitizer.text(master.data) else { return }
        let playlist = HLSSanitizer.sanitize(text).text
        guard playlist.contains("#EXT-X-STREAM-INF") else { return }
        let addresses = Array(Self.addresses(in: playlist, origin: master.url).filter { $0.playlist }.map(\.url).prefix(6))
        var keyed: [(String, URL)] = []
        for url in addresses { keyed.append((register(url, kind: .playlist).lastPathComponent, url)) }
        let replies = await withTaskGroup(of: (String, Upstream?).self) { group in
            for (key, url) in keyed { group.addTask { (key, try? await self.fetch(url, range: nil, policy: .firstPlaylist)) } }
            var all: [(String, Upstream?)] = []
            for await reply in group { all.append(reply) }
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
        let playlist = key.hasSuffix(".m3u8")
        let range = text.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("range: bytes=") }
            .map { String($0.drop { $0 != "=" }.dropFirst()) }
        do {
            let reply: Upstream
            if let early = prefetched.removeValue(forKey: key), Date().timeIntervalSince(early.at) < 20 { reply = early.reply }
            // A segment's byte range (`#EXT-X-BYTERANGE`) is asked of the server: not the whole file each time.
            // AVPlayer's `0-` is the whole file, which is sanitized here.
            else { reply = try await fetch(url, range: playlist || range == "0-" ? nil : range.map { "bytes=" + $0 }, policy: playlist ? .playlist : .media) }
            guard (200..<300).contains(reply.status) else {
                // Pass the real status on, so AVPlayer and the loading card can tell an expired link from a dead server.
                stats.failed(url.host(), status: reply.status, message: nil)
                send(connection, code: (400..<600).contains(reply.status) ? reply.status : 502, data: Data()); return
            }
            if reply.status == 206, let contentRange = reply.contentRange {
                send(connection, code: 206, data: reply.data, mime: reply.mime ?? "application/octet-stream",
                     extra: "Content-Range: \(contentRange)\r\n", head: fields[0] == "HEAD"); return
            }
            var data = reply.data
            var mime = reply.mime ?? "application/octet-stream"
            if playlist || data.starts(with: Data("#EXTM3U".utf8)) || mime.lowercased().contains("mpegurl"), let original = HLSSanitizer.text(data) {
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
            send(connection, code: code, data: data, mime: mime, extra: extra, head: fields[0] == "HEAD")
        } catch {
            stats.failed(url.host(), status: nil, message: error.localizedDescription)
            send(connection, code: Self.gatewayStatus(for: error), data: Data())
        }
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

    private func send(_ connection: NWConnection, code: Int, data: Data, mime: String = "text/plain", extra: String = "", head: Bool = false) {
        let reasons = [200: "OK", 206: "Partial Content", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 502: "Bad Gateway", 504: "Gateway Timeout"]
        let reason = reasons[code] ?? "Response"
        let header = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: \(mime)\r\nContent-Length: \(data.count)\r\n\(extra)Connection: close\r\n\r\n"
        var response = Data(header.utf8)
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
    /// What AVPlayer is told when the server couldn't be reached: it waited too long (504) or got nothing (502).
    static func gatewayStatus(for error: Error) -> Int { (error as? URLError)?.code == .timedOut ? 504 : 502 }
}

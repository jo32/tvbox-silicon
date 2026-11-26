import Foundation
import Network
import TVCore

/// A private loopback endpoint for HLS framing compatibility. Only URLs found
/// in this playback's playlists are registered; it is not an open web proxy.
actor HLSProxy {
    /// Upstream transfer counters for the player's loading card. AVPlayer only sees a segment once
    /// the proxy has all of it, so live speed and upstream errors must come from here.
    final class Stats: @unchecked Sendable {
        struct Snapshot { var received: Int64 = 0; var host: String?; var status: Int?; var failure: String? }
        private let lock = NSLock()
        private var value = Snapshot()
        var snapshot: Snapshot { lock.withLock { value } }
        func received(_ count: Int, from host: String?) {
            lock.withLock { value.received += Int64(count); value.host = host ?? value.host; value.status = nil; value.failure = nil }
        }
        func failed(_ host: String?, status: Int?, message: String?) {
            lock.withLock { value.host = host ?? value.host; value.status = status; value.failure = message }
        }
    }
    nonisolated let stats = Stats()
    private let token = UUID().uuidString
    private let headers: [String: String]
    private let renewableLive: Bool
    private let repairsDiscontinuities: Bool
    private let session: URLSession
    private let queue = DispatchQueue(label: "tvbox.hls")
    private var listener: NWListener?
    private var routes: [String: LiveHLSRenewal.Endpoint] = [:]
    private var resourceKeys: [LiveHLSRenewal.Endpoint: String] = [:]
    private var base: URL?
    private var startup: CheckedContinuation<URL, Error>?
    private var firstURL: URL?
    private var rootKey: String?
    private var rootIsDirectLive = false
    private var generation = UUID()
    private var renewal: UUID?
    init(headers: [String: String], renewableLive: Bool = false, repairsDiscontinuities: Bool = false, session: URLSession = .shared) {
        self.headers = headers; self.renewableLive = renewableLive
        self.repairsDiscontinuities = repairsDiscontinuities; self.session = session
    }

    func start(url: URL) async throws -> URL {
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
            let key = UUID().uuidString + ".m3u8"
            rootKey = key
            routes[key] = .init(url: firstURL, headers: headers)
            continuation.resume(returning: base!.appendingPathComponent(key))
        case .failed(let error): startup = nil; continuation.resume(throwing: error)
        case .cancelled: startup = nil; continuation.resume(throwing: CancellationError())
        default: break
        }
    }
    func stop() {
        generation = UUID(); rootIsDirectLive = false; renewal = nil
        listener?.cancel(); listener = nil; routes.removeAll(); resourceKeys.removeAll()
    }
    func renewableRoot() -> LiveHLSRenewal.Endpoint? {
        guard renewableLive, rootIsDirectLive, listener != nil, let rootKey else { return nil }
        return routes[rootKey]
    }
    /// Probe first, then change only the next root request. Each acquired segment
    /// already captured its endpoint and headers, and its route remains valid.
    func renew(expected: LiveHLSRenewal.Endpoint, to fresh: LiveHLSRenewal.Endpoint) async -> Bool {
        guard renewableRoot() == expected, renewal == nil, LiveHLSRenewal.compatible(expected.url, fresh.url) else { return false }
        let owner = generation, operation = UUID(); renewal = operation
        defer { if renewal == operation { renewal = nil } }
        do {
            var request = URLRequest(url: fresh.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            fresh.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
            let (stream, reply) = try await session.bytes(for: request)
            guard let response = reply as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                  LiveHLSRenewal.compatible(fresh.url, response.url ?? fresh.url) else { return false }
            var data = Data()
            for try await byte in stream {
                guard data.count < 4 << 20 else { return false }
                data.append(byte)
            }
            try Task.checkCancellation()
            guard owner == generation, renewal == operation, renewableRoot() == expected,
                  let text = String(data: data, encoding: .utf8), LiveHLSRenewal.directMedia(text), let rootKey else { return false }
            routes[rootKey] = fresh
            return true
        } catch { return false }
    }
    private func register(_ endpoint: LiveHLSRenewal.Endpoint) -> URL {
        if let key = resourceKeys[endpoint] {
            return base!.appendingPathComponent(key)
        }
        let extensionName = endpoint.url.pathExtension.lowercased() == "m3u8" ? "m3u8" : "ts"
        let key = UUID().uuidString + "." + extensionName
        routes[key] = endpoint
        resourceKeys[endpoint] = key
        return base!.appendingPathComponent(key)
    }
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
        guard parts.count == 2, parts[0] == token, let endpoint = routes[String(parts[1])] else { send(connection, code: 404, data: Data()); return }
        let url = endpoint.url, owner = generation
        do {
            var upstream = URLRequest(url: url, timeoutInterval: 25)
            endpoint.headers.forEach { upstream.setValue($1, forHTTPHeaderField: $0) }
            let (stream, reply) = try await session.bytes(for: upstream)
            guard let response = reply as? HTTPURLResponse else { send(connection, code: 502, data: Data()); return }
            guard (200..<300).contains(response.statusCode) else {
                // Pass the real status on, so AVPlayer and the loading card can tell an expired link from a dead server.
                stats.failed(url.host(), status: response.statusCode, message: nil)
                send(connection, code: (400..<600).contains(response.statusCode) ? response.statusCode : 502, data: Data()); return
            }
            var raw = Data()
            if response.expectedContentLength > 0 { raw.reserveCapacity(Int(min(response.expectedContentLength, 64 << 20))) }
            var pending = 0
            for try await byte in stream {
                raw.append(byte); pending += 1
                if pending == 32 << 10 { stats.received(pending, from: url.host()); pending = 0 }
            }
            stats.received(pending, from: url.host())
            var data = raw
            var mime = response.mimeType ?? "application/octet-stream"
            if let playlist = String(data: raw, encoding: .utf8), playlist.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") {
                guard owner == generation, listener != nil else { send(connection, code: 404, data: Data()); return }
                let routeKey = String(parts[1])
                let isCurrent = routes[routeKey] == endpoint
                if routeKey == rootKey, isCurrent {
                    rootIsDirectLive = LiveHLSRenewal.directMedia(playlist)
                }
                mime = "application/vnd.apple.mpegurl"
                var text = playlist
                if AdSkip.enabled, let cleaned = AdSkip.clean(playlist, origin: response.url ?? url) {
                    Diagnostics.shared.record(.info, "player", "ads removed runs=\(cleaned.runs) seconds=\(Int(cleaned.seconds)) host=\(cleaned.host)")
                    text = cleaned.text
                }
                let origin = response.url ?? url
                func route(_ line: String) -> String { rewrite(line, origin: origin, headers: endpoint.headers) }
                if repairsDiscontinuities || renewableLive {
                    text = LiveRepair.repairedMediaPlaylist(text, identity: isCurrent ? token + "/" + routeKey : nil, rewriteLine: route)
                } else {
                    text = text.components(separatedBy: .newlines).map(route).joined(separator: "\n")
                }
                data = Data(text.utf8)
            } else { data = MediaPayload.transportStream(raw); if data.count != raw.count { mime = "video/mp2t" } }
            var extra = ""
            var code = 200
            if let rangeLine = text.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("range: bytes=") }),
               let spec = rangeLine.components(separatedBy: "=").last,
               let low = Int(spec.components(separatedBy: "-")[0]), low >= 0, low < data.count {
                let high = min(Int(spec.components(separatedBy: "-").last ?? "") ?? (data.count - 1), data.count - 1)
                if high >= low { extra = "Content-Range: bytes \(low)-\(high)/\(data.count)\r\n"; data = Data(data[low...high]); code = 206 }
            }
            send(connection, code: code, data: data, mime: mime, extra: extra, head: fields[0] == "HEAD")
        } catch {
            stats.failed(url.host(), status: nil, message: error.localizedDescription)
            send(connection, code: 502, data: Data())
        }
    }
    private func rewrite(_ line: String, origin: URL, headers: [String: String]) -> String {
        func route(_ value: String) -> String {
            guard let url = URL(string: value, relativeTo: origin)?.absoluteURL else { return value }
            return register(.init(url: url, headers: headers)).absoluteString
        }
        let value = line.trimmingCharacters(in: .whitespaces)
        if value.isEmpty { return line }
        if !value.hasPrefix("#") { return route(value) }
        var result = line
        for match in line.matches(of: /URI="([^"]+)"/).reversed() {
            result.replaceSubrange(match.1.startIndex..<match.1.endIndex, with: route(String(match.1)))
        }
        return result
    }
    private func send(_ connection: NWConnection, code: Int, data: Data, mime: String = "text/plain", extra: String = "", head: Bool = false) {
        let header = "HTTP/1.1 \(code) \(code == 200 ? "OK" : "Response")\r\nContent-Type: \(mime)\r\nContent-Length: \(data.count)\r\n\(extra)Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        if !head { response.append(data) }
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}

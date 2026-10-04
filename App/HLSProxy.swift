#if os(macOS)
import Foundation
import Network
import TVCore

/// A private loopback endpoint for HLS framing compatibility. Only URLs found
/// in this playback's playlists are registered; it is not an open web proxy.
actor HLSProxy {
    private let token = UUID().uuidString
    private let headers: [String: String]
    private let queue = DispatchQueue(label: "tvbox.hls")
    private var listener: NWListener?
    private var routes: [String: URL] = [:]
    private var base: URL?
    private var startup: CheckedContinuation<URL, Error>?
    private var firstURL: URL?
    init(headers: [String: String]) { self.headers = headers }

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
            continuation.resume(returning: register(firstURL, playlist: true))
        case .failed(let error): startup = nil; continuation.resume(throwing: error)
        case .cancelled: startup = nil; continuation.resume(throwing: CancellationError())
        default: break
        }
    }
    func stop() { listener?.cancel(); listener = nil; routes.removeAll() }
    private func register(_ url: URL, playlist: Bool = false) -> URL {
        let extensionName = playlist || url.pathExtension.lowercased() == "m3u8" ? "m3u8" : "ts"
        let key = UUID().uuidString + "." + extensionName
        routes[key] = url
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
        guard parts.count == 2, parts[0] == token, let url = routes[String(parts[1])] else { send(connection, code: 404, data: Data()); return }
        do {
            var upstream = URLRequest(url: url, timeoutInterval: 25)
            headers.forEach { upstream.setValue($1, forHTTPHeaderField: $0) }
            let (raw, response) = try await URLSession.shared.data(for: upstream)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { send(connection, code: 502, data: Data()); return }
            var data = raw
            var mime = response.mimeType ?? "application/octet-stream"
            if let playlist = String(data: raw, encoding: .utf8), playlist.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") {
                mime = "application/vnd.apple.mpegurl"
                data = Data(rewrite(playlist, origin: response.url ?? url).utf8)
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
        } catch { send(connection, code: 502, data: Data()) }
    }
    private func rewrite(_ text: String, origin: URL) -> String {
        text.components(separatedBy: .newlines).map { line in
            let value = line.trimmingCharacters(in: .whitespaces)
            if value.isEmpty { return line }
            if !value.hasPrefix("#"), let url = URL(string: value, relativeTo: origin)?.absoluteURL { return register(url).absoluteString }
            guard let regex = try? NSRegularExpression(pattern: "URI=\"([^\"]+)\"") else { return line }
            var result = line
            for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)).reversed() {
                guard let range = Range(match.range(at: 1), in: line), let url = URL(string: String(line[range]), relativeTo: origin)?.absoluteURL,
                      let target = Range(match.range(at: 1), in: result) else { continue }
                result.replaceSubrange(target, with: register(url).absoluteString)
            }
            return result
        }.joined(separator: "\n")
    }
    private func send(_ connection: NWConnection, code: Int, data: Data, mime: String = "text/plain", extra: String = "", head: Bool = false) {
        let header = "HTTP/1.1 \(code) \(code == 200 ? "OK" : "Response")\r\nContent-Type: \(mime)\r\nContent-Length: \(data.count)\r\n\(extra)Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        if !head { response.append(data) }
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
#endif

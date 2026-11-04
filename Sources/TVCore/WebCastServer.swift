import Foundation
import Network

/// What the web UI drives. The app layer (Store) implements this so the web server can list, browse,
/// search and play any source the app can — every subscription the viewer added, plus the built-ins —
/// and control the viewer's own settings, without TVCore depending on SwiftUI.
@MainActor public protocol WebCastDataSource: AnyObject {
    /// The sources to offer, in display order, plus the merged subscription they run against.
    func webCastState() async -> WebCastState
    /// A ready-to-use catalog client for one source, resolved against the merged subscription.
    func webCastClient(for sourceKey: String) async throws -> (CatalogClient, siteName: String)
}

/// A snapshot the web server hands out: every visible source, and the live settings the web UI edits.
public struct WebCastState: Sendable {
    public struct SourceInfo: Codable, Sendable {
        public let key: String
        public let name: String
        public let runtime: String
        public let hidden: Bool
        public init(key: String, name: String, runtime: String, hidden: Bool) {
            self.key = key; self.name = name; self.runtime = runtime; self.hidden = hidden
        }
    }
    public let sources: [SourceInfo]
    public let enabled: Bool
    public let port: Int
    public init(sources: [SourceInfo], enabled: Bool, port: Int) {
        self.sources = sources; self.enabled = enabled; self.port = port
    }
}

/// The embedded web server. A computer on the same Wi-Fi opens `http://<device-ip>:<port>/`, gets the
/// web UI, and drives the app through the JSON API under the per-launch `token`. Media playback relays
/// through the app's own `LocalProxyServer`, so Referer / headers / HTTPS all work from a browser.
///
/// Reuses the `NWListener` pattern of `LocalMediaServer` and `LocalProxyServer`: a raw TCP listener,
/// hand-rolled HTTP, one response per connection (`Connection: close`).
public actor WebCastServer {
    public static let shared = WebCastServer()
    private let queue = DispatchQueue(label: "tvbox.webcast.server")
    private var listener: NWListener?
    private var port: UInt16?
    /// The web UI's own HTML/JS/CSS, embedded as a resource.
    private let webRoot: URL? = Bundle.module.url(forResource: "WebCast", withExtension: nil)

    public func stop() {
        listener?.cancel(); listener = nil; port = nil
    }

    /// Starts listening on the requested port. `bind 0.0.0.0` so other devices on the Wi-Fi reach it;
    /// `NWParameters.tcp` plus a chosen endpoint. Returns the actual port (the requested one, or an
    /// ephemeral one if it was taken).
    public func start(on requestedPort: Int) async throws -> UInt16 {
        if let port, port == UInt16(requestedPort) { return port }
        stop()
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // `on:` binds the port while leaving the address unspecified, so NWListener listens on
        // every interface (0.0.0.0) — the whole point of Web Cast, a computer reaches the phone.
        // Setting `requiredLocalEndpoint` instead would confine it to loopback, unreachable off-device.
        let server = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: UInt16(clamping: requestedPort)) ?? .any)
        listener = server
        server.newConnectionHandler = { connection in
            connection.start(queue: .global(qos: .userInitiated))
            Self.receive(connection, buffer: Data())
        }
        let p = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            // Guard against a double-resume: the state handler keeps firing for the listener's life.
            let resumed = LockedBox<Bool>(false)
            server.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // On `.ready` the port may not be reported yet; ask the listener again and fall
                    // back to the requested port so the continuation always resolves.
                    let actual = server.port?.rawValue ?? UInt16(clamping: requestedPort)
                    if resumed.swap(true) { return }
                    continuation.resume(returning: actual)
                case .failed(let error):
                    if resumed.swap(true) { return }
                    continuation.resume(throwing: error)
                case .cancelled:
                    if resumed.swap(true) { return }
                    continuation.resume(throwing: CancellationError())
                default: break
                }
            }
            server.start(queue: queue)
        }
        port = p
        return p
    }

    /// Set by the app before the server is started; nil until then.
    @MainActor public func attach(_ source: any WebCastDataSource) {
        dataSourceBox = DataSourceBox(source)
    }

    /// The data source, wrapped so it can cross into the server's actor and back. The app sets it once
    /// on the main actor and only ever replaces it there; requests only read it.
    @MainActor private var dataSourceBox: DataSourceBox?

    /// A `@unchecked Sendable` holder for the app's main-actor data source, so the server's request
    /// handlers (which hop off the main actor) can reach it without a sendability error. The value is
    /// written once on the main actor before serving and never mutated afterwards.
    private final class DataSourceBox: @unchecked Sendable {
        let value: any WebCastDataSource
        init(_ value: any WebCastDataSource) { self.value = value }
    }

    // MARK: - HTTP plumbing

    /// Reads one request off the wire on a background queue, then hands it to the main actor, where
    /// the data source lives. Everything after the header is parsed is main-actor work.
    private nonisolated static func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            var bytes = buffer
            if let data { bytes.append(data) }
            if let headerEnd = bytes.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: bytes[..<headerEnd.lowerBound], as: UTF8.self)
                let leftover = Data(bytes[headerEnd.upperBound...])
                Task { @MainActor in
                    await route(connection: connection, head: head, body: leftover)
                }
            } else if error != nil || complete || bytes.count > 1 << 20 {
                connection.cancel()
            } else {
                receive(connection, buffer: bytes)
            }
        }
    }

    @MainActor private static func route(connection: NWConnection, head: String, body: Data) async {
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { send(connection, status: 400); return }
        let fields = requestLine.split(separator: " ")
        guard fields.count >= 2 else { send(connection, status: 400); return }
        let method = String(fields[0])
        let target = String(fields[1])

        // Read Content-Length body (for POST settings) if any remains.
        var requestBody = body
        if let lengthHeader = lines.first(where: { $0.lowercased().hasPrefix("content-length:") }),
           let length = Int(lengthHeader.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)),
           requestBody.count < length {
            requestBody.append(await readBody(connection, length: length))
        }

        guard let dataSource = WebCastServer.shared.dataSourceBox?.value else { send(connection, status: 503, json: ["error": "not ready"]); return }
        await Self.dispatch(method: method, target: target, body: requestBody, head: head, connection: connection, dataSource: dataSource)
    }

    private static func readBody(_ connection: NWConnection, length: Int) async -> Data {
        var collected = Data()
        // The body may arrive across several TCP segments; keep receiving until `length` bytes are in,
        // or the connection signals it is done. A single receive is not enough for a POST split by the
        // network stack.
        while collected.count < length {
            let chunk: Data? = await withCheckedContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: max(length - collected.count, 1)) { data, _, complete, _ in
                    if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if complete {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(returning: data)
                    }
                }
            }
            guard let chunk, !chunk.isEmpty else { break }
            collected.append(chunk)
        }
        return collected
    }

    @MainActor private static func dispatch(method: String, target: String, body: Data, head: String, connection: NWConnection, dataSource: any WebCastDataSource) async {
        // Target: /<route...>?<query>. Split the query off the path first so a route like
        // `/api/<source>/search` isn't seen as `/api/<source>/search?wd=...` (which never matches).
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let route = parts

        // The web UI itself (index.html), its assets, and the login endpoint are always reachable so a
        // browser can load the page and submit the password. Everything else is gated by the login
        // password when one is set, carried as the `X-WebCast-Token` header.
        if route.isEmpty {
            await serveWebFile(connection, path: "index.html")
            return
        }
        if route[0] == "assets" {
            let file = route.dropFirst().joined(separator: "/")
            await serveWebFile(connection, path: "assets/" + file)
            return
        }
        if route[0] == "api", route.count >= 2, route[1] == "login" {
            await handleLogin(target: target, connection: connection, body: body)
            return
        }

        // Gate everything else behind the password (if one is configured). The token can arrive as an
        // `X-WebCast-Token` header (fetch/API calls) or a `?token=` query (plain <img>/<video> tags
        // can't set headers). Header wins when both are present.
        if await requiresAuth() {
            let expected = await WebCastSettings.shared.token
            guard !expected.isEmpty else {
                send(connection, status: 401, json: ["error": "unauthorized"]); return
            }
            let provided = headerValue("X-WebCast-Token", in: head) ?? query(target)["token"]
            guard provided == expected else {
                send(connection, status: 401, json: ["error": "unauthorized"])
                return
            }
        }

        if route[0] == "api" {
            await handleAPI(route: Array(route.dropFirst()), method: method, body: body, target: target, connection: connection, dataSource: dataSource)
            return
        }
        if route[0] == "proxy" {
            await handleProxy(target: target, connection: connection, head: head)
            return
        }
        send(connection, status: 404, json: ["error": "not found"])
    }

    /// Whether the login password is enabled. When off — or when the switch is on but no password is set —
    /// no authentication is applied, so a blank password never locks the viewer out.
    @MainActor private static func requiresAuth() async -> Bool {
        let s = WebCastSettings.shared
        return s.requiresToken && !s.token.isEmpty
    }

    /// `GET /api/login?pwd=...` (or POST with a JSON body) checks the password and returns 200 on match.
    @MainActor private static func handleLogin(target: String, connection: NWConnection, body: Data) async {
        let expected = WebCastSettings.shared.token
        let settings = WebCastSettings.shared
        // No password configured → anything logs in (treats auth as disabled).
        if !settings.requiresToken || expected.isEmpty {
            send(connection, status: 200, json: ["ok": true, "requiresToken": false])
            return
        }
        let q = query(target)
        let candidate: String?
        if let p = q["pwd"] {
            candidate = p
        } else if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let p = obj["pwd"] as? String {
            candidate = p
        } else {
            candidate = nil
        }
        guard let candidate, candidate == expected else {
            send(connection, status: 401, json: ["error": "unauthorized"])
            return
        }
        send(connection, status: 200, json: ["ok": true, "requiresToken": true])
    }

    /// Reads a case-insensitive header value from the raw request head.
    private static func headerValue(_ name: String, in head: String) -> String? {
        let lower = name.lowercased()
        for line in head.components(separatedBy: "\r\n") {
            let idx = line.firstIndex(of: ":") ?? line.endIndex
            let key = line[..<idx].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == lower else { continue }
            return line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    // MARK: - media proxy

    /// Relays a remote media URL (poster image or stream) so a computer's browser can play it. The
    /// browser asks `/proxy/<encoded-url>`; this fetches the URL here and streams the bytes back,
    /// rewriting m3u8 playlists so their segments also come through the proxy.
    private static func handleProxy(target: String, connection: NWConnection, head: String) async {
        // The URL is everything after `/proxy/` in the path, percent-decoded. A trailing `?token=...`
        // (added by the browser for plain <img>/<video> auth) is our own query, not part of the URL.
        guard let marker = target.range(of: "/proxy/") else { send(connection, status: 400); return }
        let encoded = String(target[marker.upperBound...])
        let urlPart = encoded.split(separator: "?", maxSplits: 1).first.map(String.init) ?? encoded
        guard let urlString = urlPart.removingPercentEncoding, let url = URL(string: urlString),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            send(connection, status: 400, json: ["error": "bad proxy url"]); return
        }

        // Pass a Range header through for seeking.
        var headers: [String: String] = ["User-Agent": HTTPClient.userAgent]
        if let rangeLine = head.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("range:") }) {
            headers["Range"] = rangeLine.dropFirst("range:".count).trimmingCharacters(in: .whitespaces)
        }
        // Referer: many CDNs refuse requests without one. Try the URL's own origin.
        if let scheme = url.scheme, let host = url.host {
            headers["Referer"] = "\(scheme)://\(host)/"
        }

        var request = URLRequest(url: url)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 200
            var body = data
            let contentType = http?.mimeType ?? "application/octet-stream"
            // Rewrite m3u8 so segments route back through us.
            if contentType.contains("mpegurl") || url.pathExtension.lowercased() == "m3u8" {
                body = rewriteM3U8(data, base: url)
            }
            send(connection, status: status, body: body, mime: contentType)
        } catch {
            send(connection, status: 502, json: ["error": "proxy failed: \(error.localizedDescription)"])
        }
    }

    private static func rewriteM3U8(_ data: Data, base: URL) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        let baseDir = base.deletingLastPathComponent()
        var out: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { out.append(line); continue }
            let full = trimmed.hasPrefix("http") ? trimmed : baseDir.appendingPathComponent(trimmed).absoluteString
            let encoded = full.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? full
            out.append("/proxy/" + encoded)
        }
        return out.joined(separator: "\n").data(using: .utf8) ?? data
    }

    // MARK: - API

    @MainActor private static func handleAPI(route: [String], method: String, body: Data, target: String, connection: NWConnection, dataSource: any WebCastDataSource) async {
        guard let action = route.first else { send(connection, status: 404); return }

        switch action {
        case "state":
            let state = await dataSource.webCastState()
            send(connection, status: 200, json: stateJSON(state))
        case "sources":
            let state = await dataSource.webCastState()
            send(connection, status: 200, json: ["sources": state.sources.map { ["key": $0.key, "name": $0.name, "runtime": $0.runtime, "hidden": $0.hidden] }])
        case "settings":
            await handleSettings(route: Array(route.dropFirst()), method: method, body: body, connection: connection, dataSource: dataSource)
        default:
            // /api/<source>/<home|category|detail|search|play>
            guard route.count >= 2 else { send(connection, status: 404); return }
            await handleCatalog(source: route[0], action: route[1], target: target, body: body, connection: connection, dataSource: dataSource)
        }
    }

    @MainActor private static func handleCatalog(source: String, action: String, target: String, body: Data, connection: NWConnection, dataSource: any WebCastDataSource) async {
        do {
            let (client, _) = try await dataSource.webCastClient(for: source)
            switch action {
            case "home":
                let page = try await client.home()
                send(connection, status: 200, json: ["class": page.categories.map { ["type_id": $0.id, "type_name": $0.name] }])
            case "category":
                let q = query(target)
                let category = q["id"] ?? q["t"] ?? ""
                let pageNum = Int(q["pg"] ?? "1") ?? 1
                let page = try await client.list(category: category, query: "", page: pageNum)
                send(connection, status: 200, json: pageJSON(page))
            case "detail":
                let q = query(target)
                guard let id = q["id"], !id.isEmpty else { send(connection, status: 400, json: ["error": "missing id"]); return }
                let video = try await client.detail(id)
                send(connection, status: 200, json: videoJSON(video))
            case "search":
                let q = query(target)
                let wd = q["wd"] ?? q["q"] ?? ""
                let pageNum = Int(q["pg"] ?? "1") ?? 1
                let page = try await client.list(category: nil, query: wd, page: pageNum)
                send(connection, status: 200, json: pageJSON(page))
            case "play":
                let q = query(target)
                guard let flag = q["flag"], let address = q["address"], !address.isEmpty else {
                    send(connection, status: 400, json: ["error": "missing flag/address"]); return
                }
                let episode = Episode(id: "0", name: q["name"] ?? "Play", address: address, flag: flag)
                let channel = try await client.playback(episode)
                var out: [String: Any] = ["url": channel.url.absoluteString, "name": channel.name]
                // A non-http(s) URL (e.g. `tvbox-hongguo://…`) is an in-app custom scheme the browser
                // can't play. Flag it so the web UI can show "play in the app" instead of spinning.
                let scheme = channel.url.scheme?.lowercased() ?? ""
                if !scheme.isEmpty, scheme != "http", scheme != "https" {
                    out["scheme"] = scheme
                }
                if !channel.headers.isEmpty { out["headers"] = channel.headers }
                send(connection, status: 200, json: out)
            default:
                send(connection, status: 404, json: ["error": "unknown action"])
            }
        } catch {
            send(connection, status: 500, json: ["error": error.localizedDescription])
        }
    }

    @MainActor private static func handleSettings(route: [String], method: String, body: Data, connection: NWConnection, dataSource: any WebCastDataSource) async {
        // GET /api/settings returns current settings; POST toggles enabled/port/hides a source.
        // (A POST has no sub-path, so `route` is empty — that must NOT be treated as the GET case.)
        if method == "GET" {
            let state = await dataSource.webCastState()
            send(connection, status: 200, json: ["enabled": state.enabled, "port": state.port])
            return
        }
        // The app layer applies mutations; it owns persistence and re-publishes state.
        await MainActor.run {
            if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                if let enabled = obj["enabled"] as? Bool { WebCastSettings.shared.enabled = enabled }
                if let port = obj["port"] as? Int, (1...65535).contains(port) { WebCastSettings.shared.port = port }
                if let proxyMedia = obj["proxyMedia"] as? Bool { WebCastSettings.shared.proxyMedia = proxyMedia }
                if let hide = obj["hideSource"] as? String { WebCastCommands.shared.hide(hide) }
                if let show = obj["showSource"] as? String { WebCastCommands.shared.show(show) }
                // Re-apply the switch/port so the server restarts to match.
                WebCastCommands.shared.apply()
            }
        }
        let state = await dataSource.webCastState()
        send(connection, status: 200, json: ["enabled": state.enabled, "port": state.port])
    }

    // MARK: - JSON

    @MainActor private static func stateJSON(_ state: WebCastState) -> [String: Any] {
        [
            "enabled": state.enabled,
            "port": state.port,
            "proxyMedia": WebCastSettings.shared.proxyMedia,
            "requiresToken": WebCastSettings.shared.requiresToken && !WebCastSettings.shared.token.isEmpty,
            "sources": state.sources.map { ["key": $0.key, "name": $0.name, "runtime": $0.runtime, "hidden": $0.hidden] },
        ]
    }

    private static func pageJSON(_ page: CatalogPage) -> [String: Any] {
        ["list": page.videos.map(videoJSON), "pagecount": page.pageCount]
    }

    private static func videoJSON(_ video: Video) -> [String: Any] {
        [
            "id": video.id,
            "name": video.name,
            "poster": video.poster?.absoluteString ?? "",
            "remarks": video.remarks,
            "synopsis": video.synopsis,
            "year": video.year ?? "",
            "category": video.category ?? "",
            "episodes": video.episodes.map { ["id": $0.id, "name": $0.name, "address": $0.address, "flag": $0.flag] },
        ]
    }

    // MARK: - static files

    private static func serveWebFile(_ connection: NWConnection, path: String) async {
        guard let root = await WebCastServer.shared.webRoot else { send(connection, status: 404); return }
        // Reject path traversal; only serve files under the WebCast resource folder.
        guard !path.contains("..") else { send(connection, status: 404); return }
        let file = root.appendingPathComponent(path).standardizedFileURL
        let rootPrefix = root.standardizedFileURL.path
        guard file.path.hasPrefix(rootPrefix), let data = try? Data(contentsOf: file) else {
            send(connection, status: 404); return
        }
        let mime: String
        switch file.pathExtension.lowercased() {
        case "html": mime = "text/html; charset=utf-8"
        case "js": mime = "application/javascript"
        case "css": mime = "text/css"
        case "svg": mime = "image/svg+xml"
        case "png": mime = "image/png"
        default: mime = "application/octet-stream"
        }
        send(connection, status: 200, body: data, mime: mime)
    }

    // MARK: - response

    private static func query(_ target: String) -> [String: String] {
        guard let q = target.split(separator: "?", maxSplits: 1).last else { return [:] }
        var out: [String: String] = [:]
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = kv.first?.removingPercentEncoding else { continue }
            let value = kv.count > 1 ? kv[1].removingPercentEncoding ?? "" : ""
            out[key] = value
        }
        return out
    }

    private static func send(_ connection: NWConnection, status: Int, json: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        send(connection, status: status, body: data, mime: "application/json; charset=utf-8")
    }

    private static func send(_ connection: NWConnection, status: Int, body: Data = Data(), mime: String = "text/plain") {
        let reason = [200: "OK", 206: "Partial Content", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 500: "Server Error", 503: "Unavailable"][status] ?? "Error"
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(mime)\r\nContent-Length: \(body.count)\r\nAccess-Control-Allow-Origin: *\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// Commands the web UI can issue that mutate the app's state. The app layer sets these closures so
/// the web server (in TVCore) can hide/show sources without importing SwiftUI's Store.
@MainActor public final class WebCastCommands {
    public static let shared = WebCastCommands()
    public var hide: (String) -> Void = { _ in }
    public var show: (String) -> Void = { _ in }
    public var apply: () -> Void = {}
}

/// A tiny thread-safe box for one-shot guards across the listener's state callbacks (which can fire
/// on any queue). `swap` returns the previous value so callers can tell who won the race.
private final class LockedBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    @discardableResult func swap(_ newValue: T) -> T {
        lock.lock(); defer { lock.unlock() }
        let old = value; value = newValue; return old
    }
}

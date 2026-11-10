import Foundation

/// A live plugin room's chat, through the plugin's own danmaku driver (`plugin_js_v1`). The plugin plans the
/// connection (`getDanmaku`: a WebSocket, or HTTP polling); the app opens it and hands each event to the
/// plugin's hooks: `createDanmakuSession`, `onDanmakuOpen`, `onDanmakuFrame` for every frame or poll response,
/// `onDanmakuTick` when the plugin's timer fires, and `destroyDanmakuSession`. Every hook may answer with
/// comments to show (`messages`), frames to send (`writes`), when to call `onDanmakuTick` next (`timer`) and an
/// HTTP request to make (`poll`). A connection that ends is opened again, waiting longer each time.
public final class LivePluginChat: LiveChat, @unchecked Sendable {
    private let plugin: String
    private let room: String
    private let user: String
    private let lock = NSLock()
    private var handler: LiveChatHandler?
    private var task: Task<Void, Never>?

    public init(plugin: String, room: String, user: String) {
        self.plugin = plugin; self.room = room; self.user = user
    }

    public func start(_ handler: @escaping LiveChatHandler) {
        lock.withLock { self.handler = handler }
        let task = Task { [weak self] in guard let self else { return }; await self.run() }
        lock.withLock { self.task = task }
    }

    public func stop() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            handler = nil
            defer { self.task = nil }
            return self.task
        }
        task?.cancel()
    }

    private func run() async {
        let runtime = LivePluginRuntime.shared
        guard await runtime.has(plugin, "getDanmaku"), await runtime.has(plugin, "createDanmakuSession") else {
            Diagnostics.shared.record(.info, "live.chat", "plugin \(plugin) has no danmaku")
            return
        }
        var failures = 0
        while !Task.isCancelled {
            let started = ContinuousClock.now
            do {
                try await connect()
            } catch is CancellationError {
                break
            } catch {
                if !Task.isCancelled { Diagnostics.shared.record(.warning, "live.chat", "plugin \(plugin) room=\(room) \(error.localizedDescription)") }
            }
            guard !Task.isCancelled else { break }
            // 2, 4, 8 … 64 s between tries; a connection that lasted a minute starts the count again.
            failures = ContinuousClock.now - started > .seconds(60) ? 1 : failures + 1
            guard failures <= 8 else {
                Diagnostics.shared.record(.warning, "live.chat", "plugin \(plugin) room=\(room) gave up after \(failures - 1) tries")
                break
            }
            try? await Task.sleep(for: .seconds(1 << failures))
        }
    }

    private func deliver(_ message: [String: JSONValue]) {
        guard let handler = lock.withLock({ handler }), let text = Self.text(message) else { return }
        handler(text, Self.color(message["color"]), .scroll)
    }

    /// One connection, from the plan until it ends.
    private func connect() async throws {
        let runtime = LivePluginRuntime.shared
        var payload: [String: JSONValue] = ["roomId": .string(room)]
        if !user.isEmpty { payload["userId"] = .string(user) }
        let plan = try await runtime.call(plugin, "getDanmaku", payload, timeout: 30).object ?? [:]
        let args = plan["args"]?.object ?? [:]
        var transport = plan["transport"]?.object ?? [:]
        // Older plugins name the address in `args` only.
        if transport["url"]?.string?.isEmpty ?? true {
            if let address = args["ws_url"]?.string, !address.isEmpty {
                transport["url"] = .string(address); transport["kind"] = .string("websocket")
            } else if let address = args["_polling_url"]?.string, !address.isEmpty {
                transport["url"] = .string(address); transport["kind"] = .string("http_polling")
                if let method = args["_polling_method"]?.string { transport["polling"] = .object(["method": .string(method), "sendOnConnect": .bool(true)]) }
            }
        }
        guard let address = transport["url"]?.string.flatMap(URL.init(string:)), let scheme = address.scheme?.lowercased(),
              ["ws", "wss", "http", "https"].contains(scheme) else {
            throw LivePluginError(code: "UNSUPPORTED", message: "no danmaku address")
        }
        let polling = transport["kind"]?.string == "http_polling"
        var headers = (plan["headers"]?.object ?? [:]).compactMapValues(\.string)
        if plan["runtime"]?.object?["webSocketHeaderMode"]?.string == "minimal_no_cookie" {
            headers = headers.filter { $0.key.lowercased() != "cookie" }
        }

        let id = UUID().uuidString
        let connection = PluginChatConnection(plugin: plugin, id: id) { [weak self] in self?.deliver($0) }
        defer {
            // Not cancelled with the chat: the plugin forgets the session either way.
            let plugin = plugin
            Task.detached {
                await connection.close()
                _ = try? await LivePluginRuntime.shared.call(plugin, "destroyDanmakuSession", ["connectionId": .string(id), "reason": .string("disconnect")], timeout: 10)
            }
        }
        var create: [String: JSONValue] = ["connectionId": .string(id), "roomId": .string(room), "args": .object(args),
                                           "headers": .object(headers.mapValues(JSONValue.string)), "transport": .object(transport),
                                           "credentialAvailable": .bool(LivePluginAccounts.isSignedIn(plugin))]
        if !user.isEmpty { create["userId"] = .string(user) }
        Diagnostics.shared.record(.info, "live.chat", "plugin \(plugin) room=\(room) connecting \(polling ? "polling" : "websocket") host=\(address.host() ?? "-")")
        await connection.apply(try await runtime.call(plugin, "createDanmakuSession", create, timeout: 30))

        // Stopping the chat closes the socket or the polls, which a waiting receive doesn't notice by itself.
        try await withTaskCancellationHandler {
            try await run(connection, id: id, address: address, polling: polling, transport: transport, headers: headers)
        } onCancel: {
            Task { await connection.close() }
        }
    }

    private func run(_ connection: PluginChatConnection, id: String, address: URL, polling: Bool,
                     transport: [String: JSONValue], headers: [String: String]) async throws {
        let runtime = LivePluginRuntime.shared
        if polling {
            await connection.apply(try await runtime.call(plugin, "onDanmakuOpen", ["connectionId": .string(id)], timeout: 30))
            let options = transport["polling"]?.object ?? [:]
            if options["sendOnConnect"].map({ if case .bool(true) = $0 { true } else { false } }) ?? false {
                await connection.pollOnce(fallback: ["url": .string(address.absoluteString), "method": options["method"] ?? .string("GET")])
            }
            try await connection.runPolls(defaultHeaders: headers)
        } else {
            var request = URLRequest(url: address, timeoutInterval: 20)
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            let protocols = (transport["subprotocols"]?.array ?? []).compactMap(\.string)
            if !protocols.isEmpty { request.setValue(protocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol") }
            try await connection.runSocket(request)
        }
    }

    /// A message's text: `text`, else its segments' text with images as their `alt`.
    static func text(_ message: [String: JSONValue]) -> String? {
        var text = message["text"]?.string ?? ""
        if text.isEmpty {
            text = (message["segments"]?.array ?? []).prefix(32).compactMap(\.object).map { segment in
                segment["type"]?.string == "image" ? (segment["alt"]?.string ?? "") : (segment["text"]?.string ?? "")
            }.joined()
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(200))
    }

    /// 0xRRGGBB; white when the plugin gives none (or black, which wouldn't show on video).
    static func color(_ value: JSONValue?) -> UInt32 {
        let number: Double? = switch value {
        case .number(let number): number
        case .string(let text): text.hasPrefix("#") ? UInt32(text.dropFirst(), radix: 16).map(Double.init) : Double(text)
        default: nil
        }
        guard let number, number.isFinite, number > 0, number <= 0xFFFFFF else { return 0xFFFFFF }
        return UInt32(number)
    }
}

/// One danmaku connection's state: frames waiting for the socket to open, the timer, and the plugin's polls.
actor PluginChatConnection {
    private static let network: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    let plugin: String
    let id: String
    private let deliver: @Sendable ([String: JSONValue]) -> Void
    private var socket: URLSessionWebSocketTask?
    private var waiting: [URLSessionWebSocketTask.Message] = []
    private var timer: Task<Void, Never>?
    private var closed = false
    private let polls: AsyncStream<[String: JSONValue]>
    private let pollQueue: AsyncStream<[String: JSONValue]>.Continuation
    private var polled = false
    /// The first frames each way go to the log, for reports of a chat that stays empty.
    private var logged = 0

    init(plugin: String, id: String, deliver: @escaping @Sendable ([String: JSONValue]) -> Void) {
        self.plugin = plugin; self.id = id; self.deliver = deliver
        (polls, pollQueue) = AsyncStream.makeStream(of: [String: JSONValue].self, bufferingPolicy: .bufferingNewest(4))
    }

    /// Acts on what a hook answered.
    func apply(_ reply: JSONValue) async {
        guard !closed, let reply = reply.object else { return }
        let messages = (reply["messages"]?.array ?? []).compactMap(\.object)
        for message in messages { deliver(message) }
        for write in reply["writes"]?.array ?? [] {
            guard let frame = Self.frame(write) else { continue }
            if case .string(let text) = frame { note("out", text) } else { note("out", "binary") }
            if let socket { try? await socket.send(frame) } else { waiting.append(frame) }
        }
        if let poll = reply["poll"]?.object { polled = true; pollQueue.yield(poll) }
        if let timer = reply["timer"]?.object { schedule(timer) }
    }

    func close() {
        closed = true
        timer?.cancel(); timer = nil
        pollQueue.finish()
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
    }

    // MARK: WebSocket

    func runSocket(_ request: URLRequest) async throws {
        let socket = Self.network.webSocketTask(with: request)
        let opening = SocketOpening()
        socket.delegate = opening
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }
        try await opening.wait(seconds: 20)
        guard !closed else { return }
        self.socket = socket
        for frame in waiting { try? await socket.send(frame) }
        waiting = []
        await apply(try await LivePluginRuntime.shared.call(plugin, "onDanmakuOpen", ["connectionId": .string(id)], timeout: 30))
        while !closed {
            let message = try await socket.receive()
            var frame: [String: JSONValue] = ["connectionId": .string(id)]
            switch message {
            case .string(let text): frame["frameType"] = .string("text"); frame["text"] = .string(text)
            case .data(let data): frame["frameType"] = .string("binary"); frame["bytesBase64"] = .string(data.base64EncodedString())
            @unknown default: continue
            }
            note("in", frame["text"]?.string ?? "\(frame["bytesBase64"]?.string?.count ?? 0) base64 bytes")
            // A frame the plugin can't read is skipped, not the end of the chat.
            if let reply = try? await LivePluginRuntime.shared.call(plugin, "onDanmakuFrame", frame, timeout: 30) { await apply(reply) }
        }
    }

    // MARK: HTTP polling

    /// Makes the first request when the plugin asked for one on connect but gave none itself.
    func pollOnce(fallback: [String: JSONValue]) { if !polled { polled = true; pollQueue.yield(fallback) } }

    /// Makes each request the plugin asks for and gives it the response, until the connection closes.
    func runPolls(defaultHeaders: [String: String]) async throws {
        var last = ContinuousClock.now - .seconds(1)
        var failures = 0
        for await poll in polls {
            guard !closed else { break }
            // At most one request a second, whatever the plugin asks.
            let wait = last + .seconds(1) - ContinuousClock.now
            if wait > .zero { try await Task.sleep(for: wait) }
            last = ContinuousClock.now
            guard let request = Self.request(poll, headers: defaultHeaders) else { continue }
            var frame: [String: JSONValue] = ["connectionId": .string(id), "frameType": .string("http_response")]
            do {
                let (data, response) = try await Self.network.data(for: request)
                let http = response as? HTTPURLResponse
                frame["statusCode"] = .number(Double(http?.statusCode ?? 0))
                frame["responseHeaders"] = .object(Dictionary((http?.allHeaderFields ?? [:]).compactMap { key, value in
                    (key as? String).map { ($0, JSONValue.string("\(value)")) }
                }, uniquingKeysWith: { first, _ in first }))
                if let text = String(data: data, encoding: .utf8) { frame["text"] = .string(text) } else { frame["bytesBase64"] = .string(data.base64EncodedString()) }
                failures = 0
            } catch {
                if closed || Task.isCancelled { break }
                failures += 1
                // Ten failed requests in a row end the connection; the chat opens a new one.
                if failures >= 10 { throw error }
                frame["statusCode"] = .number(0)
            }
            if let reply = try? await LivePluginRuntime.shared.call(plugin, "onDanmakuFrame", frame, timeout: 30) { await apply(reply) }
        }
    }

    // MARK: Timer

    private func schedule(_ settings: [String: JSONValue]) {
        timer?.cancel(); timer = nil
        let mode = settings["mode"]?.string ?? "off"
        guard mode != "off", let interval = Self.number(settings["intervalMs"]), interval > 0 else { return }
        let milliseconds = Int(min(max(interval, 1000), 600_000))
        let reason = mode == "polling" ? "polling" : "heartbeat"
        timer = Task { [plugin, id] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(milliseconds))
                guard !Task.isCancelled else { break }
                let reply = try? await LivePluginRuntime.shared.call(plugin, "onDanmakuTick", ["connectionId": .string(id), "reason": .string(reason)], timeout: 30)
                guard !Task.isCancelled else { break }
                // A new timer in the reply replaces this one.
                if let reply { await self.apply(reply) }
            }
        }
    }

    // MARK: Helpers

    private func note(_ direction: String, _ text: String) {
        guard logged < 6 else { return }
        logged += 1
        Diagnostics.shared.record(.debug, "live.chat", "plugin \(plugin) \(direction) \(text.prefix(160))")
    }

    private static func number(_ value: JSONValue?) -> Double? {
        switch value {
        case .number(let number): number
        case .string(let text): Double(text)
        default: nil
        }
    }

    private static func frame(_ write: JSONValue) -> URLSessionWebSocketTask.Message? {
        guard let write = write.object else { return nil }
        if write["kind"]?.string == "binary" {
            return write["bytesBase64"]?.string.flatMap { Data(base64Encoded: LoadedLivePlugin.padded($0)) }.map { .data($0) }
        }
        return write["text"]?.string.map { .string($0) }
    }

    /// The request a poll describes: `url` (with `query` added), `method`, `headers` over the plan's, and a body.
    private static func request(_ poll: [String: JSONValue], headers: [String: String]) -> URLRequest? {
        guard let address = poll["url"]?.string, var parts = URLComponents(string: address),
              let scheme = parts.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        if let query = poll["query"]?.object, !query.isEmpty {
            parts.queryItems = (parts.queryItems ?? []) + query.keys.sorted().compactMap { key in query[key]?.string.map { URLQueryItem(name: key, value: $0) } }
        }
        guard let url = parts.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = (poll["method"]?.string ?? "GET").uppercased()
        for (name, value) in headers where name.lowercased() != "cookie" { request.setValue(value, forHTTPHeaderField: name) }
        for (name, value) in (poll["headers"]?.object ?? [:]).compactMapValues(\.string) where name.lowercased() != "cookie" {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body = poll["bodyText"]?.string { request.httpBody = Data(body.utf8) }
        else if let body = poll["bodyBase64"]?.string { request.httpBody = Data(base64Encoded: LoadedLivePlugin.padded(body)) }
        return request
    }
}

/// Waits for a WebSocket's handshake to finish (or fail).
final class SocketOpening: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var waiter: CheckedContinuation<Void, Error>?

    func wait(seconds: Double) async throws {
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            self?.finish(.failure(URLError(.timedOut)))
        }
        defer { timeout.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let done = lock.withLock { () -> Result<Void, Error>? in
                if result == nil { waiter = continuation }
                return result
            }
            if let done { continuation.resume(with: done) }
        }
    }

    private func finish(_ outcome: Result<Void, Error>) {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard result == nil else { return nil }
            result = outcome
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume(with: outcome)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        finish(.success(()))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(.failure(error ?? URLError(.networkConnectionLost)))
    }
}

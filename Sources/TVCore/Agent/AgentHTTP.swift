import Foundation

// What the two model clients share: the bearer token, the request, Server-Sent Events, `GET /models`, and turning a
// server's refusal into an `AgentFailure` the viewer can act on. Wire details follow OpenAI's API reference and the
// MIT-licensed ChatClientKit (github.com/Lakr233/ChatClientKit), whose parsing ideas this adapts.

/// The bearer token for a request, or nil for a server that needs none (a local one). The ChatGPT sign-in refreshes
/// its token here, so it is asked for each request. Throws `AgentFailure`.
public typealias AgentAuthorization = @Sendable () async throws -> String?

/// One Server-Sent Event: its `event:` name (if any) and its `data:` lines joined.
struct SSEEvent: Equatable, Sendable {
    var name: String?
    var data: String
}

/// Splits a stream's lines into events (html.spec.whatwg.org, "server-sent events"): `data:` lines add up until an
/// empty line; `:` lines are comments.
struct SSEParser {
    private var name: String?
    private var data: [String] = []

    mutating func feed(_ line: String) -> SSEEvent? {
        if line.isEmpty { return flush() }
        if line.hasPrefix(":") { return nil }
        let field: Substring, value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            var rest = line[line.index(after: colon)...]
            if rest.first == " " { rest = rest.dropFirst() }
            value = rest
        } else { field = Substring(line); value = "" }
        switch field {
        case "data": data.append(String(value))
        case "event": name = String(value)
        default: break
        }
        return nil
    }

    /// The event still open when the stream ends without its empty line.
    mutating func flush() -> SSEEvent? {
        defer { name = nil; data = [] }
        guard !data.isEmpty else { return nil }
        return SSEEvent(name: name, data: data.joined(separator: "\n"))
    }

    /// Every event in `text` (tests and whole bodies).
    static func events(in text: String) -> [SSEEvent] {
        var parser = SSEParser()
        var events: [SSEEvent] = []
        // By scalars: "\r\n" is one Character, so a Character split would miss its "\n".
        for line in text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(String.UnicodeScalarView(line))
            if line.hasSuffix("\r") { line.removeLast() }
            if let event = parser.feed(line) { events.append(event) }
        }
        if let event = parser.flush() { events.append(event) }
        return events
    }
}

/// Turns one wire's events into `AgentEvent`s. `decode` may throw the server's failure; `finish` runs when the body
/// ends and throws when it ended too soon.
protocol AgentStreamDecoder {
    mutating func decode(_ event: SSEEvent) throws -> [AgentEvent]
    /// True once the server said the answer is complete.
    var isDone: Bool { get }
    mutating func finish() throws -> [AgentEvent]
}

enum AgentHTTP {
    static let errorBodyLimit = 65_536

    static func request(_ url: URL, method: String = "POST", body: JSONValue? = nil, authorization: AgentAuthorization) async throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 120
        if let body {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            request.httpBody = try encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token = try await authorization()?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Runs a streaming request: yields what `decoder` makes of each event, and finishes when the body ends. A non-2xx
    /// answer, a lost connection and a body that ends too soon throw `AgentFailure`.
    static func stream<Decoder: AgentStreamDecoder & Sendable>(_ label: String, session: URLSession, model: String,
                                                                 build: @escaping @Sendable () async throws -> URLRequest,
                                                                 decoder: Decoder) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let started = Date()
                var requestID = "-"
                do {
                    var request = try await build()
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw AgentFailure(.invalidResponse, AgentFailures.unreadable) }
                    requestID = http.value(forHTTPHeaderField: "x-request-id") ?? "-"
                    guard (200..<300).contains(http.statusCode) else {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count >= errorBodyLimit { break }
                        }
                        throw AgentFailures.failure(status: http.statusCode, body: body)
                    }
                    var decoder = decoder
                    var parser = SSEParser()
                    var line: [UInt8] = []
                    func handle(_ event: SSEEvent?) throws {
                        guard let event else { return }
                        for item in try decoder.decode(event) { continuation.yield(item) }
                    }
                    for try await byte in bytes {
                        if byte == 10 {
                            if line.last == 13 { line.removeLast() }
                            try handle(parser.feed(String(decoding: line, as: UTF8.self)))
                            line.removeAll(keepingCapacity: true)
                            if decoder.isDone { break }
                        } else { line.append(byte) }
                    }
                    if !decoder.isDone {
                        if !line.isEmpty { _ = parser.feed(String(decoding: line, as: UTF8.self)) }
                        try handle(parser.flush())
                    }
                    var usage = ""
                    for item in try decoder.finish() {
                        if case .finished(let input, let output) = item { usage = " in=\(input.map(String.init) ?? "-") out=\(output.map(String.init) ?? "-")" }
                        continuation.yield(item)
                    }
                    Diagnostics.shared.record(.info, "assistant", "\(label) done model=\(model) request=\(requestID)\(usage) \(elapsed(started))")
                    continuation.finish()
                } catch {
                    let failure = AgentFailures.failure(error)
                    if failure.kind == .cancelled {
                        Diagnostics.shared.record(.info, "assistant", "\(label) cancelled model=\(model) request=\(requestID) \(elapsed(started))")
                    } else {
                        Diagnostics.shared.record(.warning, "assistant", "\(label) failed model=\(model) request=\(requestID) kind=\(failure.kind.rawValue) status=\(failure.status.map(String.init) ?? "-") code=\(failure.code ?? "-") \(elapsed(started))")
                    }
                    continuation.finish(throwing: failure)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `GET {base}/models`: the ChatGPT sign-in's list (entries with `visibility == "list"`, in the server's order,
    /// `slug` and `display_name`) or a plain OpenAI-style one (`data[].id`, chat models only, `gpt-*` first).
    static func models(base: URL, session: URLSession, authorization: AgentAuthorization) async throws -> [AgentModelInfo] {
        let started = Date()
        do {
            let request = try await AgentHTTP.request(base.appending(path: "models"), method: "GET", authorization: authorization)
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { throw AgentFailures.failure(status: status, body: data) }
            guard let body = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw AgentFailure(.invalidResponse, AgentFailures.unreadable, status: status) }
            let models = parseModels(body)
            Diagnostics.shared.record(.info, "assistant", "models status=\(status) count=\(models.count) \(elapsed(started))")
            return models
        } catch {
            let failure = AgentFailures.failure(error)
            Diagnostics.shared.record(.warning, "assistant", "models failed kind=\(failure.kind.rawValue) status=\(failure.status.map(String.init) ?? "-") code=\(failure.code ?? "-")")
            throw failure
        }
    }

    static func parseModels(_ body: JSONValue) -> [AgentModelInfo] {
        let entries = body["models"]?.array ?? body["data"]?.array ?? body.array ?? []
        if entries.contains(where: { $0["slug"] != nil || $0["visibility"] != nil }) {
            return entries.compactMap { entry in
                guard entry["visibility"]?.string == "list", let slug = entry["slug"]?.string ?? entry["id"]?.string else { return nil }
                return AgentModelInfo(id: slug, name: entry["display_name"]?.string ?? slug)
            }
        }
        // Models that can't chat, by the names OpenAI and the usual compatible servers give them.
        let other = ["embed", "tts", "whisper", "dall-e", "davinci", "babbage", "moderation", "image", "audio", "realtime", "transcribe", "search-api", "sora", "rerank"]
        let ids = entries.compactMap { $0["id"]?.string }.filter { id in !other.contains { id.lowercased().contains($0) } }
        var seen = Set<String>()
        let unique = ids.filter { seen.insert($0).inserted }
        let ranked = unique.filter { $0.hasPrefix("gpt-") }.sorted { $0.localizedStandardCompare($1) == .orderedDescending }
            + unique.filter { !$0.hasPrefix("gpt-") }
        return ranked.map { AgentModelInfo(id: $0, name: $0) }
    }

    static func elapsed(_ started: Date) -> String { String(format: "%.2fs", Date().timeIntervalSince(started)) }
}

/// The viewer-facing failures: HTTP statuses and OpenAI's error codes, with what to do about each.
public enum AgentFailures {
    static var unreadable: String { L10n.text("The server's answer couldn't be read.") }

    /// Any error as an `AgentFailure`: URL errors become `network` (or `cancelled`), cancellation `cancelled`.
    public static func failure(_ error: Error) -> AgentFailure {
        if let failure = error as? AgentFailure { return failure }
        if error is CancellationError { return AgentFailure(.cancelled, L10n.text("Stopped.")) }
        if let url = error as? URLError {
            if url.code == .cancelled { return AgentFailure(.cancelled, L10n.text("Stopped.")) }
            return AgentFailure(.network, L10n.text("Couldn't reach the assistant's server. Check your connection and try again."), code: "url\(url.code.rawValue)")
        }
        if error is DecodingError || error is EncodingError { return AgentFailure(.invalidResponse, unreadable) }
        return AgentFailure(.server, error.localizedDescription)
    }

    /// A refusal from the server: its status and body (`{"error": {...}}`, `{"detail": "..."}` or text).
    public static func failure(status: Int, body: Data) -> AgentFailure {
        let json = try? JSONDecoder().decode(JSONValue.self, from: body)
        let error = json?["error"]
        let code = error?["code"]?.string ?? error?["type"]?.string ?? error?.string
        let message = error?["message"]?.string ?? json?["detail"]?.string ?? json?["message"]?.string ?? json?["error_description"]?.string
            ?? (json == nil ? String(decoding: body.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : nil)
        return failure(code: code, message: message, status: status)
    }

    /// A failure the server named by `code` (the `error.code` of a body or of a `response.failed` event).
    public static func failure(code: String?, message: String?, status: Int?) -> AgentFailure {
        let detail = message.flatMap { $0.isEmpty ? nil : String($0.prefix(300)) }
        func make(_ kind: AgentFailure.Kind, _ text: String) -> AgentFailure { AgentFailure(kind, text, code: code, status: status) }
        switch code {
        case "subscription_sharing_usage_limit_exceeded":
            return make(.usageLimit, L10n.text("You've reached your ChatGPT plan's usage limit. See chatgpt.com/settings/usage, or use an API key meanwhile."))
        case "subscription_sharing_user_not_eligible":
            return make(.unavailable, L10n.text("Your ChatGPT plan can't be used here. You can use an API key instead."))
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable":
            return make(.unavailable, L10n.text("ChatGPT couldn't check your plan right now. Try again in a moment."))
        case "subscription_sharing_unsupported_capability", "subscription_sharing_route_not_supported":
            return make(.unsupported, L10n.text("This model or feature isn't available with your ChatGPT plan. Try another model."))
        case "subscription_sharing_invalid_user", "chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context":
            return make(.unauthorized, L10n.text("ChatGPT didn't accept this sign-in. Sign in with ChatGPT again in Settings › Assistant."))
        case "invalid_api_key", "invalid_authentication", "authentication_error":
            return make(.unauthorized, L10n.text("The server refused the API key. Check it in Settings › Assistant."))
        case "insufficient_quota", "billing_hard_limit_reached":
            return make(.usageLimit, L10n.text("Your API account has no credit left. Check its billing page."))
        case "rate_limit_exceeded":
            return make(.usageLimit, L10n.text("Too many requests. Wait a moment and try again."))
        case "model_not_found":
            return make(.unsupported, L10n.text("This model isn't available. Pick another one in Settings › Assistant."))
        case "context_length_exceeded", "string_above_max_length":
            return make(.unsupported, L10n.text("The conversation is too long for this model. Clear it and start again."))
        default: break
        }
        switch status ?? 0 {
        case 401: return make(.unauthorized, L10n.text("The server refused the API key. Check it in Settings › Assistant."))
        case 403: return make(.unavailable, detail.map { L10n.text("Access was refused: %@", $0) } ?? L10n.text("Access was refused."))
        case 404: return make(.unsupported, L10n.text("The server doesn't offer this. Check the address and the API type in Settings › Assistant."))
        case 429: return make(.usageLimit, L10n.text("Too many requests. Wait a moment and try again."))
        case 503: return make(.unavailable, L10n.text("The service is unavailable right now. Try again in a moment."))
        case 400..<500: return make(.unsupported, L10n.text("The server refused the request: %@", detail ?? "HTTP \(status ?? 0)"))
        case 500..<600: return make(.server, L10n.text("The server had a problem (%@). Try again in a moment.", "HTTP \(status ?? 0)"))
        default: return make(.server, detail.map { L10n.text("The server had a problem (%@). Try again in a moment.", $0) } ?? unreadable)
        }
    }
}

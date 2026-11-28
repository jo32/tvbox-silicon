import Foundation

/// The Chat Completions API most OpenAI-compatible servers speak: `POST {base}/chat/completions` with `stream: true`.
/// Tool calls arrive in pieces (`delta.tool_calls[]` by `index`) and are put together when the stream ends.
public struct ChatCompletionsClient: AgentModelClient {
    public let baseURL: URL
    private let authorization: AgentAuthorization
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared, authorization: @escaping AgentAuthorization) {
        self.baseURL = baseURL; self.session = session; self.authorization = authorization
    }

    public func stream(model: String, instructions: String, messages: [AgentMessage], tools: [AgentToolSpec]) -> AsyncThrowingStream<AgentEvent, Error> {
        let body = Self.body(model: model, instructions: instructions, messages: messages, tools: tools)
        let url = baseURL.appending(path: "chat/completions")
        let authorization = authorization
        Diagnostics.shared.record(.info, "assistant", "chat request model=\(model) messages=\(messages.count) tools=\(tools.count)")
        return AgentHTTP.stream("chat", session: session, model: model,
                                build: { try await AgentHTTP.request(url, body: body, authorization: authorization) },
                                decoder: ChatCompletionsDecoder())
    }

    public func models() async throws -> [AgentModelInfo] {
        try await AgentHTTP.models(base: baseURL, session: session, authorization: authorization)
    }

    static func body(model: String, instructions: String, messages: [AgentMessage], tools: [AgentToolSpec]) -> JSONValue {
        var list: [JSONValue] = []
        if !instructions.isEmpty { list.append(["role": "system", "content": .string(instructions)]) }
        for message in AgentConversation.wireMessages(messages) {
            switch message.role {
            case .user:
                list.append(["role": "user", "content": .string(message.text)])
            case .assistant:
                var item: [String: JSONValue] = ["role": "assistant", "content": message.text.isEmpty ? .null : .string(message.text)]
                if !message.toolCalls.isEmpty {
                    item["tool_calls"] = .array(message.toolCalls.map {
                        ["id": .string($0.id), "type": "function",
                         "function": ["name": .string($0.name), "arguments": .string($0.arguments.isEmpty ? "{}" : $0.arguments)]]
                    })
                }
                list.append(.object(item))
            case .tool:
                list.append(["role": "tool", "tool_call_id": .string(message.toolCallID ?? ""), "content": .string(message.text)])
            }
        }
        var body: [String: JSONValue] = ["model": .string(model), "messages": .array(list), "stream": true,
                                         "stream_options": ["include_usage": true]]
        // An empty `tools` list is refused by some servers, so it is left out.
        if !tools.isEmpty {
            body["tools"] = .array(tools.map {
                ["type": "function", "function": ["name": .string($0.name), "description": .string($0.description), "parameters": $0.parameters]]
            })
        }
        return .object(body)
    }
}

/// Chat Completions chunks: `choices[0].delta.content` text, `delta.tool_calls` pieces, `usage` (the last chunk with
/// `include_usage`), an `error` object some servers send mid-stream, and `[DONE]`.
struct ChatCompletionsDecoder: AgentStreamDecoder, Sendable {
    private struct PendingCall: Sendable { var id: String; var name: String; var arguments: String }
    private(set) var isDone = false
    private var finishReason: String?
    private var calls: [Int: PendingCall] = [:]
    private var inputTokens: Int?
    private var outputTokens: Int?

    mutating func decode(_ event: SSEEvent) throws -> [AgentEvent] {
        let data = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
        if data.isEmpty { return [] }
        if data == "[DONE]" { isDone = true; return [] }
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: Data(data.utf8)) else {
            throw AgentFailure(.invalidResponse, AgentFailures.unreadable)
        }
        if let error = json["error"] {
            throw AgentFailures.failure(code: error["code"]?.string ?? error["type"]?.string, message: error["message"]?.string ?? error.string,
                                        status: error["status"]?.int ?? json["status"]?.int)
        }
        if let usage = json["usage"], usage.object != nil {
            inputTokens = usage["prompt_tokens"]?.int ?? inputTokens
            outputTokens = usage["completion_tokens"]?.int ?? outputTokens
        }
        var events: [AgentEvent] = []
        for choice in json["choices"]?.array ?? [] {
            let delta = choice["delta"] ?? choice["message"]
            if case .string(let text)? = delta?["content"], !text.isEmpty { events.append(.text(text)) }
            for (position, piece) in (delta?["tool_calls"]?.array ?? []).enumerated() {
                let index = piece["index"]?.int ?? position
                var call = calls[index] ?? PendingCall(id: "", name: "", arguments: "")
                if let id = piece["id"]?.string, !id.isEmpty { call.id = id }
                if let name = piece[path: "function", "name"]?.string, !name.isEmpty {
                    // Most servers send the name once; a few repeat it whole in each piece.
                    if !call.name.hasPrefix(name) { call.name += name }
                }
                if let arguments = piece[path: "function", "arguments"]?.string { call.arguments += arguments }
                calls[index] = call
            }
            if let reason = choice["finish_reason"]?.string { finishReason = reason }
        }
        return events
    }

    mutating func finish() throws -> [AgentEvent] {
        // Some servers end with a finish reason but no `[DONE]`.
        guard isDone || finishReason != nil else {
            throw AgentFailure(.network, L10n.text("The answer stopped before it finished. Try again."), code: "stream_ended")
        }
        if finishReason == "length", calls.isEmpty {
            throw AgentFailure(.server, L10n.text("The answer was cut short (%@).", "length"), code: "incomplete_length")
        }
        var events: [AgentEvent] = calls.keys.sorted().compactMap { index in
            guard let call = calls[index], !call.name.isEmpty else { return nil }
            return .toolCall(AgentToolCall(id: call.id.isEmpty ? "call_\(index)_\(UUID().uuidString.prefix(8))" : call.id,
                                           name: call.name, arguments: call.arguments))
        }
        events.append(.finished(inputTokens: inputTokens, outputTokens: outputTokens))
        return events
    }
}

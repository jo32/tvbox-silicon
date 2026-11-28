import Foundation

/// OpenAI's Responses API: `POST {base}/responses` with `stream: true` and `store: false` (nothing is kept on the
/// server, so each turn sends the conversation again). Used for OpenAI API keys and for Sign in with ChatGPT.
/// The answer counts only once `response.completed` arrives.
public struct ResponsesClient: AgentModelClient {
    public let baseURL: URL
    private let authorization: AgentAuthorization
    private let session: URLSession
    /// Set for Sign in with ChatGPT: a refused token then means the sign-in, not an API key.
    var signsInWithChatGPT = false

    public init(baseURL: URL, session: URLSession = .shared, authorization: @escaping AgentAuthorization) {
        self.baseURL = baseURL; self.session = session; self.authorization = authorization
    }

    public func stream(model: String, instructions: String, messages: [AgentMessage], tools: [AgentToolSpec]) -> AsyncThrowingStream<AgentEvent, Error> {
        let body = Self.body(model: model, instructions: instructions, messages: messages, tools: tools)
        let url = baseURL.appending(path: "responses")
        let authorization = authorization
        Diagnostics.shared.record(.info, "assistant", "responses request model=\(model) items=\(messages.count) tools=\(tools.count)")
        let stream = AgentHTTP.stream("responses", session: session, model: model,
                                      build: { try await AgentHTTP.request(url, body: body, authorization: authorization) },
                                      decoder: ResponsesDecoder())
        return signsInWithChatGPT ? AgentHTTP.mapFailures(stream, Self.chatGPTFailure) : stream
    }

    public func models() async throws -> [AgentModelInfo] {
        do { return try await AgentHTTP.models(base: baseURL, session: session, authorization: authorization) }
        catch { throw signsInWithChatGPT ? Self.chatGPTFailure(AgentFailures.failure(error)) : error }
    }

    @Sendable static func chatGPTFailure(_ failure: AgentFailure) -> AgentFailure {
        guard failure.kind == .unauthorized, failure.code == nil || failure.code == "invalid_api_key" else { return failure }
        return AgentFailure(.unauthorized, L10n.text("ChatGPT didn't accept this sign-in. Sign in with ChatGPT again in Settings › Assistant."),
                            code: failure.code, status: failure.status)
    }

    /// The request body: the conversation as input items (messages, `function_call`s and their
    /// `function_call_output`s) and the tools as function tools.
    static func body(model: String, instructions: String, messages: [AgentMessage], tools: [AgentToolSpec]) -> JSONValue {
        var input: [JSONValue] = []
        for message in AgentConversation.wireMessages(messages) {
            switch message.role {
            case .user:
                input.append(["type": "message", "role": "user", "content": [["type": "input_text", "text": .string(message.text)]]])
            case .assistant:
                if !message.text.isEmpty {
                    input.append(["type": "message", "role": "assistant", "content": [["type": "output_text", "text": .string(message.text)]]])
                }
                for call in message.toolCalls {
                    input.append(["type": "function_call", "call_id": .string(call.id), "name": .string(call.name),
                                  "arguments": .string(call.arguments.isEmpty ? "{}" : call.arguments)])
                }
            case .tool:
                input.append(["type": "function_call_output", "call_id": .string(message.toolCallID ?? ""), "output": .string(message.text)])
            }
        }
        var body: [String: JSONValue] = ["model": .string(model), "input": .array(input), "stream": true, "store": false]
        if !instructions.isEmpty { body["instructions"] = .string(instructions) }
        if !tools.isEmpty {
            body["tools"] = .array(tools.map { ["type": "function", "name": .string($0.name), "description": .string($0.description),
                                                "parameters": $0.parameters, "strict": false] })
        }
        return .object(body)
    }
}

/// The Responses stream's events (`type` in each event's JSON): text deltas, finished function calls
/// (`response.output_item.done`), and how the response ended.
struct ResponsesDecoder: AgentStreamDecoder, Sendable {
    private(set) var isDone = false
    private var finished: AgentEvent?
    /// Calls already sent, by call id: some servers repeat a finished item.
    private var sent = Set<String>()
    /// Argument deltas by item id, for an `output_item.done` that leaves out its arguments.
    private var arguments: [String: String] = [:]

    mutating func decode(_ event: SSEEvent) throws -> [AgentEvent] {
        let data = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
        if data.isEmpty || data == "[DONE]" { return [] }
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: Data(data.utf8)) else {
            throw AgentFailure(.invalidResponse, AgentFailures.unreadable)
        }
        switch json["type"]?.string ?? event.name ?? "" {
        case "response.output_text.delta", "response.refusal.delta":
            guard let delta = json["delta"]?.string, !delta.isEmpty else { return [] }
            return [.text(delta)]
        case "response.function_call_arguments.delta":
            if let item = json["item_id"]?.string { arguments[item, default: ""] += json["delta"]?.string ?? "" }
            return []
        case "response.output_item.done":
            guard let item = json["item"], item["type"]?.string == "function_call",
                  let name = item["name"]?.string else { return [] }
            let id = item["call_id"]?.string ?? item["id"]?.string ?? UUID().uuidString
            guard sent.insert(id).inserted else { return [] }
            let text = item["arguments"]?.string ?? item["id"]?.string.flatMap { arguments[$0] } ?? ""
            return [.toolCall(AgentToolCall(id: id, name: name, arguments: text))]
        case "response.completed":
            isDone = true
            let usage = json[path: "response", "usage"]
            finished = .finished(inputTokens: usage?["input_tokens"]?.int, outputTokens: usage?["output_tokens"]?.int)
            return []
        case "response.failed":
            let error = json[path: "response", "error"]
            throw AgentFailures.failure(code: error?["code"]?.string, message: error?["message"]?.string, status: nil)
        case "response.incomplete":
            let reason = json[path: "response", "incomplete_details", "reason"]?.string ?? "incomplete"
            throw AgentFailure(.server, L10n.text("The answer was cut short (%@).", reason), code: "incomplete_\(reason)")
        case "error":
            let error = json["error"] ?? json
            let status = error["status"]?.int ?? json["status"]?.int
            throw AgentFailures.failure(code: error["code"]?.string ?? error["type"]?.string, message: error["message"]?.string, status: status)
        default:
            return []
        }
    }

    mutating func finish() throws -> [AgentEvent] {
        guard let finished else { throw AgentFailure(.network, L10n.text("The answer stopped before it finished. Try again."), code: "stream_ended") }
        return [finished]
    }
}

import Foundation
import Testing
@testable import TVCore

/// A fake server for the assistant's tests, by host: each test registers its own host, so tests can run at once.
final class AgentStubProtocol: URLProtocol, @unchecked Sendable {
    struct Answer: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        /// Sent one after another, as a streaming server would.
        var chunks: [Data]
        init(status: Int = 200, headers: [String: String] = [:], chunks: [Data]) { self.status = status; self.headers = headers; self.chunks = chunks }
        init(status: Int = 200, headers: [String: String] = [:], text: String) { self.init(status: status, headers: headers, chunks: [Data(text.utf8)]) }
    }
    typealias Handler = @Sendable (URLRequest, Data) -> Answer
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    private static let lock = NSLock()

    static func register(_ host: String, _ handler: @escaping Handler) { lock.withLock { handlers[host] = handler } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; body.append(buffer, count: count) }
        }
        guard let handler = Self.lock.withLock({ Self.handlers[url.host() ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost)); return
        }
        let answer = handler(request, body)
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in answer.chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func collect(_ stream: AsyncThrowingStream<AgentEvent, Error>) async throws -> [AgentEvent] {
    var events: [AgentEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

private func decodeAll<D: AgentStreamDecoder>(_ decoder: inout D, _ text: String) throws -> [AgentEvent] {
    var events: [AgentEvent] = []
    for event in SSEParser.events(in: text) { events += try decoder.decode(event) }
    return events + (try decoder.finish())
}

private func body(_ data: Data) -> JSONValue { (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null }

private let searchTool = AgentToolSpec(name: "search_videos", description: "Search", parameters: ["type": "object", "properties": ["query": ["type": "string"]], "required": ["query"]], effect: .read)

private let history: [AgentMessage] = [
    AgentMessage(role: .user, text: "Find it"),
    AgentMessage(role: .assistant, text: "Looking", toolCalls: [AgentToolCall(id: "call_1", name: "search_videos", arguments: #"{"query":"x"}"#)]),
    AgentMessage(role: .tool, text: #"{"count":0}"#, toolCallID: "call_1"),
]

@Suite struct AgentSSETests {
    @Test func parsesEventsLinesAndComments() {
        let events = SSEParser.events(in: ": hello\r\nevent: one\r\ndata: a\r\ndata:b\r\n\r\ndata: {\"x\":1}\n\ndata: tail")
        #expect(events == [SSEEvent(name: "one", data: "a\nb"), SSEEvent(name: nil, data: #"{"x":1}"#), SSEEvent(name: nil, data: "tail")])
    }

    @Test func responsesTextToolCallsAndUsage() throws {
        let stream = """
        event: response.created
        data: {"type":"response.created","response":{"id":"resp_1"}}

        data: {"type":"response.output_text.delta","delta":"Hel"}

        data: {"type":"response.output_text.delta","delta":"lo"}

        data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{\\"query\\":"}

        data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"\\"x\\"}"}

        data: {"type":"response.output_item.done","item":{"type":"function_call","id":"fc_1","call_id":"call_9","name":"search_videos"}}

        data: {"type":"response.output_item.done","item":{"type":"function_call","id":"fc_2","call_id":"call_10","name":"app_state","arguments":"{}"}}

        data: {"type":"response.completed","response":{"usage":{"input_tokens":12,"output_tokens":5}}}


        """
        var decoder = ResponsesDecoder()
        let events = try decodeAll(&decoder, stream)
        #expect(events == [.text("Hel"), .text("lo"),
                           .toolCall(AgentToolCall(id: "call_9", name: "search_videos", arguments: #"{"query":"x"}"#)),
                           .toolCall(AgentToolCall(id: "call_10", name: "app_state", arguments: "{}")),
                           .finished(inputTokens: 12, outputTokens: 5)])
    }

    @Test func responsesFailures() throws {
        var failed = ResponsesDecoder()
        #expect(throws: AgentFailure.self) {
            _ = try decodeAll(&failed, #"data: {"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"limit"}}}"# + "\n\n")
        }
        do {
            var decoder = ResponsesDecoder()
            _ = try decodeAll(&decoder, #"data: {"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"limit"}}}"# + "\n\n")
        } catch let failure as AgentFailure {
            #expect(failure.kind == .usageLimit)
            #expect(failure.code == "subscription_sharing_usage_limit_exceeded")
        }
        do {
            var decoder = ResponsesDecoder()
            _ = try decodeAll(&decoder, #"data: {"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}"# + "\n\n")
            Issue.record("incomplete passed")
        } catch let failure as AgentFailure { #expect(failure.code == "incomplete_max_output_tokens") }
        do {
            var decoder = ResponsesDecoder()
            _ = try decodeAll(&decoder, #"data: {"type":"error","code":"rate_limit_exceeded","message":"slow down"}"# + "\n\n")
            Issue.record("error passed")
        } catch let failure as AgentFailure { #expect(failure.kind == .usageLimit) }
        // Text but no `response.completed`: the stream broke off.
        do {
            var decoder = ResponsesDecoder()
            _ = try decodeAll(&decoder, #"data: {"type":"response.output_text.delta","delta":"Hi"}"# + "\n\n")
            Issue.record("cut stream passed")
        } catch let failure as AgentFailure { #expect(failure.code == "stream_ended") }
    }

    @Test func chatCompletionsToolCallsInPieces() throws {
        let stream = """
        data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"Sure"}}]}

        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"search_videos","arguments":""}}]}}]}

        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"que"}}]}}]}

        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"call_b","function":{"name":"app_state","arguments":"{}"}}]}}]}

        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ry\\":\\"x\\"}"}}]}}]}

        data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

        data: {"choices":[],"usage":{"prompt_tokens":30,"completion_tokens":9}}

        data: [DONE]


        """
        var decoder = ChatCompletionsDecoder()
        let events = try decodeAll(&decoder, stream)
        #expect(events == [.text("Sure"),
                           .toolCall(AgentToolCall(id: "call_a", name: "search_videos", arguments: #"{"query":"x"}"#)),
                           .toolCall(AgentToolCall(id: "call_b", name: "app_state", arguments: "{}")),
                           .finished(inputTokens: 30, outputTokens: 9)])
    }

    @Test func chatCompletionsErrorsAndCutStreams() {
        do {
            var decoder = ChatCompletionsDecoder()
            _ = try decodeAll(&decoder, #"data: {"error":{"message":"Incorrect API key","code":"invalid_api_key"}}"# + "\n\n")
            Issue.record("error passed")
        } catch let failure as AgentFailure { #expect(failure.kind == .unauthorized) } catch { Issue.record("\(error)") }
        do {
            var decoder = ChatCompletionsDecoder()
            _ = try decodeAll(&decoder, #"data: {"choices":[{"delta":{"content":"Hi"}}]}"# + "\n\n")
            Issue.record("cut stream passed")
        } catch let failure as AgentFailure { #expect(failure.code == "stream_ended") } catch { Issue.record("\(error)") }
        // A finish reason without `[DONE]` is a whole answer.
        var decoder = ChatCompletionsDecoder()
        #expect((try? decodeAll(&decoder, #"data: {"choices":[{"delta":{"content":"Hi"},"finish_reason":"stop"}]}"# + "\n\n")) == [.text("Hi"), .finished(inputTokens: nil, outputTokens: nil)])
    }

    @Test func failureMapping() {
        let limit = AgentFailures.failure(status: 429, body: Data(#"{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"x"}}"#.utf8))
        #expect(limit.kind == .usageLimit && limit.status == 429)
        #expect(AgentFailures.failure(status: 403, body: Data(#"{"detail":"Region not supported"}"#.utf8)).kind == .unavailable)
        #expect(AgentFailures.failure(status: 401, body: Data()).kind == .unauthorized)
        #expect(AgentFailures.failure(status: 404, body: Data("Not Found".utf8)).kind == .unsupported)
        #expect(AgentFailures.failure(status: 502, body: Data("<html>".utf8)).kind == .server)
        #expect(AgentFailures.failure(status: 400, body: Data(#"{"error":{"code":"context_length_exceeded","message":"too long"}}"#.utf8)).kind == .unsupported)
        #expect(AgentFailures.failure(status: 503, body: Data(#"{"error":{"code":"subscription_sharing_usage_unavailable"}}"#.utf8)).kind == .unavailable)
        #expect(AgentFailures.failure(URLError(.notConnectedToInternet)).kind == .network)
        #expect(AgentFailures.failure(URLError(.cancelled)).kind == .cancelled)
        #expect(AgentFailures.failure(CancellationError()).kind == .cancelled)
    }

    @Test func modelLists() {
        let chatGPT: JSONValue = ["models": [
            ["slug": "gpt-6.2-sol", "display_name": "GPT-6.2 Sol", "visibility": "list"],
            ["slug": "hidden", "display_name": "Hidden", "visibility": "hide"],
            ["slug": "gpt-6.1-mini", "display_name": "GPT-6.1 mini", "visibility": "list"],
        ]]
        #expect(AgentHTTP.parseModels(chatGPT) == [AgentModelInfo(id: "gpt-6.2-sol", name: "GPT-6.2 Sol"), AgentModelInfo(id: "gpt-6.1-mini", name: "GPT-6.1 mini")])
        let openAI: JSONValue = ["object": "list", "data": [["id": "text-embedding-3-small"], ["id": "o4-mini"], ["id": "gpt-4.1"], ["id": "gpt-5"], ["id": "whisper-1"]]]
        #expect(AgentHTTP.parseModels(openAI).map(\.id) == ["gpt-5", "gpt-4.1", "o4-mini"])
    }
}

@Suite struct AgentClientRequestTests {
    @Test func responsesRequestAndStream() async throws {
        let host = "responses.agent.test"
        let seen = AgentLocked<(URLRequest, Data)?>(nil)
        AgentStubProtocol.register(host) { request, data in
            seen.set((request, data))
            let lines = [
                #"data: {"type":"response.output_text.delta","delta":"Hi "}"# + "\n\n",
                #"data: {"type":"response.output_text.delta","de"#, #"lta":"there"}"# + "\n", "\n",
                #"data: {"type":"response.completed","response":{"usage":{"input_tokens":3,"output_tokens":2}}}"# + "\n\n",
            ]
            return .init(headers: ["Content-Type": "text/event-stream", "x-request-id": "req_1"], chunks: lines.map { Data($0.utf8) })
        }
        let client = ResponsesClient(baseURL: URL(string: "https://\(host)/v1")!, session: AgentStubProtocol.session()) { "sk-test" }
        let events = try await collect(client.stream(model: "gpt-5", instructions: "Be brief", messages: history, tools: [searchTool]))
        #expect(events == [.text("Hi "), .text("there"), .finished(inputTokens: 3, outputTokens: 2)])
        let (request, data) = try #require(seen.get())
        #expect(request.url?.path == "/v1/responses")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let sent = body(data)
        #expect(sent["stream"] == .bool(true) && sent["store"] == .bool(false) && sent["instructions"] == "Be brief")
        let input = sent["input"]?.array ?? []
        #expect(input.map { $0["type"]?.string ?? "" } == ["message", "message", "function_call", "function_call_output"])
        #expect(input[2]["call_id"] == "call_1" && input[2]["arguments"] == #"{"query":"x"}"#)
        #expect(input[3]["call_id"] == "call_1" && input[3]["output"] == #"{"count":0}"#)
        #expect(sent["tools"]?.array?.first?["name"] == "search_videos")
        #expect(sent["tools"]?.array?.first?["type"] == "function")
    }

    @Test func chatCompletionsRequestAndStream() async throws {
        let host = "chat.agent.test"
        let seen = AgentLocked<Data?>(nil)
        AgentStubProtocol.register(host) { _, data in
            seen.set(data)
            let text = #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"search_videos","arguments":"{\"q"}}]}}]}"# + "\n\n"
                + #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\":1}"}}]},"finish_reason":"tool_calls"}]}"# + "\n\n"
                + "data: [DONE]\n\n"
            return .init(chunks: Array(text.utf8).chunked(7).map { Data($0) })
        }
        // No key: a local server.
        let client = ChatCompletionsClient(baseURL: URL(string: "http://\(host)/v1")!, session: AgentStubProtocol.session()) { nil }
        let events = try await collect(client.stream(model: "local", instructions: "Sys", messages: history, tools: [searchTool]))
        #expect(events == [.toolCall(AgentToolCall(id: "c1", name: "search_videos", arguments: #"{"q":1}"#)), .finished(inputTokens: nil, outputTokens: nil)])
        let sent = body(try #require(seen.get()))
        let messages = sent["messages"]?.array ?? []
        #expect(messages.map { $0["role"]?.string ?? "" } == ["system", "user", "assistant", "tool"])
        #expect(messages[2]["tool_calls"]?.array?.first?[path: "function", "name"] == "search_videos")
        #expect(messages[3]["tool_call_id"] == "call_1")
        #expect(sent["tools"]?.array?.first?[path: "function", "name"] == "search_videos")
    }

    @Test func httpErrorsBecomeFailures() async {
        let host = "limit.agent.test"
        AgentStubProtocol.register(host) { _, _ in
            .init(status: 429, headers: ["x-request-id": "req_2"], text: #"{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"Usage limit"}}"#)
        }
        let client = ResponsesClient(baseURL: URL(string: "https://\(host)/v1")!, session: AgentStubProtocol.session()) { "token" }
        do {
            _ = try await collect(client.stream(model: "m", instructions: "", messages: history, tools: []))
            Issue.record("no failure")
        } catch let failure as AgentFailure {
            #expect(failure.kind == .usageLimit && failure.status == 429)
        } catch { Issue.record("\(error)") }
    }

    @Test func modelsRequest() async throws {
        let host = "models.agent.test"
        AgentStubProtocol.register(host) { request, _ in
            #expect(request.url?.path == "/v1/models")
            return .init(text: #"{"data":[{"id":"llama3"},{"id":"gpt-4o"}]}"#)
        }
        let client = ChatCompletionsClient(baseURL: URL(string: "http://\(host)/v1")!, session: AgentStubProtocol.session()) { nil }
        #expect(try await client.models().map(\.id) == ["gpt-4o", "llama3"])
    }

    @Test func clientsForConnections() throws {
        let secrets = MemoryAgentSecrets()
        #expect(throws: AgentFailure.self) { _ = try AgentClients.make(.apiKey(.openAI), secrets: secrets) }
        secrets.setAPIKey(" sk-1 ", for: URL(string: "https://api.openai.com/v1/")!)
        #expect(secrets.apiKey(for: APIKeyConnection.openAI.baseURL) == "sk-1")
        #expect(try AgentClients.make(.apiKey(.openAI), secrets: secrets) is ResponsesClient)
        let local = APIKeyConnection(baseURL: URL(string: "http://192.168.1.5:11434/v1")!, wire: .chatCompletions)
        #expect(try AgentClients.make(.apiKey(local), secrets: secrets) is ChatCompletionsClient)
        secrets.setAPIKey("", for: APIKeyConnection.openAI.baseURL)
        #expect(secrets.apiKey(for: APIKeyConnection.openAI.baseURL) == nil)
    }

    @Test func keychainRoundTrip() {
        let keychain = AgentKeychain(service: "com.yingxia.assistant.tests.\(UUID().uuidString)")
        let url = URL(string: "https://example.test/v1")!
        keychain.setAPIKey("sk-round-trip", for: url)
        #expect(keychain.apiKey(for: url) == "sk-round-trip")
        keychain.setAPIKey("sk-second", for: url)
        #expect(keychain.apiKey(for: url) == "sk-second")
        keychain.setAPIKey(nil, for: url)
        #expect(keychain.apiKey(for: url) == nil)
    }
}

/// A value shared with a stub's handler.
final class AgentLocked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ value: Value) { lock.withLock { self.value = value } }
    func update<T>(_ change: (inout Value) -> T) -> T { lock.withLock { change(&value) } }
}

private extension Array {
    func chunked(_ size: Int) -> [[Element]] { stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) } }
}

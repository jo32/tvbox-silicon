import Foundation

// The assistant (Docs/agent.md): a chat with a model that can operate the app through tools. This file is the contract
// the pieces share; the model clients, the loop, the sign-in and the app's tools each live in their own files.

/// One turn of the conversation as the model sees it.
public struct AgentMessage: Codable, Equatable, Sendable, Identifiable {
    public enum Role: String, Codable, Sendable { case user, assistant, tool }
    public var id: UUID
    public var role: Role
    /// The words: the viewer's, the model's, or a tool's result (JSON text).
    public var text: String
    /// The tools the model asked for in this assistant turn.
    public var toolCalls: [AgentToolCall]
    /// For a tool turn: the call it answers.
    public var toolCallID: String?
    public var date: Date

    public init(id: UUID = UUID(), role: Role, text: String, toolCalls: [AgentToolCall] = [], toolCallID: String? = nil, date: Date = Date()) {
        self.id = id; self.role = role; self.text = text; self.toolCalls = toolCalls; self.toolCallID = toolCallID; self.date = date
    }
}

/// A tool the model asked to run, with its arguments as the JSON text the model wrote.
public struct AgentToolCall: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var arguments: String
    public init(id: String, name: String, arguments: String) { self.id = id; self.name = name; self.arguments = arguments }
}

/// What a tool may do, which decides whether the viewer is asked first.
public enum AgentToolEffect: String, Codable, Sendable {
    /// Reads or shows (search, list, open a page, play): runs at once.
    case read
    /// Changes something the viewer can easily undo (a setting, a favorite, the playback speed).
    case change
    /// Hard to undo or touches what the viewer made (remove a subscription, overwrite a script, clear history):
    /// always asks, whatever the settings say.
    case destructive
}

/// A tool as the model is told about it.
public struct AgentToolSpec: Equatable, Sendable {
    /// `snake_case`, unique, at most 64 characters (both APIs' limit).
    public var name: String
    /// What it does and when to use it, written for the model, in English.
    public var description: String
    /// A JSON Schema object for the arguments (`type: object`, `properties`, `required`).
    public var parameters: JSONValue
    public var effect: AgentToolEffect
    public init(name: String, description: String, parameters: JSONValue, effect: AgentToolEffect) {
        self.name = name; self.description = description; self.parameters = parameters; self.effect = effect
    }
}

/// A tool the assistant can use. The app's tools run on the main actor, where the app's state lives.
public protocol AgentTool: Sendable {
    var spec: AgentToolSpec { get }
    /// Runs it. `arguments` is the parsed JSON object the model sent. The result goes back to the model as JSON; keep it
    /// small (lists capped, long text cut) and never put secrets in it. Throw `AgentToolError` for a refusal the
    /// model should read.
    @MainActor func run(_ arguments: [String: JSONValue]) async throws -> JSONValue
}

public struct AgentToolError: Error, Equatable, Sendable, LocalizedError {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The tools on offer, by name.
@MainActor public final class AgentToolbox {
    public private(set) var tools: [String: any AgentTool] = [:]
    public private(set) var order: [String] = []
    public init(_ tools: [any AgentTool] = []) { tools.forEach(add) }
    public func add(_ tool: any AgentTool) {
        let name = tool.spec.name
        if tools[name] == nil { order.append(name) }
        tools[name] = tool
    }
    public var specs: [AgentToolSpec] { order.compactMap { tools[$0]?.spec } }
    /// Swaps in a new set, e.g. after a subscription made a section appear.
    public func replace(with tools: [any AgentTool]) {
        self.tools = [:]; order = []
        tools.forEach(add)
    }
}

/// What a model client streams back for one request.
public enum AgentEvent: Equatable, Sendable {
    /// More of the answer's words.
    case text(String)
    /// A finished tool call (its arguments complete).
    case toolCall(AgentToolCall)
    /// The request finished; `inputTokens`/`outputTokens` when the server said.
    case finished(inputTokens: Int?, outputTokens: Int?)
}

/// A failure the viewer is shown, in their language, with what to do about it.
public struct AgentFailure: Error, Equatable, Sendable, LocalizedError {
    public enum Kind: String, Sendable { case notSignedIn, unauthorized, usageLimit, unavailable, unsupported, network, server, invalidResponse, cancelled }
    public var kind: Kind
    public var message: String
    /// The server's own code (e.g. `subscription_sharing_usage_limit_exceeded`) and HTTP status, for the log.
    public var code: String?
    public var status: Int?
    public init(_ kind: Kind, _ message: String, code: String? = nil, status: Int? = nil) {
        self.kind = kind; self.message = message; self.code = code; self.status = status
    }
    public var errorDescription: String? { message }
}

/// A model behind one wire format. Implementations: `ResponsesClient` (`POST {base}/responses`, OpenAI and ChatGPT
/// plan sign-in) and `ChatCompletionsClient` (`POST {base}/chat/completions`, OpenAI-compatible servers).
public protocol AgentModelClient: Sendable {
    /// Streams one model turn. `instructions` is the system prompt; `messages` the conversation so far, tool results
    /// included. Throws `AgentFailure`. Cancelling the task stops the request.
    func stream(model: String, instructions: String, messages: [AgentMessage], tools: [AgentToolSpec]) -> AsyncThrowingStream<AgentEvent, Error>
    /// The models this account can use, best first (`GET {base}/models`), as (id, display name).
    func models() async throws -> [AgentModelInfo]
}

public struct AgentModelInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// How the assistant reaches a model. Secrets never leave the Keychain except in the request's header.
public enum AgentConnection: Codable, Equatable, Sendable {
    /// The viewer's own key: OpenAI or any OpenAI-compatible server.
    case apiKey(APIKeyConnection)
    /// Sign in with ChatGPT (plan usage): tokens in the Keychain (`ChatGPTSignIn`).
    case chatGPT(accountLabel: String)
}

public struct APIKeyConnection: Codable, Equatable, Sendable {
    public enum Wire: String, Codable, Sendable, CaseIterable { case responses, chatCompletions }
    /// e.g. https://api.openai.com/v1
    public var baseURL: URL
    public var wire: Wire
    public init(baseURL: URL, wire: Wire) { self.baseURL = baseURL; self.wire = wire }
    public static let openAI = APIKeyConnection(baseURL: URL(string: "https://api.openai.com/v1")!, wire: .responses)
}

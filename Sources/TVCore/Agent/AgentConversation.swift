import Foundation
import Observation

/// A tool call waiting for the viewer's yes or no (`AgentConversation.confirm`).
public struct AgentConfirmation: Equatable, Sendable, Identifiable {
    public var id: String { call.id }
    public var call: AgentToolCall
    public var effect: AgentToolEffect
    /// One line for the viewer, in their language, e.g. "Remove the subscription 饭太硬?" (the tool's `summary`).
    public var summary: String
    /// What will change, when the tool can say (a setting's old and new value, a script's diff).
    public var detail: String?
    public init(call: AgentToolCall, effect: AgentToolEffect, summary: String, detail: String? = nil) {
        self.call = call; self.effect = effect; self.summary = summary; self.detail = detail
    }
}

/// A tool that can describe a call before it runs, for the confirmation card.
public protocol AgentDescribedTool: AgentTool {
    @MainActor func summary(_ arguments: [String: JSONValue]) -> (summary: String, detail: String?)
}

/// One conversation with the assistant: sends the viewer's words, streams the answer, runs the tools the model asks
/// for (asking first where `AgentToolEffect` says so), and loops until the model answers in words.
/// STUB (feature/agent skeleton): the core implementation replaces the bodies, keeping this API.
@MainActor @Observable public final class AgentConversation {
    public private(set) var messages: [AgentMessage] = []
    /// The answer arriving now, before it becomes a message.
    public private(set) var streamingText = ""
    /// The tool running now, for a "Searching…" line.
    public private(set) var runningTool: AgentToolCall?
    public private(set) var isRunning = false
    public private(set) var pendingConfirmation: AgentConfirmation?
    public private(set) var failure: AgentFailure?

    public var model: String
    public var asksBeforeChanges: Bool
    public let toolbox: AgentToolbox
    private let client: any AgentModelClient
    private let instructions: @MainActor () -> String

    /// `instructions` is read at each turn so it can carry the app's current state (page, playing item).
    public init(client: any AgentModelClient, model: String, toolbox: AgentToolbox, asksBeforeChanges: Bool = true,
                messages: [AgentMessage] = [], instructions: @escaping @MainActor () -> String) {
        self.client = client; self.model = model; self.toolbox = toolbox; self.asksBeforeChanges = asksBeforeChanges
        self.messages = messages; self.instructions = instructions
    }

    public func send(_ text: String) { messages.append(AgentMessage(role: .user, text: text)) }
    public func stop() { isRunning = false }
    public func confirm(_ allowed: Bool) { pendingConfirmation = nil }
    public func clear() { messages = []; streamingText = ""; failure = nil }
}

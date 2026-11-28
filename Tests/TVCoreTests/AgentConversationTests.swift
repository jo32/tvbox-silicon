import Foundation
import Testing
@testable import TVCore

/// A model that answers from a script: one turn per request.
private final class ScriptedClient: AgentModelClient, @unchecked Sendable {
    enum Turn: Sendable {
        case events([AgentEvent])
        /// Sends these, then waits until cancelled.
        case hang([AgentEvent])
        case fail(AgentFailure)
    }
    private let lock = NSLock()
    private var turns: [Turn]
    /// Once the script runs out, this turn repeats.
    private let otherwise: Turn
    private(set) var requests: [[AgentMessage]] = []

    init(_ turns: [Turn], otherwise: Turn = .events([.text("Done."), .finished(inputTokens: nil, outputTokens: nil)])) {
        self.turns = turns; self.otherwise = otherwise
    }
    var requestCount: Int { lock.withLock { requests.count } }
    var lastRequest: [AgentMessage] { lock.withLock { requests.last ?? [] } }

    func stream(model: String, instructions: String, messages: [AgentMessage], tools: [AgentToolSpec]) -> AsyncThrowingStream<AgentEvent, Error> {
        let turn: Turn = lock.withLock {
            requests.append(AgentConversation.wireMessages(messages))
            return turns.isEmpty ? otherwise : turns.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            switch turn {
            case .events(let events):
                events.forEach { continuation.yield($0) }
                continuation.finish()
            case .hang(let events):
                events.forEach { continuation.yield($0) }
                let task = Task { try? await Task.sleep(for: .seconds(60)); continuation.finish() }
                continuation.onTermination = { _ in task.cancel() }
            case .fail(let failure):
                continuation.finish(throwing: failure)
            }
        }
    }
    func models() async throws -> [AgentModelInfo] { [] }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var runs: [[String: JSONValue]] = []
    func add(_ arguments: [String: JSONValue]) { lock.withLock { runs.append(arguments) } }
    var count: Int { lock.withLock { runs.count } }
}

private struct FakeTool: AgentDescribedTool {
    let spec: AgentToolSpec
    let counter = Counter()
    var result: @Sendable ([String: JSONValue]) throws -> JSONValue = { _ in ["ok": true] }
    init(_ name: String, _ effect: AgentToolEffect, result: (@Sendable ([String: JSONValue]) throws -> JSONValue)? = nil) {
        spec = AgentToolSpec(name: name, description: name, parameters: ["type": "object"], effect: effect)
        if let result { self.result = result }
    }
    func run(_ arguments: [String: JSONValue]) async throws -> JSONValue { counter.add(arguments); return try result(arguments) }
    func summary(_ arguments: [String: JSONValue]) -> (summary: String, detail: String?) { ("Run \(spec.name)?", "detail") }
}

private func call(_ name: String, _ id: String = UUID().uuidString, _ arguments: String = "{}") -> AgentEvent {
    .toolCall(AgentToolCall(id: id, name: name, arguments: arguments))
}
private let done = AgentEvent.finished(inputTokens: nil, outputTokens: nil)

/// Waits (up to 5 s) for `condition`, letting the conversation's task run.
@MainActor private func until(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    #expect(condition())
}

@MainActor @Suite struct AgentConversationTests {
    private func conversation(_ client: ScriptedClient, _ tools: [any AgentTool], asks: Bool = true, store: AgentConversationStore? = nil) -> AgentConversation {
        AgentConversation(client: client, model: "m", toolbox: AgentToolbox(tools), asksBeforeChanges: asks, store: store) { "You are a test." }
    }

    @Test func readToolRunsAndTheLoopAnswers() async {
        let tool = FakeTool("search_videos", .read) { arguments in ["found": .string(arguments["q"]?.string ?? "")] }
        let client = ScriptedClient([.events([.text("Let me look. "), call("search_videos", "c1", #"{"q":"cats"}"#), done])])
        let chat = conversation(client, [tool])
        chat.send("Find cats")
        await until { !chat.isRunning }
        #expect(tool.counter.count == 1)
        #expect(chat.messages.map(\.role) == [.user, .assistant, .tool, .assistant])
        #expect(chat.messages[2].text == #"{"found":"cats"}"#)
        #expect(chat.messages[2].toolCallID == "c1")
        #expect(chat.messages[3].text == "Done.")
        #expect(client.requestCount == 2)
        #expect(client.lastRequest.last?.role == .tool)
        #expect(chat.failure == nil)
    }

    @Test func changeAsksAndRunsWhenAllowed() async {
        let tool = FakeTool("settings_set", .change)
        let chat = conversation(ScriptedClient([.events([call("settings_set", "c1"), done])]), [tool])
        chat.send("Turn it on")
        await until { chat.pendingConfirmation != nil }
        #expect(chat.pendingConfirmation?.summary == "Run settings_set?")
        #expect(chat.pendingConfirmation?.detail == "detail")
        #expect(tool.counter.count == 0)
        chat.confirm(true)
        await until { !chat.isRunning }
        #expect(tool.counter.count == 1)
        #expect(chat.messages[2].text == #"{"ok":true}"#)
    }

    @Test func declinedChangeTellsTheModel() async {
        let tool = FakeTool("settings_set", .change)
        let chat = conversation(ScriptedClient([.events([call("settings_set", "c1"), done])]), [tool])
        chat.send("Turn it on")
        await until { chat.pendingConfirmation != nil }
        chat.confirm(false)
        await until { !chat.isRunning }
        #expect(tool.counter.count == 0)
        #expect(chat.messages[2].text == #"{"declined":true}"#)
    }

    @Test func changeRunsAtOnceWhenNotAsking() async {
        let change = FakeTool("settings_set", .change)
        let destructive = FakeTool("subscription_remove", .destructive)
        let chat = conversation(ScriptedClient([.events([call("settings_set"), call("subscription_remove"), done])]), [change, destructive], asks: false)
        chat.send("Do both")
        // The change runs; the destructive one still asks.
        await until { chat.pendingConfirmation != nil }
        #expect(change.counter.count == 1)
        #expect(chat.pendingConfirmation?.call.name == "subscription_remove")
        #expect(chat.pendingConfirmation?.effect == .destructive)
        chat.confirm(true)
        await until { !chat.isRunning }
        #expect(destructive.counter.count == 1)
    }

    @Test func badArgumentsUnknownToolsAndRefusals() async {
        let refusing = FakeTool("script_read", .read) { _ in throw AgentToolError("No such script.") }
        let failing = FakeTool("open_page", .read) { _ in throw URLError(.timedOut) }
        let client = ScriptedClient([.events([call("script_read", "c1", "{not json"), call("nope", "c2"), call("script_read", "c3"),
                                              call("open_page", "c4", ""), done])])
        let chat = conversation(client, [refusing, failing])
        chat.send("Go")
        await until { !chat.isRunning }
        let results = chat.messages.filter { $0.role == .tool }
        #expect(results.count == 4)
        #expect(results[0].text.contains("not a JSON object"))
        #expect(results[1].text.contains("no tool named nope"))
        #expect(results[2].text == #"{"error":"No such script."}"#)
        #expect(results[3].text.contains("error"))
        #expect(refusing.counter.count == 1)
        #expect(failing.counter.count == 1)
    }

    @Test func stopsAfterMaxRounds() async {
        let tool = FakeTool("app_state", .read)
        let client = ScriptedClient([], otherwise: .events([call("app_state"), done]))
        let chat = conversation(client, [tool])
        chat.send("Loop")
        await until { !chat.isRunning }
        #expect(tool.counter.count == AgentConversation.maxRounds)
        #expect(client.requestCount == AgentConversation.maxRounds + 1)
        #expect(chat.messages.last?.role == .assistant)
        #expect(chat.messages.last?.text.contains("\(AgentConversation.maxRounds)") == true)
        // Every call has its result, so the next message can go on.
        let wire = AgentConversation.wireMessages(chat.messages)
        #expect(wire.count == chat.messages.count)
    }

    @Test func stopCancelsStreamAndQuestion() async {
        let tool = FakeTool("subscription_remove", .destructive)
        let client = ScriptedClient([.events([call("subscription_remove", "c1"), done]), .hang([.text("Partial")])])
        let chat = conversation(client, [tool])
        chat.send("Remove it")
        await until { chat.pendingConfirmation != nil }
        chat.stop()
        #expect(!chat.isRunning)
        #expect(chat.pendingConfirmation == nil)
        #expect(tool.counter.count == 0)
        // The unanswered call reads as cancelled to the model.
        let wire = AgentConversation.wireMessages(chat.messages)
        #expect(wire.last?.role == .tool && wire.last?.text == #"{"cancelled":true}"#)

        // A stream stopped half way keeps what arrived.
        chat.send("Again")
        await until { chat.streamingText == "Partial" }
        chat.stop()
        #expect(chat.messages.last?.role == .assistant && chat.messages.last?.text == "Partial")
        #expect(!chat.isRunning && chat.streamingText.isEmpty)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(chat.failure == nil)
    }

    @Test func failureIsShownAndRetried() async {
        let client = ScriptedClient([.fail(AgentFailure(.network, "offline"))])
        let chat = conversation(client, [])
        chat.send("Hello")
        await until { !chat.isRunning }
        #expect(chat.failure?.kind == .network)
        #expect(chat.messages.map(\.role) == [.user])
        chat.retry()
        await until { !chat.isRunning }
        #expect(chat.failure == nil)
        #expect(chat.messages.last?.text == "Done.")
    }

    @Test func longResultsAreCut() async {
        let tool = FakeTool("recent_log", .read) { _ in .string(String(repeating: "影", count: 10_000)) }
        let chat = conversation(ScriptedClient([.events([call("recent_log"), done])]), [tool])
        chat.send("Log")
        await until { !chat.isRunning }
        let result = chat.messages.first { $0.role == .tool }?.text ?? ""
        #expect(result.utf8.count <= AgentConversation.resultLimit)
        #expect(result.contains("[cut:"))
    }

    @Test func savesRestoresAndClears() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = AgentConversationStore(file: folder.appendingPathComponent("conversation.json"))
        let chat = conversation(ScriptedClient([]), [], store: store)
        chat.send("Remember me")
        await until { !chat.isRunning }
        let restored = conversation(ScriptedClient([]), [], store: store)
        #expect(restored.messages.map(\.text) == ["Remember me", "Done."])
        restored.clear()
        #expect(restored.messages.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.file.path))

        // Only the last 50 are kept, never starting with an orphan result.
        var many: [AgentMessage] = []
        for index in 0..<30 {
            many.append(AgentMessage(role: .assistant, text: "", toolCalls: [AgentToolCall(id: "c\(index)", name: "x", arguments: "{}")]))
            many.append(AgentMessage(role: .tool, text: "{}", toolCallID: "c\(index)"))
        }
        many.append(AgentMessage(role: .tool, text: "{}", toolCallID: "late"))
        store.save(many)
        let kept = store.load()
        #expect(kept.count <= AgentConversationStore.limit)
        #expect(kept.first?.role == .assistant)
    }

    @Test func wireMessagesRepairHistory() {
        let messages = [
            AgentMessage(role: .tool, text: "{}", toolCallID: "orphan"),
            AgentMessage(role: .user, text: "Hi"),
            AgentMessage(role: .assistant, text: "", toolCalls: [AgentToolCall(id: "a", name: "x", arguments: "{}"), AgentToolCall(id: "b", name: "x", arguments: "{}")]),
            AgentMessage(role: .tool, text: "1", toolCallID: "b"),
            AgentMessage(role: .assistant, text: ""),
            AgentMessage(role: .user, text: "Next"),
        ]
        let wire = AgentConversation.wireMessages(messages)
        #expect(wire.map(\.role) == [.user, .assistant, .tool, .tool, .user])
        #expect(wire[2].toolCallID == "b")
        #expect(wire[3].toolCallID == "a" && wire[3].text == #"{"cancelled":true}"#)
    }
}

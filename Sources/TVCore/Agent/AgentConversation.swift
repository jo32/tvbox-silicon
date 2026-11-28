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
@MainActor @Observable public final class AgentConversation {
    /// Tool rounds one message may take before the loop stops and says so.
    nonisolated public static let maxRounds = 12
    /// A tool result longer than this (UTF-8 bytes) is cut before it goes to the model.
    nonisolated public static let resultLimit = 8192

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
    @ObservationIgnored private let store: AgentConversationStore?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var confirmation: CheckedContinuation<Bool, Never>?
    /// Bumped by `stop()`: a run from before it leaves the conversation alone when it wakes up.
    @ObservationIgnored private var generation = 0

    /// `instructions` is read at each turn so it can carry the app's current state (page, playing item). With no
    /// `messages`, the conversation `store` keeps is restored; pass a nil `store` to keep nothing.
    public init(client: any AgentModelClient, model: String, toolbox: AgentToolbox, asksBeforeChanges: Bool = true,
                messages: [AgentMessage] = [], store: AgentConversationStore? = .standard,
                instructions: @escaping @MainActor () -> String) {
        self.client = client; self.model = model; self.toolbox = toolbox; self.asksBeforeChanges = asksBeforeChanges
        self.store = store; self.instructions = instructions
        self.messages = messages.isEmpty ? (store?.load() ?? []) : messages
    }

    /// Sends the viewer's words and runs the turn. Ignored while a turn runs or for empty text.
    public func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        append(AgentMessage(role: .user, text: text))
        start()
    }

    /// Runs the turn again after a failure (the last message is the viewer's or a tool's).
    public func retry() {
        guard !isRunning, let last = messages.last, last.role != .assistant || !last.toolCalls.isEmpty else { return }
        start()
    }

    /// Stops the answer, the tool round and any pending question. What has arrived is kept.
    public func stop() {
        guard isRunning else { return }
        generation += 1
        task?.cancel(); task = nil
        let text = streamingText
        streamingText = ""
        if !text.isEmpty { append(AgentMessage(role: .assistant, text: text)) }
        resolveConfirmation(false)
        runningTool = nil
        isRunning = false
        Diagnostics.shared.record(.info, "assistant", "turn stopped")
    }

    /// The viewer's answer to `pendingConfirmation`.
    public func confirm(_ allowed: Bool) { resolveConfirmation(allowed) }

    /// Forgets the conversation, here and on disk.
    public func clear() {
        stop()
        messages = []; streamingText = ""; failure = nil
        store?.delete()
    }

    // MARK: The loop

    private func start() {
        failure = nil
        isRunning = true
        generation += 1
        let run = generation
        task = Task { [weak self] in await self?.run(run) }
    }

    private func current(_ run: Int) -> Bool { run == generation && !Task.isCancelled }

    private func run(_ run: Int) async {
        var rounds = 0
        while current(run) {
            let started = Date()
            streamingText = ""
            var calls: [AgentToolCall] = []
            do {
                let stream = client.stream(model: model, instructions: instructions(), messages: messages, tools: toolbox.specs)
                for try await event in stream {
                    guard current(run) else { break }
                    switch event {
                    case .text(let text): streamingText += text
                    case .toolCall(let call): calls.append(call)
                    case .finished: break
                    }
                }
            } catch {
                guard current(run) else { return }
                let failure = AgentFailures.failure(error)
                streamingText = ""
                if failure.kind != .cancelled { self.failure = failure }
                return end()
            }
            guard current(run) else { return }
            let text = streamingText
            streamingText = ""
            if !text.isEmpty || !calls.isEmpty { append(AgentMessage(role: .assistant, text: text, toolCalls: calls)) }
            Diagnostics.shared.record(.info, "assistant", "turn round=\(rounds) tools=\(calls.map(\.name).joined(separator: ",")) \(AgentHTTP.elapsed(started))")
            if calls.isEmpty { return end() }
            if rounds >= Self.maxRounds {
                for call in calls { appendResult(call, ["error": "Stopped: too many tool rounds for one message."]) }
                append(AgentMessage(role: .assistant, text: L10n.text("I stopped after %@ tool steps. Send a message to let me go on.", "\(Self.maxRounds)")))
                Diagnostics.shared.record(.warning, "assistant", "turn stopped at max rounds=\(Self.maxRounds)")
                return end()
            }
            rounds += 1
            for call in calls {
                guard let result = await runTool(call, run: run), current(run) else { return }
                appendResult(call, result)
            }
        }
    }

    private func end() {
        isRunning = false
        runningTool = nil
        task = nil
    }

    /// Runs one call, asking first where its effect says so. Nil when the run was stopped meanwhile.
    private func runTool(_ call: AgentToolCall, run: Int) async -> JSONValue? {
        guard let tool = toolbox.tools[call.name] else {
            Diagnostics.shared.record(.warning, "assistant", "tool unknown name=\(call.name.prefix(64))")
            return ["error": .string("There is no tool named \(call.name).")]
        }
        let raw = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let arguments: [String: JSONValue]
        if raw.isEmpty { arguments = [:] }
        else if case .object(let object)? = JSONValue.parse(raw) { arguments = object }
        else {
            Diagnostics.shared.record(.warning, "assistant", "tool bad arguments name=\(call.name)")
            return ["error": "The arguments were not a JSON object. Call the tool again with arguments that match its parameters."]
        }
        let effect = tool.spec.effect
        if effect == .destructive || (effect == .change && asksBeforeChanges) {
            let described = (tool as? any AgentDescribedTool)?.summary(arguments)
            let question = AgentConfirmation(call: call, effect: effect,
                                             summary: described?.summary ?? L10n.text("Allow the assistant to use %@?", call.name),
                                             detail: described?.detail)
            let allowed = await ask(question)
            guard current(run) else { return nil }
            Diagnostics.shared.record(.info, "assistant", "tool \(allowed ? "allowed" : "declined") name=\(call.name) effect=\(effect.rawValue)")
            if !allowed { return ["declined": true] }
        }
        runningTool = call
        defer { if current(run) { runningTool = nil } }
        let started = Date()
        do {
            let result = try await tool.run(arguments)
            Diagnostics.shared.record(.info, "assistant", "tool ok name=\(call.name) \(AgentHTTP.elapsed(started))")
            return result
        } catch let error as AgentToolError {
            Diagnostics.shared.record(.info, "assistant", "tool refused name=\(call.name) \(AgentHTTP.elapsed(started))")
            return ["error": .string(error.message)]
        } catch {
            guard current(run) else { return nil }
            Diagnostics.shared.record(.warning, "assistant", "tool failed name=\(call.name) error=\(type(of: error)) \(AgentHTTP.elapsed(started))")
            return ["error": .string(error.localizedDescription)]
        }
    }

    private func ask(_ question: AgentConfirmation) async -> Bool {
        resolveConfirmation(false)
        pendingConfirmation = question
        return await withCheckedContinuation { confirmation = $0 }
    }

    private func resolveConfirmation(_ allowed: Bool) {
        let waiting = confirmation
        confirmation = nil
        pendingConfirmation = nil
        waiting?.resume(returning: allowed)
    }

    private func appendResult(_ call: AgentToolCall, _ result: JSONValue) {
        append(AgentMessage(role: .tool, text: Self.cut(result.jsonText), toolCallID: call.id))
    }

    private func append(_ message: AgentMessage) {
        messages.append(message)
        store?.save(messages)
    }

    // MARK: Helpers the clients share

    /// `text` cut to `limit` UTF-8 bytes (on a character boundary), with a note saying so.
    nonisolated static func cut(_ text: String, limit: Int = resultLimit) -> String {
        let total = text.utf8.count
        guard total > limit else { return text }
        let budget = limit - 100
        var used = 0
        var end = text.startIndex
        for character in text {
            let size = character.utf8.count
            if used + size > budget { break }
            used += size
            end = text.index(after: end)
        }
        return String(text[..<end]) + "\n[cut: the result was \(total) bytes; ask for less, e.g. a smaller range or a narrower search]"
    }

    /// The messages as a model may see them: every tool call followed by one result (a missing one, from a stopped
    /// turn, reads `{"cancelled":true}`), results without their call dropped, and empty turns left out.
    nonisolated static func wireMessages(_ messages: [AgentMessage]) -> [AgentMessage] {
        var wire: [AgentMessage] = []
        var open: [String] = []
        func close() {
            for id in open { wire.append(AgentMessage(role: .tool, text: #"{"cancelled":true}"#, toolCallID: id)) }
            open = []
        }
        for message in messages {
            switch message.role {
            case .tool:
                guard let id = message.toolCallID, let index = open.firstIndex(of: id) else { continue }
                open.remove(at: index)
                wire.append(message)
            case .user:
                close()
                wire.append(message)
            case .assistant:
                close()
                guard !message.text.isEmpty || !message.toolCalls.isEmpty else { continue }
                wire.append(message)
                open = message.toolCalls.map(\.id)
            }
        }
        close()
        return wire
    }
}

/// Where a conversation is kept between launches: Application Support/Assistant/conversation.json (Caches on the TV,
/// where apps may keep nothing else), the last 50 messages.
public struct AgentConversationStore: Sendable {
    public static let limit = 50
    public let file: URL
    public init(file: URL) { self.file = file }

    public static var standard: AgentConversationStore {
        #if os(tvOS)
        let location: FileManager.SearchPathDirectory = .cachesDirectory
        #else
        let location: FileManager.SearchPathDirectory = .applicationSupportDirectory
        #endif
        let folder = FileManager.default.urls(for: location, in: .userDomainMask)[0].appendingPathComponent("Assistant", isDirectory: true)
        return AgentConversationStore(file: folder.appendingPathComponent("conversation.json"))
    }

    public func load() -> [AgentMessage] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        do { return try JSONDecoder().decode([AgentMessage].self, from: data) }
        catch {
            Diagnostics.shared.record(.warning, "assistant", "conversation unreadable, starting afresh")
            return []
        }
    }

    public func save(_ messages: [AgentMessage]) {
        var kept = Array(messages.suffix(Self.limit))
        // A result whose call was cut off is no use on its own.
        while kept.first?.role == .tool { kept.removeFirst() }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(kept).write(to: file, options: [.atomic])
        } catch {
            Diagnostics.shared.record(.warning, "assistant", "conversation save failed \(type(of: error))")
        }
    }

    public func delete() { try? FileManager.default.removeItem(at: file) }
}

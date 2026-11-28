#if DEBUG
import Foundation
import TVCore

/// `-qaAgentTool <name> -qaAgentArgs '<json object>'` runs one assistant tool at launch, without a model, and prints
/// its confirmation summary and JSON result (`AGENT-QA` lines on stdout, and Caches/agent-qa.json). Several in a row:
/// `-qaAgentStepsFile <steps.json>` holding `[{"tool":"app_state"},{"tool":"settings_get","args":{"ids":["appearance"]}}]`. Needs a QA launch
/// (`-qaSection …`), after its `-qaSubscription` import.
@MainActor enum AgentToolsQA {
    static func start(_ store: Store) {
        let defaults = UserDefaults.standard
        var steps: [(String, [String: JSONValue])] = []
        if let name = defaults.string(forKey: "qaAgentTool") {
            steps.append((name, defaults.string(forKey: "qaAgentArgs").flatMap(JSONValue.parse)?.object ?? [:]))
        }
        // `-qaAgentStepsFile <path>`: the steps in a file, as launch arguments read JSON-like text as a property list.
        let file = defaults.string(forKey: "qaAgentStepsFile").flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        if let text = file ?? defaults.string(forKey: "qaAgentSteps"), let list = JSONValue.parse(text)?.array {
            for step in list {
                guard let name = step.object?["tool"]?.string else { continue }
                steps.append((name, step.object?["args"]?.object ?? [:]))
            }
        }
        guard !steps.isEmpty else { return }
        Task { @MainActor in
            // The launch's page and subscription settle first.
            try? await Task.sleep(for: .seconds(defaults.double(forKey: "qaAgentDelay").nonZero ?? 2))
            let tools = AppAgentTools.all(store: store)
            var report: [JSONValue] = []
            emit("tools \(tools.count): \(tools.map(\.spec.name).joined(separator: ","))")
            for (name, arguments) in steps {
                // `{"tool":"wait","args":{"seconds":3}}` lets the player or a page settle between steps.
                if name == "wait" {
                    try? await Task.sleep(for: .seconds(arguments["seconds"]?.int ?? 2))
                    continue
                }
                guard let tool = tools.first(where: { $0.spec.name == name }) else {
                    emit("\(name) -> unknown tool"); report.append(.obj(["tool": .str(name), "error": .str("unknown tool")])); continue
                }
                let summary = (tool as? any AgentDescribedTool)?.summary(arguments)
                if let summary { emit("\(name) summary: \(summary.summary)" + (summary.detail.map { "\n\($0)" } ?? "")) }
                let started = Date()
                var entry: [String: JSONValue?] = ["tool": .str(name), "effect": .str("\(tool.spec.effect)"), "args": .object(arguments),
                                                   "summary": summary.map { .str($0.summary) }]
                do {
                    let result = try await tool.run(arguments)
                    entry["result"] = result
                    emit("\(name) (\(Int(Date().timeIntervalSince(started) * 1000)) ms) -> \(result.jsonText)")
                } catch {
                    let message = (error as? AgentToolError)?.message ?? error.localizedDescription
                    entry["error"] = .str(message)
                    emit("\(name) -> error: \(message)")
                }
                report.append(.obj(entry))
            }
            let file = URL.cachesDirectory.appending(path: "agent-qa.json")
            try? Data(JSONValue.array(report).jsonText.utf8).write(to: file)
            emit("done \(file.path)")
        }
    }

    private static func emit(_ line: String) {
        print("AGENT-QA " + line)
        fflush(stdout)
        Diagnostics.shared.record(.info, "agent-qa", String(line.prefix(2000)))
    }
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
#endif

import TVCore

/// Every tool the assistant can use (Docs/agent.md, "Tools").
/// PLACEHOLDER from the UI branch so the app builds before the tools land: the tools branch replaces this file.
@MainActor enum AppAgentTools {
    static func all(store: Store) -> [any AgentTool] { [] }
}

import Foundation

/// The assistant's settings (UserDefaults) and where its secrets are (Keychain).
/// STUB (feature/agent skeleton): the core implementation fills these in, keeping the names.
public enum AgentSettings {
    /// Off until the viewer turns it on in Settings › Assistant.
    public static let enabledKey = "assistant.enabled"
    /// JSON of `AgentConnection`.
    public static let connectionKey = "assistant.connection"
    public static let modelKey = "assistant.model"
    /// Ask before `change` tools (destructive ones always ask).
    public static let asksKey = "assistant.asksBeforeChanges"
    /// Sign in with ChatGPT is offered only when this is on (remote flag or debug), see Docs/agent.md "Eligibility".
    public static let chatGPTSignInKey = "assistant.chatGPTSignIn"

    public static var connection: AgentConnection? {
        get { UserDefaults.standard.data(forKey: connectionKey).flatMap { try? JSONDecoder().decode(AgentConnection.self, from: $0) } }
        set { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: connectionKey) }
    }
}

/// Makes the client for a connection, reading its secret from the Keychain.
/// STUB: throws until the core implementation lands.
public enum AgentClients {
    public static func make(_ connection: AgentConnection) throws -> any AgentModelClient {
        throw AgentFailure(.notSignedIn, "Not implemented yet")
    }
}

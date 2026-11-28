import Foundation
import Security

/// The assistant's settings (UserDefaults) and where its secrets are (Keychain).
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

    public static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// The model picked in Settings, or nil for the connection's first one.
    public static var model: String? {
        get { UserDefaults.standard.string(forKey: modelKey).flatMap { $0.isEmpty ? nil : $0 } }
        set { UserDefaults.standard.set(newValue, forKey: modelKey) }
    }

    /// On unless the viewer turned it off.
    public static var asksBeforeChanges: Bool {
        get { UserDefaults.standard.object(forKey: asksKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: asksKey) }
    }

    public static var offersChatGPTSignIn: Bool {
        #if os(tvOS)
        false
        #elseif DEBUG
        // Development builds offer it unless turned off; TestFlight and App Store builds only once it's turned on
        // (Docs/agent.md, "Eligibility").
        UserDefaults.standard.object(forKey: chatGPTSignInKey) as? Bool ?? true
        #else
        UserDefaults.standard.bool(forKey: chatGPTSignInKey)
        #endif
    }
}

/// Where the assistant keeps secrets: API keys (one per base URL) and the ChatGPT sign-in's tokens.
public protocol AgentSecretStore: Sendable {
    func data(_ account: String) -> Data?
    /// Nil removes it.
    func set(_ data: Data?, _ account: String)
}

extension AgentSecretStore {
    /// The API key saved for `baseURL` (its address without a trailing slash).
    public func apiKey(for baseURL: URL) -> String? {
        data(Self.apiKeyAccount(baseURL)).map { String(decoding: $0, as: UTF8.self) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Saves (or, with nil or empty text, removes) the API key for `baseURL`.
    public func setAPIKey(_ key: String?, for baseURL: URL) {
        let key = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        set(key.isEmpty ? nil : Data(key.utf8), Self.apiKeyAccount(baseURL))
    }

    static func apiKeyAccount(_ baseURL: URL) -> String {
        var text = baseURL.absoluteString.lowercased()
        while text.hasSuffix("/") { text.removeLast() }
        return "apikey " + text
    }
}

/// The Keychain: generic passwords under `com.yingxia.assistant`, never synced, readable after the first unlock.
public struct AgentKeychain: AgentSecretStore {
    public let service: String
    public init(service: String = "com.yingxia.assistant") { self.service = service }

    public func data(_ account: String) -> Data? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status != errSecSuccess, status != errSecItemNotFound { Diagnostics.shared.record(.warning, "assistant", "keychain read failed status=\(status)") }
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    public func set(_ data: Data?, _ account: String) {
        SecItemDelete(base(account) as CFDictionary)
        guard let data else { return }
        var item = base(account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { Diagnostics.shared.record(.warning, "assistant", "keychain save failed status=\(status)") }
    }

    private func base(_ account: String) -> [String: Any] {
        // On the Mac this is the login keychain: the data-protection one needs an entitlement Debug builds lack.
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }
}

/// Secrets held in memory, for tests and previews.
public final class MemoryAgentSecrets: AgentSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: Data] = [:]
    public init() {}
    public func data(_ account: String) -> Data? { lock.withLock { stored[account] } }
    public func set(_ data: Data?, _ account: String) { lock.withLock { stored[account] = data } }
}

/// Makes the client for a connection, reading its secret from the Keychain.
public enum AgentClients {
    public static func make(_ connection: AgentConnection) throws -> any AgentModelClient {
        try make(connection, secrets: AgentKeychain())
    }

    public static func make(_ connection: AgentConnection, secrets: any AgentSecretStore, session: URLSession = .shared) throws -> any AgentModelClient {
        switch connection {
        case .apiKey(let settings):
            let key = secrets.apiKey(for: settings.baseURL)
            // OpenAI always needs a key; a server of the viewer's own (a local one) may not.
            if key == nil, settings.baseURL.host()?.lowercased() == APIKeyConnection.openAI.baseURL.host() {
                throw AgentFailure(.notSignedIn, L10n.text("Add an API key or sign in with ChatGPT in Settings › Assistant."))
            }
            let authorization: AgentAuthorization = { key }
            switch settings.wire {
            case .responses: return ResponsesClient(baseURL: settings.baseURL, session: session, authorization: authorization)
            case .chatCompletions: return ChatCompletionsClient(baseURL: settings.baseURL, session: session, authorization: authorization)
            }
        case .chatGPT:
            #if os(tvOS)
            throw AgentFailure(.unsupported, L10n.text("Sign in with ChatGPT isn't available on Apple TV. Use an API key instead."))
            #else
            var client = ResponsesClient(baseURL: APIKeyConnection.openAI.baseURL, session: session) {
                try await ChatGPTSignIn.shared.accessToken()
            }
            client.signsInWithChatGPT = true
            return client
            #endif
        }
    }
}

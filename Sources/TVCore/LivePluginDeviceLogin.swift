import Foundation

/// A device-code sign-in (`auth.credentialKinds` has `oauth_device_code`; Twitch): the plugin gets a short
/// code from the platform, the viewer enters it on the platform's own page on any device, and the plugin's
/// polling ends with tokens that the app keeps in the Keychain (`LivePluginTokens`).
public struct LivePluginDeviceCode: Sendable, Equatable {
    /// What the viewer types on the page.
    public let code: String
    /// The platform's page; it may carry the code already.
    public let page: URL
    public let expires: Date
    public let interval: Double
}

public enum LivePluginDeviceState: Sendable, Equatable {
    case waiting, authorized, denied, expired, failed
}

extension LivePlugins {
    /// Whether the plugin signs in with a device code.
    public func signsInByDeviceCode(_ id: String) async -> Bool {
        guard let folder = try? await files(id), let data = try? Data(contentsOf: folder.appending(path: "manifest.json")),
              let manifest = try? JSONDecoder().decode(JSONValue.self, from: data).object,
              (manifest["auth"]?.object?["credentialKinds"]?.array ?? []).contains(where: { $0.string == "oauth_device_code" }) else { return false }
        return await LivePluginRuntime.shared.has(id, "startDeviceLogin")
    }
}

public actor LivePluginDeviceSession {
    public let plugin: String
    private var login: String?

    public init(plugin: String) { self.plugin = plugin }

    public func start() async throws -> LivePluginDeviceCode {
        await cancel()
        let id = UUID().uuidString.lowercased()
        let reply = try await LivePluginRuntime.shared.call(plugin, "startDeviceLogin", ["loginId": .string(id)], timeout: 30).object ?? [:]
        guard let code = reply["userCode"]?.string, !code.isEmpty,
              let page = reply["verificationUri"]?.string.flatMap(URL.init(string:)), page.scheme?.lowercased() == "https" else {
            throw LivePluginError(code: "INVALID_RESPONSE", message: L10n.text("The platform sent no sign-in code."))
        }
        login = id
        Diagnostics.shared.record(.info, "plugins", "\(plugin) device sign-in code made")
        return LivePluginDeviceCode(code: code, page: page,
                                    expires: Date(timeIntervalSince1970: reply["expiresAt"]?.double ?? Date().timeIntervalSince1970 + 600),
                                    interval: min(60, max(2, reply["interval"]?.double ?? 5)))
    }

    /// Asks the plugin; it keeps to the platform's own pace however often this is called.
    public func poll() async throws -> LivePluginDeviceState {
        guard let login else { return .expired }
        let reply = try await LivePluginRuntime.shared.call(plugin, "pollDeviceLogin", ["loginId": .string(login)], timeout: 30).object ?? [:]
        switch reply["state"]?.string ?? "" {
        case "waiting", "starting": return .waiting
        case "authorized":
            self.login = nil
            guard let credential = reply["credential"]?.object, credential["accessToken"]?.string?.isEmpty == false else { return .failed }
            let before = LivePluginTokens.credential(plugin)
            LivePluginTokens.set(plugin, credential)
            // A token the plugin itself calls invalid is not kept.
            if await LivePlugins.shared.checkSignIn(plugin) == false {
                LivePluginTokens.set(plugin, before)
                Diagnostics.shared.record(.warning, "plugins", "\(plugin) device sign-in: the plugin rejected the new token")
                return .failed
            }
            Diagnostics.shared.record(.info, "plugins", "\(plugin) signed in by device code")
            return .authorized
        case "denied": self.login = nil; return .denied
        case "expired": self.login = nil; return .expired
        default: self.login = nil; return .failed
        }
    }

    public func cancel() async {
        guard let login else { return }
        self.login = nil
        _ = try? await LivePluginRuntime.shared.call(plugin, "cancelDeviceLogin", ["loginId": .string(login)], timeout: 10)
    }
}

import Foundation

/// A plugin's QR sign-in (`loginChallenge` in its manifest, kind `qrcode`): the plugin makes a code, the viewer
/// scans it with the platform's app, and the plugin's polling collects the sign-in cookies in a jar of this
/// sign-in's own. Once confirmed, the platform's cookies move to the Keychain like a web sign-in's.
public struct LivePluginQRPlan: Sendable {
    public let hint: String
    public let pollInterval: Double
    public let timeout: Double
    public let maxRefreshes: Int
    /// The plugin can take a verification code (Douyin's SMS check).
    public let verifies: Bool
    public let resends: Bool
    let functions: [String: String]
    /// Sites whose cookies make up the sign-in.
    let domains: [String]

    init?(manifest: [String: JSONValue]) {
        guard let challenge = manifest["loginChallenge"]?.object, challenge["kind"]?.string == "qrcode",
              Int(challenge["minLoginChallengeProtocol"]?.double ?? 1) <= 2 else { return nil }
        hint = challenge["hint"]?.string ?? ""
        pollInterval = max(1, (challenge["pollIntervalMs"]?.double ?? 2000) / 1000)
        timeout = min(600, max(30, challenge["timeoutSeconds"]?.double ?? 180))
        maxRefreshes = Int(challenge["maxRefreshes"]?.double ?? 3)
        functions = (challenge["functions"]?.object ?? [:]).compactMapValues(\.string)
        verifies = functions["submitVerification"] != nil
        resends = functions["resendVerification"] != nil
        let flow = manifest["loginFlow"]?.object ?? [:]
        var domains = (flow["cookieDomains"]?.array ?? []).compactMap(\.string)
        if let site = flow["websiteHost"]?.string { domains.append(site) }
        self.domains = domains.map(LivePluginLoginJars.bare).filter { !$0.isEmpty }
    }
}

public struct LivePluginQRChallenge: Sendable, Equatable {
    /// What the QR code holds.
    public let content: String
    public let hint: String
    public let expires: Date?
    public let pollInterval: Double
    public let firstPollDelay: Double
}

public enum LivePluginQRState: Sendable, Equatable {
    case waiting
    case scanned
    /// The platform wants a code it sent (SMS); `message` is its own wording.
    case verification(message: String)
    case confirmed
    case expired
    case failed(String)
}

extension LivePlugins {
    /// The plugin's QR sign-in, when it has one this app can run.
    public func qrLogin(_ id: String) async -> LivePluginQRPlan? {
        guard let folder = try? await files(id), let data = try? Data(contentsOf: folder.appending(path: "manifest.json")),
              let manifest = try? JSONDecoder().decode(JSONValue.self, from: data).object else { return nil }
        return LivePluginQRPlan(manifest: manifest)
    }
}

/// One QR sign-in, from the code to the saved cookie.
public actor LivePluginQRSession {
    public let plugin: String
    public let plan: LivePluginQRPlan
    private var transaction: String?
    private var challenge: String?

    public init(plugin: String, plan: LivePluginQRPlan) {
        self.plugin = plugin; self.plan = plan
    }

    private func name(_ function: String, _ fallback: String) -> String { plan.functions[function] ?? fallback }
    private var identity: [String: JSONValue] {
        ["transactionId": .string(transaction ?? ""), "challengeId": .string(challenge ?? ""), "platform": .string(plugin)]
    }

    /// A new code. An earlier one of this session is cancelled.
    public func start() async throws -> LivePluginQRChallenge {
        await cancel()
        let id = UUID().uuidString.lowercased()
        LivePluginLoginJars.shared.open(id, plugin: plugin)
        transaction = id
        do {
            let reply = try await LivePluginRuntime.shared.call(plugin, name("create", "createLoginChallenge"),
                                                                ["transactionId": .string(id), "platform": .string(plugin)], timeout: 40).object ?? [:]
            guard let content = reply["qrContent"]?.string, !content.isEmpty, let challenge = reply["challengeId"]?.string else {
                throw LivePluginError(code: "INVALID_RESPONSE", message: L10n.text("The platform sent no sign-in code."))
            }
            self.challenge = challenge
            let expires = reply["expiresAt"]?.double.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
            Diagnostics.shared.record(.info, "plugins", "\(plugin) QR sign-in code made")
            return LivePluginQRChallenge(content: content, hint: reply["hint"]?.string ?? plan.hint, expires: expires,
                                         pollInterval: max(1, (reply["pollIntervalMs"]?.double).map { $0 / 1000 } ?? plan.pollInterval),
                                         firstPollDelay: max(0, (reply["initialPollDelayMs"]?.double ?? 0) / 1000))
        } catch {
            LivePluginLoginJars.shared.close(id); transaction = nil
            throw error
        }
    }

    public func poll() async throws -> LivePluginQRState {
        guard transaction != nil, challenge != nil else { return .expired }
        let reply = try await LivePluginRuntime.shared.call(plugin, name("poll", "pollLoginChallenge"), identity, timeout: 40).object ?? [:]
        return await state(reply)
    }

    /// The code the platform sent, after `.verification`.
    public func submit(code: String) async throws -> LivePluginQRState {
        guard let function = plan.functions["submitVerification"], transaction != nil else { return .expired }
        var payload = identity
        payload["code"] = .string(code); payload["verificationCode"] = .string(code)
        return await state(try await LivePluginRuntime.shared.call(plugin, function, payload, timeout: 40).object ?? [:])
    }

    public func resend() async throws {
        guard let function = plan.functions["resendVerification"], transaction != nil else { return }
        _ = try await LivePluginRuntime.shared.call(plugin, function, identity, timeout: 40)
    }

    private func state(_ reply: [String: JSONValue]) async -> LivePluginQRState {
        let message = reply["message"]?.string ?? ""
        switch reply["state"]?.string ?? "" {
        case "scanned": return .scanned
        case "verification_required": return .verification(message: reply["verification"]?.object?["message"]?.string ?? message)
        case "confirmed": return await finish()
        case "expired": close(); return .expired
        case "failed": close(); return .failed(message)
        default: return .waiting
        }
    }

    /// Moves the platform's cookies from the jar to the Keychain; a cookie the plugin calls invalid is not kept.
    private func finish() async -> LivePluginQRState {
        guard let transaction else { return .expired }
        let cookies = LivePluginLoginJars.shared.cookies(transaction).filter { cookie in
            plan.domains.isEmpty || plan.domains.contains { cookie.domain == $0 || cookie.domain.hasSuffix("." + $0) || $0.hasSuffix("." + cookie.domain) }
        }
        close()
        var seen = Set<String>()
        let header = cookies.reversed().filter { seen.insert($0.name).inserted }.reversed().map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        guard !header.isEmpty else { return .failed(L10n.text("The platform confirmed the sign-in but sent no cookies.")) }
        let before = LivePluginAccounts.cookie(plugin)
        LivePluginAccounts.setCookie(plugin, header)
        if await LivePlugins.shared.checkSignIn(plugin) == false {
            LivePluginAccounts.setCookie(plugin, before.isEmpty ? nil : before)
            Diagnostics.shared.record(.warning, "plugins", "\(plugin) QR sign-in: the plugin rejected the new cookie")
            return .failed(L10n.text("The platform didn't accept this sign-in. Try again."))
        }
        Diagnostics.shared.record(.info, "plugins", "\(plugin) signed in by QR code (\(cookies.count) cookies)")
        return .confirmed
    }

    private func close() {
        if let transaction { LivePluginLoginJars.shared.close(transaction) }
        transaction = nil; challenge = nil
    }

    public func cancel() async {
        guard transaction != nil else { return }
        let payload = identity
        close()
        if challenge == nil, payload["challengeId"]?.string?.isEmpty == false {
            _ = try? await LivePluginRuntime.shared.call(plugin, name("cancel", "cancelLoginChallenge"), payload, timeout: 10)
        }
    }
}

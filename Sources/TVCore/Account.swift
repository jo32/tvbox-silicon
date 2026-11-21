import CryptoKit
import Foundation
import Security

/// A Yingxia account, kept by the accounts server (Services/accounts): who signed in (with Apple or Telegram), the
/// feedback that counts for them (what their signed-in installs sent, and how much of it the developer adopted), and
/// Pro, which comes from redeem codes. The app keeps the session token in the keychain and the last copy of the
/// account in its preferences, so Settings shows it at once and Pro holds offline.
public struct Account: Codable, Sendable, Equatable {
    public struct Identity: Codable, Sendable, Equatable, Identifiable {
        /// `apple` or `telegram`.
        public var provider: String
        /// An email address, @username or name.
        public var label: String
        public var created: Double
        public var id: String { provider }
    }

    public struct Pro: Codable, Sendable, Equatable {
        public var active: Bool
        /// Unix seconds; nil when never Pro.
        public var until: Double?
        public var lifetime: Bool
    }

    /// What the server signed: the person and when Pro ends. `ProEntitlement.until` checks it.
    public struct Entitlement: Codable, Sendable, Equatable {
        public var payload: String
        public var signature: String
    }

    public struct Feedback: Codable, Sendable, Equatable {
        public struct Issue: Codable, Sendable, Equatable, Identifiable {
            public var number: Int
            public var title: String
            /// open, fixed (a reported bug), adopted (a suggested idea), closed, declined or duplicate.
            public var status: String
            public var sent: Double
            public var id: Int { number }
        }
        public var sent: Int
        public var adopted: Int
        public var declined: Int
        public var points: Int
        /// Pro days each adopted message gives; 0 when adopting gives none.
        public var rewardDays: Int
        public var issues: [Issue]
    }

    /// Points (Services/accounts/src/points.ts): what the person's help is worth, with the rules so the app can explain
    /// them. They reward feedback and code that get used far more than volume.
    public struct Points: Codable, Sendable, Equatable {
        public struct Rules: Codable, Sendable, Equatable {
            public var daily: Int
            public var sent: Int
            public var sentPerDay: Int
            /// A reported bug the developer fixed (the `fixed` label).
            public var fixed: Int
            /// A suggested idea the developer adopted (the `adopted` label).
            public var adopted: Int
            public var pullRequest: Int
            /// The server's own (Services/accounts/wrangler.jsonc), for explaining points before an account or a server
            /// has sent any.
            public static let standard = Rules(daily: 1, sent: 1, sentPerDay: 3, fixed: 50, adopted: 100, pullRequest: 500)

            public init(daily: Int, sent: Int, sentPerDay: Int, fixed: Int, adopted: Int, pullRequest: Int) {
                self.daily = daily; self.sent = sent; self.sentPerDay = sentPerDay
                self.fixed = fixed; self.adopted = adopted; self.pullRequest = pullRequest
            }

            /// A server from before fixed bugs had their own rule paid them as adopted.
            public init(from decoder: any Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                daily = try values.decode(Int.self, forKey: .daily)
                sent = try values.decode(Int.self, forKey: .sent)
                sentPerDay = try values.decode(Int.self, forKey: .sentPerDay)
                adopted = try values.decode(Int.self, forKey: .adopted)
                fixed = try values.decodeIfPresent(Int.self, forKey: .fixed) ?? adopted
                pullRequest = try values.decode(Int.self, forKey: .pullRequest)
            }
        }
        public var total: Int
        /// Days the app was open while signed in.
        public var days: Int
        /// Feedback messages that earned their point: at most `sentPerDay` a day, never duplicates or declined ones.
        public var sent: Int
        /// Reported bugs the developer fixed; a server from before this rule counts them in `adopted`.
        public var fixed: Int
        /// Suggested ideas the developer adopted.
        public var adopted: Int
        public var pullRequests: Int
        /// Added (or taken away) by the developer.
        public var adjusted: Int
        public var rules: Rules

        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            total = try values.decode(Int.self, forKey: .total)
            days = try values.decode(Int.self, forKey: .days)
            sent = try values.decode(Int.self, forKey: .sent)
            fixed = try values.decodeIfPresent(Int.self, forKey: .fixed) ?? 0
            adopted = try values.decode(Int.self, forKey: .adopted)
            pullRequests = try values.decode(Int.self, forKey: .pullRequests)
            adjusted = try values.decode(Int.self, forKey: .adjusted)
            rules = try values.decode(Rules.self, forKey: .rules)
        }

        /// What fixed bugs and adopted ideas brought together.
        public var feedbackEarned: Int { fixed * rules.fixed + adopted * rules.adopted }
    }

    /// A merged pull request that counts for the person.
    public struct PullRequest: Codable, Sendable, Equatable, Identifiable {
        public var number: Int
        public var title: String
        public var merged: Double
        public var id: Int { number }
    }

    public var id: String
    public var name: String
    public var identities: [Identity]
    public var pro: Pro
    public var entitlement: Entitlement?
    public var feedback: Feedback
    public var points: Points?
    public var pullRequests: [PullRequest]?
    public var telegramBot: String?

    public func has(_ provider: String) -> Bool { identities.contains { $0.provider == provider } }
    /// The name, or how they signed in.
    public var displayName: String { name.isEmpty ? identities.first?.label ?? "" : name }
}

/// The accounts server's routes.
public enum AccountService {
    public static let address = URL(string: "https://yingxia-accounts.getmegaportal.com")!

    /// Debug builds take another server with `-qaAccounts <url>`, or the one built in with `ACCOUNTS_SERVER=<url>`.
    static var base: URL {
        #if DEBUG
        if let text = UserDefaults.standard.string(forKey: "qaAccounts"), let url = URL(string: text) { return url }
        if let text = Bundle.main.object(forInfoDictionaryKey: "YingxiaAccountsServer") as? String, !text.isEmpty,
           let url = URL(string: text) { return url }
        #endif
        return address
    }

    public enum Failure: LocalizedError, Equatable {
        case signedOut, rejected, identityTaken, expired, tooMany, unavailable, failed
        /// A code that didn't redeem, with the server's reason.
        case code(String)

        public var errorDescription: String? {
            switch self {
            case .signedOut: L10n.text("You've been signed out. Sign in again.")
            case .rejected: L10n.text("Couldn't sign in. Please try again.")
            case .identityTaken: L10n.text("This sign-in already belongs to another Yingxia account.")
            case .expired: L10n.text("This sign-in link has expired. Start again.")
            case .tooMany: L10n.text("Too many tries. Wait a minute and try again.")
            case .unavailable: L10n.text("Accounts aren't available right now. Please try again later.")
            case .failed: L10n.text("Couldn't reach the server. Please try again.")
            case .code(let reason):
                switch reason {
                case "not_found", "invalid": L10n.text("There's no such code. Check it and try again.")
                case "revoked": L10n.text("This code has been withdrawn.")
                case "expired": L10n.text("This code has expired.")
                case "used_up": L10n.text("This code has already been used.")
                case "already_redeemed": L10n.text("You've already redeemed this code.")
                default: L10n.text("Couldn't redeem this code.")
                }
            }
        }
    }

    public struct SignIn: Sendable {
        /// A new session; nil when an account already signed in only gained a way to sign in.
        public let token: String?
        public let account: Account
    }

    public struct TelegramLogin: Decodable, Sendable, Equatable {
        public let code: String
        /// t.me/<bot>?start=<code>: opens the bot, whose Start finishes the sign-in.
        public let url: URL
        public let expires: Double
    }

    private struct SignInBody: Decodable { let token: String?; let account: Account }
    private struct RedeemBody: Decodable { let days: Int?; let account: Account }
    private struct DayBody: Decodable { let counted: Bool; let account: Account }
    private struct ErrorBody: Decodable { let error: String }

    private static func call(_ path: String, method: String = "POST", body: [String: String]? = nil, token: String? = nil,
                             session: URLSession = .shared) async throws -> (Data, Int) {
        var request = URLRequest(url: base.appending(path: path), timeoutInterval: 20)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw Failure.failed }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return (data, status)
        case 401: throw Failure.signedOut
        case 409 where (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error == "identity_taken": throw Failure.identityTaken
        case 410: throw Failure.expired
        case 429: throw Failure.tooMany
        case 503: throw Failure.unavailable
        default: throw Failure.failed
        }
    }

    /// The install (its error reports and feedback carry the same random ID) and platform, so the server can count
    /// the feedback it sent for the person.
    private static var device: [String: String] { ["install": ErrorReports.shared.install, "platform": ErrorReports.platform] }

    /// `token`: already signed in (with Telegram), so Apple joins that account.
    public static func signInWithApple(identityToken: String, authorizationCode: String?, name: String?, token: String?) async throws -> SignIn {
        var body = device
        body["identityToken"] = identityToken
        if let authorizationCode { body["authorizationCode"] = authorizationCode }
        if let name, !name.isEmpty { body["name"] = name }
        do {
            let (data, _) = try await call("v1/auth/apple", body: body, token: token)
            let decoded = try JSONDecoder().decode(SignInBody.self, from: data)
            return SignIn(token: decoded.token, account: decoded.account)
        } catch Failure.signedOut where token == nil {
            throw Failure.rejected // without a session, a 401 means Apple's token didn't check out
        }
    }

    public static func startTelegram(token: String?) async throws -> TelegramLogin {
        let (data, _) = try await call("v1/auth/telegram", body: device, token: token)
        return try JSONDecoder().decode(TelegramLogin.self, from: data)
    }

    /// The sign-in once the bot has seen it, nil while it is still waiting.
    public static func pollTelegram(code: String, token: String?) async throws -> SignIn? {
        let (data, status) = try await call("v1/auth/telegram/poll", body: ["code": code], token: token)
        if status == 202 { return nil }
        let decoded = try JSONDecoder().decode(SignInBody.self, from: data)
        return SignIn(token: decoded.token, account: decoded.account)
    }

    public static func account(token: String) async throws -> Account {
        let (data, _) = try await call("v1/me", method: "GET", token: token)
        return try JSONDecoder().decode(Account.self, from: data)
    }

    /// The app is open today: the day's point. The server counts a day once per account, and gives each device's day to
    /// one account only.
    public static func markActiveDay(token: String) async throws -> Account {
        let (data, _) = try await call("v1/me/day", body: [:], token: token)
        return try JSONDecoder().decode(DayBody.self, from: data).account
    }

    public static func redeem(code: String, token: String) async throws -> (days: Int?, account: Account) {
        var request = URLRequest(url: base.appending(path: "v1/me/redeem"), timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["code": code])
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) } catch { throw Failure.failed }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 || status == 409, let reason = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error { throw Failure.code(reason) }
        switch status {
        case 200..<300:
            let decoded = try JSONDecoder().decode(RedeemBody.self, from: data)
            return (decoded.days, decoded.account)
        case 401: throw Failure.signedOut
        case 429: throw Failure.tooMany
        case 503: throw Failure.unavailable
        default: throw Failure.failed
        }
    }

    public static func signOut(token: String) async {
        _ = try? await call("v1/sign-out", token: token)
    }

    /// Deletes the account and everything the server keeps about the person; Apple's sign-in is revoked too.
    public static func delete(token: String) async throws {
        _ = try await call("v1/me", method: "DELETE", token: token)
    }
}

/// Pro, as the app knows it offline: the server's signed entitlement, checked with its Ed25519 public key. The
/// private key is the accounts server's ENTITLEMENT_KEY secret.
public enum ProEntitlement {
    static let publicKey = "Z+s/rd1C+C0Nf5M7LNT0oWnzq2EsSK7f8uWEZ1HnJLE="

    private struct Payload: Decodable { let v: Int; let user: String; let until: Double }

    /// When Pro ends for `user`, or nil when the entitlement isn't the server's, is someone else's, or gives no Pro.
    public static func until(_ entitlement: Account.Entitlement, user: String) -> Date? {
        until(entitlement, user: user, key: publicKey)
    }

    static func until(_ entitlement: Account.Entitlement, user: String, key: String) -> Date? {
        guard let raw = Data(base64Encoded: key), let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
              let payload = Data(base64URL: entitlement.payload), let signature = Data(base64URL: entitlement.signature),
              publicKey.isValidSignature(signature, for: payload),
              let decoded = try? JSONDecoder().decode(Payload.self, from: payload),
              decoded.v == 1, decoded.user == user, decoded.until > 0 else { return nil }
        return Date(timeIntervalSince1970: decoded.until)
    }
}

extension Data {
    init?(base64URL text: String) {
        var plain = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        plain += String(repeating: "=", count: (4 - plain.count % 4) % 4)
        self.init(base64Encoded: plain)
    }
}

/// The session token, in the keychain (this device only). QA runs with `-qaIsolatedData` keep their own.
public enum AccountKeychain {
    static var service: String {
        "com.jo32.yingxia.account" + (UserDefaults.standard.bool(forKey: "qaIsolatedData") ? ".qa" : "")
    }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "session"]
    }

    public static func token() -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func save(_ token: String?) {
        SecItemDelete(query as CFDictionary)
        guard let token else { return }
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}

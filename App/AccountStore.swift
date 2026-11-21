import AuthenticationServices
import StoreKit
import SwiftUI
import TVCore

/// The signed-in Yingxia account (Sources/TVCore/Account.swift), for Settings › Account and for whatever Pro unlocks:
/// ask `AccountStore.shared.isPro`. The last copy of the account is kept, so Pro holds offline and Settings shows the
/// name at once.
@MainActor @Observable final class AccountStore {
    static let shared = AccountStore()

    private(set) var account: Account?
    /// A Telegram sign-in waiting for the person to tap Start in the bot.
    private(set) var telegramLogin: AccountService.TelegramLogin?
    private(set) var busy = false
    private var refreshed: Date?
    private var sandboxAppTransaction: Bool?

    private static let cacheKey = "account.cached"
    private static let ownsKeychainKey = "account.ownsKeychain"

    init() {
        // The keychain outlives the app on iPhone and Apple TV: an app installed again starts signed out.
        if !UserDefaults.standard.bool(forKey: Self.ownsKeychainKey) {
            AccountKeychain.save(nil)
            UserDefaults.standard.set(true, forKey: Self.ownsKeychainKey)
        }
        #if DEBUG
        // `-qaAccountToken <session>` (with `-qaAccounts <url>`): QA runs start signed in, without Apple or Telegram.
        if let token = UserDefaults.standard.string(forKey: "qaAccountToken") { AccountKeychain.save(token) }
        #endif
        if AccountKeychain.token() != nil, let data = UserDefaults.standard.data(forKey: Self.cacheKey) {
            account = try? JSONDecoder().decode(Account.self, from: data)
        }
    }

    var signedIn: Bool { account != nil }

    /// TestFlight, the Mac download, and sideloaded builds support Pro and in-app code redemption.
    var proAvailable: Bool {
        !Distribution.isAppStore || Distribution.isTestFlight || sandboxAppTransaction == true
    }

    /// TestFlight can lack a receipt, so also check the verified StoreKit app transaction.
    func checkAppTransaction() async {
        #if APPSTORE
        guard !Distribution.isTestFlight, sandboxAppTransaction == nil,
              case .verified(let transaction)? = try? await AppTransaction.shared else { return }
        sandboxAppTransaction = transaction.environment == .sandbox
        #endif
    }

    /// When Pro ends, from the signed entitlement.
    var proUntil: Date? {
        guard proAvailable, let account, let entitlement = account.entitlement,
              let until = ProEntitlement.until(entitlement, user: account.id), until > Date() else { return nil }
        return until
    }
    var isPro: Bool { proUntil != nil }
    var isLifetime: Bool { (proUntil?.timeIntervalSince1970 ?? 0) >= 253_402_300_799 }

    private func keep(_ account: Account?) {
        self.account = account
        if let account, let data = try? JSONEncoder().encode(account) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.cacheKey)
        }
    }

    private func finish(_ signIn: AccountService.SignIn) {
        if let token = signIn.token { AccountKeychain.save(token) }
        keep(signIn.account)
        Task { await markActiveDay() }
    }

    private static let activeDayKey = "account.activeDay"

    /// Once a day while signed in (TVBoxApp calls it whenever the app becomes active): the day's point. The server
    /// counts each day once anyway; this only saves asking again. A day starts at midnight UTC+8, as on the server.
    func markActiveDay() async {
        guard let token = AccountKeychain.token(), let account else { return }
        let today = "\(account.id):\(Int((Date().timeIntervalSince1970 + 8 * 3600) / 86400))"
        guard UserDefaults.standard.string(forKey: Self.activeDayKey) != today else { return }
        do {
            keep(try await AccountService.markActiveDay(token: token))
            refreshed = Date()
            UserDefaults.standard.set(today, forKey: Self.activeDayKey)
        } catch AccountService.Failure.signedOut {
            signedOutLocally()
        } catch {
            // Offline: try again next time the app comes back.
        }
    }

    private func signedOutLocally() {
        AccountKeychain.save(nil)
        keep(nil)
        telegramLogin = nil
    }

    /// Reads the account again; `force` even when it was read in the last few minutes. Signs out locally when the
    /// server no longer knows the session (deleted elsewhere, or expired).
    func refresh(force: Bool = false) async {
        guard let token = AccountKeychain.token() else {
            if account != nil { keep(nil) }
            return
        }
        if !force, let refreshed, Date().timeIntervalSince(refreshed) < 300 { return }
        do {
            keep(try await AccountService.account(token: token))
            refreshed = Date()
        } catch AccountService.Failure.signedOut {
            signedOutLocally()
        } catch {
            // Offline or the server is busy: keep the last copy.
        }
    }

    func signInWithApple(_ credential: AppleCredential) async throws {
        busy = true
        defer { busy = false }
        finish(try await AccountService.signInWithApple(identityToken: credential.identityToken, authorizationCode: credential.authorizationCode,
                                                         name: credential.name, token: AccountKeychain.token()))
        refreshed = Date()
    }

    /// Starts a Telegram sign-in (or adds Telegram to the account signed in), then waits for the bot to see it.
    func startTelegram() async throws {
        busy = true
        defer { busy = false }
        telegramLogin = try await AccountService.startTelegram(token: AccountKeychain.token())
    }

    func cancelTelegram() { telegramLogin = nil }

    /// Asks every two seconds until the bot has seen the sign-in, it expires, or `cancelTelegram()`.
    func waitForTelegram() async throws {
        while let login = telegramLogin, !Task.isCancelled {
            if Date().timeIntervalSince1970 > login.expires { telegramLogin = nil; throw AccountService.Failure.expired }
            // A check that fails on the way (no network, or the app suspended while the person is in Telegram) isn't the
            // end: keep waiting until the code expires.
            let signIn: AccountService.SignIn?
            do {
                signIn = try await AccountService.pollTelegram(code: login.code, token: AccountKeychain.token())
            } catch AccountService.Failure.failed, AccountService.Failure.unavailable, AccountService.Failure.tooMany {
                try await Task.sleep(for: .seconds(2))
                continue
            }
            if let signIn {
                guard telegramLogin?.code == login.code else { return }
                telegramLogin = nil
                finish(signIn)
                refreshed = Date()
                return
            }
            try await Task.sleep(for: .seconds(2))
        }
    }

    /// The Pro days the code gave (nil for lifetime).
    func redeem(_ code: String) async throws -> Int? {
        guard let token = AccountKeychain.token() else { throw AccountService.Failure.signedOut }
        busy = true
        defer { busy = false }
        do {
            let result = try await AccountService.redeem(code: code, token: token)
            keep(result.account)
            return result.days
        } catch AccountService.Failure.signedOut {
            signedOutLocally()
            throw AccountService.Failure.signedOut
        }
    }

    func signOut() async {
        if let token = AccountKeychain.token() { await AccountService.signOut(token: token) }
        signedOutLocally()
    }

    func delete() async throws {
        guard let token = AccountKeychain.token() else { return signedOutLocally() }
        busy = true
        defer { busy = false }
        do {
            try await AccountService.delete(token: token)
        } catch AccountService.Failure.signedOut {
            // Already gone on the server.
        }
        signedOutLocally()
    }
}

/// What Sign in with Apple gave, as the accounts server takes it.
struct AppleCredential: Sendable {
    let identityToken: String
    let authorizationCode: String?
    /// Only the first time someone signs in to the app.
    let name: String?

    init?(_ authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let token = credential.identityToken.flatMap({ String(data: $0, encoding: .utf8) }) else { return nil }
        identityToken = token
        authorizationCode = credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
        name = credential.fullName.map { PersonNameComponentsFormatter().string(from: $0) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Cancelling Apple's sheet isn't a failure.
    static func cancelled(_ error: Error) -> Bool {
        (error as? ASAuthorizationError)?.code == .canceled
    }
}

/// Whether this build can sign in with Apple. It needs the entitlement, which builds get with APPLE_SIGN_IN=YES
/// (Info.plist `YingxiaAppleSignIn`) once the App IDs and profiles have the capability. A build someone re-signed with
/// their own profile (sideloaded) loses it, so the embedded profile must allow it too; Telegram works everywhere.
enum AppleSignInSupport {
    static let available: Bool = {
        guard (Bundle.main.object(forInfoDictionaryKey: "YingxiaAppleSignIn") as? String)?.uppercased() == "YES" else { return false }
        #if os(macOS)
        let profile = Bundle.main.bundleURL.appending(path: "Contents/embedded.provisionprofile")
        #else
        let profile = Bundle.main.bundleURL.appending(path: "embedded.mobileprovision")
        #endif
        // App Store and TestFlight builds carry no profile: their entitlements are the ones they were archived with.
        guard let data = try? Data(contentsOf: profile) else { return true }
        guard let start = data.range(of: Data("<?xml".utf8)), let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else { return false }
        return entitlements["com.apple.developer.applesignin"] != nil
    }()
}

/// Sign in with Apple without Apple's button: Settings draws its own (Apple TV rows can't use Apple's, and on iPhone,
/// iPad and Mac the Apple and Telegram buttons share one look). On Apple TV the system asks on the TV or a nearby iPhone.
@MainActor final class AppleSignInRequest: NSObject {
    private var continuation: CheckedContinuation<AppleCredential, Error>?
    private var controller: ASAuthorizationController?

    func run() async throws -> AppleCredential {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        self.controller = controller
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    fileprivate func complete(_ result: Result<AppleCredential, Error>) {
        continuation?.resume(with: result)
        continuation = nil
        controller = nil
    }
}

extension AppleSignInRequest: @preconcurrency ASAuthorizationControllerDelegate, @preconcurrency ASAuthorizationControllerPresentationContextProviding {
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        complete(AppleCredential(authorization).map { .success($0) } ?? .failure(AccountService.Failure.rejected))
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        complete(.failure(error))
    }
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        #if os(macOS)
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #else
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        #endif
    }
}

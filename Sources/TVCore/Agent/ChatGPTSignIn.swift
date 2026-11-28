#if !os(tvOS)
import CryptoKit
import Foundation
import Network
import Observation
import Security

/// OpenAI's "Sign in with ChatGPT" for open-source apps (developers.openai.com/siwc/token-sharing-open-source): the
/// viewer signs in in a browser, the answer comes back to a listener on 127.0.0.1:1455, and the tokens it gives call
/// the Responses API on the viewer's ChatGPT plan. Tokens stay in the Keychain; nothing here is logged but statuses
/// and error codes. Not on Apple TV, which has no browser.
@MainActor @Observable public final class ChatGPTSignIn {
    public enum Status: Equatable, Sendable {
        case signedOut
        case signedIn(email: String)
        /// Signed in, but the plan-usage permission (`chatgpt.tokens.use.direct`) wasn't granted.
        case planUsageUnavailable(email: String)
    }

    /// Where to sign in. Tests point `issuer` at a fake server.
    public struct Endpoints: Sendable {
        public var issuer: URL
        /// The API the tokens are for (`resource`).
        public var resource: String
        /// The listener tries these in turn; only the port of the redirect address may change between sign-ins.
        public var callbackPorts: [UInt16]
        public init(issuer: URL, resource: String, callbackPorts: [UInt16]) {
            self.issuer = issuer; self.resource = resource; self.callbackPorts = callbackPorts
        }
        public static let openAI = Endpoints(issuer: URL(string: "https://auth.openai.com")!, resource: "https://api.openai.com/v1",
                                             callbackPorts: [1455, 1456, 1457])
    }

    public static let shared = ChatGPTSignIn()
    /// The viewer's plan usage page, for the usage-limit failure.
    nonisolated public static let usageURL = URL(string: "https://chatgpt.com/settings/usage")!
    nonisolated static let directScope = "chatgpt.tokens.use.direct"
    nonisolated static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    nonisolated static let hostIDKey = "assistant.chatGPT.hostID"
    nonisolated static let clientIDKey = "assistant.chatGPT.clientID"
    nonisolated static let credentialsAccount = "chatgpt credentials"

    public private(set) var status: Status = .signedOut
    public private(set) var isSigningIn = false

    @ObservationIgnored private let endpoints: Endpoints
    @ObservationIgnored private let secrets: any AgentSecretStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var credentials: Credentials?
    @ObservationIgnored private var refreshing: Task<Credentials, Error>?
    @ObservationIgnored private var discovery: Discovery?
    @ObservationIgnored private var listener: LoopbackListener?
    @ObservationIgnored private var attempt = 0

    public init(endpoints: Endpoints = .openAI, secrets: any AgentSecretStore = AgentKeychain(), defaults: UserDefaults = .standard,
                session: URLSession = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.endpoints = endpoints; self.secrets = secrets; self.defaults = defaults; self.session = session; self.now = now
        credentials = secrets.data(Self.credentialsAccount).flatMap { try? JSONDecoder().decode(Credentials.self, from: $0) }
        updateStatus()
    }

    /// This install's id for OpenAI (`ext_agent_host_id`), made once and kept.
    public var hostID: String {
        if let id = defaults.string(forKey: Self.hostIDKey), !id.isEmpty { return id }
        let id = "urn:uuid:" + UUID().uuidString.lowercased()
        defaults.set(id, forKey: Self.hostIDKey)
        return id
    }

    /// The client id OpenAI issued on the first sign-in (`oaiapp_…`); kept after sign-out.
    public var clientID: String? { defaults.string(forKey: Self.clientIDKey).flatMap { $0.isEmpty ? nil : $0 } }

    public var email: String? { credentials?.email }

    // MARK: Sign in

    /// Signs in: starts the loopback listener, hands `open` the address to show in a browser (an in-app browser
    /// sheet on iPhone and iPad, so the app stays awake to hear the answer; the default browser on the Mac), and
    /// returns once the tokens are saved. Throws `AgentFailure` (`.cancelled` when the viewer said no or
    /// `cancelSignIn()` ran). The caller closes its browser sheet when this returns.
    public func signIn(open: @MainActor (URL) -> Void) async throws {
        cancelSignIn()
        attempt += 1
        let mine = attempt
        isSigningIn = true
        var opened: LoopbackListener?
        defer {
            opened?.stop()
            if mine == attempt { isSigningIn = false; listener = nil }
        }
        let started = Date()
        do {
            let discovery = try await loadDiscovery()
            let verifier = Self.randomToken()
            let state = Self.randomToken(), nonce = Self.randomToken()
            let listener = try await LoopbackListener.start(ports: endpoints.callbackPorts, path: "/auth/callback", state: state)
            opened = listener
            guard mine == attempt else { throw CancellationError() }
            self.listener = listener
            let redirect = "http://127.0.0.1:\(listener.port)/auth/callback"
            let saved = clientID
            let url = Self.authorizationURL(endpoint: discovery.authorization, clientID: saved, hostID: hostID, redirectURI: redirect,
                                            challenge: Self.challenge(verifier), state: state, nonce: nonce,
                                            resource: endpoints.resource, idTokenHint: credentials?.idToken)
            Diagnostics.shared.record(.info, "assistant", "signin start port=\(listener.port) registered=\(saved != nil)")
            open(url)
            let answer = try await withTaskCancellationHandler { try await listener.callback() } onCancel: { listener.cancel() }
            if let error = answer["error"] {
                Diagnostics.shared.record(.info, "assistant", "signin callback error=\(error.prefix(64))")
                if error == "access_denied" { throw AgentFailure(.cancelled, L10n.text("Sign-in was cancelled."), code: error) }
                throw AgentFailure(.unauthorized, L10n.text("Sign-in didn't finish. Try again."), code: error)
            }
            guard let code = answer["code"], !code.isEmpty else { throw AgentFailure(.invalidResponse, L10n.text("Sign-in didn't finish. Try again."), code: "no_code") }
            let issued = answer["client_id"].flatMap { $0.isEmpty ? nil : $0 }
            let client: String
            if let saved {
                if let issued, issued != saved { throw AgentFailure(.invalidResponse, L10n.text("Sign-in didn't finish. Try again."), code: "client_mismatch") }
                client = saved
            } else {
                guard let issued else { throw AgentFailure(.invalidResponse, L10n.text("Sign-in didn't finish. Try again."), code: "registration_incomplete") }
                client = issued
            }
            let tokens = try await tokenRequest(discovery.token, ["grant_type": "authorization_code", "client_id": client, "code": code,
                                                                  "code_verifier": verifier, "redirect_uri": redirect, "resource": endpoints.resource])
            guard let idToken = tokens.idToken, let refresh = tokens.refreshToken else {
                throw AgentFailure(.invalidResponse, L10n.text("Sign-in didn't finish. Try again."), code: "missing_tokens")
            }
            let keys = try await loadKeys(discovery.jwks)
            let claims = try Self.verifyIDToken(idToken, issuer: discovery.issuer, clientID: client, nonce: nonce, now: now(), keys: keys)
            if saved == nil { defaults.set(client, forKey: Self.clientIDKey) }
            let scopes = (tokens.scope ?? answer["scope"] ?? "").split(separator: " ").map(String.init)
            let record = Credentials(email: claims["email"]?.string ?? "", subject: claims["sub"]?.string ?? "", clientID: client,
                                     idToken: idToken, accessToken: tokens.accessToken, refreshToken: refresh,
                                     expiresAt: now().addingTimeInterval(tokens.expiresIn ?? 3600), earliestRefreshAt: tokens.earliestRefreshAt,
                                     scopes: scopes, savedAt: now())
            save(record)
            Diagnostics.shared.record(.info, "assistant", "signin ok direct=\(scopes.contains(Self.directScope)) \(AgentHTTP.elapsed(started))")
        } catch {
            let failure = AgentFailures.failure(error)
            Diagnostics.shared.record(failure.kind == .cancelled ? .info : .warning, "assistant",
                                      "signin failed kind=\(failure.kind.rawValue) status=\(failure.status.map(String.init) ?? "-") code=\(failure.code ?? "-")")
            if failure.kind == .cancelled, failure.code == nil { throw AgentFailure(.cancelled, L10n.text("Sign-in was cancelled.")) }
            throw failure
        }
    }

    /// Stops a sign-in waiting for the browser (the viewer closed the sheet).
    public func cancelSignIn() {
        listener?.cancel()
        listener = nil
    }

    // MARK: Tokens

    /// A current access token for `POST /v1/responses`, refreshed first when it ends within a minute. Refreshes run
    /// one at a time (the refresh token changes with each). Throws `AgentFailure`: `.notSignedIn` when signed out or
    /// when the sign-in has ended, `.unavailable` without plan usage.
    public func accessToken() async throws -> String {
        guard let credentials else { throw AgentFailure(.notSignedIn, L10n.text("Add an API key or sign in with ChatGPT in Settings › Assistant.")) }
        guard credentials.scopes.contains(Self.directScope) else {
            throw AgentFailure(.unavailable, L10n.text("ChatGPT plan usage wasn't allowed for Yingxia. Sign in again and allow it, or use an API key."), code: "scope_missing")
        }
        let date = now()
        if credentials.expiresAt.timeIntervalSince(date) > 60 { return credentials.accessToken }
        if let earliest = credentials.earliestRefreshAt, date < earliest, credentials.expiresAt > date { return credentials.accessToken }
        return try await refresh().accessToken
    }

    private func refresh() async throws -> Credentials {
        if let refreshing { return try await refreshing.value }
        let task = Task { try await self.performRefresh() }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private func performRefresh() async throws -> Credentials {
        guard let old = credentials else { throw AgentFailure(.notSignedIn, L10n.text("Add an API key or sign in with ChatGPT in Settings › Assistant.")) }
        let started = Date()
        do {
            let discovery = try await loadDiscovery()
            let tokens = try await tokenRequest(discovery.token, ["grant_type": "refresh_token", "client_id": old.clientID,
                                                                  "refresh_token": old.refreshToken, "resource": endpoints.resource])
            var record = old
            record.accessToken = tokens.accessToken
            record.refreshToken = tokens.refreshToken ?? old.refreshToken
            record.idToken = tokens.idToken ?? old.idToken
            record.expiresAt = now().addingTimeInterval(tokens.expiresIn ?? 3600)
            record.earliestRefreshAt = tokens.earliestRefreshAt
            if let scope = tokens.scope { record.scopes = scope.split(separator: " ").map(String.init) }
            record.savedAt = now()
            // The viewer may have signed out meanwhile.
            guard credentials != nil else { throw AgentFailure(.notSignedIn, L10n.text("Add an API key or sign in with ChatGPT in Settings › Assistant.")) }
            save(record)
            Diagnostics.shared.record(.info, "assistant", "refresh ok \(AgentHTTP.elapsed(started))")
            return record
        } catch let failure as AgentFailure {
            Diagnostics.shared.record(.warning, "assistant", "refresh failed status=\(failure.status.map(String.init) ?? "-") code=\(failure.code ?? "-")")
            if let code = failure.code, Self.endedCodes.contains(code) {
                clearTokens()
                throw AgentFailure(.notSignedIn, L10n.text("Your ChatGPT sign-in has ended. Sign in again in Settings › Assistant."), code: code, status: failure.status)
            }
            throw failure
        }
    }

    /// Refresh errors after which the refresh token is no use: sign in again.
    nonisolated static let endedCodes: Set<String> = ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
                                          "refresh_token_invalidated", "refresh_token_reused"]

    // MARK: Sign out

    /// Revokes the refresh token at the discovery document's `revocation_endpoint` and forgets the tokens (the
    /// client id and host id stay). False when the revocation couldn't be confirmed (the tokens are forgotten anyway).
    @discardableResult public func signOut() async -> Bool {
        cancelSignIn()
        guard let old = credentials else { return true }
        var confirmed = false
        if let discovery = try? await loadDiscovery() {
            for attempt in 0..<3 {
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(500 * attempt)) }
                var request = URLRequest(url: discovery.revocation)
                request.httpMethod = "POST"
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = Data(Self.form(["token": old.refreshToken, "token_type_hint": "refresh_token", "client_id": old.clientID]).utf8)
                let status = (try? await session.data(for: request)).flatMap { ($0.1 as? HTTPURLResponse)?.statusCode }
                Diagnostics.shared.record(.info, "assistant", "signout revoke status=\(status.map(String.init) ?? "network")")
                if status == 200 { confirmed = true; break }
                // Only a lost connection or a server problem is worth another try.
                if let status, status < 500, status != 429 { break }
            }
        }
        clearTokens()
        return confirmed
    }

    // MARK: Storage

    struct Credentials: Codable, Equatable, Sendable {
        var email: String
        var subject: String
        var clientID: String
        var idToken: String
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        var earliestRefreshAt: Date?
        var scopes: [String]
        var savedAt: Date
    }

    private func save(_ record: Credentials) {
        credentials = record
        secrets.set(try? JSONEncoder().encode(record), Self.credentialsAccount)
        updateStatus()
    }

    private func clearTokens() {
        credentials = nil
        secrets.set(nil, Self.credentialsAccount)
        updateStatus()
    }

    private func updateStatus() {
        guard let credentials else { status = .signedOut; return }
        status = credentials.scopes.contains(Self.directScope) ? .signedIn(email: credentials.email) : .planUsageUnavailable(email: credentials.email)
    }

    // MARK: OpenID

    struct Discovery: Sendable {
        var issuer: String
        var authorization: URL
        var token: URL
        var revocation: URL
        var jwks: URL
    }

    /// The discovery document, or the addresses OpenAI documents when it can't be read.
    private func loadDiscovery() async throws -> Discovery {
        if let discovery { return discovery }
        let issuer = endpoints.issuer
        var found = Discovery(issuer: issuer.absoluteString, authorization: issuer.appending(path: "api/accounts/authorize"),
                              token: issuer.appending(path: "api/accounts/oauth/token"), revocation: issuer.appending(path: "api/accounts/oauth/revoke"),
                              jwks: issuer.appending(path: ".well-known/jwks.json"))
        do {
            let (data, response) = try await session.data(from: issuer.appending(path: ".well-known/openid-configuration"))
            guard (response as? HTTPURLResponse)?.statusCode == 200, let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                throw AgentFailure(.invalidResponse, AgentFailures.unreadable)
            }
            func url(_ key: String) -> URL? { json[key]?.string.flatMap(URL.init(string:)) }
            found.issuer = json["issuer"]?.string ?? found.issuer
            found.authorization = url("authorization_endpoint") ?? found.authorization
            found.token = url("token_endpoint") ?? found.token
            found.revocation = url("revocation_endpoint") ?? found.revocation
            found.jwks = url("jwks_uri") ?? found.jwks
            discovery = found
        } catch {
            Diagnostics.shared.record(.warning, "assistant", "discovery failed \(AgentFailures.failure(error).code ?? "-")")
            if AgentFailures.failure(error).kind == .cancelled { throw error }
        }
        return found
    }

    private func loadKeys(_ url: URL) async throws -> [JSONValue] {
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let keys = (try? JSONDecoder().decode(JSONValue.self, from: data))?["keys"]?.array else {
            throw AgentFailure(.invalidResponse, L10n.text("The sign-in couldn't be verified. Try again."), code: "jwks")
        }
        return keys
    }

    struct TokenResponse: Sendable {
        var accessToken: String
        var refreshToken: String?
        var idToken: String?
        var expiresIn: Double?
        var scope: String?
        var earliestRefreshAt: Date?
    }

    /// A form POST to the token endpoint. A refusal throws `AgentFailure` with the OAuth `error` as its code.
    private func tokenRequest(_ url: URL, _ fields: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(Self.form(fields).utf8)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        guard status == 200, let json, let access = json["access_token"]?.string else {
            let code = json?["error"]?.string ?? json?[path: "error", "code"]?.string
            let failure = AgentFailures.failure(status: status, body: data)
            if status == 400 || status == 401 {
                throw AgentFailure(.unauthorized, L10n.text("Sign-in didn't finish. Try again."), code: code ?? failure.code, status: status)
            }
            throw AgentFailure(failure.kind, failure.message, code: code ?? failure.code, status: status)
        }
        var earliest: Date?
        if let seconds = json["earliest_refresh_at"]?.double { earliest = Date(timeIntervalSince1970: seconds) }
        else if let text = json["earliest_refresh_at"]?.string { earliest = ISO8601DateFormatter().date(from: text) }
        return TokenResponse(accessToken: access, refreshToken: json["refresh_token"]?.string, idToken: json["id_token"]?.string,
                             expiresIn: json["expires_in"]?.double, scope: json["scope"]?.string, earliestRefreshAt: earliest)
    }

    // MARK: Pieces (static, tested on their own)

    /// The browser's address: first sign-in registers (`dynamic_agent_client` and `agent_name_hint`); later ones
    /// use the issued client id, and `id_token_hint` skips the account picker.
    nonisolated static func authorizationURL(endpoint: URL, clientID: String?, hostID: String, redirectURI: String, challenge: String,
                                             state: String, nonce: String, resource: String, idTokenHint: String?) -> URL {
        var fields: [(String, String)] = [
            ("response_type", "code"), ("client_id", clientID ?? "dynamic_agent_client"), ("redirect_uri", redirectURI),
            ("scope", scopes), ("code_challenge", challenge), ("code_challenge_method", "S256"), ("state", state),
            ("nonce", nonce), ("resource", resource), ("ext_agent_host_id", hostID),
        ]
        if clientID == nil { fields.append(("agent_name_hint", "Yingxia")) }
        if let idTokenHint, clientID != nil { fields.append(("id_token_hint", idTokenHint)) }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = fields.map { escape($0.0) + "=" + escape($0.1) }.joined(separator: "&")
        return components.url!
    }

    nonisolated static func form(_ fields: [String: String]) -> String {
        fields.sorted { $0.key < $1.key }.map { escape($0.key) + "=" + escape($0.value) }.joined(separator: "&")
    }

    nonisolated private static func escape(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? text
    }

    /// 32 random bytes, base64url: a PKCE verifier (43 characters), a state or a nonce.
    nonisolated static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) }))
    }

    /// PKCE S256: base64url(SHA-256(verifier)).
    nonisolated static func challenge(_ verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Checks the ID token: its RS256 signature against `keys` (a JWKS's `keys`), `iss`, `aud` (the client id),
    /// `exp` and our `nonce`. Returns its claims.
    nonisolated static func verifyIDToken(_ token: String, issuer: String, clientID: String, nonce: String?, now: Date, keys: [JSONValue]) throws -> [String: JSONValue] {
        func refuse(_ reason: String) -> AgentFailure {
            AgentFailure(.invalidResponse, L10n.text("The sign-in couldn't be verified. Try again."), code: "id_token_" + reason)
        }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let headerData = Data(base64URL: parts[0]), let payloadData = Data(base64URL: parts[1]),
              let signature = Data(base64URL: parts[2]),
              case .object(let header)? = try? JSONDecoder().decode(JSONValue.self, from: headerData),
              case .object(let claims)? = try? JSONDecoder().decode(JSONValue.self, from: payloadData) else { throw refuse("format") }
        guard header["alg"]?.string == "RS256" else { throw refuse("alg") }
        let kid = header["kid"]?.string
        let candidates = keys.filter { $0["kty"]?.string == "RSA" && (kid == nil || $0["kid"]?.string == kid) }
        let signed = Data((parts[0] + "." + parts[1]).utf8)
        let valid = candidates.contains { jwk in
            guard let n = jwk["n"]?.string.flatMap({ Data(base64URL: $0) }), let e = jwk["e"]?.string.flatMap({ Data(base64URL: $0) }),
                  let key = rsaPublicKey(modulus: n, exponent: e) else { return false }
            return SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, signed as CFData, signature as CFData, nil)
        }
        guard valid else { throw refuse("signature") }
        func trimmed(_ text: String) -> String { text.hasSuffix("/") ? String(text.dropLast()) : text }
        guard let iss = claims["iss"]?.string, trimmed(iss) == trimmed(issuer) else { throw refuse("iss") }
        let audiences = claims["aud"]?.array?.compactMap(\.string) ?? claims["aud"]?.string.map { [$0] } ?? []
        guard audiences.contains(clientID) else { throw refuse("aud") }
        guard let exp = claims["exp"]?.double, Date(timeIntervalSince1970: exp) > now.addingTimeInterval(-60) else { throw refuse("exp") }
        if let nonce, claims["nonce"]?.string != nonce { throw refuse("nonce") }
        return claims
    }

    /// An RSA public key from a JWK's modulus and exponent (DER: SEQUENCE { INTEGER n, INTEGER e }).
    nonisolated static func rsaPublicKey(modulus: Data, exponent: Data) -> SecKey? {
        func length(_ count: Int) -> [UInt8] {
            if count < 128 { return [UInt8(count)] }
            var bytes: [UInt8] = []
            var value = count
            while value > 0 { bytes.insert(UInt8(value & 0xff), at: 0); value >>= 8 }
            return [0x80 | UInt8(bytes.count)] + bytes
        }
        func integer(_ data: Data) -> [UInt8] {
            var bytes = Array(data)
            while bytes.count > 1, bytes.first == 0 { bytes.removeFirst() }
            if let first = bytes.first, first >= 0x80 { bytes.insert(0, at: 0) }
            return [0x02] + length(bytes.count) + bytes
        }
        let body = integer(modulus) + integer(exponent)
        let der = Data([0x30] + length(body.count) + body)
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        return SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil)
    }
}

/// The sign-in's redirect listener on 127.0.0.1: waits for `GET <path>?…&state=<state>`, answers with a short page
/// and hands back the query. Other requests get a 404 and the wait goes on.
final class LoopbackListener: @unchecked Sendable {
    let port: UInt16
    private let listener: NWListener
    private let path: String
    private let state: String
    private let lock = NSLock()
    private var waiting: CheckedContinuation<[String: String], Error>?
    private var result: Result<[String: String], Error>?

    private init(listener: NWListener, port: UInt16, path: String, state: String) {
        self.listener = listener; self.port = port; self.path = path; self.state = state
    }

    /// Listens on the first of `ports` that is free.
    static func start(ports: [UInt16], path: String, state: String) async throws -> LoopbackListener {
        var lastError: Error?
        for port in ports {
            do { return try await start(port: port, path: path, state: state) } catch { lastError = error }
        }
        Diagnostics.shared.record(.warning, "assistant", "signin listener failed \(String(describing: lastError).prefix(120))")
        throw AgentFailure(.unavailable, L10n.text("Sign-in can't hear back from the browser: port 1455 on this device is busy. Close other apps signing in to ChatGPT and try again."), code: "port_busy")
    }

    private static func start(port: UInt16, path: String, state: String) async throws -> LoopbackListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        let server = try NWListener(using: parameters)
        let listener = LoopbackListener(listener: server, port: port, path: path, state: state)
        server.newConnectionHandler = { [weak listener] connection in
            guard let listener else { connection.cancel(); return }
            connection.start(queue: .global(qos: .userInitiated))
            listener.receive(connection, buffer: Data())
        }
        let ready = OneShot<Void>()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ready.set(continuation)
            server.stateUpdateHandler = { state in
                switch state {
                case .ready: ready.resume(.success(()))
                case .failed(let error), .waiting(let error): ready.resume(.failure(error)); server.cancel()
                case .cancelled: ready.resume(.failure(CancellationError()))
                default: break
                }
            }
            server.start(queue: DispatchQueue(label: "yingxia.assistant.signin"))
        }
        return listener
    }

    /// The callback's query, once the browser is sent back.
    func callback() async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            let ready: Result<[String: String], Error>? = lock.withLock {
                if let result { return result }
                waiting = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }

    func cancel() { finish(.failure(CancellationError())) }

    func stop() { listener.cancel() }

    private func finish(_ outcome: Result<[String: String], Error>) {
        let continuation: CheckedContinuation<[String: String], Error>? = lock.withLock {
            guard result == nil else { return nil }
            result = outcome
            defer { waiting = nil }
            return waiting
        }
        continuation?.resume(with: outcome)
        if case .failure = outcome { listener.cancel() }
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var bytes = buffer
            if let data { bytes.append(data) }
            if bytes.range(of: Data("\r\n\r\n".utf8)) != nil { self.answer(connection, request: bytes) }
            else if error != nil || complete || bytes.count > 16384 { connection.cancel() }
            else { self.receive(connection, buffer: bytes) }
        }
    }

    private func answer(_ connection: NWConnection, request: Data) {
        let line = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        let fields = line.split(separator: " ")
        guard fields.count >= 2, fields[0] == "GET", let components = URLComponents(string: "http://127.0.0.1" + fields[1]),
              components.path == path else {
            send(connection, status: "404 Not Found", text: "Not found")
            return
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        guard query["state"] == state else {
            // Not our sign-in (an old tab, or another page): keep waiting for ours.
            send(connection, status: "400 Bad Request", text: L10n.text("This sign-in link is out of date. Go back to Yingxia and try again."))
            return
        }
        let done = query["error"] == nil
        send(connection, status: "200 OK", text: done ? L10n.text("Signed in. You can return to Yingxia.") : L10n.text("Sign-in didn't finish. You can return to Yingxia."))
        finish(.success(query))
    }

    private func send(_ connection: NWConnection, status: String, text: String) {
        let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        let page = """
            <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Yingxia</title>\
            <style>body{font:17px -apple-system,system-ui,sans-serif;display:flex;min-height:90vh;align-items:center;justify-content:center;\
            text-align:center;padding:24px;color:#222;background:#fff}@media(prefers-color-scheme:dark){body{color:#eee;background:#111}}</style>\
            </head><body><p>\(escaped)</p></body></html>
            """
        let body = Data(page.utf8)
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
#endif

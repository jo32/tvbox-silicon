#if !os(tvOS)
import Foundation
import Security
import Testing
@testable import TVCore

/// An RSA key that signs ID tokens the way the auth server would, with its JWK.
private struct TestKey: @unchecked Sendable {
    let privateKey: SecKey
    let jwk: JSONValue

    init() {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, nil)!
        let der = SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(privateKey)!, nil)! as Data
        // PKCS#1 RSAPublicKey: SEQUENCE { INTEGER n, INTEGER e }.
        var bytes = Array(der)[...]
        func read() -> [UInt8] {
            bytes.removeFirst()
            var length = Int(bytes.removeFirst())
            if length >= 0x80 {
                let count = length & 0x7f
                length = bytes.prefix(count).reduce(0) { $0 << 8 | Int($1) }
                bytes.removeFirst(count)
            }
            defer { bytes.removeFirst(length) }
            return Array(bytes.prefix(length))
        }
        bytes = read()[...]
        let n = read(), e = read()
        jwk = ["kty": "RSA", "kid": "k1", "alg": "RS256", "use": "sig",
               "n": .string(ChatGPTSignIn.base64URL(Data(n.drop { $0 == 0 }))), "e": .string(ChatGPTSignIn.base64URL(Data(e)))]
    }

    func sign(_ claims: JSONValue) -> String {
        let input = ChatGPTSignIn.base64URL(Data(#"{"alg":"RS256","kid":"k1","typ":"JWT"}"#.utf8)) + "." + ChatGPTSignIn.base64URL(Data(claims.jsonText.utf8))
        let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data(input.utf8) as CFData, nil)! as Data
        return input + "." + ChatGPTSignIn.base64URL(signature)
    }
}

private let key = TestKey()

/// What the fake auth server saw and will answer.
private struct FakeAuth: Sendable {
    var challenge = ""
    var nonce = ""
    var refreshes = 0
    var refreshToken = "refresh-1"
    var revoked: [String: String] = [:]
    var refreshError: String?
    var exchange: [String: String] = [:]
}

private func formFields(_ data: Data) -> [String: String] {
    var fields: [String: String] = [:]
    for pair in String(decoding: data, as: UTF8.self).split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
        if parts.count == 2 { fields[parts[0]] = parts[1] }
    }
    return fields
}

/// Registers an auth server on `host` that issues `oaiapp_test`, signs ID tokens with `key`, and rotates refresh tokens.
private func fakeAuthServer(_ host: String, _ auth: AgentLocked<FakeAuth>, grant: String = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct") {
    let issuer = "https://\(host)"
    AgentStubProtocol.register(host) { request, body in
        switch request.url?.path ?? "" {
        case "/.well-known/openid-configuration":
            return .init(text: (["issuer": .string(issuer), "authorization_endpoint": .string(issuer + "/api/accounts/authorize"),
                                 "token_endpoint": .string(issuer + "/api/accounts/oauth/token"),
                                 "revocation_endpoint": .string(issuer + "/api/accounts/oauth/revoke"),
                                 "jwks_uri": .string(issuer + "/.well-known/jwks.json")] as JSONValue).jsonText)
        case "/.well-known/jwks.json":
            return .init(text: (["keys": [key.jwk]] as JSONValue).jsonText)
        case "/api/accounts/oauth/token":
            let fields = formFields(body)
            return auth.update { state -> AgentStubProtocol.Answer in
                if fields["grant_type"] == "authorization_code" {
                    state.exchange = fields
                    guard fields["code"] == "code-1", fields["client_id"] == "oaiapp_test",
                          ChatGPTSignIn.challenge(fields["code_verifier"] ?? "") == state.challenge else {
                        return .init(status: 400, text: #"{"error":"invalid_grant"}"#)
                    }
                    let idToken = key.sign(["iss": .string(issuer), "aud": "oaiapp_test", "sub": "user-1", "email": "viewer@example.com",
                                            "nonce": .string(state.nonce), "exp": .number(Date().timeIntervalSince1970 + 3600),
                                            "iat": .number(Date().timeIntervalSince1970)])
                    return .init(text: (["access_token": "access-1", "refresh_token": "refresh-1", "id_token": .string(idToken),
                                         "token_type": "Bearer", "expires_in": 3600, "scope": .string(grant)] as JSONValue).jsonText)
                }
                if let error = state.refreshError { return .init(status: 400, text: #"{"error":"\#(error)"}"#) }
                guard fields["client_id"] == "oaiapp_test", fields["refresh_token"] == state.refreshToken, fields["scope"] == nil else {
                    return .init(status: 400, text: #"{"error":"refresh_token_reused"}"#)
                }
                state.refreshes += 1
                state.refreshToken = "refresh-\(state.refreshes + 1)"
                return .init(text: (["access_token": .string("access-\(state.refreshes + 1)"), "refresh_token": .string(state.refreshToken),
                                     "expires_in": 3600, "scope": .string(grant)] as JSONValue).jsonText)
            }
        case "/api/accounts/oauth/revoke":
            auth.update { $0.revoked = formFields(body) }
            return .init(text: "")
        default:
            return .init(status: 404, text: "")
        }
    }
}

/// Plays the browser: checks the authorize address, then follows the redirect to the app's listener.
private func browser(_ auth: AgentLocked<FakeAuth>, query: @escaping @Sendable (URLComponents) -> [URLQueryItem]) -> @MainActor (URL) -> Void {
    { url in
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let fields = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { _, last in last }
        auth.update { $0.challenge = fields["code_challenge"] ?? ""; $0.nonce = fields["nonce"] ?? "" }
        Task.detached {
            let plain = URLSession(configuration: .ephemeral)
            var redirect = URLComponents(string: fields["redirect_uri"] ?? "")!
            // Someone else's answer first: ignored, and the sign-in keeps waiting.
            redirect.queryItems = [URLQueryItem(name: "code", value: "stolen"), URLQueryItem(name: "state", value: "wrong")]
            _ = try? await plain.data(from: redirect.url!)
            redirect.queryItems = query(components)
            _ = try? await plain.data(from: redirect.url!)
        }
    }
}

private func callbackQuery(_ components: URLComponents) -> [URLQueryItem] {
    let state = components.queryItems?.first { $0.name == "state" }?.value
    return [URLQueryItem(name: "code", value: "code-1"), URLQueryItem(name: "state", value: state), URLQueryItem(name: "client_id", value: "oaiapp_test")]
}

@MainActor @Suite struct ChatGPTSignInTests {
    private func make(_ host: String, ports: [UInt16], clock: AgentLocked<Date> = AgentLocked(Date())) -> ChatGPTSignIn {
        let defaults = UserDefaults(suiteName: "agent-signin-tests-\(UUID().uuidString)")!
        return ChatGPTSignIn(endpoints: .init(issuer: URL(string: "https://\(host)")!, resource: "https://api.openai.com/v1", callbackPorts: ports),
                             secrets: MemoryAgentSecrets(), defaults: defaults, session: AgentStubProtocol.session(), now: { clock.get() })
    }

    @Test func pkceMatchesTheRFCExample() {
        // base64url(SHA-256), as Python's hashlib and base64.urlsafe_b64encode give it.
        #expect(ChatGPTSignIn.challenge("dBjftJeZ4CVP-mB92K1uhbHkxGN6OJp-RZ9BJ8yeLnc") == "EEGKcogT8V9Ln5NBi6FkkMQ6zj3lyTv-vbHv0aJhSW0")
        let token = ChatGPTSignIn.randomToken()
        #expect(token.count == 43 && !token.contains("=") && !token.contains("+") && !token.contains("/"))
        #expect(token != ChatGPTSignIn.randomToken())
    }

    @Test func authorizationAddresses() {
        let endpoint = URL(string: "https://auth.openai.com/api/accounts/authorize")!
        func fields(_ url: URL) -> [String: String] {
            Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { _, last in last }
        }
        let first = fields(ChatGPTSignIn.authorizationURL(endpoint: endpoint, clientID: nil, hostID: "urn:uuid:abc", redirectURI: "http://127.0.0.1:1455/auth/callback",
                                                          challenge: "ch", state: "st", nonce: "no", resource: "https://api.openai.com/v1", idTokenHint: "old"))
        #expect(first["client_id"] == "dynamic_agent_client" && first["agent_name_hint"] == "Yingxia" && first["id_token_hint"] == nil)
        #expect(first["response_type"] == "code" && first["code_challenge_method"] == "S256" && first["code_challenge"] == "ch")
        #expect(first["scope"] == "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct")
        #expect(first["redirect_uri"] == "http://127.0.0.1:1455/auth/callback" && first["resource"] == "https://api.openai.com/v1")
        #expect(first["ext_agent_host_id"] == "urn:uuid:abc" && first["state"] == "st" && first["nonce"] == "no")
        let later = fields(ChatGPTSignIn.authorizationURL(endpoint: endpoint, clientID: "oaiapp_1", hostID: "urn:uuid:abc", redirectURI: "r",
                                                          challenge: "ch", state: "st", nonce: "no", resource: "res", idTokenHint: "old"))
        #expect(later["client_id"] == "oaiapp_1" && later["agent_name_hint"] == nil && later["id_token_hint"] == "old")
        let address = ChatGPTSignIn.authorizationURL(endpoint: endpoint, clientID: nil, hostID: "h", redirectURI: "r", challenge: "c", state: "s", nonce: "n", resource: "x", idTokenHint: nil)
        #expect(address.absoluteString.contains("scope=openid%20profile"))
    }

    @Test func idTokenChecks() throws {
        let now = Date()
        let claims: [String: JSONValue] = ["iss": "https://auth.openai.com", "aud": ["oaiapp_1"], "exp": .number(now.timeIntervalSince1970 + 600), "nonce": "n1", "sub": "u"]
        let good = key.sign(.object(claims))
        let verified = try ChatGPTSignIn.verifyIDToken(good, issuer: "https://auth.openai.com", clientID: "oaiapp_1", nonce: "n1", now: now, keys: [key.jwk])
        #expect(verified["sub"] == "u")
        func refused(_ token: String, issuer: String = "https://auth.openai.com", client: String = "oaiapp_1", nonce: String = "n1", keys: [JSONValue] = [key.jwk]) -> String? {
            do { _ = try ChatGPTSignIn.verifyIDToken(token, issuer: issuer, clientID: client, nonce: nonce, now: now, keys: keys); return nil }
            catch { return (error as? AgentFailure)?.code }
        }
        #expect(refused(good, nonce: "other") == "id_token_nonce")
        #expect(refused(good, client: "oaiapp_2") == "id_token_aud")
        #expect(refused(good, issuer: "https://evil.example") == "id_token_iss")
        #expect(refused(good, keys: [TestKey().jwk]) == "id_token_signature")
        var expired = claims; expired["exp"] = .number(now.timeIntervalSince1970 - 3600)
        #expect(refused(key.sign(.object(expired))) == "id_token_exp")
        // A changed payload no longer matches its signature.
        let parts = good.split(separator: ".").map(String.init)
        var forged = claims; forged["sub"] = "someone-else"
        #expect(refused(parts[0] + "." + ChatGPTSignIn.base64URL(Data(JSONValue.object(forged).jsonText.utf8)) + "." + parts[2]) == "id_token_signature")
    }

    @Test func signInRefreshAndSignOut() async throws {
        let host = "auth-flow.agent.test"
        let auth = AgentLocked(FakeAuth())
        fakeAuthServer(host, auth)
        let clock = AgentLocked(Date())
        let signIn = make(host, ports: [18455, 18456, 18457], clock: clock)
        #expect(signIn.status == .signedOut)
        let hostID = signIn.hostID
        #expect(hostID.hasPrefix("urn:uuid:") && signIn.hostID == hostID)
        try await signIn.signIn(open: browser(auth, query: callbackQuery))
        #expect(signIn.status == .signedIn(email: "viewer@example.com"))
        #expect(signIn.clientID == "oaiapp_test")
        #expect(!signIn.isSigningIn)
        let exchange = auth.get().exchange
        #expect(exchange["redirect_uri"]?.hasPrefix("http://127.0.0.1:1845") == true && exchange["resource"] == "https://api.openai.com/v1")
        #expect(try await signIn.accessToken() == "access-1")

        // Near expiry, two callers share one refresh (the refresh token rotates).
        clock.set(Date().addingTimeInterval(3590))
        async let first = signIn.accessToken()
        async let second = signIn.accessToken()
        let tokens = try await [first, second]
        #expect(tokens == ["access-2", "access-2"])
        #expect(auth.get().refreshes == 1)

        #expect(await signIn.signOut())
        #expect(signIn.status == .signedOut)
        #expect(auth.get().revoked == ["token": "refresh-2", "token_type_hint": "refresh_token", "client_id": "oaiapp_test"])
        #expect(signIn.clientID == "oaiapp_test")
        await #expect(throws: AgentFailure.self) { try await signIn.accessToken() }
    }

    @Test func endedRefreshSignsOut() async throws {
        let host = "auth-ended.agent.test"
        let auth = AgentLocked(FakeAuth())
        fakeAuthServer(host, auth)
        let clock = AgentLocked(Date())
        let signIn = make(host, ports: [18465, 18466], clock: clock)
        try await signIn.signIn(open: browser(auth, query: callbackQuery))
        auth.update { $0.refreshError = "refresh_token_expired" }
        clock.set(Date().addingTimeInterval(4000))
        do {
            _ = try await signIn.accessToken()
            Issue.record("refresh passed")
        } catch let failure as AgentFailure {
            #expect(failure.kind == .notSignedIn && failure.code == "refresh_token_expired")
        }
        #expect(signIn.status == .signedOut)
    }

    @Test func withoutPlanUsageAndDenied() async throws {
        let host = "auth-scope.agent.test"
        let auth = AgentLocked(FakeAuth())
        fakeAuthServer(host, auth, grant: "openid profile email offline_access")
        let signIn = make(host, ports: [18475, 18476])
        try await signIn.signIn(open: browser(auth, query: callbackQuery))
        #expect(signIn.status == .planUsageUnavailable(email: "viewer@example.com"))
        do { _ = try await signIn.accessToken(); Issue.record("no scope passed") }
        catch let failure as AgentFailure { #expect(failure.kind == .unavailable) }

        let denied = make(host, ports: [18485, 18486])
        do {
            try await denied.signIn(open: browser(auth) { components in
                [URLQueryItem(name: "error", value: "access_denied"), components.queryItems!.first { $0.name == "state" }!]
            })
            Issue.record("denied passed")
        } catch let failure as AgentFailure { #expect(failure.kind == .cancelled) }
        #expect(denied.status == .signedOut && denied.clientID == nil)
    }

    @Test func cancelStopsTheWait() async throws {
        let host = "auth-cancel.agent.test"
        let auth = AgentLocked(FakeAuth())
        fakeAuthServer(host, auth)
        let signIn = make(host, ports: [18495, 18496])
        let task = Task { try await signIn.signIn { _ in } }
        for _ in 0..<200 where !signIn.isSigningIn { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(200))
        signIn.cancelSignIn()
        do { try await task.value; Issue.record("cancel passed") }
        catch let failure as AgentFailure { #expect(failure.kind == .cancelled) }
        #expect(!signIn.isSigningIn)
    }
}
#endif

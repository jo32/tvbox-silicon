import Foundation
import Testing
@testable import TVCore

/// Xunlei's sign-in servers: a code for 13800138000, the session for code 246810, and tokens for that session.
private final class XunleiProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var bodies: [String: [String: Any]] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
        }
        let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        Self.bodies[url.lastPathComponent] = body
        let answer: String
        switch url.lastPathComponent {
        case "sendsms":
            answer = body["mobile"] as? String == "13800138000" ? #"{"errorCode":0,"creditkey":"credit","token":"sms-token","deviceid":"div101.server"}"#
                : #"{"errorCode":10,"errorDesc":"手机号格式错误"}"#
        case "smslogin":
            answer = body["smsCode"] as? String == "246810" && body["creditkey"] as? String == "credit"
                ? #"{"errorCode":"0","sessionID":"signin-session"}"# : #"{"errorCode":"11","errorDesc":"验证码错误"}"#
        case "token":
            answer = body["signin_token"] as? String == "signin-session" && self.request.value(forHTTPHeaderField: "X-Client-Id") == "Xp6vsxz_7IYVw2BB"
                ? #"{"access_token":"access","refresh_token":"refresh","token_type":"Bearer","sub":"42","expires_in":7200}"#
                : #"{"error":"invalid_grant"}"#
        default: answer = "{}"
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct XunleiSignInTests {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [XunleiProtocol.self]
        return URLSession(configuration: config)
    }

    @Test func aTextedCodeBecomesTokensTheBundlesTake() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let challenge = try await XunleiSignIn.sendCode(to: "+86 138 0013 8000", session: session)
        #expect(XunleiProtocol.bodies["sendsms"]?["devicesign"] as? String == challenge.account.deviceSign)
        let account = try await XunleiSignIn.signIn(challenge, code: " 246810 ", session: session)
        #expect(XunleiProtocol.bodies["smslogin"]?["devicesign"] as? String == "div101.server")
        #expect(account.accessToken == "access" && account.refreshToken == "refresh" && account.userId == "42")
        #expect(account.mobile == "13800138000")
        #expect(abs((account.expireTime ?? 0) / 1000 - Date().timeIntervalSince1970 - 7200) < 60)
        // The keys the bundle reads from /pan/thunder/config.
        let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(account)) as? [String: Any]
        for key in ["deviceId", "deviceSign", "peerId", "accessToken", "refreshToken", "expireTime"] { #expect(saved?[key] != nil) }
        #expect(saved?["authVersion"] as? String == "downloadprovider-25.0.6.30")
        #expect(saved?["authPackage"] as? String == "com.xunlei.downloadprovider")
        #expect(saved?["authClientId"] as? String == "Xp6vsxz_7IYVw2BB")
    }

    @Test func xunleiRefusalsAreShownInItsOwnWords() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let challenge = try await XunleiSignIn.sendCode(to: "13800138000", session: session)
        do {
            _ = try await XunleiSignIn.signIn(challenge, code: "000000", session: session)
            Issue.record("A wrong code signed in")
        } catch { #expect(error.localizedDescription == "验证码错误") }
        #expect(XunleiSignIn.normalized("12345") == nil)
        #expect(XunleiSignIn.normalized("86 13800138000") == "13800138000")
    }

    /// A signature the bundle itself made, from the ID beside it.
    @Test func deviceSignaturesMatchTheAndroidApp() {
        #expect(XunleiSignIn.deviceSign("208770e1c13543a8bf2c47f58aa41ded") == "div101.208770e1c13543a8bf2c47f58aa41dedbdfee9855d580ee0b39682de0a24f970")
        let device = XunleiSignIn.newDevice()
        #expect(device.deviceId.count == 32 && device.peerId.count == 32 && device.deviceId != device.peerId)
    }

    @Test func accountsSavedBeforeXunleiStillLoad() throws {
        let accounts = try JSONDecoder().decode(CloudDriveAccounts.self, from: Data(#"{"quarkCookie":"q","ucCookie":"","ucToken":"","token":""}"#.utf8))
        #expect(accounts.quarkCookie == "q" && accounts.xunlei == nil)
    }
}

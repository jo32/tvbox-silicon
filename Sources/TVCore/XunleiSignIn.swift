import Foundation
import CryptoKit

/// A Xunlei (迅雷) sign-in, kept in the shape CatPawOpen bundles of the wexfnw family store theirs
/// (`/pan/thunder/config`), so it passes to them as it is. They refresh the tokens themselves.
public struct XunleiAccount: Codable, Equatable, Sendable {
    public var deviceId: String
    public var deviceSign: String
    public var peerId: String
    /// The Android app the tokens were issued to; the bundles ignore a sign-in made for another.
    public var authVersion = XunleiSignIn.authVersion
    public var authPackage = XunleiSignIn.packageName
    public var authClientId = XunleiSignIn.clientID
    public var mobile: String?
    public var accessToken: String?
    public var refreshToken: String?
    public var tokenType: String?
    public var userId: String?
    /// When the access token expires, in milliseconds since 1970, as the bundles keep it.
    public var expireTime: Double?
}

/// Xunlei's sign-in with a code texted to the phone, made as its Android app (the identity the wexfnw bundles use,
/// so the tokens work there).
public enum XunleiSignIn {
    static let clientID = "Xp6vsxz_7IYVw2BB"
    static let clientSecret = "Xp6vsy4tN9toTVdMSpomVdXpRmES"
    static let packageName = "com.xunlei.downloadprovider"
    static let clientVersion = "25.0.6.30"
    static let authVersion = "downloadprovider-25.0.6.30"
    static let appID = "40"
    static let sdkVersion = "513006"
    static let deviceSignKey = "34a062aaa22f906fca4fefe9fb3a3021"
    private static let loginAgent = "android-ok-http-client/xl-acc-sdk/version-5.1.3.\(sdkVersion)"
    private static let tokenAgent = "ANDROID-\(packageName)/\(clientVersion) netWorkType/WIFI appid/\(appID) deviceName/Android_Android "
        + "deviceModel/Android OSVersion/10 protocolVersion/301 platformVersion/10 sdkVersion/\(sdkVersion) Oauth2Client/0.9 (Linux 4_14_186-g844fd19c60e0) (JAVA 0)"

    /// A code on its way to the phone; `signIn` completes it.
    public struct Challenge: Sendable {
        public let account: XunleiAccount
        let creditKey: String
        let token: String
        let deviceSign: String?
    }

    /// A mainland China mobile number, without spaces or +86; nil for anything else.
    public static func normalized(_ mobile: String) -> String? {
        var digits = mobile.filter { !$0.isWhitespace && $0 != "-" }
        if digits.hasPrefix("+86") { digits.removeFirst(3) } else if digits.hasPrefix("86"), digits.count == 13 { digits.removeFirst(2) }
        return digits.count == 11 && digits.hasPrefix("1") && digits.allSatisfy(\.isASCII) && digits.allSatisfy(\.isNumber) ? digits : nil
    }

    /// Asks Xunlei to text a code to `mobile`, from a new device.
    public static func sendCode(to mobile: String, session: URLSession = .shared) async throws -> Challenge {
        guard let mobile = normalized(mobile) else { throw TVError.unsupported(L10n.text("Enter a mainland China mobile number.")) }
        var account = newDevice()
        account.mobile = mobile
        var body = login(account, sequence: "1000003")
        body["mobile"] = mobile; body["register"] = "0"
        let answer = try await post("https://xluser-ssl.xunlei.com/xluser.core.login/v3/sendsms", body, agent: loginAgent, session: session)
        try check(answer)
        return Challenge(account: account, creditKey: answer["creditkey"] as? String ?? "", token: answer["token"] as? String ?? "",
                         deviceSign: answer["deviceid"] as? String ?? answer["deviceId"] as? String)
    }

    /// Signs in with the texted code: the session it opens becomes the tokens the bundles use.
    public static func signIn(_ challenge: Challenge, code: String, session: URLSession = .shared) async throws -> XunleiAccount {
        var account = challenge.account
        var body = login(account, sequence: "1000004")
        body["mobile"] = account.mobile ?? ""; body["creditkey"] = challenge.creditKey; body["token"] = challenge.token
        body["smsCode"] = code.trimmingCharacters(in: .whitespacesAndNewlines); body["register"] = "0"
        if let sign = challenge.deviceSign, !sign.isEmpty { body["devicesign"] = sign }
        let answer = try await post("https://xluser-ssl.xunlei.com/xluser.core.login/v3/smslogin", body, agent: loginAgent, session: session)
        try check(answer)
        guard let signin = answer["sessionID"] as? String ?? answer["session_id"] as? String, !signin.isEmpty else {
            throw TVError.unsupported(L10n.text("Sign-in was approved, but the drive didn't return a login. Try again."))
        }
        let tokens = try await post("https://xluser-ssl.xunlei.com/v1/auth/signin/token",
                                    ["client_id": clientID, "client_secret": clientSecret, "provider": "access_end_point_token", "signin_token": signin],
                                    agent: tokenAgent, device: account.deviceId, session: session)
        guard let access = tokens["access_token"] as? String, !access.isEmpty, let refresh = tokens["refresh_token"] as? String, !refresh.isEmpty else {
            throw TVError.unsupported(tokens["error_description"] as? String ?? tokens["error"] as? String
                                      ?? L10n.text("Sign-in was approved, but the drive didn't return a login. Try again."))
        }
        account.accessToken = access; account.refreshToken = refresh
        account.tokenType = tokens["token_type"] as? String
        account.userId = tokens["user_id"] as? String ?? tokens["sub"] as? String
        let lifetime = (tokens["expires_in"] as? NSNumber)?.doubleValue ?? 7200
        account.expireTime = (Date().timeIntervalSince1970 + lifetime) * 1000
        return account
    }

    static func newDevice() -> XunleiAccount {
        let id = randomID()
        return XunleiAccount(deviceId: id, deviceSign: deviceSign(id), peerId: randomID())
    }

    /// The device's signature, as the Android app makes it from its ID.
    static func deviceSign(_ id: String) -> String {
        "div101.\(id)" + hex(Insecure.MD5.hash(data: Data(hex(Insecure.SHA1.hash(data: Data((id + packageName + appID + deviceSignKey).utf8))).utf8)))
    }

    private static func randomID() -> String { (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased().prefix(32).description }
    private static func hex<D: Digest>(_ digest: D) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    private static func login(_ account: XunleiAccount, sequence: String) -> [String: String] {
        ["protocolVersion": "301", "sequenceNo": sequence, "platformVersion": "10", "isCompressed": "0", "appid": appID,
         "clientVersion": clientVersion, "peerID": account.peerId, "appName": "ANDROID-\(packageName)", "sdkVersion": sdkVersion,
         "devicesign": account.deviceSign, "netWorkType": "WIFI", "providerName": "NONE", "deviceModel": "Android",
         "deviceName": "Android_Android", "OSVersion": "10", "hl": "zh-CN", "creditkey": ""]
    }

    /// Xunlei's own words when it refuses (a wrong code, too many texts), else the step that failed.
    private static func check(_ answer: [String: Any]) throws {
        let code = (answer["errorCode"] as? NSNumber)?.intValue ?? Int(answer["errorCode"] as? String ?? "") ?? 0
        guard code != 0 else { return }
        let message = answer["errorDesc"] as? String ?? answer["errorMessage"] as? String ?? answer["error"] as? String
        throw TVError.unsupported(message.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.text("Xunlei refused the sign-in (%@).", String(code)))
    }

    private static func post(_ address: String, _ body: [String: String], agent: String, device: String? = nil,
                             session: URLSession) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: address)!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json;charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        if let device {
            request.setValue(device, forHTTPHeaderField: "X-Device-Id")
            request.setValue(clientID, forHTTPHeaderField: "X-Client-Id")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw TVError.unsupported(L10n.text("The source %@ returned HTTP %lld.", request.url?.host ?? "", status))
        }
        return object
    }
}

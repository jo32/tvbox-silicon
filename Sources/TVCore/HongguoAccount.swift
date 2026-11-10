import Foundation

/// The signed-in Hongguo (红果短剧) account. Hongguo's playback endpoint turns many anonymous devices
/// away; the Hongguo source sends this account's sign-in with its requests (`SourceAccounts`).
/// Signing in is by scanning a code with the Hongguo phone app, as hongguoduanju.com does, so it
/// works the same on Apple TV.
public struct HongguoAccount: Codable, Equatable, Sendable {
    /// The hongguoduanju.com cookies of the signed-in web session.
    public var cookie = ""
    public var name = ""
    public init(cookie: String = "", name: String = "") { self.cookie = cookie; self.name = name }
    public var signedIn: Bool { cookie.contains("sessionid=") }

    static var fileURL: URL {
        #if os(tvOS)
        // tvOS only permits Caches; `load` restores a purged copy from user defaults.
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #endif
        return base.appendingPathComponent("com.tvbox.yingxia/Hongguo/account.json")
    }
    private static let defaultsKey = "hongguoAccount"

    public static func load() -> Self {
        if let data = try? Data(contentsOf: fileURL), let account = try? JSONDecoder().decode(Self.self, from: data) { return account }
        #if os(tvOS)
        if let data = UserDefaults.standard.data(forKey: defaultsKey), let account = try? JSONDecoder().decode(Self.self, from: data) {
            try? account.save()
            return account
        }
        #endif
        return Self()
    }
    public func save() throws {
        let folder = Self.fileURL.deletingLastPathComponent()
        let data = try JSONEncoder().encode(self)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: Self.fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.fileURL.path)
        #if os(tvOS)
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        #endif
    }
    public static func signOut() {
        try? FileManager.default.removeItem(at: fileURL)
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    /// Fills in the nickname; false when Hongguo no longer accepts the sign-in.
    public mutating func refresh() async -> Bool {
        guard signedIn else { return false }
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        guard let reply = try? await HongguoPassport.json("/passport/account/info/v2/", cookie: cookie, session: session) else { return true }
        let data = reply["data"]?.object ?? [:]
        if reply["message"]?.string == "success" {
            let nickname = data["name"]?.string ?? data["screen_name"]?.string ?? ""
            if !nickname.isEmpty { name = nickname }
            return true
        }
        // "会话过期" (session expired) means sign in again; anything else (a network hiccup, a new error) keeps it.
        return !(data["description"]?.string ?? "").contains("会话过期")
    }
}

/// hongguoduanju.com's passport, as its own pages call it.
enum HongguoPassport {
    static let base = URL(string: "https://hongguoduanju.com")!
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"
    private static let query = [("aid", "513755"), ("passport_jssdk_version", "3.4.10"), ("passport_jssdk_type", "normal"),
                                ("account_sdk_source", "web"), ("is_from_ttaccountsdk", "1"), ("language", "zh")]

    /// A passport call. `cookie` adds a saved sign-in; otherwise the session's own cookies go along.
    static func json(_ path: String, _ items: [(String, String)] = [], cookie: String? = nil, session: URLSession) async throws -> [String: JSONValue] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = base.host()
        components.path = path
        components.queryItems = (query + items).map { URLQueryItem(name: $0.0, value: $0.1) }
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://hongguoduanju.com/", forHTTPHeaderField: "Referer")
        request.setValue("https://hongguoduanju.com", forHTTPHeaderField: "Origin")
        request.setValue("application/json, text/javascript", forHTTPHeaderField: "Accept")
        if let cookie {
            request.httpShouldHandleCookies = false
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        let (body, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw TVError.unsupported(L10n.text("Hongguo didn't answer. Try again."))
        }
        return try JSONDecoder().decode([String: JSONValue].self, from: body)
    }
}

/// Sign in by scanning a code with the Hongguo phone app, as hongguoduanju.com does. One login keeps
/// its own cookie store: the code's csrf cookie must go along with each status check, and confirming
/// sets the session cookies.
public final class HongguoQRLogin: @unchecked Sendable {
    public enum Status: Sendable, Equatable { case waiting, scanned, expired, signedIn(HongguoAccount) }
    /// The text to encode in the QR code.
    public let code: String
    private let token: String
    private let session: URLSession
    private static let next = ("next", "https://hongguoduanju.com/")

    private init(code: String, token: String, session: URLSession) { self.code = code; self.token = token; self.session = session }
    deinit { session.invalidateAndCancel() }

    public static func start() async throws -> HongguoQRLogin {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = HTTPCookieStorage()
        configuration.httpCookieAcceptPolicy = .always
        let session = URLSession(configuration: configuration)
        let reply = try await HongguoPassport.json("/passport/web/get_qrcode/", [next], session: session)
        guard reply["message"]?.string == "success", let data = reply["data"]?.object,
              let code = data["qrcode_index_url"]?.string, !code.isEmpty, let token = data["token"]?.string, !token.isEmpty else {
            session.invalidateAndCancel()
            throw TVError.unsupported(L10n.text("Couldn't get a sign-in code. Try again."))
        }
        return HongguoQRLogin(code: code, token: token, session: session)
    }

    public func poll() async throws -> Status {
        let reply = try await HongguoPassport.json("/passport/web/check_qrconnect/", [Self.next, ("token", token)], session: session)
        let data = reply["data"]?.object ?? [:]
        guard reply["message"]?.string == "success" else {
            if let description = data["description"]?.string, !description.isEmpty { throw TVError.unsupported(description) }
            return .expired
        }
        switch data["status"]?.string ?? data["status"]?.int.map(String.init) {
        case "new", "1": return .waiting
        case "scanned", "2": return .scanned
        case "confirmed", "3": break
        default: return .expired
        }
        // Confirming answers with an address on the site whose visit sets the session cookies.
        if let address = data["redirect_url"]?.string, let url = URL(string: address, relativeTo: HongguoPassport.base)?.absoluteURL,
           url.scheme == "https", let host = url.host(), host == "hongguoduanju.com" || host.hasSuffix(".hongguoduanju.com") {
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue(HongguoPassport.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("https://hongguoduanju.com/", forHTTPHeaderField: "Referer")
            _ = try? await session.data(for: request)
        }
        let cookies = (session.configuration.httpCookieStorage?.cookies(for: HongguoPassport.base) ?? [])
            .filter { !$0.value.isEmpty && ($0.expiresDate.map { $0 > Date() } ?? true) }
        guard cookies.contains(where: { $0.name == "sessionid" }) else {
            throw TVError.unsupported(L10n.text("Sign-in was approved, but Hongguo didn't return a login. Try again."))
        }
        var fields: [String: String] = [:]
        for cookie in cookies { fields[cookie.name] = cookie.value }
        var account = HongguoAccount(cookie: fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; "))
        _ = await account.refresh()
        try account.save()
        return .signedIn(account)
    }
}

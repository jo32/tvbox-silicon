import Foundation

/// Quark and UC sign in by scanning a code with their phone app. The approved code yields a
/// service ticket, which the drive exchanges for the same cookie its web sign-in sets.
public struct CloudDriveQRLogin: Sendable {
    public enum Drive: Sendable { case quark, uc }
    public enum Status: Sendable, Equatable { case waiting, expired, signedIn(cookie: String) }

    public let drive: Drive
    /// The text to encode in the QR code.
    public let code: String
    private let token: String

    public static func start(_ drive: Drive) async throws -> CloudDriveQRLogin {
        let members = try await members(drive, "getTokenForQrcodeLogin", [:])
        guard let token = members?["token"] as? String, !token.isEmpty else { throw TVError.unsupported(L10n.text("Couldn't get a sign-in code. Try again.")) }
        return CloudDriveQRLogin(drive: drive, code: drive.page(token), token: token)
    }

    public func poll() async throws -> Status {
        let (status, members) = try await Self.call(drive, "getServiceTicketByQrcodeToken", ["token": token])
        switch status {
        case 2_000_000:
            guard let ticket = members?["service_ticket"] as? String else { return .expired }
            return .signedIn(cookie: try await Self.cookie(drive, ticket: ticket))
        case 50_004_001: return .waiting
        default: return .expired
        }
    }

    private static func members(_ drive: Drive, _ action: String, _ query: [String: String]) async throws -> [String: Any]? {
        let (status, members) = try await call(drive, action, query)
        guard status == 2_000_000 else { throw TVError.unsupported(L10n.text("Couldn't get a sign-in code. Try again.")) }
        return members
    }

    private static func call(_ drive: Drive, _ action: String, _ query: [String: String]) async throws -> (Int, [String: Any]?) {
        var components = URLComponents(string: drive.authHost + "/cas/ajax/" + action)!
        components.queryItems = (["client_id": drive.clientID, "v": "1.2", "request_id": UUID().uuidString.lowercased()].merging(query) { $1 })
            .sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let (data, _) = try await URLSession.shared.data(for: request(components.url!, drive))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let status = (object?["status"] as? NSNumber)?.intValue ?? 0
        return (status, (object?["data"] as? [String: Any])?["members"] as? [String: Any])
    }

    /// The account page sets the drive cookies for the ticket; keep only those the plugins send.
    private static func cookie(_ drive: Drive, ticket: String) async throws -> String {
        // An ephemeral session keeps its cookies in a private in-memory store, redirects included.
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        var components = URLComponents(string: drive.accountPage)!
        components.queryItems = [URLQueryItem(name: "st", value: ticket), URLQueryItem(name: "lw", value: "scan")]
        _ = try await session.data(for: request(components.url!, drive))
        var fields: [String: String] = [:]
        for cookie in session.configuration.httpCookieStorage?.cookies ?? [] {
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            if domain == drive.domain || domain.hasSuffix("." + drive.domain) { fields[cookie.name] = cookie.value }
        }
        guard fields["__pus"]?.isEmpty == false else { throw TVError.unsupported(L10n.text("Sign-in was approved, but the drive didn't return a login. Try again.")) }
        return fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    private static func request(_ url: URL, _ drive: Drive) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue(drive.referer, forHTTPHeaderField: "Referer")
        return request
    }
}

private extension CloudDriveQRLogin.Drive {
    var authHost: String { self == .quark ? "https://uop.quark.cn" : "https://api.open.uc.cn" }
    var clientID: String { self == .quark ? "532" : "381" }
    var domain: String { self == .quark ? "quark.cn" : "uc.cn" }
    var referer: String { self == .quark ? "https://pan.quark.cn/" : "https://drive.uc.cn/" }
    var accountPage: String { self == .quark ? "https://pan.quark.cn/account/info" : "https://drive.uc.cn/account/info" }
    func page(_ token: String) -> String {
        self == .quark
            ? "https://su.quark.cn/4_eMHBJ?token=\(token)&client_id=532&ssb=weblogin&uc_param_str=&uc_biz_str=S%3Acustom%7COPT%3ASAREA%400%7COPT%3AIMMERSIVE%401%7COPT%3ABACK_BTN_STYLE%400"
            : "https://su.uc.cn/1_n0ZCv?token=\(token)&client_id=381&uc_param_str=&uc_biz_str=S%3Acustom%7CC%3Atitlebar_fix"
    }
}

import Foundation

/// Sign in to a cloud drive by scanning a code with its phone app. Quark and UC: the approved
/// code yields a service ticket, which the drive exchanges for the same cookie its web sign-in
/// sets. Baidu Netdisk: the passport's QR login sets BDUSS, STOKEN and PTOKEN. Aliyun Drive:
/// the approved code carries the account's refresh token. 115: the approved code signs in a client, which
/// gets the UID, CID, SEID and KID cookies.
public struct CloudDriveQRLogin: Sendable {
    public enum Drive: String, Sendable { case quark, uc, baidu, aliyun, pan115 }
    public struct Credentials: Sendable, Equatable {
        public let cookie: String
        public let serviceTicket: String?
        /// Aliyun Drive's refresh token.
        public var refreshToken: String? = nil
    }
    public enum Status: Sendable, Equatable { case waiting, expired, signedIn(Credentials) }

    public let drive: Drive
    /// The text to encode in the QR code; empty when the drive serves the code as an image.
    public let code: String
    /// Baidu serves its code as an image.
    public let image: URL?
    private let token: String
    private let state: [String: String]
    /// Baidu's sign-in spans several requests that share cookies.
    private let session: URLSession?

    private init(drive: Drive, code: String, image: URL? = nil, token: String, state: [String: String] = [:], session: URLSession? = nil) {
        self.drive = drive; self.code = code; self.image = image; self.token = token; self.state = state; self.session = session
    }

    public static func start(_ drive: Drive) async throws -> CloudDriveQRLogin {
        switch drive {
        case .baidu: return try await startBaidu()
        case .aliyun: return try await startAliyun()
        case .pan115: return try await start115()
        case .quark, .uc: break
        }
        let members = try await members(drive, "getTokenForQrcodeLogin", [:])
        guard let token = members?["token"] as? String, !token.isEmpty else { throw TVError.unsupported(L10n.text("Couldn't get a sign-in code. Try again.")) }
        return CloudDriveQRLogin(drive: drive, code: drive.page(token), token: token)
    }

    public func poll() async throws -> Status {
        switch drive {
        case .baidu: return try await pollBaidu()
        case .aliyun: return try await pollAliyun()
        case .pan115: return try await poll115()
        case .quark, .uc: break
        }
        let (status, members) = try await Self.call(drive, "getServiceTicketByQrcodeToken", ["token": token])
        switch status {
        case 2_000_000:
            guard let ticket = members?["service_ticket"] as? String else { return .expired }
            let session = URLSession(configuration: .ephemeral)
            defer { session.finishTasksAndInvalidate() }
            return .signedIn(try await Self.complete(drive, ticket: ticket, session: session))
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
    static func complete(_ drive: Drive, ticket: String, session: URLSession) async throws -> Credentials {
        // Keep cookies and the mobile ticket from the same approved scan. FTY's player
        // requires both; passing only the web cookie makes it ask to scan again.
        var components = URLComponents(string: drive.accountPage)!
        components.queryItems = [URLQueryItem(name: "st", value: ticket), URLQueryItem(name: "lw", value: "scan")]
        let (_, response) = try await session.data(for: request(components.url!, drive))
        try check(response)
        let serviceTicket = drive == .quark ? try await quarkMobileTicket(ticket, session: session) : nil
        var fields: [String: String] = [:]
        for cookie in session.configuration.httpCookieStorage?.cookies ?? [] {
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            if domain == drive.domain || domain.hasSuffix("." + drive.domain) { fields[cookie.name] = cookie.value }
        }
        guard fields["__pus"]?.isEmpty == false else { throw TVError.unsupported(L10n.text("Sign-in was approved, but the drive didn't return a login. Try again.")) }
        return Credentials(cookie: fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; "), serviceTicket: serviceTicket)
    }

    /// Quark's mobile service ticket for an approved sign-in ticket, from a scanned code or the web page.
    /// The ticket is encoded by hand: a query builder leaves `+` and `/` raw, and Quark then reads `+` as a space.
    public static func quarkMobileTicket(_ ticket: String, session: URLSession = .shared, cookie: String? = nil) async throws -> String {
        let encoded = ticket.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(.init(charactersIn: "-._~"))) ?? ticket
        var missingCode = -1
        var missingKeys = "-"
        for client in ["h5", "pc"] {
            guard let url = URL(string: "https://pan.quark.cn/account/mobileinfo?pr=ucpro&fr=\(client)&st=\(encoded)") else { continue }
            var info = request(url, .quark)
            if let cookie { info.setValue(cookie, forHTTPHeaderField: "Cookie") }
            let (data, response) = try await session.data(for: info)
            try check(response)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if object?["success"] as? Bool == true, let serviceTicket = (object?["data"] as? [String: Any])?["serviceTicket"] as? String, !serviceTicket.isEmpty {
                return serviceTicket
            }
            missingCode = (object?["code"] as? NSNumber)?.intValue ?? (object?["status"] as? NSNumber)?.intValue ?? -1
            missingKeys = object?.keys.sorted().joined(separator: ",") ?? "-"
        }
        Diagnostics.shared.record(.warning, "cloud.signin", "quark mobile ticket missing length=\(ticket.count) code=\(missingCode) keys=\(missingKeys)")
        throw TVError.unsupported(L10n.text("Sign-in was approved, but the drive didn't return a login. Try again."))
    }

    // MARK: Baidu Netdisk

    private static func startBaidu() async throws -> CloudDriveQRLogin {
        let configuration = URLSessionConfiguration.ephemeral
        // The status request is held open until something happens, for up to about 30 seconds.
        configuration.timeoutIntervalForRequest = 45
        let session = URLSession(configuration: configuration)
        let gid = UUID().uuidString.uppercased(), time = milliseconds()
        var components = URLComponents(string: "https://passport.baidu.com/v2/api/getqrcode")!
        components.queryItems = [("lp", "pc"), ("qrloginfrom", "pc"), ("gid", gid), ("callback", "tangram_guid_\(time)"), ("apiver", "v3"),
                                 ("tt", "\(time)"), ("tpl", "netdisk"), ("logPage", "traceId:pc_loginv5_\(time),logPage:loginv5"), ("_", "\(time)")]
            .map { URLQueryItem(name: $0.0, value: $0.1) }
        let object = try await jsonp(session, components.url!)
        guard let address = object["imgurl"] as? String, let sign = object["sign"] as? String, !sign.isEmpty,
              let image = URL(string: address.hasPrefix("http") ? address : "https://" + address) else {
            throw TVError.unsupported(L10n.text("Couldn't get a sign-in code. Try again."))
        }
        return CloudDriveQRLogin(drive: .baidu, code: "", image: image, token: sign, state: ["gid": gid], session: session)
    }

    private func pollBaidu() async throws -> Status {
        guard let session, let gid = state["gid"] else { return .expired }
        let time = Self.milliseconds()
        var components = URLComponents(string: "https://passport.baidu.com/channel/unicast")!
        components.queryItems = [("channel_id", token), ("gid", gid), ("tpl", "netdisk"), ("_sdkFrom", "1"), ("callback", "tangram_guid_\(time)"),
                                 ("apiver", "v3"), ("tt", "\(time)"), ("_", "\(time)")].map { URLQueryItem(name: $0.0, value: $0.1) }
        let object = try await Self.jsonp(session, components.url!)
        // errno 1: nothing happened while the request was held open.
        let errno = (object["errno"] as? NSNumber)?.intValue ?? -1
        if errno == 1 { return .waiting }
        guard errno == 0, let channel = (object["channel_v"] as? String)?.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: channel) as? [String: Any] else { return .expired }
        switch (value["status"] as? NSNumber)?.intValue {
        case 1: return .waiting  // scanned, not yet confirmed
        case 0:
            guard let temporary = value["v"] as? String, !temporary.isEmpty else { return .expired }
            return .signedIn(try await completeBaidu(temporary, session: session))
        default: return .expired
        }
    }

    private func completeBaidu(_ temporary: String, session: URLSession) async throws -> Credentials {
        let time = Self.milliseconds()
        var components = URLComponents(string: "https://passport.baidu.com/v3/login/main/qrbdusslogin")!
        components.queryItems = [("v", "\(time)"), ("bduss", temporary), ("u", "https://pan.baidu.com/disk/home"), ("loginVersion", "v4"),
                                 ("qrcode", "1"), ("tpl", "netdisk"), ("apiver", "v3"), ("tt", "\(time)"), ("traceid", ""),
                                 ("time", "\(time / 1000)"), ("alg", "v3"), ("callback", "bd__cbs__\(Int.random(in: 100_000...999_999))")]
            .map { URLQueryItem(name: $0.0, value: $0.1) }
        let (_, response) = try await session.data(for: Self.baiduRequest(components.url!))
        try Self.check(response)
        var fields: [String: String] = [:]
        for cookie in session.configuration.httpCookieStorage?.cookies ?? [] where cookie.domain.hasSuffix("baidu.com") {
            if ["BDUSS", "STOKEN", "PTOKEN"].contains(cookie.name), !cookie.value.isEmpty { fields[cookie.name] = cookie.value }
        }
        guard fields["BDUSS"] != nil else { throw TVError.unsupported(L10n.text("Sign-in was approved, but the drive didn't return a login. Try again.")) }
        return Credentials(cookie: fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; "), serviceTicket: nil)
    }

    private static func jsonp(_ session: URLSession, _ url: URL) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: baiduRequest(url))
        try check(response)
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any] else {
            throw TVError.unsupported(L10n.text("Couldn't get a sign-in code. Try again."))
        }
        return object
    }

    private static func baiduRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 45)
        request.setValue(browser, forHTTPHeaderField: "User-Agent")
        request.setValue("https://pan.baidu.com/", forHTTPHeaderField: "Referer")
        return request
    }

    // MARK: Aliyun Drive

    private static let aliyunQuery: [(String, String)] = [("appName", "aliyun_drive"), ("fromSite", "52"), ("_bx-v", "2.2.3")]

    private static func startAliyun() async throws -> CloudDriveQRLogin {
        var components = URLComponents(string: "https://passport.aliyundrive.com/newlogin/qrcode/generate.do")!
        components.queryItems = (aliyunQuery + [("appEntrance", "web"), ("isMobile", "false"), ("lang", "zh_CN"), ("returnUrl", ""), ("bizParams", "")])
            .map { URLQueryItem(name: $0.0, value: $0.1) }
        let (data, response) = try await URLSession.shared.data(for: aliyunRequest(components.url!))
        try check(response)
        let content = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["content"] as? [String: Any])?["data"] as? [String: Any]
        guard let code = content?["codeContent"] as? String, let ck = content?["ck"] as? String, let time = content?["t"] else {
            throw TVError.unsupported(L10n.text("Couldn't get a sign-in code. Try again."))
        }
        return CloudDriveQRLogin(drive: .aliyun, code: code, token: ck, state: ["t": "\(time)"])
    }

    private func pollAliyun() async throws -> Status {
        var components = URLComponents(string: "https://passport.aliyundrive.com/newlogin/qrcode/query.do")!
        components.queryItems = Self.aliyunQuery.map { URLQueryItem(name: $0.0, value: $0.1) }
        var request = Self.aliyunRequest(components.url!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [("t", state["t"] ?? ""), ("ck", token), ("appName", "aliyun_drive"), ("appEntrance", "web"), ("isMobile", "false"),
                           ("lang", "zh_CN"), ("returnUrl", ""), ("fromSite", "52"), ("bizParams", ""), ("navlanguage", "zh-CN"), ("navPlatform", "MacIntel")]
            .map { URLQueryItem(name: $0.0, value: $0.1) }
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response)
        let content = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["content"] as? [String: Any])?["data"] as? [String: Any]
        switch content?["qrCodeStatus"] as? String {
        case "NEW", "SCANED": return .waiting
        case "CONFIRMED":
            guard let token = (content?["bizExt"] as? String).flatMap(Self.aliyunRefreshToken) else {
                throw TVError.unsupported(L10n.text("Sign-in was approved, but the drive didn't return a login. Try again."))
            }
            return .signedIn(Credentials(cookie: "", serviceTicket: nil, refreshToken: token))
        default: return .expired
        }
    }

    /// `bizExt` is base64 of JSON (its text may be GBK); only the ASCII refresh token is read.
    static func aliyunRefreshToken(_ bizExt: String) -> String? {
        guard let data = Data(base64Encoded: bizExt) else { return nil }
        let text = String(decoding: data.map { $0 < 0x80 ? $0 : 0x20 }, as: UTF8.self)
        guard let match = text.firstMatch(of: /"refreshToken"\s*:\s*"([0-9A-Za-z]+)"/) else { return nil }
        return String(match.1)
    }

    private static func aliyunRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(browser, forHTTPHeaderField: "User-Agent")
        request.setValue("https://passport.aliyundrive.com/", forHTTPHeaderField: "Referer")
        return request
    }

    // MARK: 115

    /// The client the sign-in is made as. 115 keeps one sign-in per kind of client, so this one signs out
    /// another TV app of the same account, but not 115 on the phone, the computer or the web.
    static let pan115App = "tv"

    private static func start115() async throws -> CloudDriveQRLogin {
        let (data, response) = try await URLSession.shared.data(for: pan115Request(URL(string: "https://qrcodeapi.115.com/api/1.0/web/1.0/token/")!))
        try check(response)
        let session = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [String: Any]
        guard let uid = session?["uid"] as? String, let sign = session?["sign"] as? String, let time = session?["time"] as? NSNumber,
              let code = session?["qrcode"] as? String, !uid.isEmpty, !code.isEmpty else {
            throw TVError.unsupported(L10n.text("Couldn't get a sign-in code. Try again."))
        }
        return CloudDriveQRLogin(drive: .pan115, code: code, token: uid, state: ["time": time.stringValue, "sign": sign])
    }

    private func poll115() async throws -> Status {
        var components = URLComponents(string: "https://qrcodeapi.115.com/get/status/")!
        components.queryItems = [("uid", token), ("time", state["time"] ?? ""), ("sign", state["sign"] ?? ""), ("_", "\(Self.milliseconds())")]
            .map { URLQueryItem(name: $0.0, value: $0.1) }
        // The status request is held open until something happens, for up to about 30 seconds.
        let (data, response) = try await URLSession.shared.data(for: Self.pan115Request(components.url!, timeout: 45))
        try Self.check(response)
        switch Self.pan115Status(data) {
        case .some(2): return .signedIn(try await Self.complete115(token))
        case .some(let status) where status < 0: return .expired
        default: return .waiting
        }
    }

    /// The code's status: nothing yet (nil), 0 waiting, 1 scanned, 2 approved, -1 expired, -2 cancelled.
    /// An answer that isn't a success means the code is gone.
    static func pan115Status(_ data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard (object["state"] as? NSNumber)?.intValue == 1 else { return -1 }
        return ((object["data"] as? [String: Any])?["status"] as? NSNumber)?.intValue
    }

    private static func complete115(_ uid: String) async throws -> Credentials {
        var request = pan115Request(URL(string: "https://passportapi.115.com/app/1.0/\(pan115App)/1.0/login/qrcode/")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("account=\(uid)&app=\(pan115App)".utf8)
        // Its cookies are the account's; they belong in the saved sign-in, not in the app's cookie store.
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        try check(response)
        guard let cookie = pan115Cookie(data) else {
            throw TVError.unsupported(L10n.text("Sign-in was approved, but the drive didn't return a login. Try again."))
        }
        return Credentials(cookie: cookie, serviceTicket: nil)
    }

    /// "UID=…; CID=…; SEID=…; KID=…" from the sign-in's answer, `{"data": {"cookie": {"UID": …}}}`.
    static func pan115Cookie(_ data: Data) -> String? {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let cookie = (object?["data"] as? [String: Any])?["cookie"] as? [String: Any] ?? [:]
        let fields = ["UID", "CID", "SEID", "KID"].compactMap { name in (cookie[name] as? String).flatMap { $0.isEmpty ? nil : (name, $0) } }
        guard Set(fields.map { $0.0 }).isSuperset(of: ["UID", "CID", "SEID"]) else { return nil }
        return fields.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
    }

    private static func pan115Request(_ url: URL, timeout: TimeInterval = 15) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(Pan115Files.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://115.com/", forHTTPHeaderField: "Referer")
        return request
    }

    private static let browser = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    private static func milliseconds() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private static func check(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TVError.unsupported(L10n.text("The source %@ returned HTTP %lld.", http.url?.host ?? "", http.statusCode))
        }
    }

    private static func request(_ url: URL, _ drive: Drive) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue(drive.referer, forHTTPHeaderField: "Referer")
        return request
    }
}

private extension CloudDriveQRLogin.Drive {
    // Quark and UC only.
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

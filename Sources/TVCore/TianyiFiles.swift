import CryptoKit
import Foundation

/// Tianyi Cloud (天翼云盘, cloud.189.cn) through the API its TV app uses, as OpenList's `189_tv` driver does. The
/// saved sign-in is the account's long-lived access token (from the TV app's code, `CloudDriveQRLogin`); it is
/// exchanged for a session key and secret, which sign every request. A folder and a file are known by their id;
/// the personal space's top folder is -11.
actor TianyiFiles {
    static let shared = TianyiFiles()
    static let api = "https://api.cloud.189.cn"
    /// The TV app's key and the secret its requests are signed with before a session exists.
    static let appKey = "600100885"
    static let appSecret = "fe5734c74c2f96a38157f420b32dc995"
    static let userAgent = "EcloudTV/6.5.5 (PJX110; unknown; home02) Android/35"
    /// Every request names the client it comes from.
    static let client: [(String, String)] = [
        ("clientType", "FAMILY_TV"), ("version", "6.5.5"), ("channelId", "home02"), ("clientSn", "unknown"), ("model", "PJX110"),
        ("osFamily", "Android"), ("osVersion", "35"), ("networkAccessMode", "WIFI"), ("telecomsOperator", "46011"),
    ]
    static let root = "-11"
    static let pageSize = 130

    struct Session: Equatable { let key: String; let secret: String }

    private let session: URLSession
    private let account: @Sendable () -> String
    /// The token the session was made from; signing in again makes a new one.
    private var signedIn = ""
    private var current: Session?

    init(session: URLSession? = nil, account: (@Sendable () -> String)? = nil) {
        self.session = session ?? {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = 20
            return URLSession(configuration: configuration)
        }()
        self.account = account ?? { ((try? CloudDriveAccounts.load()) ?? CloudDriveAccounts()).tianyiToken ?? "" }
    }

    private var name: String { L10n.text("Tianyi Cloud") }

    func list(_ folder: String) async throws -> [CloudFile] {
        var files: [CloudFile] = []
        for page in 1...50 {
            let answer = try await call("/listFiles.action", [
                ("folderId", folder), ("fileType", "0"), ("mediaAttr", "0"), ("iconOption", "5"), ("pageNum", "\(page)"),
                ("pageSize", "\(Self.pageSize)"), ("recursive", "0"), ("orderBy", "filename"), ("descending", "false"),
            ])
            let listed = Self.files(answer)
            files += listed
            if listed.count < Self.pageSize { break }
        }
        return files
    }

    /// Files and folders anywhere in the personal space whose names hold `keywords`. Not every account's answer has
    /// been seen: one that can't be read finds nothing rather than failing the whole search.
    func search(_ keywords: String, page: Int, size: Int) async throws -> (files: [CloudFile], total: Int) {
        do {
            let answer = try await call("/searchFiles.action", [
                ("folderId", Self.root), ("filename", keywords), ("recursive", "1"), ("fileType", "0"), ("mediaType", "0"),
                ("iconOption", "5"), ("pageNum", "\(page)"), ("pageSize", "\(size)"),
            ])
            let files = Self.files(answer)
            let list = answer["fileListAO"] as? [String: Any] ?? answer
            return (files, Int(Self.number(list["count"]) ?? Int64(files.count)))
        } catch let error as CloudFilesError {
            throw error
        } catch {
            Diagnostics.shared.failure("files", "tianyi search", error)
            return ([], 0)
        }
    }

    /// A listing's folders and files: `{"fileListAO": {"count": n, "folderList": […], "fileList": […]}}`. A search
    /// may answer with the two lists at the top.
    static func files(_ answer: [String: Any]) -> [CloudFile] {
        let list = answer["fileListAO"] as? [String: Any] ?? answer
        let folders = (list["folderList"] as? [[String: Any]] ?? []).compactMap { file($0, isFolder: true) }
        return folders + (list["fileList"] as? [[String: Any]] ?? []).compactMap { file($0, isFolder: false) }
    }

    static func file(_ item: [String: Any], isFolder: Bool) -> CloudFile? {
        guard let id = text(item["id"]), let name = item["name"] as? String, !name.isEmpty else { return nil }
        let modified = (item["lastOpTime"] as? String).flatMap(date)
        return CloudFile(id: id, name: name, isFolder: isFolder, size: isFolder ? 0 : number(item["size"]) ?? 0, modified: modified)
    }

    func stream(_ id: String, name: String) async throws -> URL {
        guard CloudFile.playsOriginal(name) else { throw CloudFilesError.unsupportedFormat((name as NSString).pathExtension) }
        let source = try await link(id, name: name)
        return CloudStreams.register(source) { [self] in try? await link(id, name: name) }
    }

    /// The file's download link, followed to the CDN it redirects to.
    func link(_ id: String, name: String) async throws -> CloudStreams.Source {
        let answer = try await call("/getFileDownloadUrl.action", [("fileId", id), ("dt", "3"), ("flag", "1")])
        guard let address = Self.downloadAddress(answer) else {
            throw TVError.unsupported(L10n.text("%@ didn't return a link for this file. Try again.", self.name))
        }
        let headers = ["User-Agent": Self.userAgent]
        let (url, length) = try await CloudDriveLink.resolve(address, headers: headers, session: session)
        return CloudStreams.Source(url: url, headers: headers, length: length, name: name)
    }

    /// `fileDownloadUrl`, written as XML would (`&amp;`) and on plain HTTP; the same address over HTTPS works.
    static func downloadAddress(_ answer: [String: Any]) -> URL? {
        guard var text = answer["fileDownloadUrl"] as? String, !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        if text.hasPrefix("http://") { text = "https://" + text.dropFirst(7) }
        return URL(string: text)
    }

    // MARK: Requests

    private func call(_ path: String, _ query: [(String, String)], retried: Bool = false) async throws -> [String: Any] {
        let session = try await signedInSession()
        let url = Self.address(path, query)
        var request = URLRequest(url: url)
        for (field, value) in Self.sessionHeaders(session, method: "GET", path: path, date: Date()) { request.setValue(value, forHTTPHeaderField: field) }
        request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await self.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let body = String(decoding: data.prefix(400), as: UTF8.self)
        // An expired session: make a new one from the saved token, once.
        if body.contains("InvalidSessionKey") || body.contains("userSessionBO is null") {
            current = nil
            if !retried { return try await call(path, query, retried: true) }
            throw CloudFilesError.signInRequired(name)
        }
        if let failure = Self.failure(answer) {
            Diagnostics.shared.record(.warning, "files", "tianyi \(path) status=\(status) \(failure)")
            throw TVError.unsupported(L10n.text("%@ says: %@", name, failure))
        }
        guard (200..<300).contains(status) else { throw TVError.http(status) }
        return answer
    }

    /// The session the saved token opens, made once and kept until it expires.
    private func signedInSession() async throws -> Session {
        let token = account().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw CloudFilesError.signInRequired(name) }
        if token != signedIn { signedIn = token; current = nil }
        if let current { return current }
        let made: Session
        do { made = try await Self.session(for: token, using: session) } catch {
            Diagnostics.shared.failure("files", "tianyi session", error)
            throw CloudFilesError.signInRequired(name)
        }
        current = made
        return made
    }

    /// The session key and secret for an access token (`loginFamilyMerge.action`).
    static func session(for token: String, using session: URLSession) async throws -> Session {
        let path = "/family/manage/loginFamilyMerge.action"
        let (data, _) = try await session.data(for: appRequest(path, [("e189AccessToken", token)]))
        let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let key = answer["sessionKey"] as? String, let secret = answer["sessionSecret"] as? String, !key.isEmpty, !secret.isEmpty else {
            throw TVError.unsupported(failure(answer) ?? "no session")
        }
        return Session(key: key, secret: secret)
    }

    /// A request signed with the app's key, before there is a session: the sign-in code and the session itself.
    static func appRequest(_ path: String, _ query: [(String, String)], time: Date = Date()) -> URLRequest {
        var request = URLRequest(url: address(path, query), timeoutInterval: 20)
        let timestamp = String(Int64(time.timeIntervalSince1970 * 1000))
        request.setValue(timestamp, forHTTPHeaderField: "Timestamp")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Request-ID")
        request.setValue(appKey, forHTTPHeaderField: "AppKey")
        request.setValue(signature(appSecret, "AppKey=\(appKey)&Operate=GET&RequestURI=\(path)&Timestamp=\(timestamp)"), forHTTPHeaderField: "AppSignature")
        request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    static func sessionHeaders(_ session: Session, method: String, path: String, date: Date) -> [String: String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let gmt = formatter.string(from: date)
        return ["Date": gmt, "SessionKey": session.key, "X-Request-ID": UUID().uuidString.lowercased(),
                "Signature": signature(session.secret, "SessionKey=\(session.key)&Operate=\(method)&RequestURI=\(path)&Date=\(gmt)")]
    }

    /// HMAC-SHA1 in upper-case hex.
    static func signature(_ secret: String, _ text: String) -> String {
        HMAC<Insecure.SHA1>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: Data(secret.utf8)))
            .map { String(format: "%02X", $0) }.joined()
    }

    static func address(_ path: String, _ query: [(String, String)]) -> URL {
        var components = URLComponents(string: api + path)!
        components.queryItems = (client + query).map { URLQueryItem(name: $0.0, value: $0.1) }
        // `+` would read as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    /// What a failed answer says; nil for a success. Answers carry `res_code` (0 or a name), `errorCode` or `code`.
    static func failure(_ answer: [String: Any]) -> String? {
        if let code = answer["res_code"] {
            if (code as? NSNumber)?.intValue == 0 || (code as? String) == "0" || (code as? String)?.isEmpty == true { return nil }
            return (answer["res_message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "\(code)"
        }
        if let code = answer["errorCode"] as? String, !code.isEmpty { return answer["errorMsg"] as? String ?? code }
        if let code = answer["code"] as? String, !code.isEmpty, code != "SUCCESS" { return answer["msg"] as? String ?? answer["message"] as? String ?? code }
        return nil
    }

    /// "2024-05-01 20:15:00", China time.
    static func date(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: text)
    }
    static func number(_ value: Any?) -> Int64? {
        if let value = value as? NSNumber { return value.int64Value }
        return (value as? String).flatMap { Int64($0) }
    }
    static func text(_ value: Any?) -> String? {
        let text = (value as? String) ?? (value as? NSNumber)?.stringValue
        return text?.isEmpty == false ? text : nil
    }
}

/// A drive's download link followed to where the bytes are: the address after its redirects and the file's length,
/// from a one-byte range request. A link may instead answer with JSON naming the address (`redirect_url`).
enum CloudDriveLink {
    static func resolve(_ url: URL, headers: [String: String], session: URLSession, hops: Int = 0) async throws -> (URL, Int) {
        var request = URLRequest(url: url, timeoutInterval: 20)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TVError.invalidURL }
        if (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("json"), hops < 2,
           let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let next = ((answer["data"] as? [String: Any])?["redirect_url"] as? String).flatMap(URL.init(string:)) {
            return try await resolve(next, headers: headers, session: session, hops: hops + 1)
        }
        guard (200..<300).contains(http.statusCode) else { throw TVError.http(http.statusCode) }
        let final = http.url ?? url
        if let range = http.value(forHTTPHeaderField: "Content-Range"), let total = range.split(separator: "/").last.flatMap({ Int($0) }) {
            return (final, total)
        }
        let length = Int(http.expectedContentLength)
        guard length > 1 else { throw TVError.unsupported(L10n.text("%@ didn't return a link for this file. Try again.", final.host ?? "")) }
        return (final, length)
    }
}

import Foundation

/// 光鸭云盘 (Guangya Cloud) through the API its web page uses, signed in with the tokens saved under Cloud Drive Accounts.
/// A file or folder is known by its id; the drive's top folder has none. Guangya hands over each file as it is stored,
/// from a signed link.
actor GuangyaFiles {
    static let shared = GuangyaFiles()
    static let api = "https://api.guangyapan.com"
    static let accountAPI = "https://account.guangyapan.com"
    /// The web page's client, which also signs in TVs and other devices with a code its app approves.
    static let clientID = "aMe-8VSlkrbQXpUR"
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36"
    /// The web page. Its download links serve only requests that come from it, as its API does.
    static let referer = "https://www.guangyapan.com/"
    /// Files per listing request.
    static let pageSize = 100

    private let session: URLSession
    private let load: @Sendable () -> GuangyaAccount?
    /// Saves refreshed tokens in place of the sign-in whose refresh token is given.
    private let store: @Sendable (_ replacing: String, _ account: GuangyaAccount) -> Void

    init(session: URLSession? = nil, load: (@Sendable () -> GuangyaAccount?)? = nil,
         store: (@Sendable (_ replacing: String, _ account: GuangyaAccount) -> Void)? = nil) {
        self.session = session ?? {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = 20
            return URLSession(configuration: configuration)
        }()
        self.load = load ?? { ((try? CloudDriveAccounts.load()) ?? CloudDriveAccounts()).guangya }
        self.store = store ?? { replacing, account in
            var accounts = (try? CloudDriveAccounts.load()) ?? CloudDriveAccounts()
            // A sign-out or a new sign-in since the refresh began wins.
            guard accounts.guangya?.refreshToken == replacing else { return }
            accounts.guangya = account
            try? accounts.save()
        }
    }

    private var name: String { L10n.text("Guangya Cloud") }

    func list(_ folder: String) async throws -> [CloudFile] {
        var files: [CloudFile] = []
        for page in 0..<100 {
            let answer = try await call("/nd.bizuserres.s/v1/file/get_file_list", [
                "parentId": Self.parent(folder), "page": page, "pageSize": Self.pageSize, "orderBy": 3, "sortType": 1,
            ])
            let data = answer["data"] as? [String: Any]
            let items = data?["list"] as? [[String: Any]] ?? []
            files += items.compactMap(Self.file)
            let total = Pan115Files.number(data?["total"]).map(Int.init) ?? 0
            if items.count < Self.pageSize || (total > 0 && files.count >= total) { break }
        }
        return files
    }

    /// The top folder is "0" in Cloud Files and has no id here.
    static func parent(_ folder: String) -> String { folder == "0" ? "" : folder }

    /// A listing row: `fileId`, `fileName`, `fileSize`, `resType` (2 is a folder) and `utime` in seconds.
    static func file(_ item: [String: Any]) -> CloudFile? {
        guard let id = Pan115Files.text(item["fileId"]), let name = item["fileName"] as? String, !name.isEmpty else { return nil }
        let modified = (Pan115Files.number(item["utime"]) ?? Pan115Files.number(item["ctime"])).flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
        let folder = Pan115Files.number(item["resType"]) == 2
        return CloudFile(id: id, name: name, isFolder: folder, size: folder ? 0 : Pan115Files.number(item["fileSize"]) ?? 0, modified: modified)
    }

    func stream(_ id: String, name: String) async throws -> URL {
        guard CloudFile.playsOriginal(name) else { throw CloudFilesError.unsupportedFormat((name as NSString).pathExtension) }
        let source = try await link(id, name: name)
        return CloudStreams.register(source) { [self] in try? await link(id, name: name) }
    }

    /// The file's signed download link.
    func link(_ id: String, name: String) async throws -> CloudStreams.Source {
        let answer = try await call("/nd.bizuserres.s/v1/get_res_download_url", ["fileId": id])
        let data = answer["data"] as? [String: Any]
        guard let address = [data?["signedURL"], data?["downloadUrl"]].compactMap({ $0 as? String }).first(where: { !$0.isEmpty }),
              let url = URL(string: address) else {
            throw TVError.unsupported(L10n.text("%@ didn't return a link for this file. Try again.", self.name))
        }
        let headers = ["User-Agent": Self.userAgent, "Referer": Self.referer]
        return CloudStreams.Source(url: url, headers: headers, length: try await length(url, headers: headers), name: name)
    }

    /// The file's length, from the link's answer to its first byte: the listing that had it isn't at hand here.
    private func length(_ url: URL, headers: [String: String]) async throws -> Int {
        var request = URLRequest(url: url, timeoutInterval: 20)
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TVError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        if let total = Self.total(http.value(forHTTPHeaderField: "Content-Range")) { return total }
        // A link that ignores the range sends the whole file; its length is the file's.
        guard http.statusCode == 200, http.expectedContentLength > 0 else { throw TVError.http(http.statusCode) }
        return Int(http.expectedContentLength)
    }

    /// The total in `Content-Range: bytes 0-0/12345`.
    static func total(_ range: String?) -> Int? {
        (range?.split(separator: "/").last).flatMap { Int($0) }
    }

    /// One API request, with the saved access token; one the drive turns down is refreshed once and the request sent again.
    private func call(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        guard var account = load(), !account.refreshToken.isEmpty else { throw CloudFilesError.signInRequired(name) }
        if account.accessToken.isEmpty { account = try await refresh(account) }
        var (answer, status) = try await send(path, body, account)
        if Self.rejected(answer, status: status) {
            account = try await refresh(account)
            (answer, status) = try await send(path, body, account)
        }
        if (200..<300).contains(status), Self.succeeded(answer) { return answer }
        let message = answer["msg"] as? String ?? ""
        Diagnostics.shared.record(.warning, "files", "guangya \(path) status=\(status) code=\(Pan115Files.number(answer["code"]) ?? -1) \(message)")
        if Self.rejected(answer, status: status) { throw CloudFilesError.signInRequired(name) }
        if !message.isEmpty { throw TVError.unsupported(L10n.text("%@ says: %@", name, message)) }
        throw TVError.http(status)
    }

    private func send(_ path: String, _ body: [String: Any], _ account: GuangyaAccount) async throws -> ([String: Any], Int) {
        var request = Self.request(URL(string: Self.api + path)!, body: body)
        request.setValue("Bearer " + account.accessToken, forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:], (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// The drive answers `{"code": 0, "msg": "success", "data": …}`; a failure has another code and its reason.
    static func succeeded(_ answer: [String: Any]) -> Bool {
        let code = Pan115Files.number(answer["code"]) ?? 0
        let message = (answer["msg"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        return code == 0 && (message.isEmpty || message.lowercased() == "success")
    }

    /// A missing or expired token: HTTP 401 or 403, or code 117 "无效token".
    static func rejected(_ answer: [String: Any], status: Int) -> Bool {
        status == 401 || status == 403 || Pan115Files.number(answer["code"]) == 117
    }

    /// New tokens for the saved refresh token, saved for the next request.
    private func refresh(_ account: GuangyaAccount) async throws -> GuangyaAccount {
        let answer: [String: Any]
        do { answer = try await Self.token(session: session, ["grant_type": "refresh_token", "refresh_token": account.refreshToken]) }
        catch let failure as GuangyaTokenError {
            Diagnostics.shared.record(.warning, "files", "guangya refresh failed: \(failure.code)")
            throw CloudFilesError.signInRequired(name)
        }
        guard let access = answer["access_token"] as? String, !access.isEmpty else { throw CloudFilesError.signInRequired(name) }
        let refreshed = GuangyaAccount(accessToken: access, refreshToken: (answer["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? account.refreshToken)
        store(account.refreshToken, refreshed)
        return refreshed
    }

    /// The account service's token endpoint (OAuth 2): the answer, or its `error` ("authorization_pending" while a
    /// sign-in code waits).
    static func token(session: URLSession = .shared, _ fields: [String: String]) async throws -> [String: Any] {
        let request = request(URL(string: accountAPI + "/v1/auth/token")!, body: fields.merging(["client_id": clientID]) { $1 })
        let (data, _) = try await session.data(for: request)
        let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let access = answer["access_token"] as? String, !access.isEmpty { return answer }
        throw GuangyaTokenError(code: answer["error"] as? String ?? "")
    }

    static func request(_ url: URL, body: [String: Any]) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }
}

struct GuangyaTokenError: Error { let code: String }

/// A Guangya sign-in: the account service's tokens. The access token lasts a while; the refresh token gets new ones.
public struct GuangyaAccount: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public init(accessToken: String, refreshToken: String) { self.accessToken = accessToken; self.refreshToken = refreshToken }
}

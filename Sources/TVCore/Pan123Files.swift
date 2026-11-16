import Foundation

/// 123pan (123云盘) through its web API, as OpenList's `123` driver uses it, signed in with the Bearer token the web
/// app's code gives (`CloudDriveQRLogin`). Every request carries a sign of its path and the time in China. A
/// folder is known by its id; a file by its id with the etag, storage flag and size its download link is asked with.
actor Pan123Files {
    static let shared = Pan123Files()
    static let api = "https://yun.123pan.com/b/api"
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
    static let pageSize = 100

    private let session: URLSession
    private let account: @Sendable () -> String

    init(session: URLSession? = nil, account: (@Sendable () -> String)? = nil) {
        self.session = session ?? {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = 20
            return URLSession(configuration: configuration)
        }()
        self.account = account ?? { ((try? CloudDriveAccounts.load()) ?? CloudDriveAccounts()).pan123Token ?? "" }
    }

    private var name: String { L10n.text("123pan") }

    func list(_ folder: String) async throws -> [CloudFile] {
        try await listing(folder: folder, search: "").files
    }

    /// Files and folders anywhere in the drive whose names hold `keywords`.
    func search(_ keywords: String, page: Int, size: Int) async throws -> (files: [CloudFile], total: Int) {
        try await listing(folder: "0", search: keywords, page: page, pages: 1)
    }

    private func listing(folder: String, search: String, page first: Int = 1, pages: Int = 50) async throws -> (files: [CloudFile], total: Int) {
        var files: [CloudFile] = [], total = 0
        for page in first..<(first + pages) {
            let answer = try await call("/file/list/new", query: [
                ("driveId", "0"), ("limit", "\(Self.pageSize)"), ("next", "0"), ("orderBy", "file_id"), ("orderDirection", "desc"),
                ("parentFileId", folder), ("trashed", "false"), ("SearchData", search), ("Page", "\(page)"),
                ("OnlyLookAbnormalFile", "0"), ("event", "homeListFile"), ("operateType", "4"), ("inDirectSpace", "false"),
            ])
            let data = answer["data"] as? [String: Any] ?? [:]
            let items = data["InfoList"] as? [[String: Any]] ?? []
            files += items.compactMap(Self.file)
            total = Int(Self.number(data["Total"]) ?? Int64(files.count))
            if items.isEmpty || (data["Next"] as? String) == "-1" || files.count >= total { break }
        }
        return (files, total)
    }

    /// A listing row: `{"FileId": 1, "FileName": "…", "Type": 0 or 1 (folder), "Size": …, "Etag": "…", "S3KeyFlag": "…",
    /// "UpdateAt": "2024-05-01T20:15:00+08:00"}`.
    static func file(_ item: [String: Any]) -> CloudFile? {
        guard let id = number(item["FileId"]), let name = item["FileName"] as? String, !name.isEmpty else { return nil }
        let modified = (item["UpdateAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        if number(item["Type"]) == 1 { return CloudFile(id: "\(id)", name: name, isFolder: true, modified: modified) }
        let size = number(item["Size"]) ?? 0
        let key = FileKey(id: id, etag: item["Etag"] as? String ?? "", flag: item["S3KeyFlag"] as? String ?? "", size: size)
        return CloudFile(id: key.text, name: name, isFolder: false, size: size, modified: modified)
    }

    /// What a file's download link is asked with, kept in its id as "id~etag~flag~size".
    struct FileKey: Equatable {
        let id: Int64, etag: String, flag: String, size: Int64
        var text: String { "\(id)~\(etag)~\(flag)~\(size)" }
        init(id: Int64, etag: String, flag: String, size: Int64) { self.id = id; self.etag = etag; self.flag = flag; self.size = size }
        init?(_ text: String) {
            let parts = text.split(separator: "~", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4, let id = Int64(parts[0]), let size = Int64(parts[3]) else { return nil }
            self.init(id: id, etag: parts[1], flag: parts[2], size: size)
        }
    }

    func stream(_ id: String, name: String) async throws -> URL {
        guard CloudFile.playsOriginal(name) else { throw CloudFilesError.unsupportedFormat((name as NSString).pathExtension) }
        let source = try await link(id, name: name)
        return CloudStreams.register(source) { [self] in try? await link(id, name: name) }
    }

    func link(_ id: String, name: String) async throws -> CloudStreams.Source {
        guard let key = FileKey(id) else { throw TVError.invalidURL }
        let answer = try await call("/file/download_info", body: [
            "driveId": 0, "etag": key.etag, "fileId": key.id, "fileName": name, "s3keyFlag": key.flag, "size": key.size, "type": 0,
        ])
        guard let (address, referer) = Self.download(answer) else {
            throw TVError.unsupported(L10n.text("%@ didn't return a link for this file. Try again.", self.name))
        }
        let headers = ["Referer": referer, "User-Agent": Self.userAgent]
        let (url, length) = try await CloudDriveLink.resolve(address, headers: headers, session: session)
        return CloudStreams.Source(url: url, headers: headers, length: length, name: name)
    }

    /// `data.DownloadUrl`. Its `params` query holds the real address in base64; the CDN wants a Referer of the link's own site.
    static func download(_ answer: [String: Any]) -> (URL, String)? {
        guard let text = (answer["data"] as? [String: Any])?["DownloadUrl"] as? String, let link = URL(string: text),
              let scheme = link.scheme, let host = link.host() else { return nil }
        let referer = "\(scheme)://\(host)/"
        if let params = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "params" })?.value,
           let decoded = Data(base64Encoded: params).map({ String(decoding: $0, as: UTF8.self) }), let inner = URL(string: decoded), inner.scheme != nil {
            return (inner, referer)
        }
        return (link, referer)
    }

    // MARK: Requests

    private func call(_ path: String, query: [(String, String)] = [], body: [String: Any]? = nil) async throws -> [String: Any] {
        let token = account().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw CloudFilesError.signInRequired(name) }
        var components = URLComponents(string: Self.api + path)!
        let sign = Self.sign(path: components.path, time: Date(), random: Int.random(in: 0..<10_000_000))
        components.queryItems = (query + [sign]).map { URLQueryItem(name: $0.0, value: $0.1) }
        var request = URLRequest(url: components.url!)
        for (field, value) in Self.headers(token: token) { request.setValue(value, forHTTPHeaderField: field) }
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = Self.number(answer["code"]) ?? -1
        if code == 0, (200..<300).contains(status) { return answer }
        let message = answer["message"] as? String ?? ""
        Diagnostics.shared.record(.warning, "files", "pan123 \(path) status=\(status) code=\(code) \(message)")
        // 401: the token is missing or has expired (it lasts about 90 days).
        if status == 401 || code == 401 { throw CloudFilesError.signInRequired(name) }
        if !message.isEmpty { throw TVError.unsupported(L10n.text("%@ says: %@", name, message)) }
        throw TVError.http(status)
    }

    static func headers(token: String) -> [String: String] {
        ["Authorization": "Bearer " + token, "Origin": "https://yun.123pan.com", "Referer": "https://yun.123pan.com/",
         "User-Agent": userAgent, "platform": "web", "app-version": "3"]
    }

    /// The sign every web request carries: a query item named after the CRC-32 of the time in China (yyyyMMddHHmm, its
    /// digits swapped for letters), whose value is the time, a random number and the CRC-32 of both with the path.
    static func sign(path: String, time: Date, random: Int) -> (String, String) {
        let letters = Array("adefghlmyijnopkqrstubcvwsz")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "yyyyMMddHHmm"
        let mapped = String(formatter.string(from: time).compactMap { $0.wholeNumberValue.map { letters[$0] } })
        let timeSign = String(SubtitleArchive.crc32(Data(mapped.utf8)))
        let timestamp = Int64(time.timeIntervalSince1970)
        let data = "\(timestamp)|\(random)|\(path)|web|3|\(timeSign)"
        return (timeSign, "\(timestamp)-\(random)-\(SubtitleArchive.crc32(Data(data.utf8)))")
    }

    static func number(_ value: Any?) -> Int64? {
        if let value = value as? NSNumber { return value.int64Value }
        return (value as? String).flatMap { Int64($0) }
    }
}

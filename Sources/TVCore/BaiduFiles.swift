import Foundation

/// Baidu Netdisk through the web API its own pages use (`pan.baidu.com/api/…`), signed in with the cookies (BDUSS,
/// STOKEN) saved under Cloud Drive Accounts, the same sign-in plugins get. Files and folders are known by their
/// path, as the drive itself names them. Videos play as the drive's own HLS copy (`/api/streaming`): Baidu slows
/// down downloads of the original for accounts without a membership, but streams its copy at full speed, in the
/// best quality the account may play. Everything else, and a video with no copy, plays from the original file.
actor BaiduFiles {
    static let shared = BaiduFiles()
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
    /// The User-Agent Baidu's download links are handed to (its own clients'; as AList/OpenList send).
    static let downloadAgent = "pan.baidu.com"
    static let api = "https://pan.baidu.com/api"
    /// The web app's id, which every web API call names.
    static let appID = "250528"
    /// Files per listing request; the web page asks for 100 at a time, the API serves up to 1,000.
    static let pageSize = 1000
    /// The qualities of the drive's HLS copy, best first; an account gets those its membership allows.
    static let qualities = ["M3U8_AUTO_1080", "M3U8_AUTO_720", "M3U8_AUTO_480"]
    /// The longest an account without a membership is asked to wait before the copy plays (`adTime`).
    static let longestWait = 30

    private let session: URLSession
    private let account: @Sendable () -> String
    private let wait: @Sendable (Int) async throws -> Void
    /// The saved cookie the jar was built from; signing in again starts a new jar.
    private var signedIn = ""
    private var jar = CookieJar()

    init(session: URLSession? = nil, account: (@Sendable () -> String)? = nil,
         wait: (@Sendable (Int) async throws -> Void)? = nil) {
        self.session = session ?? {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = 20
            return URLSession(configuration: configuration)
        }()
        self.account = account ?? { ((try? CloudDriveAccounts.load()) ?? CloudDriveAccounts()).baiduCookie ?? "" }
        self.wait = wait ?? { try await Task.sleep(for: .seconds($0)) }
    }

    private var name: String { L10n.text("Baidu Netdisk") }

    func list(_ folder: String) async throws -> [CloudFile] {
        var files: [CloudFile] = []
        for page in 1...50 {
            let answer = try await json("/list", [("dir", folder), ("order", "name"), ("desc", "0"), ("showempty", "0"),
                                                  ("page", "\(page)"), ("num", "\(Self.pageSize)")])
            let items = answer["list"] as? [[String: Any]] ?? []
            files += items.compactMap(Self.file)
            if items.count < Self.pageSize { break }
        }
        return files
    }

    /// Files and folders anywhere in the drive whose names hold `keywords`. Baidu says only whether more follow.
    func search(_ keywords: String, page: Int, size: Int) async throws -> (files: [CloudFile], total: Int) {
        let answer = try await json("/search", [("key", keywords), ("dir", "/"), ("recursion", "1"), ("page", "\(page)"), ("num", "\(size)")])
        let files = (answer["list"] as? [[String: Any]] ?? []).compactMap(Self.file)
        let more = Self.number(answer["has_more"]) == 1
        return (files, (page - 1) * size + files.count + (more ? 1 : 0))
    }

    /// A listing row: `server_filename`, `path`, `isdir`, `size` and `server_mtime` (seconds).
    static func file(_ item: [String: Any]) -> CloudFile? {
        guard let path = item["path"] as? String, !path.isEmpty else { return nil }
        let name = (item["server_filename"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (path as NSString).lastPathComponent
        guard !name.isEmpty else { return nil }
        let modified = (number(item["server_mtime"]) ?? number(item["local_mtime"])).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let folder = number(item["isdir"]) == 1
        return CloudFile(id: path, name: name, isFolder: folder, size: folder ? 0 : number(item["size"]) ?? 0, modified: modified)
    }

    /// A video plays as the drive's HLS copy when it has one; otherwise, and for songs, the original file.
    func stream(_ path: String, name: String) async throws -> URL {
        if CloudFile.kind(of: name) == .video {
            do {
                let copy = try await playlist(path)
                return CloudStreams.registerPlaylist(copy, headers: headers)
            } catch let error as CloudFilesError {
                throw error
            } catch {
                Diagnostics.shared.record(.info, "files", "baidu no HLS copy, trying the original: \(error.localizedDescription)")
                guard CloudFile.playsOriginal(name) else { throw error }
            }
        }
        guard CloudFile.playsOriginal(name) else { throw CloudFilesError.unsupportedFormat((name as NSString).pathExtension) }
        let source = try await original(path, name: name)
        return CloudStreams.register(source) { [self] in try? await original(path, name: name) }
    }

    /// The address of the best HLS copy of the video at `path` this account may play. Baidu answers a playlist
    /// when it's ready; an account without a membership is first asked to wait (errno 133, `adTime` seconds) and
    /// then asks again with the `adToken` it was given, as Baidu's own player does.
    func playlist(_ path: String) async throws -> URL {
        var token: String?
        var last: Error = TVError.unsupported(L10n.text("%@ hasn't prepared a version of this video that Apple devices can play.", name))
        for quality in Self.qualities {
            for _ in 0..<2 {
                var query = [("path", path), ("type", quality)]
                if let token { query.append(("adToken", token)) }
                let url = address("/streaming", query)
                let (data, status) = try await fetch(url)
                if Self.isPlaylist(data) {
                    Diagnostics.shared.record(.info, "files", "baidu HLS copy \(quality)")
                    return url
                }
                let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                let code = Self.number(answer["errno"]) ?? -1
                Diagnostics.shared.record(.info, "files", "baidu streaming \(quality) status=\(status) errno=\(code)")
                if Self.signedOut(code) { throw CloudFilesError.signInRequired(name) }
                // Asked to wait first; asked once per quality, so a token that never works doesn't loop.
                if code == 133, let offered = answer["adToken"] as? String, !offered.isEmpty, token != offered {
                    token = offered
                    try await wait(min(max(Int(Self.number(answer["adTime"]) ?? 0), 0), Self.longestWait))
                    continue
                }
                last = Self.failure(code, message: answer["errmsg"] as? String ?? answer["show_msg"] as? String, drive: name, status: status)
                break
            }
        }
        throw last
    }

    /// The original file's download link, which Baidu hands to its own clients' User-Agent.
    func original(_ path: String, name: String) async throws -> CloudStreams.Source {
        let target = String(decoding: try JSONSerialization.data(withJSONObject: [path], options: [.withoutEscapingSlashes]), as: UTF8.self)
        let answer = try await json("/filemetas", [("target", target), ("dlink", "1"), ("origin", "dlna")], web: "5")
        guard let item = (answer["info"] as? [[String: Any]])?.first, let address = item["dlink"] as? String,
              let url = URL(string: address), let size = Self.number(item["size"]), size > 0 else {
            throw TVError.unsupported(L10n.text("%@ didn't return a link for this file. Try again.", self.name))
        }
        return CloudStreams.Source(url: url, headers: ["Cookie": jar.header, "User-Agent": Self.downloadAgent], length: Int(size), name: name)
    }

    static func isPlaylist(_ data: Data) -> Bool {
        String(decoding: data.prefix(64), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U")
    }

    /// -6 is "not signed in"; 9019 "need verify" and 31045 "access token invalid" mean the login stopped working.
    static func signedOut(_ code: Int64) -> Bool { code == -6 || code == 9019 || code == 31045 }

    static func failure(_ code: Int64, message: String?, drive: String, status: Int) -> Error {
        switch code {
        // The file is gone, or isn't a video Baidu can make a copy of.
        case -9, 31066: TVError.unsupported(L10n.text("%@ says: %@", drive, L10n.text("This file no longer exists.")))
        // A copy is still being made.
        case 31341, 31346: TVError.unsupported(L10n.text("%@ hasn't prepared a version of this video that Apple devices can play.", drive))
        default:
            if let message, !message.isEmpty { TVError.unsupported(L10n.text("%@ says: %@", drive, message)) }
            else if (200..<300).contains(status) { TVError.unsupported(L10n.text("%@ hasn't prepared a version of this video that Apple devices can play.", drive)) }
            else { TVError.http(status) }
        }
    }

    /// The API and its CDN want the account's cookies, a browser's User-Agent and the drive's page as referrer.
    private var headers: [String: String] { ["Cookie": jar.header, "User-Agent": Self.userAgent, "Referer": "https://pan.baidu.com/disk/home"] }

    /// `path` of the web API with `query` and the parameters every call of the web app carries.
    private func address(_ path: String, _ query: [(String, String)], web: String = "1") -> URL {
        let all = query + [("app_id", Self.appID), ("channel", "chunlei"), ("clienttype", "0"), ("web", web)]
        // Paths may hold `+`, `&` and `=`, which a query keeps only percent-encoded.
        let kept = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~/"))
        let encoded = all.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: kept) ?? $0.1)" }.joined(separator: "&")
        return URL(string: Self.api + path + "?" + encoded)!
    }

    private func fetch(_ url: URL) async throws -> (Data, Int) {
        let saved = account().trimmingCharacters(in: .whitespacesAndNewlines)
        guard saved.contains("BDUSS") else { throw CloudFilesError.signInRequired(name) }
        if saved != signedIn { signedIn = saved; jar = CookieJar(saved) }
        var request = URLRequest(url: url)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse { jar.update(http) }
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func json(_ path: String, _ query: [(String, String)], web: String = "1") async throws -> [String: Any] {
        let (data, status) = try await fetch(address(path, query, web: web))
        let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = Self.number(answer["errno"]) ?? -1
        if code == 0, (200..<300).contains(status) { return answer }
        let message = answer["errmsg"] as? String ?? answer["show_msg"] as? String
        Diagnostics.shared.record(.warning, "files", "baidu \(path) status=\(status) errno=\(code) \(message ?? "")")
        if status == 401 || (status == 403 && code == -1) || Self.signedOut(code) { throw CloudFilesError.signInRequired(name) }
        throw Self.failure(code, message: message, drive: name, status: status)
    }

    /// Baidu sends numbers as JSON numbers or as text.
    static func number(_ value: Any?) -> Int64? {
        if let value = value as? NSNumber { return value.int64Value }
        return (value as? String).flatMap { Int64($0) }
    }
}

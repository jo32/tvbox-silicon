import Foundation

/// Quark and UC Drive through their web API, signed in with the account saved under Cloud Drive
/// Accounts. Every API answer refreshes the `__puus` cookie, and the CDN refuses a download
/// (HTTP 412) without the latest one, so the cookies live here, not only in the saved account.
actor QuarkFiles {
    enum Service { case quark, uc }
    static let quark = QuarkFiles(.quark)
    static let uc = QuarkFiles(.uc)
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"

    let service: Service
    private let session: URLSession
    private let account: @Sendable () -> String
    /// The saved cookie the jar was built from; signing in again starts a new jar.
    private var signedIn = ""
    private var jar = CookieJar()

    init(_ service: Service, session: URLSession? = nil, account: (@Sendable () -> String)? = nil) {
        self.service = service
        self.session = session ?? {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = 20
            return URLSession(configuration: configuration)
        }()
        self.account = account ?? {
            let accounts = (try? CloudDriveAccounts.load()) ?? CloudDriveAccounts()
            return service == .quark ? accounts.quarkCookie : accounts.ucCookie
        }
    }

    private var name: String { service == .quark ? L10n.text("Quark") : "UC" }
    private var api: String { service == .quark ? "https://drive-pc.quark.cn/1/clouddrive" : "https://pc-api.uc.cn/1/clouddrive" }
    private var query: String { service == .quark ? "pr=ucpro&fr=pc&uc_param_str=" : "pr=UCBrowser&fr=pc&uc_param_str=" }
    private var referer: String { service == .quark ? "https://pan.quark.cn/" : "https://drive.uc.cn/" }

    func list(_ folder: String) async throws -> [CloudFile] {
        var files: [CloudFile] = []
        for page in 1...50 {
            let answer = try await call("/file/sort?\(query)&pdir_fid=\(folder)&_page=\(page)&_size=100&_fetch_total=1&_fetch_sub_dirs=0&_sort=file_type:asc,file_name:asc")
            let items = ((answer["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
            files += items.compactMap(Self.file)
            let total = ((answer["metadata"] as? [String: Any])?["_total"] as? Int) ?? files.count
            if items.isEmpty || files.count >= total { break }
        }
        return files
    }

    /// Files and folders anywhere in the drive whose names hold `keywords`, newest first.
    func search(_ keywords: String, page: Int, size: Int) async throws -> (files: [CloudFile], total: Int) {
        let words = keywords.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?#"))) ?? keywords
        let answer = try await call("/file/search?\(query)&q=\(words)&_page=\(page)&_size=\(size)&_fetch_total=1&_sort=file_type:desc,updated_at:desc")
        let files = (((answer["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []).compactMap(Self.file)
        return (files, ((answer["metadata"] as? [String: Any])?["_total"] as? NSNumber)?.intValue ?? files.count)
    }

    static func file(_ item: [String: Any]) -> CloudFile? {
        guard let id = item["fid"] as? String, let name = item["file_name"] as? String else { return nil }
        let updated = (item["updated_at"] as? NSNumber)?.doubleValue
        return CloudFile(id: id, name: name, isFolder: item["dir"] as? Bool ?? false, size: (item["size"] as? NSNumber)?.int64Value ?? 0,
                         modified: updated.map { Date(timeIntervalSince1970: $0 / 1000) })
    }

    /// The original when it plays as stored (MKV and the like through `Remux`), else the drive's transcoded
    /// copy, which is smaller and lower in quality. That copy also stands in for a video the drive won't hand
    /// over as it is: free accounts may not download large files ("download file size limit"), but may play it.
    func stream(_ id: String, name: String) async throws -> URL {
        if CloudFile.playsOriginal(name) {
            do {
                let source = try await original(id, name: name)
                return CloudStreams.register(source) { [self] in try? await original(id, name: name) }
            } catch TVError.unsupported(let reason) where CloudFile.kind(of: name) == .video {
                Diagnostics.shared.record(.info, "files", "\(service) original refused, using the transcoded copy: \(reason)")
            }
        }
        guard CloudFile.kind(of: name) == .video else { throw CloudFilesError.unsupportedFormat((name as NSString).pathExtension) }
        let copy = try await transcoded(id, name: name)
        Diagnostics.shared.record(.info, "files", "\(service) transcoded copy \(copy.source.length) bytes playlist=\(copy.playlist)")
        // Most transcoded copies are HLS (`format: m3u8`): a playlist of segments, not the bytes of one file.
        if copy.playlist { return CloudStreams.registerPlaylist(copy.source.url, headers: copy.source.headers) }
        return CloudStreams.register(copy.source) { [self] in try? await transcoded(id, name: name).source }
    }

    private func original(_ id: String, name: String) async throws -> CloudStreams.Source {
        let answer = try await call("/file/download?\(query)", body: ["fids": [id]])
        guard let item = (answer["data"] as? [[String: Any]])?.first, let address = item["download_url"] as? String,
              let url = URL(string: address), let size = (item["size"] as? NSNumber)?.intValue, size > 0 else {
            throw TVError.unsupported(L10n.text("%@ didn't return a link for this file. Try again.", name))
        }
        return CloudStreams.Source(url: url, headers: cdnHeaders, length: size, name: name)
    }

    /// The best transcoded copy this account may play: free accounts get the lower resolutions.
    private func transcoded(_ id: String, name: String) async throws -> (source: CloudStreams.Source, playlist: Bool) {
        let answer = try await call("/file/v2/play?\(query)", body: ["fid": id, "resolutions": "normal,low,high,super,2k,4k", "supports": "fmp4,m3u8"])
        let videos = ((answer["data"] as? [String: Any])?["video_list"] as? [[String: Any]]) ?? []
        let ranks = ["4k", "2k", "super", "high", "normal", "low"]
        let playable = videos.compactMap { video -> (rank: Int, url: URL, size: Int, playlist: Bool)? in
            guard video["accessable"] as? Bool != false, let info = video["video_info"] as? [String: Any],
                  let address = info["url"] as? String, let url = URL(string: address),
                  let size = (info["size"] as? NSNumber)?.intValue, size > 0 else { return nil }
            let format = ((info["format"] ?? info["file_format"]) as? String)?.lowercased()
            return (ranks.firstIndex(of: video["resolution"] as? String ?? "") ?? ranks.count, url, size,
                    format == "m3u8" || url.pathExtension.lowercased() == "m3u8")
        }
        guard let best = playable.min(by: { $0.rank < $1.rank }) else {
            throw TVError.unsupported(L10n.text("%@ hasn't prepared a version of this video that Apple devices can play.", self.name))
        }
        return (CloudStreams.Source(url: best.url, headers: cdnHeaders, length: best.size,
                                    name: (name as NSString).deletingPathExtension + (best.playlist ? ".m3u8" : ".mp4")), best.playlist)
    }

    private var cdnHeaders: [String: String] { ["Cookie": jar.header, "User-Agent": Self.userAgent, "Referer": referer] }

    private func call(_ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        let saved = account().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !saved.isEmpty else { throw CloudFilesError.signInRequired(name) }
        if saved != signedIn { signedIn = saved; jar = CookieJar(saved) }
        var request = URLRequest(url: URL(string: api + path)!)
        request.setValue(jar.header, forHTTPHeaderField: "Cookie")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse { jar.update(http) }
        let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (answer["code"] as? Int) == 0, (200..<300).contains(status) { return answer }
        let message = answer["message"] as? String ?? ""
        Diagnostics.shared.record(.warning, "files", "\(service) \(path.prefix(while: { $0 != "?" })) status=\(status) code=\(answer["code"] ?? "-") \(message)")
        if status == 401 || (answer["code"] as? Int) == 31001 || message.lowercased().contains("login") {
            throw CloudFilesError.signInRequired(name)
        }
        if !message.isEmpty { throw TVError.unsupported(L10n.text("%@ says: %@", name, message)) }
        throw TVError.http(status)
    }
}

/// Cookies as one `Cookie` header, kept up to date with what responses set.
struct CookieJar: Sendable {
    private var names: [String] = []
    private var values: [String: String] = [:]
    init(_ header: String = "") {
        for part in header.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, !pair[0].isEmpty { set(pair[0], pair[1]) }
        }
    }
    var header: String { names.map { "\($0)=\(values[$0]!)" }.joined(separator: "; ") }
    subscript(name: String) -> String? { values[name] }
    mutating func set(_ name: String, _ value: String) {
        if values[name] == nil { names.append(name) }
        values[name] = value
    }
    mutating func update(_ response: HTTPURLResponse) {
        guard let url = response.url else { return }
        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields { if let key = key as? String, let value = value as? String { fields[key] = value } }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: url) { set(cookie.name, cookie.value) }
    }
}

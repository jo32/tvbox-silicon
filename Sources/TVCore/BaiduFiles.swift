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
        let (data, response) = try await send(url)
        return (data, response.statusCode)
    }

    /// A request with the account's cookies and a caller-chosen method, body and headers. Sharing links need
    /// a few calls the drive's own pages make (`/share/verify`, `/share/list`, `/share/transfer`) with their
    /// own referrer and form bodies; unlike `fetch`, this returns the response so a share page's final URL
    /// (after its redirect to `/share/init`) can be read for the `surl`.
    private func send(_ url: URL, method: String = "GET", body: String? = nil,
                      referer: String? = nil, extraHeaders: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        let saved = account().trimmingCharacters(in: .whitespacesAndNewlines)
        guard saved.contains("BDUSS") else { throw CloudFilesError.signInRequired(name) }
        if saved != signedIn { signedIn = saved; jar = CookieJar(saved) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        var fields = headers
        if let referer = referer { fields["Referer"] = referer }
        for (key, value) in extraHeaders { fields[key] = value }
        for (field, value) in fields { request.setValue(value, forHTTPHeaderField: field) }
        if let body = body {
            request.httpBody = body.data(using: .utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse ?? HTTPURLResponse(url: url, statusCode: 0, httpVersion: nil, headerFields: nil)!
        jar.update(http)
        return (data, http)
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

    // MARK: - Share links

    /// A video inside a share, with the ids the transfer API needs.
    struct SharedVideo {
        let fsID: String
        let name: String
    }

    /// Opens a `pan.baidu.com/s/…` share link and saves its first playable video into the signed-in
    /// account's drive, returning the path of the saved copy (ready for `stream`/`original`). A share is
    /// a folder of someone else's files, so it has to be saved before this account's APIs can stream it.
    /// Already-saved copies are reused, so opening the same line twice never makes duplicates (#2811).
    func saveFirstVideo(from link: BaiduShareLink) async throws -> (path: String, name: String) {
        // A fresh page seeds BAIDUID/csrfToken; its redirect reveals the `surl` verify needs.
        let page = try await loadSharePage(link)
        var shareID = Self.shareValue("shareid", in: page.html)
        var shareUK = Self.shareValue("share_uk", in: page.html)
        var html = page.html

        // The first load is the extraction-code page: it has the ids but no file list, and the
        // permission cookies are missing. Verify the code, then load the page again to list files.
        var sekey = ""
        if !Self.hasFileList(html) {
            let randsk = try await verify(link, surl: page.surl)
            sekey = randsk.removingPercentEncoding ?? randsk
            html = try await loadSharePage(link).html
        } else if let saved = jar["BDCLND"] {
            sekey = saved.removingPercentEncoding ?? saved
        }
        if shareID == nil { shareID = Self.shareValue("shareid", in: html) }
        if shareUK == nil { shareUK = Self.shareValue("share_uk", in: html) }
        guard let sid = shareID, let uk = shareUK else {
            throw TVError.unsupported(L10n.text("Baidu Netdisk didn't return the share's file list. The link may have expired."))
        }

        // Files embedded in the verified page are the share's root; a nested folder is read by /share/list.
        var videos = Self.videos(in: html)
        if videos.isEmpty, let folder = Self.firstFolder(in: html) {
            videos = try await listShare(folder: folder, shareID: sid, shareUK: uk, sekey: sekey)
        }
        guard let video = videos.first else {
            throw TVError.unsupported(L10n.text("This Baidu share has no video Yingxia can play."))
        }

        // Transfers land in a fixed folder; reuse a copy saved from an earlier tap.
        let destination = "/我的资源"
        let target = "\(destination)/\(video.name)"
        let existing = try? await json("/list", [("dir", destination), ("order", "name"), ("desc", "0"),
                                                  ("page", "1"), ("num", "\(Self.pageSize)")])
        if let existing, (existing["list"] as? [[String: Any]])?.contains(where: { Self.file($0)?.name == video.name }) == true {
            Diagnostics.shared.record(.info, "files", "baidu share reusing saved copy \(target)")
            return (target, video.name)
        }

        let saved = try await transfer(video: video, shareID: sid, shareUK: uk, sekey: sekey, to: destination)
        Diagnostics.shared.record(.info, "files", "baidu share saved \(target)")
        return (saved.isEmpty ? target : saved, video.name)
    }

    /// The share page, loaded through the account's cookies. Baidu redirects `/s/<code>?pwd=…` to
    /// `/share/init`; the final URL and the page may carry the ids and the embedded file list.
    private func loadSharePage(_ link: BaiduShareLink) async throws -> (html: String, surl: String) {
        var components = URLComponents(string: "https://pan.baidu.com/s/\(link.code)")!
        components.queryItems = [URLQueryItem(name: "pwd", value: link.password)]
        let referer = components.url!.absoluteString
        let (data, response) = try await send(components.url!, referer: referer)
        let html = String(data: data, encoding: .utf8) ?? ""
        let surl = URLComponents(url: response.url ?? components.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "surl" }?.value ?? link.surl
        return (html, surl)
    }

    /// POST the extraction code. Baidu returns `randsk` and sets BDCLND; the drive's own pages then
    /// read the share's files. errno 105 means a captcha is needed, which can't be solved in the app.
    private func verify(_ link: BaiduShareLink, surl: String) async throws -> String {
        let stamp = Int64(Date().timeIntervalSince1970 * 1000)
        let url = URL(string: "https://pan.baidu.com/share/verify?t=\(stamp)&bioc=1&surl=\(surl)")!
        let body = form([("pwd", link.password), ("vcode", ""), ("vcode_str", "")])
        let referer = "https://pan.baidu.com/share/init?surl=\(surl)&pwd=\(link.password)"
        let (data, _) = try await send(url, method: "POST", body: body, referer: referer,
                                       extraHeaders: ["X-Requested-With": "XMLHttpRequest"])
        let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = Self.number(answer["errno"]) ?? -1
        if code == 0, let randsk = answer["randsk"] as? String, !randsk.isEmpty { return randsk }
        if code == 105 {
            throw TVError.unsupported(L10n.text("Baidu Netdisk asks for a verification code for this share. Open the link in a browser first, then try again."))
        }
        throw TVError.unsupported(L10n.text("Baidu Netdisk didn't accept this share's extraction code."))
    }

    /// List a folder of the share. The parameters mirror the ones the drive's own share page sends.
    private func listShare(folder: String, shareID: String, shareUK: String, sekey: String) async throws -> [SharedVideo] {
        var items: [[String: Any]] = []
        for page in 1...20 {
            let query: [(String, String)] = [("is_from_web", "true"), ("sekey", sekey), ("uk", shareUK),
                                             ("shareid", shareID), ("order", "name"), ("desc", "0"),
                                             ("showempty", "0"), ("view_mode", "1"), ("web", "1"),
                                             ("dir", folder), ("page", "\(page)"), ("num", "1000")]
            let (data, _) = try await send(URL(string: "https://pan.baidu.com/share/list?" + Self.query(query))!,
                                           extraHeaders: ["X-Requested-With": "XMLHttpRequest"])
            let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let code = Self.number(answer["errno"]) ?? -1
            guard code == 0 else {
                if Self.signedOut(code) { throw CloudFilesError.signInRequired(name) }
                throw TVError.unsupported(L10n.text("Baidu Netdisk didn't return this share's files."))
            }
            let rows = answer["list"] as? [[String: Any]] ?? []
            items += rows
            if rows.count < 1000 { break }
        }
        return items.compactMap { item in
            guard Self.number(item["isdir"]) != 1, Self.number(item["category"]) == 1,
                  let name = item["server_filename"] as? String, let fsID = Self.number(item["fs_id"]) else { return nil }
            return SharedVideo(fsID: String(fsID), name: name)
        }
    }

    /// Save a shared video into the account's own drive. `ondup=newcopy` keeps an already-saved file
    /// untouched; `type=1` tells Baidu the destination is the "我的资源" folder.
    private func transfer(video: SharedVideo, shareID: String, shareUK: String, sekey: String, to folder: String) async throws -> String {
        let params: [(String, String)] = [("ondup", "newcopy"), ("async", "1"), ("shareid", shareID),
                                          ("from", shareUK), ("sekey", sekey)]
        let url = URL(string: "https://pan.baidu.com/share/transfer?" + Self.query(params))!
        let body = form([("fsidlist", "[\(video.fsID)]"), ("path", folder),
                         ("type", folder == "/我的资源" ? "1" : "")])
        let (data, _) = try await send(url, method: "POST", body: body, extraHeaders: ["X-Requested-With": "XMLHttpRequest"])
        let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = Self.number(answer["errno"]) ?? -1
        if code == 0 {
            let saved = (answer["extra"] as? [String: Any])?["list"] as? [[String: Any]]
            if let path = saved?.first?["to"] as? String, !path.isEmpty { return path }
            return ""
        }
        if Self.signedOut(code) { throw CloudFilesError.signInRequired(name) }
        let message = answer["show_msg"] as? String ?? answer["errmsg"] as? String
        throw TVError.unsupported(L10n.text("Baidu couldn't save this share to your drive: %@", message ?? L10n.text("try again later")))
    }

    /// Form-encode a request body.
    private func form(_ pairs: [(String, String)]) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return pairs.filter { !$0.1.isEmpty }.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.1)" }
                    .joined(separator: "&")
    }

    /// Percent-encode query values the way the drive's pages do. Values such as `sekey` and folder
    /// paths hold `/`, `+`, `=` and Chinese characters, all of which must be encoded to survive.
    private static func query(_ pairs: [(String, String)]) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return pairs.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.1)" }
                    .joined(separator: "&")
    }

    /// Read a scalar out of the page's `locals` blob (`"shareid":22100766350` or `"share_uk":"…"`).
    private static func shareValue(_ key: String, in html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\"\(key)\"\\s*:\\s*\"?([^\",}]+)\"?"),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        let value = String(html[range]).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// The verified page embeds its root file list as `"file_list":[…]`.
    private static func hasFileList(_ html: String) -> Bool { html.contains("\"file_list\":") }

    /// Videos in the embedded root file list — only files Baidu marks as video (`category: 1`).
    private static func videos(in html: String) -> [SharedVideo] {
        guard let array = jsonArray(after: "\"file_list\":", in: html) else { return [] }
        return array.compactMap { item in
            guard number(item["isdir"]) != 1, number(item["category"]) == 1,
                  let name = item["server_filename"] as? String, let fsID = number(item["fs_id"]) else { return nil }
            return SharedVideo(fsID: String(fsID), name: name)
        }
    }

    /// The first folder in the embedded root list, whose children are read by /share/list.
    private static func firstFolder(in html: String) -> String? {
        guard let array = jsonArray(after: "\"file_list\":", in: html) else { return nil }
        for item in array where number(item["isdir"]) == 1 {
            if let path = item["path"] as? String { return path }
        }
        return nil
    }

    /// Parse the JSON array that follows `marker` in a page, balancing brackets and respecting strings.
    private static func jsonArray(after marker: String, in html: String) -> [[String: Any]]? {
        guard let markerRange = html.range(of: marker),
              let open = html[markerRange.upperBound...].firstIndex(of: "[") else { return nil }
        var depth = 0, inString = false, escaped = false
        var end: String.Index?
        for index in html[open...].indices {
            let character = html[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            if character == "\"" { inString = true }
            else if character == "[" { depth += 1 }
            else if character == "]" {
                depth -= 1
                if depth == 0 { end = html.index(after: index); break }
            }
        }
        guard let stop = end, let data = String(html[open..<stop]).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    }
}

/// A Baidu share link (`pan.baidu.com/s/<code>`, with a `?pwd=` extraction code) as posted by a
/// Telegram channel. Baidu's verify API takes the code without its first character (`surl`).
struct BaiduShareLink {
    let code: String
    let password: String
    var surl: String { code.count > 1 ? String(code.dropFirst()) : code }

    init?(url: URL) {
        let host = url.host()?.lowercased() ?? ""
        guard host == "pan.baidu.com" || host == "yun.baidu.com" || host.hasSuffix(".pan.baidu.com") else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, parts[0] == "s", !parts[1].isEmpty else { return nil }
        code = parts[1]
        password = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "pwd" }?.value ?? ""
    }
}

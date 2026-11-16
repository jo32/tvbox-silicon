import CryptoKit
import Foundation

/// 飞牛影视, the media app of a 飞牛 fnOS NAS, in Cloud Files (#1017): sign in with the fnOS account, browse its
/// libraries as folders (a library's films, series and folders; a series' seasons; a season's episodes), search
/// them for Global Search, and play a file as the NAS stores it through `CloudStreams`.
///
/// The API is the one fnOS's own web app (`/v`) uses. It isn't documented; what is here is what the open-source
/// clients FlyNarwhal (FNOSP/FlyNarwhal), fntv-jellyfin-bridge (notxx) and fnos_tv_danmu (rgcaafe) all send:
/// every request carries `Authx`, a signature of its path and body (`authx`), and, once signed in, the token as
/// `Authorization`; answers are `{code, msg, data}` with code 0 for success. Sign-ins last as long as the app runs.
public actor FnOS {
    public static let shared = FnOS()
    private let session: URLSession
    private var tokens: [String: String] = [:]

    /// The key and secret fnOS's web app signs with, which the clients above sign with too.
    static let apiKey = "NDzZTVxnRKP8Z0jXg1VAMonaG8akvh"
    static let apiSecret = "16CCEB3D-AB42-077D-36A1-F355324E4237"
    /// What a library lists, as fnOS's web app asks for it: films, series, folders and other videos.
    static let itemTypes = ["Movie", "TV", "Directory", "Video"]
    static let pageSize = 100

    init(session: URLSession? = nil) {
        self.session = session ?? {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            return URLSession(configuration: configuration)
        }()
    }

    /// `nonce=…&timestamp=…&sign=…`, where sign is the MD5 of the key, the request's path, the nonce, the time in
    /// milliseconds, the MD5 of what is signed (the JSON body, a GET's query as `name=value`, else nothing) and the
    /// secret, joined by "_".
    static func authx(path: String, signed: Data?, nonce: String = String(Int.random(in: 100_000..<1_000_000)),
                      timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> String {
        let source = [apiKey, path, nonce, String(timestamp), md5(signed ?? Data()), apiSecret].joined(separator: "_")
        return "nonce=\(nonce)&timestamp=\(timestamp)&sign=\(md5(Data(source.utf8)))"
    }

    static func md5(_ data: Data) -> String { Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// The headers of a request to `path`. `mode=relay` is what FN Connect's relay wants, and the NAS itself ignores.
    static func headers(path: String, signed: Data?, token: String?) -> [String: String] {
        var headers = ["Authx": authx(path: path, signed: signed), "Cookie": "mode=relay", "User-Agent": HTTPClient.userAgent,
                       "Accept": "application/json"]
        if let token { headers["Authorization"] = token }
        return headers
    }

    /// The fnOS NAS at `url`, or nil when nothing there answers like 飞牛影视. The address may be the one fnOS opens
    /// at (`http://nas:5666`) or 飞牛影视's own page (`http://nas:5666/v/…`); the API is always at the host's root.
    public static func probe(_ url: URL, session: URLSession = .shared) async -> AListServer? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = url.host(),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? "") else { return nil }
        parts.path = ""; parts.query = nil; parts.fragment = nil; parts.user = nil; parts.password = nil
        let path = "/v/api/v1/sys/config"
        guard let base = parts.string, let endpoint = URL(string: base + path) else { return nil }
        var request = URLRequest(url: endpoint, timeoutInterval: 8)
        headers(path: path, signed: nil, token: nil).forEach { request.setValue($1, forHTTPHeaderField: $0) }
        guard let (data, _) = try? await session.data(for: request),
              let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              answer["code"] is NSNumber, answer["data"] != nil || answer["msg"] != nil else { return nil }
        return AListServer(name: host, address: base, kind: .fnos)
    }

    /// Checks a server before it is saved: the account signs in and its libraries list.
    public func check(_ server: AListServer) async throws {
        tokens[server.id] = try await signIn(server)
        _ = try await list(server, id: server.root)
    }

    /// The root ("/") lists the libraries. Any other folder is named `<type>:<guid>`: a library (`mdb`) lists its
    /// films, series and folders, a folder (`Directory`) what is in it, a series (`TV`) its seasons, or straight
    /// away its episodes when it has one season, and a season its episodes.
    func list(_ server: AListServer, id: String) async throws -> [CloudFile] {
        if id == "/" || id.isEmpty {
            let libraries = try await call(server, "/v/api/v1/mediadb/list") as? [[String: Any]] ?? []
            return libraries.compactMap { library in
                guard let guid = library["guid"] as? String, let title = (library["title"] as? String)?.trimmingCharacters(in: .whitespaces),
                      !title.isEmpty else { return nil }
                return CloudFile(id: "mdb:" + guid, name: title, isFolder: true,
                                 artwork: Self.image((library["posters"] as? [String])?.first, server: server))
            }
        }
        guard let (type, guid) = Self.parse(id) else { return [] }
        switch type {
        case "mdb": return try await items(server, ["ancestor_guid": guid])
        case "Directory": return try await items(server, ["parent_guid": guid])
        case "TV":
            let seasons = try await call(server, "/v/api/v1/season/list/" + guid) as? [[String: Any]] ?? []
            if seasons.count == 1, let only = seasons[0]["guid"] as? String { return try await episodes(server, season: only) }
            return seasons.compactMap { Self.file($0, server: server) }
        case "Season": return try await episodes(server, season: guid)
        default: return []
        }
    }

    /// A library's or folder's items, page by page, as fnOS's web app lists them.
    private func items(_ server: AListServer, _ scope: [String: Any]) async throws -> [CloudFile] {
        var files: [CloudFile] = [], page = 1
        while page <= 50 {
            var body: [String: Any] = ["exclude_grouped_video": 1, "sort_type": "DESC", "sort_column": "create_time",
                                       "page_size": Self.pageSize, "page": page, "tags": ["type": Self.itemTypes]]
            body.merge(scope) { $1 }
            let answer = try await call(server, "/v/api/v1/item/list", body: body) as? [String: Any] ?? [:]
            let list = answer["list"] as? [[String: Any]] ?? []
            files += list.compactMap { Self.file($0, server: server) }
            let total = (answer["total"] as? NSNumber)?.intValue ?? 0
            if list.count < Self.pageSize || page * Self.pageSize >= total { break }
            page += 1
        }
        return files
    }

    private func episodes(_ server: AListServer, season: String) async throws -> [CloudFile] {
        let list = try await call(server, "/v/api/v1/episode/list/" + season) as? [[String: Any]] ?? []
        return list.compactMap { Self.file($0, server: server) }
    }

    /// Films, series and videos whose names hold `term`. fnOS answers a search in one list.
    func search(_ server: AListServer, _ term: String, page: Int, size: Int) async throws -> (files: [CloudFile], total: Int) {
        guard page == 1 else { return ([], 0) }
        let list = try await call(server, "/v/api/v1/search/list", query: ["q": term]) as? [[String: Any]] ?? []
        let files = list.compactMap { Self.file($0, server: server) }
        return (files, files.count)
    }

    /// An item as a file. Series, seasons and folders open as folders. Films, videos and episodes are files whose
    /// name ends in the extension of the file the NAS keeps, when it says, else `.mp4`: the player reads the
    /// container from the file's first bytes, as for Emby. Episodes lead with their number, and films add their year.
    static func file(_ item: [String: Any], server: AListServer) -> CloudFile? {
        guard let guid = item["guid"] as? String, let type = item["type"] as? String else { return nil }
        var name = (item["title"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let artwork = image(item["poster"] as? String ?? (item["poster_list"] as? [String])?.first, server: server)
        switch type {
        case "TV", "Season", "Directory":
            if name.isEmpty, let season = (item["season_number"] as? NSNumber)?.intValue { name = "S\(season)" }
            guard !name.isEmpty else { return nil }
            return CloudFile(id: type + ":" + guid, name: name, isFolder: true, artwork: artwork)
        case "Movie", "Video", "Episode":
            let stored = (item["file_name"] as? String ?? "")
            if name.isEmpty { name = (stored as NSString).deletingPathExtension }
            guard !name.isEmpty else { return nil }
            if type == "Episode", let number = (item["episode_number"] as? NSNumber)?.intValue, number > 0 { name = "\(number). \(name)" }
            if type == "Movie", let date = item["release_date"] as? String, date.count >= 4, !name.contains(date.prefix(4)) {
                name += " (\(date.prefix(4)))"
            }
            let ext = (stored as NSString).pathExtension.lowercased()
            return CloudFile(id: type + ":" + guid, name: name + "." + (ext.isEmpty || ext.count > 5 ? "mp4" : ext), isFolder: false,
                             artwork: artwork)
        default: return nil  // Live channels aren't files.
        }
    }

    /// `<type>:<guid>` split.
    static func parse(_ id: String) -> (type: String, guid: String)? {
        guard let colon = id.firstIndex(of: ":") else { return nil }
        let guid = String(id[id.index(after: colon)...])
        return guid.isEmpty ? nil : (String(id[..<colon]), guid)
    }

    /// A poster's address: fnOS gives the path under its image endpoint, which scales it to the width asked for.
    static func image(_ path: String?, server: AListServer) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("http") { return URL(string: path) }
        let relative = path.hasPrefix("/v/api/") ? path : "/v/api/v1/sys/img" + (path.hasPrefix("/") ? path : "/" + path)
        return URL(string: server.address + relative + (relative.contains("?") ? "" : "?w=400"))
    }

    func stream(_ server: AListServer, id: String, name: String) async throws -> URL {
        let source = try await source(server, id: id, name: name)
        guard CloudFile.playsOriginal(source.name) else { throw CloudFilesError.unsupportedFormat((source.name as NSString).pathExtension) }
        return CloudStreams.register(source) { [self] in try? await self.source(server, id: id, name: name) }
    }

    /// The file as the NAS stores it (`media/range`, which answers ranges only), each range signed afresh. The
    /// item's first file is the one played, as fnOS's web app starts it.
    func source(_ server: AListServer, id: String, name: String) async throws -> CloudStreams.Source {
        guard let guid = Self.parse(id)?.guid ?? (id.contains(":") ? nil : id) else { throw TVError.invalidURL }
        let streams = try await call(server, "/v/api/v1/stream/list/" + guid) as? [String: Any] ?? [:]
        let files = streams["files"] as? [[String: Any]] ?? []
        guard let file = files.first(where: { ($0["can_play"] as? NSNumber)?.intValue != 0 }) ?? files.first,
              let media = file["guid"] as? String else {
            throw TVError.unsupported(L10n.text("%@ didn't return a link for this file. Try again.", server.name))
        }
        let path = "/v/api/v1/media/range/" + media
        guard let url = URL(string: server.address + path), let token = tokens[server.id] else { throw TVError.invalidURL }
        let stored = file["file_name"] as? String ?? ""
        return CloudStreams.Source(url: url, headers: Self.headers(path: path, signed: nil, token: token),
                                   length: (file["size"] as? NSNumber)?.intValue ?? 0, name: stored.isEmpty ? name : stored,
                                   freshHeaders: { _ in ["Authx": Self.authx(path: path, signed: nil)] })
    }

    /// Calls the API with the account's token, signing in first, and again, once, when the NAS no longer takes it.
    /// A GET's `query` is signed as `name=value` pairs in name order; a POST's JSON body as it is sent.
    private func call(_ server: AListServer, _ path: String, query: [String: String] = [:], body: [String: Any]? = nil,
                      retry: Bool = true) async throws -> Any {
        let token: String
        if let saved = tokens[server.id] { token = saved } else {
            token = try await signIn(server)
            tokens[server.id] = token
        }
        guard var parts = URLComponents(string: server.address + path) else { throw TVError.invalidURL }
        let pairs = query.sorted { $0.key < $1.key }
        if !pairs.isEmpty { parts.queryItems = pairs.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = parts.url else { throw TVError.invalidURL }
        var request = URLRequest(url: url)
        var signed = pairs.isEmpty ? nil : Data(pairs.map { "\($0.key)=\($0.value)" }.joined(separator: "&").utf8)
        if let body {
            let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
            request.httpMethod = "POST"; request.httpBody = data; signed = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        Self.headers(path: path, signed: signed, token: token).forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = (answer?["code"] as? NSNumber)?.intValue, message = answer?["msg"] as? String ?? ""
        if code == 0 { return answer?["data"] ?? NSNull() }
        // The token expired, or the NAS restarted: sign in again, once. A signature it refused (two requests in the
        // same millisecond with the same nonce), or a search it was too busy for (-2): once more, signed afresh.
        let transient = message == "invalid sign" || code == -2
        if retry, transient || status == 401 || code == 401 || code == 403 {
            if !transient { tokens[server.id] = nil }
            return try await call(server, path, query: query, body: body, retry: false)
        }
        Diagnostics.shared.record(.warning, "files", "fnos \(path) status=\(status) code=\(code.map(String.init) ?? "-") \(message)")
        guard let code else { throw TVError.http(status) }
        throw TVError.unsupported(message.isEmpty ? L10n.text("The server returned HTTP %lld.", code) : L10n.text("%@ says: %@", server.name, message))
    }

    /// Signs in as fnOS's web app does, with the fnOS account's user name and password.
    private func signIn(_ server: AListServer) async throws -> String {
        guard !server.username.isEmpty else { throw CloudFilesError.signInRequired(server.name) }
        let path = "/v/api/v1/login"
        guard let url = URL(string: server.address + path) else { throw TVError.invalidURL }
        let body = try JSONSerialization.data(withJSONObject: ["app_name": "trimemedia-web", "username": server.username,
                                                               "password": server.password], options: [.sortedKeys, .withoutEscapingSlashes])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        Self.headers(path: path, signed: body, token: nil).forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (answer?["code"] as? NSNumber)?.intValue == 0, let token = (answer?["data"] as? [String: Any])?["token"] as? String,
              !token.isEmpty else {
            Diagnostics.shared.record(.warning, "files", "fnos sign-in status=\(status) code=\(answer?["code"] ?? "-") \(answer?["msg"] ?? "")")
            if answer == nil { throw TVError.http(status) }
            throw TVError.unsupported(L10n.text("%@ didn't accept the user name and password.", server.name))
        }
        return token
    }
}

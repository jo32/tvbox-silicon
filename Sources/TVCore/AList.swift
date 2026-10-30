import Foundation

/// An AList (or OpenList) server, a WebDAV share or an Emby or Jellyfin server in Cloud Files: where
/// its API lives, the folder browsing starts in, and the account and folder password it may need.
/// Kept beside the cloud-drive accounts.
public struct AListServer: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// Where the API lives: the server's address, with the path it is served under, if any.
    public var address: String
    /// The folder browsing starts in.
    public var root: String
    public var username: String
    public var password: String
    /// Sent with every request, as TVBox AList configurations do, for servers whose files sit
    /// behind one folder password.
    public var folderPassword: String
    /// What answers at `address`. Nil in servers saved before WebDAV shares could be added, which are all AList.
    public var kind: Kind?
    public enum Kind: String, Codable, Sendable { case alist, webdav, emby }
    public var isWebDAV: Bool { kind == .webdav }
    /// An Emby or Jellyfin server: its folders are libraries and items, named by their ids.
    public var isEmby: Bool { kind == .emby }

    public init(id: String = UUID().uuidString, name: String, address: String, root: String = "/",
                username: String = "", password: String = "", folderPassword: String = "", kind: Kind? = nil) {
        self.id = id; self.name = name; self.address = address; self.root = root
        self.username = username; self.password = password; self.folderPassword = folderPassword; self.kind = kind
    }

    /// The servers a TVBox AList configuration lists (`[{name, server, password, path, login}]`,
    /// also wrapped as `{"drives": [...]}`), as FongMi's AList spider reads it: the API is at the
    /// server's host, and `path`, else the server address's own path, is where browsing starts.
    public static func list(from data: Data) -> [AListServer]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        // A subscription that also lists drives stays a subscription.
        let wrapper = (json as? [String: Any]).flatMap { $0["sites"] == nil && $0["lives"] == nil ? $0 : nil }
        let entries = json as? [[String: Any]] ?? wrapper?["drives"] as? [[String: Any]]
        let servers = (entries ?? []).compactMap { entry -> AListServer? in
            guard let text = entry["server"] as? String, let url = try? WebAddress.resolve(text),
                  var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            let path = (entry["path"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? parts.path
            parts.path = ""; parts.query = nil; parts.fragment = nil
            guard let address = parts.string else { return nil }
            let login = entry["login"] as? [String: Any]
            return AListServer(name: (entry["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url.host() ?? text, address: address,
                               root: Self.folder(path), username: login?["username"] as? String ?? "", password: login?["password"] as? String ?? "",
                               folderPassword: entry["password"] as? String ?? "")
        }
        return servers.isEmpty ? nil : servers
    }

    /// "/" or "/a/b", without a trailing slash.
    static func folder(_ path: String) -> String {
        let parts = path.split(separator: "/").map { $0.removingPercentEncoding ?? String($0) }
        return "/" + parts.joined(separator: "/")
    }
}

/// The saved AList servers. A file beside the cloud-drive accounts, readable only by the app: it
/// can hold the servers' passwords.
public enum AListServers {
    static var fileURL: URL { CloudDriveAccounts.fileURL.deletingLastPathComponent().appendingPathComponent("alist.json") }
    #if os(tvOS)
    private static let defaultsKey = "alistServers"
    #endif

    public static func load() -> [AListServer] {
        if let data = try? Data(contentsOf: fileURL) { return (try? JSONDecoder().decode([AListServer].self, from: data)) ?? [] }
        #if os(tvOS)
        // tvOS may purge Caches; the copy in user defaults brings the list back.
        if let data = UserDefaults.standard.data(forKey: defaultsKey), let servers = try? JSONDecoder().decode([AListServer].self, from: data) {
            try? save(servers)
            return servers
        }
        #endif
        return []
    }

    public static func save(_ servers: [AListServer]) throws {
        let data = try JSONEncoder().encode(servers)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        #if os(tvOS)
        UserDefaults.standard.set(data, forKey: defaultsKey)
        #endif
    }

    /// Adds servers, or updates the saved one at the same address and folder. Returns the servers as saved.
    @discardableResult
    public static func add(_ servers: [AListServer]) throws -> [AListServer] {
        var saved = load(), result: [AListServer] = []
        for var server in servers {
            if let index = saved.firstIndex(where: { $0.address == server.address && $0.root == server.root }) {
                server.id = saved[index].id
                saved[index] = server
            } else { saved.append(server) }
            result.append(server)
        }
        try save(saved)
        return result
    }

    public static func update(_ server: AListServer) throws {
        var saved = load()
        guard let index = saved.firstIndex(where: { $0.id == server.id }) else { return }
        saved[index] = server
        try save(saved)
    }

    public static func remove(_ id: String) throws {
        try save(load().filter { $0.id != id })
    }
}

/// The AList v3 API (OpenList keeps it): `/api/fs/list` and `/api/fs/get`, as a guest or with the
/// token `/api/auth/login` gives. Tokens and folder passwords last as long as the app runs.
public actor AList {
    public static let shared = AList()
    private let session: URLSession
    private var tokens: [String: String] = [:]
    /// Folder passwords entered while browsing, by server and folder; subfolders use them too.
    private var passwords: [String: [String: String]] = [:]

    init(session: URLSession? = nil) {
        self.session = session ?? {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            return URLSession(configuration: configuration)
        }()
    }

    /// The AList server at `url`, or nil when nothing there answers like one. The API may be served
    /// under a path (`https://host/alist`); what follows it is the folder to start in.
    public static func probe(_ url: URL, session: URLSession = .shared) async -> AListServer? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), url.host() != nil else { return nil }
        let segments = parts.path.split(separator: "/").map(String.init)
        parts.query = nil; parts.fragment = nil
        for depth in 0...min(segments.count, 2) {
            parts.path = segments.prefix(depth).map { "/" + $0 }.joined()
            guard let base = parts.string, let endpoint = URL(string: base + "/api/public/settings") else { continue }
            var request = URLRequest(url: endpoint, timeoutInterval: 8)
            request.setValue(HTTPClient.userAgent, forHTTPHeaderField: "User-Agent")
            guard let (data, _) = try? await session.data(for: request),
                  let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  answer["code"] as? Int == 200, let settings = answer["data"] as? [String: Any] else { continue }
            let title = (settings["site_title"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            return AListServer(name: title.isEmpty || ["AList", "OpenList"].contains(title) ? url.host() ?? title : title,
                               address: base, root: AListServer.folder(segments.dropFirst(depth).joined(separator: "/")))
        }
        return nil
    }

    /// Checks a server before it is saved: its root lists with the account given.
    public func check(_ server: AListServer) async throws {
        tokens[server.id] = server.username.isEmpty ? nil : try await login(server)
        _ = try await list(server, path: server.root, password: nil)
    }

    func list(_ server: AListServer, path: String, password: String?) async throws -> [CloudFile] {
        if let password { passwords[server.id, default: [:]][path] = password }
        let data = try await call(server, "/api/fs/list", ["path": path, "password": folderPassword(server, path), "page": 1, "per_page": 0, "refresh": false])
        let items = data["content"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            let modified = (item["modified"] as? String).flatMap(Self.date)
            return CloudFile(id: (path == "/" ? "" : path) + "/" + name, name: name, isFolder: item["is_dir"] as? Bool ?? false,
                             size: (item["size"] as? NSNumber)?.int64Value ?? 0, modified: modified)
        }
    }

    func stream(_ server: AListServer, path: String, name: String) async throws -> URL {
        guard CloudFile.playsOriginal(name) else { throw CloudFilesError.unsupportedFormat((name as NSString).pathExtension) }
        let source = try await link(server, path: path, name: name)
        // A playlist, or a file whose size the server doesn't know, plays from its link as it is.
        if (name as NSString).pathExtension.lowercased() == "m3u8" || source.length <= 0 { return source.url }
        return CloudStreams.register(source) { [self] in try? await link(server, path: path, name: name) }
    }

    /// The file's link: the storage's own (`raw_url`), else the server's download address.
    func link(_ server: AListServer, path: String, name: String) async throws -> CloudStreams.Source {
        let folder = (path as NSString).deletingLastPathComponent
        let data = try await call(server, "/api/fs/get", ["path": path, "password": folderPassword(server, folder)])
        let size = (data["size"] as? NSNumber)?.intValue ?? 0
        var address = (data["raw_url"] as? String).flatMap(URL.init(string:))
        if address?.scheme?.hasPrefix("http") != true {
            var download = URLComponents(string: server.address)!
            download.path += "/d" + path
            if let sign = data["sign"] as? String, !sign.isEmpty { download.queryItems = [URLQueryItem(name: "sign", value: sign)] }
            address = download.url
        }
        guard let url = address.map({ Self.reachable($0, server: server) }) else {
            throw TVError.unsupported(L10n.text("%@ didn't return a link for this file. Try again.", server.name))
        }
        // Baidu's servers only answer its own client; FongMi's AList spider sends the same.
        let headers = url.host()?.contains("baidupcs.com") == true ? ["User-Agent": "pan.baidu.com"] : [:]
        return CloudStreams.Source(url: url, headers: headers, length: size, name: name)
    }

    /// A server that doesn't know its public address names itself `localhost` in links; those go
    /// to the address the server was added with.
    static func reachable(_ link: URL, server: AListServer) -> URL {
        guard ["localhost", "127.0.0.1", "0.0.0.0", "::1"].contains(link.host() ?? ""),
              let base = URLComponents(string: server.address), let host = base.host,
              !["localhost", "127.0.0.1"].contains(host),
              var parts = URLComponents(url: link, resolvingAgainstBaseURL: false) else { return link }
        parts.scheme = base.scheme; parts.host = host; parts.port = base.port
        return parts.url ?? link
    }

    private func folderPassword(_ server: AListServer, _ path: String) -> String {
        let saved = passwords[server.id] ?? [:]
        var folder = path
        while true {
            if let password = saved[folder] { return password }
            if folder == "/" || folder.isEmpty { return server.folderPassword }
            folder = (folder as NSString).deletingLastPathComponent
        }
    }

    private func call(_ server: AListServer, _ endpoint: String, _ body: [String: Any], retry: Bool = true) async throws -> [String: Any] {
        guard let url = URL(string: server.address + endpoint) else { throw TVError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(HTTPClient.userAgent, forHTTPHeaderField: "User-Agent")
        if let token = tokens[server.id] { request.setValue(token, forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw TVError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let code = answer["code"] as? Int ?? 0, message = answer["message"] as? String ?? ""
        if code == 200 { return answer["data"] as? [String: Any] ?? [:] }
        Diagnostics.shared.record(.warning, "files", "alist \(endpoint) code=\(code) \(message)")
        // A guest that may not browse, or a token that has expired: sign in, once.
        if code == 401 {
            guard retry, !server.username.isEmpty else { throw CloudFilesError.signInRequired(server.name) }
            tokens[server.id] = try await login(server)
            return try await call(server, endpoint, body, retry: false)
        }
        if code == 403, message.lowercased().contains("password") { throw CloudFilesError.passwordRequired }
        throw TVError.unsupported(message.isEmpty ? L10n.text("The server returned HTTP %lld.", code) : L10n.text("%@ says: %@", server.name, message))
    }

    private func login(_ server: AListServer) async throws -> String {
        var request = URLRequest(url: URL(string: server.address + "/api/auth/login")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["username": server.username, "password": server.password])
        let (data, _) = try await session.data(for: request)
        let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard answer?["code"] as? Int == 200, let token = (answer?["data"] as? [String: Any])?["token"] as? String, !token.isEmpty else {
            Diagnostics.shared.record(.warning, "files", "alist login code=\(answer?["code"] ?? "-") \(answer?["message"] ?? "")")
            throw TVError.unsupported(L10n.text("%@ didn't accept the user name and password.", server.name))
        }
        return token
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

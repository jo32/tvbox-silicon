import Foundation

/// Emby and Jellyfin media servers in Cloud Files. Jellyfin began as a fork of Emby and keeps its
/// API, so one client serves both: sign in with the account (`/Users/AuthenticateByName`), browse the
/// user's libraries and their items as folders, and play a file as the server stores it
/// (`/Videos/{id}/stream?static=true`) through `CloudStreams`, with the server's posters beside the names.
/// Sign-ins last as long as the app runs; an expired one signs in again, once.
public actor Emby {
    public static let shared = Emby()
    private let session: URLSession
    private var signIns: [String: SignIn] = [:]

    struct SignIn: Equatable { var token: String; var user: String }

    init(session: URLSession? = nil) {
        self.session = session ?? {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            return URLSession(configuration: configuration)
        }()
    }

    /// The Emby or Jellyfin server at `url`, or nil when nothing there answers like one. The address
    /// may be the one the web app opens at (`http://nas:8096/web/index.html#!/home`), or have the
    /// path a reverse proxy serves the server under (`https://host/emby`).
    public static func probe(_ url: URL, session: URLSession = .shared) async -> AListServer? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = url.host(),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? "") else { return nil }
        var segments = parts.path.split(separator: "/").map(String.init)
        if let web = segments.firstIndex(where: { $0.lowercased() == "web" }) { segments.removeSubrange(web...) }
        parts.path = segments.map { "/" + $0 }.joined()
        parts.query = nil; parts.fragment = nil; parts.user = nil; parts.password = nil
        guard let base = parts.string, let endpoint = URL(string: base + "/System/Info/Public") else { return nil }
        var request = URLRequest(url: endpoint, timeoutInterval: 8)
        request.setValue(HTTPClient.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await session.data(for: request),
              let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              info["Id"] is String, info["Version"] is String else { return nil }
        let name = (info["ServerName"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return AListServer(name: name.isEmpty ? host : name, address: base, kind: .emby)
    }

    /// Checks a server before it is saved: the account signs in and its libraries list.
    public func check(_ server: AListServer) async throws {
        signIns[server.id] = try await signIn(server)
        _ = try await list(server, id: server.root)
    }

    /// The root ("/") lists the user's libraries; any other folder is an item whose children list:
    /// a library's films or series, a series' seasons, a season's episodes.
    func list(_ server: AListServer, id: String) async throws -> [CloudFile] {
        let answer: Any
        if id == "/" {
            answer = try await call(server) { "/Users/\($0)/Views" }
        } else {
            answer = try await call(server, query: ["ParentId": id, "Fields": "Path", "SortBy": "SortName"]) { "/Users/\($0)/Items" }
        }
        let items = (answer as? [String: Any])?["Items"] as? [[String: Any]] ?? []
        return items.compactMap { Self.file($0, server: server) }
    }

    /// An item as a file: folders by their name, and media by a name ending in the extension of
    /// the file the server keeps, which says how it plays. Episodes lead with their number so the
    /// season lists in order.
    static func file(_ item: [String: Any], server: AListServer) -> CloudFile? {
        guard let id = item["Id"] as? String, var name = (item["Name"] as? String)?.trimmingCharacters(in: .whitespaces),
              !name.isEmpty, item["CollectionType"] as? String != "livetv" else { return nil }
        let isFolder = item["IsFolder"] as? Bool ?? false
        let source = (item["MediaSources"] as? [[String: Any]])?.first
        if !isFolder {
            if item["Type"] as? String == "Episode", let number = item["IndexNumber"] as? Int { name = "\(number). \(name)" }
            if item["Type"] as? String == "Movie", let year = item["ProductionYear"] as? Int, !name.contains(String(year)) { name += " (\(year))" }
            if let type = Self.type(path: source?["Path"] as? String ?? item["Path"] as? String,
                                    container: source?["Container"] as? String ?? item["Container"] as? String) { name += "." + type }
        }
        var artwork: URL?
        if let tag = (item["ImageTags"] as? [String: Any])?["Primary"] as? String,
           var image = URLComponents(string: server.address + "/Items/\(id)/Images/Primary") {
            image.queryItems = [URLQueryItem(name: "tag", value: tag), URLQueryItem(name: "maxHeight", value: "240")]
            artwork = image.url
        }
        return CloudFile(id: id, name: name, isFolder: isFolder, size: (source?["Size"] as? NSNumber)?.int64Value ?? 0, artwork: artwork)
    }

    /// The extension of the file the server keeps, else one for the container it names (Jellyfin
    /// names an MP4's as FFmpeg does, "mov,mp4,m4a,3gp,3g2,mj2").
    static func type(path: String?, container: String?) -> String? {
        let type = ((path ?? "") as NSString).pathExtension.lowercased()
        if !type.isEmpty, type.count <= 5, type != "strm" { return type }
        let names = (container ?? "").lowercased().split(separator: ",").map(String.init)
        if names.contains("mp4") { return "mp4" }
        guard let first = names.first else { return nil }
        return ["matroska": "mkv", "mpegts": "ts", "mpeg": "mpg"][first] ?? first
    }

    func stream(_ server: AListServer, id: String, name: String) async throws -> URL {
        guard CloudFile.playsOriginal(name) else { throw CloudFilesError.unsupportedFormat((name as NSString).pathExtension) }
        let source = try await source(server, id: id, name: name)
        // A playlist, or a file whose size the server doesn't tell, plays from its address as it is,
        // with the token in it: AVPlayer can't send headers.
        if (name as NSString).pathExtension.lowercased() == "m3u8" || source.length <= 0 {
            guard let token = signIns[server.id]?.token, var parts = URLComponents(url: source.url, resolvingAgainstBaseURL: false) else { return source.url }
            parts.queryItems = (parts.queryItems ?? []) + [URLQueryItem(name: "api_key", value: token)]
            return parts.url ?? source.url
        }
        return CloudStreams.register(source) { [self] in try? await self.source(server, id: id, name: name) }
    }

    /// The file as the server stores it, read by ranges with the sign-in's token.
    func source(_ server: AListServer, id: String, name: String) async throws -> CloudStreams.Source {
        let item = try await call(server) { "/Users/\($0)/Items/\(id)" } as? [String: Any] ?? [:]
        let media = (item["MediaSources"] as? [[String: Any]])?.first
        let audio = item["MediaType"] as? String == "Audio" || CloudFile.kind(of: name) == .audio
        guard var address = URLComponents(string: server.address + (audio ? "/Audio/" : "/Videos/") + id + "/stream") else { throw TVError.invalidURL }
        address.queryItems = [URLQueryItem(name: "static", value: "true")]
        if let source = media?["Id"] as? String { address.queryItems?.append(URLQueryItem(name: "MediaSourceId", value: source)) }
        guard let url = address.url, let signIn = signIns[server.id] else { throw TVError.invalidURL }
        return CloudStreams.Source(url: url, headers: Self.headers(server, token: signIn.token),
                                   length: (media?["Size"] as? NSNumber)?.intValue ?? 0, name: name)
    }

    /// GETs an endpoint of the signed-in user (`path` is given the user's id), signing in first, and
    /// again, once, when the server no longer takes the token.
    private func call(_ server: AListServer, query: [String: String] = [:], retry: Bool = true,
                      _ path: (String) -> String) async throws -> Any {
        let signIn: SignIn
        if let saved = signIns[server.id] { signIn = saved } else {
            signIn = try await self.signIn(server)
            signIns[server.id] = signIn
        }
        guard var parts = URLComponents(string: server.address + path(signIn.user)) else { throw TVError.invalidURL }
        if !query.isEmpty { parts.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = parts.url else { throw TVError.invalidURL }
        var request = URLRequest(url: url)
        Self.headers(server, token: signIn.token).forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401, retry {
            signIns[server.id] = nil
            return try await call(server, query: query, retry: false, path)
        }
        guard (200..<300).contains(status), let answer = try? JSONSerialization.jsonObject(with: data) else {
            Diagnostics.shared.record(.warning, "files", "emby GET status=\(status)")
            throw TVError.http(status)
        }
        return answer
    }

    private func signIn(_ server: AListServer) async throws -> SignIn {
        guard !server.username.isEmpty else { throw CloudFilesError.signInRequired(server.name) }
        guard let url = URL(string: server.address + "/Users/AuthenticateByName") else { throw TVError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        Self.headers(server, token: nil).forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["Username": server.username, "Pw": server.password])
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status), let token = answer?["AccessToken"] as? String, !token.isEmpty,
              let user = (answer?["User"] as? [String: Any])?["Id"] as? String else {
            Diagnostics.shared.record(.warning, "files", "emby sign-in status=\(status)")
            if status == 401 || status == 403 || (200..<300).contains(status) {
                throw TVError.unsupported(L10n.text("%@ didn't accept the user name and password.", server.name))
            }
            throw TVError.http(status)
        }
        return SignIn(token: token, user: user)
    }

    /// Who is asking, as both servers want it: Emby reads `X-Emby-Authorization`, Jellyfin
    /// `Authorization`. The device id is the server's entry in Cloud Files, so the server keeps one
    /// device for the app however often it signs in.
    static func headers(_ server: AListServer, token: String?) -> [String: String] {
        #if os(tvOS)
        let device = "Apple TV"
        #elseif os(iOS)
        let device = "iPhone"
        #else
        let device = "Mac"
        #endif
        let version = ErrorReports.bundleValue("CFBundleShortVersionString")
        var fields = [#"Client="Yingxia""#, #"Device="\#(device)""#, #"DeviceId="yingxia-\#(server.id)""#,
                      #"Version="\#(version)""#]
        if let token { fields.append(#"Token="\#(token)""#) }
        let authorization = "MediaBrowser " + fields.joined(separator: ", ")
        var headers = ["X-Emby-Authorization": authorization, "Authorization": authorization, "User-Agent": HTTPClient.userAgent]
        if let token { headers["X-Emby-Token"] = token }
        return headers
    }
}

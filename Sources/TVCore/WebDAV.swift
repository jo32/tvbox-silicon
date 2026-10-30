import Foundation

/// WebDAV shares in Cloud Files: the file server a NAS turns on (Synology, QNAP, 极空间, 绿联, ...),
/// rclone, or AList's own `/dav`. Folders list with PROPFIND; files play through `CloudStreams` by
/// ranged reads. The account goes with every request as Basic authentication.
public actor WebDAV {
    public static let shared = WebDAV()
    private let session: URLSession

    init(session: URLSession? = nil) {
        self.session = session ?? {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            return URLSession(configuration: configuration)
        }()
    }

    /// The WebDAV share at `url`, or nil when nothing there answers PROPFIND. The share is the
    /// address's server; its path is the folder to start in. Throws when the share wants an account
    /// and none, or a wrong one, was given.
    public func probe(_ url: URL, username: String = "", password: String = "") async throws -> AListServer? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = url.host(),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? "") else { return nil }
        let root = AListServer.folder(parts.percentEncodedPath)
        parts.percentEncodedPath = ""; parts.query = nil; parts.fragment = nil; parts.user = nil; parts.password = nil
        guard let address = parts.string else { return nil }
        let server = AListServer(name: host, address: address, root: root, username: username, password: password, kind: .webdav)
        guard let status = try? await propfind(server, path: root, folder: true, depth: 0).0 else { return nil }
        if status == 401 { throw refusal(server) }
        return status == 207 ? server : nil
    }

    /// Checks a share before it is saved: its root lists with the account given.
    public func check(_ server: AListServer) async throws {
        _ = try await list(server, path: server.root)
    }

    func list(_ server: AListServer, path: String) async throws -> [CloudFile] {
        let folder = AListServer.folder(path)
        return try await entries(server, path: folder, folder: true, depth: 1).compactMap { entry in
            let path = AListServer.folder(entry.path)
            // The folder answers for itself too.
            guard path != folder, let name = path.split(separator: "/").last.map(String.init) else { return nil }
            return CloudFile(id: path, name: name, isFolder: entry.isFolder, size: entry.size, modified: entry.modified)
        }
    }

    func stream(_ server: AListServer, path: String, name: String) async throws -> URL {
        guard CloudFile.playsOriginal(name) else { throw CloudFilesError.unsupportedFormat((name as NSString).pathExtension) }
        let source = try await source(server, path: path, name: name)
        // A playlist, or a file whose size the share doesn't tell, plays from its address as it is.
        if (name as NSString).pathExtension.lowercased() == "m3u8" || source.length <= 0 {
            guard var parts = URLComponents(url: source.url, resolvingAgainstBaseURL: false) else { return source.url }
            if !server.username.isEmpty { parts.user = server.username; parts.password = server.password }
            return parts.url ?? source.url
        }
        return CloudStreams.register(source) { [self] in try? await self.source(server, path: path, name: name) }
    }

    func source(_ server: AListServer, path: String, name: String) async throws -> CloudStreams.Source {
        let size = try await entries(server, path: path, folder: false, depth: 0).first?.size ?? 0
        return CloudStreams.Source(url: try Self.url(server, path: path, folder: false), headers: Self.headers(server), length: Int(size), name: name)
    }

    private func entries(_ server: AListServer, path: String, folder: Bool, depth: Int) async throws -> [Entry] {
        let (status, data) = try await propfind(server, path: path, folder: folder, depth: depth)
        if status == 207 { return Self.entries(data) }
        Diagnostics.shared.record(.warning, "files", "webdav PROPFIND status=\(status)")
        if status == 401 { throw refusal(server) }
        throw TVError.http(status)
    }

    private func refusal(_ server: AListServer) -> Error {
        server.username.isEmpty ? CloudFilesError.signInRequired(server.name)
            : TVError.unsupported(L10n.text("%@ didn't accept the user name and password.", server.name))
    }

    private func propfind(_ server: AListServer, path: String, folder: Bool, depth: Int) async throws -> (Int, Data) {
        var request = URLRequest(url: try Self.url(server, path: path, folder: folder))
        request.httpMethod = "PROPFIND"
        request.setValue(String(depth), forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(HTTPClient.userAgent, forHTTPHeaderField: "User-Agent")
        Self.headers(server).forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = Data(#"<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>"#.utf8)
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    /// The share's address for `path`, each name percent-encoded; a folder's ends in a slash, as
    /// servers redirect to that address otherwise.
    static func url(_ server: AListServer, path: String, folder: Bool) throws -> URL {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let names = path.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: unreserved) ?? String($0) }
        let encoded = names.map { "/" + $0 }.joined() + (folder ? "/" : "")
        guard let url = URL(string: server.address + (encoded.isEmpty ? "/" : encoded)) else { throw TVError.invalidURL }
        return url
    }

    static func headers(_ server: AListServer) -> [String: String] {
        guard !server.username.isEmpty else { return [:] }
        return ["Authorization": "Basic " + Data("\(server.username):\(server.password)".utf8).base64EncodedString()]
    }

    struct Entry: Equatable {
        /// The `href`'s path, as the server sent it (usually percent-encoded).
        var path = ""
        var isFolder = false
        var size: Int64 = 0
        var modified: Date?
    }

    /// The entries of a PROPFIND answer (a `multistatus`), whatever prefixes its namespaces use.
    static func entries(_ data: Data) -> [Entry] {
        let reader = MultistatusReader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = reader
        parser.parse()
        return reader.entries
    }
}

private final class MultistatusReader: NSObject, XMLParserDelegate {
    var entries: [WebDAV.Entry] = []
    private var entry: WebDAV.Entry?
    private var text = ""
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if name == "response" { entry = WebDAV.Entry() }
        if name == "collection" { entry?.isFolder = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "href" where entry?.path.isEmpty == true:
            // An absolute address or a path; only the path names the file.
            var path = value
            if let scheme = path.range(of: "://") {
                path = path[scheme.upperBound...].firstIndex(of: "/").map { String(path[$0...]) } ?? "/"
            }
            entry?.path = path
        case "getcontentlength": if let size = Int64(value) { entry?.size = size }
        case "getlastmodified": entry?.modified = dateFormatter.date(from: value)
        case "response":
            if let entry, !entry.path.isEmpty { entries.append(entry) }
            entry = nil
        default: break
        }
    }
}

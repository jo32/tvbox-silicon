import Foundation

/// Live playlists that TVBox configurations point at the Android player's own local server. FongMi and takagen99
/// TVBox serve `http://127.0.0.1:9978/proxy?…` (written `proxy://…` too): `do=live&type=txt&ext=<base64 address>`
/// (or `url=<address>`) fetches that playlist, and any other `do=` goes to the configuration's spider
/// (`com.github.catvod.spider.Proxy.proxy`). Nothing listens there on Apple devices, or only the plugin runtime's
/// stand-in while a JAR source is open, so the app reads these addresses itself.
public enum LoopbackPlaylist {
    public enum Route: Equatable, Sendable {
        /// The playlist the address names.
        case playlist(URL)
        /// `ext` held the playlist itself.
        case text(String)
        /// The configuration's spider answers this `/proxy` query.
        case spider(query: String)
        /// `/file/…` or `clan://`: a file in the Android device's own storage.
        case deviceFile
    }

    /// The port Android TVBox players serve on, for `proxy://` addresses.
    static let androidPort = 9978

    /// `proxy://do=live&…` as the `http://127.0.0.1:9978/proxy?do=live&…` it stands for; any other text as it is.
    public static func normalize(_ address: String) -> String {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.lowercased().hasPrefix("proxy://") else { return text }
        return "http://127.0.0.1:\(androidPort)/proxy?" + text.dropFirst("proxy://".count)
    }

    /// 127.x.x.x, localhost, 0.0.0.0 or ::1: this device, where Android players run their server.
    public static func isLoopback(_ url: URL) -> Bool {
        guard url.scheme == "http" || url.scheme == "https", let host = url.host(percentEncoded: false)?.lowercased() else { return false }
        if ["localhost", "0.0.0.0", "::1", "[::1]"].contains(host) { return true }
        return host.range(of: #"^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$"#, options: .regularExpression) != nil
    }

    /// How to read a loopback playlist address, or nil for any other address (and loopback paths these players
    /// don't serve, which are fetched as they are).
    public static func route(_ url: URL) -> Route? {
        guard isLoopback(url) else { return nil }
        let path = url.path(percentEncoded: false)
        if path.hasPrefix("/file/") { return .deviceFile }
        guard path == "/proxy" || path == "/proxy/" else { return nil }
        let query = url.query(percentEncoded: true) ?? ""
        let items = parameters(query)
        guard items.first(where: { $0.name == "do" })?.value == "live" else { return .spider(query: query) }
        if var ext = items.first(where: { $0.name == "ext" })?.value, !ext.isEmpty {
            // A plain address may carry its own unencoded query.
            if ext.lowercased().hasPrefix("http"), let whole = rawValue("ext", in: query) { ext = whole }
            if let route = liveRoute(ext) { return route }
        }
        if let address = rawValue("url", in: query), let route = liveRoute(address) { return route }
        // `do=live` with the spider's own parameters (`u=<name>`): the spider's proxy knows the list.
        return .spider(query: query)
    }

    /// A coarse, private name for the kind of loopback address, for diagnostics: no file names or addresses.
    public static func label(_ url: URL) -> String? {
        switch route(url) {
        case .playlist?, .text?: return "route=live"
        case .spider(let query)?:
            let action = parameters(query).first(where: { $0.name == "do" })?.value ?? "-"
            return "route=spider do=" + (["live", "js", "py", "jar", "ck"].contains(action) ? action : "other")
        case .deviceFile?: return "route=file"
        case nil: return isLoopback(url) ? "route=other" : nil
        }
    }

    /// `ext` or `url` of a `do=live` address: a playlist address as it is, the same in Base64 (standard or
    /// URL-safe, as takagen99's ApiConfig decodes it), or the playlist itself in Base64.
    static func liveRoute(_ value: String) -> Route? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let route = addressRoute(text) { return route }
        guard let decoded = base64(text)?.trimmingCharacters(in: .whitespacesAndNewlines), !decoded.isEmpty else { return nil }
        if let route = addressRoute(decoded) { return route }
        // The playlist itself: a TXT group or channel line, or an M3U.
        if decoded.contains("#genre#") || decoded.contains("#EXTINF") || decoded.contains(",http") { return .text(decoded) }
        return nil
    }

    private static func addressRoute(_ text: String) -> Route? {
        let lower = text.lowercased()
        if lower.hasPrefix("clan://") || lower.hasPrefix("file://") { return .deviceFile }
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("http%3a") || lower.hasPrefix("https%3a") else { return nil }
        let address = lower.hasPrefix("http%3a") || lower.hasPrefix("https%3a") ? (text.removingPercentEncoding ?? text) : text
        guard !address.contains("\n"), let url = try? WebAddress.resolve(address) else { return nil }
        // A playlist on this device's server again: only the spider can answer that.
        if isLoopback(url), let inner = route(url) { return inner }
        return .playlist(url)
    }

    private static func base64(_ text: String) -> String? {
        var value = text.removingPercentEncoding ?? text
        value = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: " ", with: "+").filter { !$0.isNewline }
        guard !value.isEmpty, value.range(of: #"^[A-Za-z0-9+/]+=*$"#, options: .regularExpression) != nil else { return nil }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        return Data(base64Encoded: value).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// The query split by hand, as `CatalogClient.pluginProxyQuery` does: these values are often not encoded.
    static func parameters(_ query: String) -> [URLQueryItem] {
        func decode(_ text: Substring) -> String { String(text).removingPercentEncoding ?? String(text) }
        return query.split(separator: "&").map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return URLQueryItem(name: decode(parts[0]), value: parts.count > 1 ? decode(parts[1]) : nil)
        }
    }

    /// A parameter whose value is an address that configurations rarely encode (`url=https://a/b?x=1&y=2`): the
    /// rest of the query, up to another parameter these addresses use.
    static func rawValue(_ name: String, in query: String) -> String? {
        guard let start = query.range(of: #"(^|&)"# + name + "=", options: .regularExpression) else { return nil }
        var value = String(query[start.upperBound...])
        if let end = value.range(of: #"&(do|type|ext|name|epg|u)="#, options: .regularExpression) { value = String(value[..<end.lowerBound]) }
        let decoded = value.lowercased().hasPrefix("http%3a") || value.lowercased().hasPrefix("https%3a") ? (value.removingPercentEncoding ?? value) : value
        return decoded.isEmpty ? nil : decoded
    }

    /// What the spider's proxy answered (`Proxy.proxy`'s status, content type, body and any redirect).
    public struct Answer: Sendable, Equatable {
        public let status: Int
        public let body: Data
        public let location: URL?
        init(status: Int, body: Data, location: URL?) { self.status = status; self.body = body; self.location = location }
        init(_ json: [String: JSONValue]) throws {
            guard let status = json["status"]?.int else { throw TVError.unsupported(L10n.text("The plugin returned no content. Try another source.")) }
            self.status = status
            body = json["body"]?.string.flatMap { Data(base64Encoded: $0) } ?? Data()
            location = json["location"]?.string.flatMap { try? WebAddress.resolve($0) }
        }
    }

    static let needsPlugin = TVError.unsupported(L10n.text("This live playlist comes from its subscription's plugin, which this device can't run."))
    static let deviceFileError = TVError.unsupported(L10n.text("This live playlist is a file on an Android device (127.0.0.1:9978/file), which Yingxia can't open. Add the playlist's web address instead."))
}

/// The JAR spider that answers a subscription's loopback live playlists (`LoopbackPlaylist`): FongMi hands
/// `/proxy?do=…` to the configuration's spider archive, so any source on it will do.
public struct LiveSpider: Codable, Hashable, Sendable {
    public let site: Site
    public let origin: URL
    public let archive: URL?
    public init(site: Site, origin: URL, archive: URL?) { self.site = site; self.origin = origin; self.archive = archive }

    /// A JAR source on the subscription's own spider, else on any archive; nil without one.
    static func pick(_ sites: [Site], origin: URL, spider: URL?) -> LiveSpider? {
        let jars = sites.filter { $0.runtime == .jar && $0.api.hasPrefix("csp_") && !$0.isBuiltIn }
        func ownArchive(_ site: Site) -> Bool { site.raw["jar"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
        guard let site = (spider == nil ? nil : jars.first { !ownArchive($0) }) ?? jars.first(where: ownArchive) else { return nil }
        return LiveSpider(site: site, origin: origin, archive: spider)
    }
}

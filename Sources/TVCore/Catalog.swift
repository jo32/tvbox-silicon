import Foundation

public struct Category: Identifiable, Sendable {
    public let id: String
    public let name: String
}
public struct Episode: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let address: String
    public let flag: String
    public let videoID: String?
    public init(id: String, name: String, address: String, flag: String, videoID: String? = nil) {
        self.id = id; self.name = name; self.address = address; self.flag = flag; self.videoID = videoID
    }
}
public struct Video: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let poster: URL?
    public let posterHeaders: [String: String]
    public let remarks: String
    public let synopsis: String
    public let episodes: [Episode]
    public init?(json: [String: JSONValue], origin: URL) {
        guard let id = json["vod_id"]?.string, !id.isEmpty else { return nil }
        self.id = id; name = json["vod_name"]?.string ?? id
        let artwork = json["vod_pic"]?.string.flatMap { PosterResource(address: $0, origin: origin) }
        poster = artwork?.url; posterHeaders = artwork?.headers ?? [:]
        remarks = HTMLText.plain(json["vod_remarks"]?.string ?? "")
        synopsis = HTMLText.plain(json["vod_content"]?.string ?? "")
        let flags = (json["vod_play_from"]?.string ?? "").components(separatedBy: "$$$")
        var episodes: [Episode] = []
        for (groupIndex, group) in (json["vod_play_url"]?.string ?? "").components(separatedBy: "$$$").enumerated() {
            let flag = groupIndex < flags.count ? flags[groupIndex] : ""
            for (index, item) in group.components(separatedBy: "#").enumerated() where !item.isEmpty {
                let parts = item.split(separator: "$", maxSplits: 1).map(String.init)
                episodes.append(Episode(id: "\(groupIndex)-\(index)", name: parts.count == 2 ? parts[0] : L10n.text("Play"), address: parts.last ?? item, flag: flag, videoID: id))
            }
        }
        self.episodes = episodes
    }
}
/// Plugins pass through site HTML, often entity-escaped twice ("&amp;nbsp;"), so decode until stable before stripping tags.
enum HTMLText {
    private static let entity = try! NSRegularExpression(pattern: "&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z]{2,8});?")
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "lsquo": "\u{2018}", "rsquo": "\u{2019}",
        "hellip": "\u{2026}", "mdash": "\u{2014}", "ndash": "\u{2013}", "middot": "\u{00B7}",
    ]

    static func plain(_ html: String) -> String {
        var text = html
        for _ in 0..<3 {
            let decoded = decodeEntities(text)
            if decoded == text { break }
            text = decoded
        }
        return text
            .replacingOccurrences(of: "<br\\s*/?>|</p>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[ \\t\u{00A0}\u{3000}]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " *\n\\s*", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let source = text as NSString
        var output = "", cursor = 0
        for match in entity.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let body = source.substring(with: match.range(at: 1))
            let scalar: UInt32? = body.hasPrefix("#x") || body.hasPrefix("#X") ? UInt32(body.dropFirst(2), radix: 16)
                : body.hasPrefix("#") ? UInt32(body.dropFirst()) : nil
            guard let replacement = scalar.flatMap(Unicode.Scalar.init).map({ String(Character($0)) }) ?? named[body.lowercased()]
            else { continue }
            output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)) + replacement
            cursor = match.range.location + match.range.length
        }
        return output + source.substring(from: cursor)
    }
}

public struct CatalogPage: Sendable {
    public let categories: [Category]
    public let videos: [Video]
    public let pageCount: Int
    public init(json: [String: JSONValue], origin: URL) {
        categories = (json["class"]?.array ?? []).compactMap {
            guard let v = $0.object, let id = v["type_id"]?.string else { return nil }
            return Category(id: id, name: v["type_name"]?.string ?? id)
        }
        videos = (json["list"]?.array ?? []).compactMap { $0.object.flatMap { Video(json: $0, origin: origin) } }
        pageCount = max(1, json["pagecount"]?.int ?? 1)
    }
}

public struct CatalogClient: Sendable {
    public let site: Site
    public let origin: URL
    public let http: HTTPClient
    public let jarURL: URL?
    public init(site: Site, origin: URL, http: HTTPClient = HTTPClient(), jarURL: URL? = nil) {
        self.site = site; self.origin = origin; self.http = http; self.jarURL = jarURL
    }
    public func requestURL(_ params: [String: String]) throws -> URL {
        guard site.native else { throw TVError.unsupported(L10n.text("%@: this source cannot run in this version.", site.compatibility)) }
        let endpoint = try WebAddress.resolve(site.api, relativeTo: origin)
        guard var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: true) else { throw TVError.invalidURL }
        var values = params
        if let ext = site.raw["ext"] {
            if let text = ext.string { values["extend"] = text }
            else if let data = try? JSONEncoder().encode(ext) { values["extend"] = String(data: data, encoding: .utf8) }
        }
        parts.queryItems = (parts.queryItems ?? []).filter { values[$0.name] == nil } + values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = parts.url else { throw TVError.invalidURL }
        return url
    }
    private func request(_ params: [String: String]) async throws -> [String: JSONValue] {
        #if os(macOS)
        if site.type == 3, !site.api.hasPrefix("csp_") {
            return try await LocalJarHost.shared.request(site: site, jarURL: WebAddress.resolve(site.api, relativeTo: origin), params: params, http: http, scriptOrigin: origin)
        }
        #endif
        if site.type == 3, site.api.hasPrefix("csp_"), let plugin = try site.pluginURL(origin: origin, fallback: jarURL) {
            let progress = PluginPreparation(site: site, origin: origin)
            defer { progress.finish() }
            return try await EmbeddedJarHost.shared.request(site: site, jarURL: plugin, params: params, http: http, configurationOrigin: origin, progress: progress)
        }
        let (data, _) = try await http.get(requestURL(params), headers: site.raw["header"]?.object?.compactMapValues(\.string) ?? [:])
        return try JSONDecoder().decode([String: JSONValue].self, from: data)
    }
    public func home() async throws -> CatalogPage {
        CatalogPage(json: try await request(site.type == 4 ? ["filter": "true"] : [:]), origin: origin)
    }
    public func recommendations() async throws -> [Recommendation] {
        let json = try await request(site.type == 4 ? ["filter": "true"] : [:])
        var seen = Set<String>()
        return (json["list"]?.array ?? []).compactMap { entry in
            entry.object.flatMap { Recommendation(json: $0, origin: origin, isIndex: (site.raw["indexs"]?.int ?? 0) == 1) }
        }.filter { seen.insert($0.id).inserted }
    }
    public func list(category: String?, query: String, page: Int) async throws -> CatalogPage {
        var params = ["pg": String(page)]
        if !query.isEmpty { params["wd"] = query; params["quick"] = "false" }
        else { params["ac"] = "detail"; params["t"] = category }
        return CatalogPage(json: try await request(params), origin: origin)
    }
    public func detail(_ id: String) async throws -> Video {
        var json = try await request(["ac": "detail", "ids": id])
        if let list = json["list"]?.array {
            json["list"] = .array(list.map { item in
                guard var fields = item.object else { return item }
                if fields["vod_id"] == nil { fields["vod_id"] = .string(id) }
                return .object(fields)
            })
        }
        let result = CatalogPage(json: json, origin: origin)
        guard let video = result.videos.first else { throw TVError.unsupported(L10n.text("The API did not return video details.")) }
        return video
    }
    public func playback(_ episode: Episode) async throws -> Channel {
        let plan = try await preparePlayback(episode)
        return try await resolvePlayback(plan, choice: plan.choices[0])
    }

    public func preparePlayback(_ episode: Episode) async throws -> PlaybackPlan {
        var headers = site.raw["header"]?.object?.compactMapValues(\.string) ?? [:]
        if site.type == 4 || site.type == 3 {
            var params = ["play": episode.address, "flag": episode.flag]
            if site.type == 3 { params["detailID"] = episode.videoID }
            let result = try await request(params)
            if let message = Self.providerError(result) { throw TVError.unsupported(message) }
            if let fields = result["header"]?.object { headers.merge(fields.compactMapValues(\.string)) { _, new in new } }
            else if let text = result["header"]?.string, let data = text.data(using: .utf8),
                    let fields = try? JSONDecoder().decode([String: String].self, from: data) { headers.merge(fields) { _, new in new } }
            if let ua = result["UA"]?.string ?? result["ua"]?.string, !ua.isEmpty { headers["User-Agent"] = ua }
            let prefix = result["playUrl"]?.string ?? ""
            let choices = PlaybackChoice.parse(result["url"], prefix: prefix, fallbackName: episode.name)
            guard !choices.isEmpty else { throw TVError.unsupported(L10n.text("The API did not return a single playback URL.")) }
            return PlaybackPlan(choices: choices, headers: headers, group: episode.flag,
                                requiresWebDetection: (result["parse"]?.int ?? 0) != 0 || (result["jx"]?.int ?? 0) != 0 || !prefix.isEmpty)
        }
        let prefix = site.raw["playUrl"]?.string ?? ""
        return PlaybackPlan(choices: [PlaybackChoice(id: 0, name: episode.name, address: prefix + episode.address)], headers: headers, group: episode.flag, requiresWebDetection: !prefix.isEmpty)
    }

    public func resolvePlayback(_ plan: PlaybackPlan, choice: PlaybackChoice) async throws -> Channel {
        guard !plan.requiresWebDetection || Self.isDirectMedia(choice.address) else {
            throw TVError.unsupported(L10n.text("This source requires web video detection or additional parsing. Only resolved media URLs are supported."))
        }
        let address = Self.unwrapPluginProxy(choice.address)
        if address.lowercased().hasPrefix("magnet:") { throw TVError.unsupported(L10n.text("This source returned a magnet link. Torrent playback is not supported.")) }
        if Self.isPluginProxy(address) {
            if let result = try await BilibiliPlayback.resolve(address, headers: plan.headers, http: http) {
                return Channel(name: choice.name, group: plan.group, url: result.url, headers: result.headers)
            }
            throw TVError.unsupported(L10n.text("This source needs a playback proxy that is not supported yet."))
        }
        return Channel(name: choice.name, group: plan.group, url: try WebAddress.resolve(address), headers: plan.headers)
    }
    static func isDirectMedia(_ address: String) -> Bool {
        guard let url = try? WebAddress.resolve(address) else { return false }
        return ["mp4", "m4v", "m3u8", "mp3", "m4a", "aac"].contains(url.pathExtension.lowercased())
    }
    static func providerError(_ result: [String: JSONValue]) -> String? {
        // Providers often supply the useful login/authorization reason beside an empty URL.
        guard result["url"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
              result["url"]?.array?.isEmpty != false else { return nil }
        for key in ["errMsg", "msg", "message"] {
            if let message = result[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty { return message }
        }
        return nil
    }
    static func isPluginProxy(_ address: String) -> Bool {
        guard let marker = address.range(of: "/proxy?") else { return false }
        let authority = String(address[..<marker.lowerBound])
        for host in ["http://127.0.0.1", "http://localhost"] {
            if authority == host { return true }
            if authority.hasPrefix(host + ":"), let port = Int(authority.dropFirst(host.count + 1)), (-1...65535).contains(port) { return true }
        }
        return false
    }
    /// Plugins wrap HLS addresses in their own loopback proxy (`http://127.0.0.1:<port>/proxy?do=m3u8&url=...`).
    /// This app hosts no such proxy, and in `m3u8` mode the wrapped address is the real playlist.
    static func unwrapPluginProxy(_ address: String) -> String {
        guard isPluginProxy(address), let marker = address.range(of: "/proxy?") else { return address }
        var parts = URLComponents()
        parts.percentEncodedQuery = String(address[marker.upperBound...])
        let items = parts.queryItems ?? []
        guard items.first(where: { $0.name == "do" })?.value == "m3u8",
              let inner = items.first(where: { $0.name == "url" })?.value, !inner.isEmpty else { return address }
        return inner
    }
}

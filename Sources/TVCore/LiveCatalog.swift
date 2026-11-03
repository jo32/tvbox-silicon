import Foundation

/// The live platforms Yingxia's own subscription lists (`yingxiaLive`): each is a script in that
/// subscription that lists its rooms by area, searches them, and turns a room into a playable stream
/// when it starts. Stream addresses expire, so channels carry `<scheme>://room/<id>` and
/// `LiveCatalog.resolve` asks the script for the address at play time.
///
/// The script's contract: `home()` gives `{areas: [{id, name}]}` (id "" is the recommendations),
/// `category(area, page)` and `search(keyword, quick, page)` give `{rooms: [{id, title, host, cover,
/// online, area}]}`, and `play(quality, room)` gives `{url, header, title, qualities: [{id, label}],
/// current, repair}`; `play("relay", address)` turns a playlist's FLV address into HLS.
public struct LivePlatform: Hashable, Identifiable, Sendable {
    public let id: String
    public let scheme: String
    let api: String
    private let names: [String: String]
    private let fallbackName: String
    /// The brand colour, as "#RRGGBB".
    public let tint: String
    /// The mark: a drawn logo ("bilibili"), else `glyph` on the tint, offset in two colours when `split`.
    public let mark: String?
    public let glyph: String
    public let split: Bool
    /// The service account the script signs in as ("douyin"), if any.
    public let account: String?
    public let searchNeedsAccount: Bool
    /// The live chat protocol rooms speak ("bilibili"), if the app shows it as danmaku.
    public let chat: String?
    /// Hosts whose FLV addresses the script can turn into HLS (`play("relay", address)`).
    let relayHosts: [String]

    init?(json: [String: JSONValue]) {
        guard let id = json["id"]?.string, !id.isEmpty, let scheme = json["scheme"]?.string, !scheme.isEmpty,
              let api = json["api"]?.string, URL(string: api) != nil else { return nil }
        self.id = id; self.scheme = scheme.lowercased(); self.api = api
        names = json["names"]?.object?.compactMapValues(\.string) ?? [:]
        fallbackName = json["name"]?.string ?? id
        tint = json["tint"]?.string ?? "#5E5CE6"
        mark = json["mark"]?.string
        glyph = json["glyph"]?.string ?? String(fallbackName.prefix(1))
        split = json["split"].map { if case .bool(true) = $0 { true } else { false } } ?? false
        account = json["account"]?.string
        searchNeedsAccount = json["searchNeedsAccount"].map { if case .bool(true) = $0 { true } else { false } } ?? false
        chat = json["chat"]?.string
        relayHosts = (json["relayHosts"]?.array ?? []).compactMap { $0.string?.lowercased() }
    }

    /// The platforms of the latest copy of Yingxia's own subscription, in its order.
    public static var all: [LivePlatform] { CloudSources.platforms }

    public init?(scheme: String?) {
        guard let scheme = scheme?.lowercased(), let platform = Self.all.first(where: { $0.scheme == scheme }) else { return nil }
        self = platform
    }
    public init?(rawValue: String) {
        guard let platform = Self.all.first(where: { $0.id == rawValue }) else { return nil }
        self = platform
    }

    public var name: String { names[L10n.resolvedLanguage()] ?? L10n.text(fallbackName) }
    public var source: LiveSource { LiveSource(name: name, url: URL(string: "\(scheme)://rooms")!) }
    /// Some platforms answer searches only for signed-in accounts.
    public var searchable: Bool { !searchNeedsAccount || SourceAccounts.signedIn(account) }

    /// The script, as a source the runtime runs, with the account's cookie in its ext.
    var site: Site {
        var yingxia: [String: JSONValue] = ["builtin": .bool(true)]
        if let account { yingxia["account"] = .string(account) }
        return Site(key: "live." + id, name: name, type: 3, api: api, raw: ["yingxia": .object(yingxia), "ext": .object([:])])
    }

    func call(_ params: [String: String]) async throws -> [String: JSONValue] {
        let site = site
        return try await ScriptRuntime.shared.request(site: site, scriptURL: try WebAddress.resolve(api, relativeTo: CloudSources.address),
                                                      params: params, http: HTTPClient(), origin: CloudSources.address)
    }
}

/// A group of rooms a platform lists together: a game, a category, or its recommendations (empty id).
public struct LiveArea: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
    static var recommended: LiveArea { LiveArea(id: "", name: L10n.text("Recommended")) }
}

/// A live room as the room lists show it.
public struct LiveRoom: Identifiable, Hashable, Sendable {
    public let platform: LivePlatform
    public let roomID: String
    public let title: String
    public let host: String
    public let cover: URL?
    /// Viewers (or the platform's popularity figure), 0 when unknown.
    public let online: Int
    public let area: String
    public var id: String { platform.id + ":" + roomID }
    public var url: URL { URL(string: "\(platform.scheme)://room/\(roomID)")! }
    /// The room as a playable channel; its stream is resolved when it plays.
    public var channel: Channel {
        Channel(name: [host, title].filter { !$0.isEmpty }.joined(separator: " · "), group: area, url: url, logo: cover)
    }

    init(platform: LivePlatform, roomID: String, title: String, host: String, cover: String?, online: Int, area: String) {
        self.platform = platform; self.roomID = roomID; self.online = online
        self.title = LiveText.plain(title); self.host = LiveText.plain(host); self.area = LiveText.plain(area)
        self.cover = cover.flatMap(LiveText.imageURL)
    }

    init?(platform: LivePlatform, json: [String: JSONValue]) {
        guard let id = json["id"]?.string, !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { return nil }
        self.init(platform: platform, roomID: id, title: json["title"]?.string ?? "", host: json["host"]?.string ?? "",
                  cover: json["cover"]?.string, online: json["online"]?.double.map { Int($0) } ?? 0, area: json["area"]?.string ?? "")
    }
}

public enum LiveCatalog {
    public static func areas(_ platform: LivePlatform) async throws -> [LiveArea] {
        let reply = try await platform.call([:])
        return (reply["areas"]?.array ?? []).compactMap(\.object).compactMap { area in
            guard let id = area["id"]?.string, let name = area["name"]?.string, !name.isEmpty else { return nil }
            return LiveArea(id: id, name: name)
        }
    }

    /// One page (from 1) of an area's rooms, busiest first; empty past the last page.
    public static func rooms(_ platform: LivePlatform, area: LiveArea, page: Int) async throws -> [LiveRoom] {
        rooms(platform, try await platform.call(["t": area.id, "pg": String(page)]))
    }

    /// Rooms whose title or streamer matches `keyword`.
    public static func search(_ platform: LivePlatform, keyword: String, page: Int = 1) async throws -> [LiveRoom] {
        rooms(platform, try await platform.call(["wd": keyword, "pg": String(page)]))
    }

    private static func rooms(_ platform: LivePlatform, _ reply: [String: JSONValue]) -> [LiveRoom] {
        var seen = Set<String>()
        return (reply["rooms"]?.array ?? []).compactMap(\.object).compactMap { LiveRoom(platform: platform, json: $0) }.filter { seen.insert($0.roomID).inserted }
    }

    /// The first area's rooms, as channels (the live source's channel list).
    public static func channels(_ platform: LivePlatform) async throws -> [Channel] {
        let area = try await areas(platform).first ?? .recommended
        let rooms = try await self.rooms(platform, area: area, page: 1)
        guard !rooms.isEmpty else { throw TVError.unsupported(L10n.text("%@ could not be reached. Try again later.", platform.name)) }
        return rooms.map(\.channel)
    }

    /// The platform and room of a room channel's address.
    public static func room(_ url: URL) -> (platform: LivePlatform, id: String)? {
        guard url.host() == "room", let platform = LivePlatform(scheme: url.scheme) else { return nil }
        let id = url.lastPathComponent
        return id.isEmpty || id == "/" ? nil : (platform, id)
    }
    public static func isRoom(_ url: URL) -> Bool { room(url) != nil }
    /// Whether the address has a live platform's shape (`<name>-live://room/<id>`), known to this copy or not:
    /// favorites keep a room by its address even before the platforms load.
    public static func isRoomAddress(_ url: URL) -> Bool {
        url.host() == "room" && (url.scheme?.lowercased().hasSuffix("-live") ?? false) && url.pathComponents.count == 2
    }
    /// A live platform's listing address (`<name>-live://rooms`) in a subscription's `lives`.
    static func platformAddress(_ text: String) -> URL? {
        guard let url = URL(string: text), url.host() == "rooms", url.scheme?.lowercased().hasSuffix("-live") == true else { return nil }
        return url
    }

    /// The playable channel for a room channel (at the quality its address asks for, else the best),
    /// with the room's qualities and the one served; any other channel is returned unchanged.
    public static func resolve(_ channel: Channel) async throws -> (channel: Channel, qualities: [StreamQuality], current: Int?) {
        guard let (platform, id) = room(channel.url) else { return (channel, [], nil) }
        let asked = URLComponents(url: channel.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value.flatMap(Int.init)
        let reply = try await platform.call(["play": id, "flag": asked.map(String.init) ?? ""])
        guard var url = reply["url"]?.string.flatMap({ try? WebAddress.resolve($0) }) else {
            throw TVError.unsupported(L10n.text("This live room has no stream this device can play."))
        }
        let headers = reply["header"]?.object?.compactMapValues(\.string) ?? [:]
        if reply["repair"]?.string == "discontinuity" { url = LiveRepair.address(url, headers: headers) }
        let qualities = (reply["qualities"]?.array ?? []).compactMap(\.object).compactMap { quality -> StreamQuality? in
            guard let number = quality["id"]?.double.map({ Int($0) }), let label = quality["label"]?.string,
                  let address = URL(string: "\(platform.scheme)://room/\(id)?q=\(number)") else { return nil }
            return StreamQuality(id: number, label: label, url: address)
        }
        let title = reply["title"]?.string.flatMap { $0.isEmpty ? nil : LiveText.plain($0) }
        let name = channel.name.isEmpty ? (title ?? platform.name) : channel.name
        return (Channel(name: name, group: channel.group.isEmpty ? platform.name : channel.group, url: url, logo: channel.logo, headers: headers),
                qualities, reply["current"]?.double.map { Int($0) })
    }

    /// A playlist channel whose FLV address is a platform's stream, directly or through a relay, as the
    /// HLS line of the same stream; any other channel is returned unchanged.
    public static func playable(_ channel: Channel) async -> Channel { await playable(channel, session: LiveHTTP.unredirected) }
    static func playable(_ channel: Channel, session: URLSession, platforms: [LivePlatform] = LivePlatform.all,
                         convert: @Sendable (LivePlatform, URL) async -> URL? = { platform, flv in
                             guard let reply = try? await platform.call(["play": flv.absoluteString, "flag": "relay"]) else { return nil }
                             return reply["url"]?.string.flatMap(URL.init(string:))
                         }) async -> Channel {
        guard channel.url.pathExtension.lowercased() == "flv", !platforms.allSatisfy(\.relayHosts.isEmpty) else { return channel }
        func owner(_ url: URL) -> LivePlatform? {
            let host = url.host()?.lowercased() ?? ""
            return platforms.first { $0.relayHosts.contains { host.hasSuffix($0) } }
        }
        // A relay answers with a redirect (or a few) to the platform's own address.
        var address = channel.url, found: (LivePlatform, URL)?
        for _ in 0..<4 {
            if let platform = owner(address) { found = (platform, address); break }
            var request = URLRequest(url: address, timeoutInterval: 8)
            // Relays made for Android TVBox can refuse other clients.
            request.setValue(HTTPClient.subscriptionUserAgent, forHTTPHeaderField: "User-Agent")
            channel.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
            guard let (bytes, response) = try? await session.bytes(for: request) else { return channel }
            bytes.task.cancel() // A live stream's body never ends.
            guard let http = response as? HTTPURLResponse, (300..<400).contains(http.statusCode),
                  let location = http.value(forHTTPHeaderField: "Location"),
                  let next = URL(string: location, relativeTo: address)?.absoluteURL else { return channel }
            address = next
        }
        guard let (platform, flv) = found, let url = await convert(platform, flv) else { return channel }
        Diagnostics.shared.record(.info, "player", "\(platform.id) flv as hls relay=\(channel.url.host() ?? "-") line=\(url.host() ?? "-")")
        return Channel(name: channel.name, group: channel.group, url: url, logo: channel.logo, headers: channel.headers, skipScope: channel.skipScope,
                       historyContext: channel.historyContext, resumePosition: channel.resumePosition)
    }
}

extension LiveSource {
    /// Offered with every subscription, before the subscription's own live playlists.
    public static var builtIn: [LiveSource] { LivePlatform.all.map(\.source) }
    public var platform: LivePlatform? { url.host() == "rooms" ? LivePlatform(scheme: url.scheme) : nil }
    public var isBuiltIn: Bool { platform != nil }
}

/// HTTP for the live platforms' web APIs.
enum LiveHTTP {
    static let desktopAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    static let mobileAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private final class Redirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    /// Answers redirects instead of following them.
    static let unredirected = URLSession(configuration: .ephemeral, delegate: Redirects(), delegateQueue: nil)

    static func data(_ url: URL, headers: [String: String] = [:], form: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(desktopAgent, forHTTPHeaderField: "User-Agent")
        if let form {
            request.httpMethod = "POST"
            request.httpBody = Data(form.utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TVError.invalidURL }
        guard (200..<300).contains(http.statusCode) else { throw TVError.http(http.statusCode) }
        return (data, http)
    }
    static func text(_ url: URL, headers: [String: String] = [:], form: String? = nil) async throws -> String {
        String(decoding: try await data(url, headers: headers, form: form).0, as: UTF8.self)
    }
    static func json(_ url: URL, headers: [String: String] = [:], form: String? = nil) async throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: try await data(url, headers: headers, form: form).0)
    }
    static func url(_ base: String, _ query: [(String, String)]) -> URL {
        var components = URLComponents(string: base)!
        components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        // `+` is a space to these servers; URLComponents leaves it as is.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }
}

enum LiveText {
    /// Search results mark the matched words with `<em>` and escape entities.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func imageURL(_ text: String) -> URL? {
        guard !text.isEmpty else { return nil }
        let address = text.hasPrefix("//") ? "https:" + text : text.replacingOccurrences(of: "http://", with: "https://")
        return URL(string: address)
    }
    /// "1.2万" and similar popularity figures.
    static func count(_ text: String?) -> Int {
        guard var text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return 0 }
        var scale = 1.0
        if text.hasSuffix("万") { scale = 10_000; text.removeLast() } else if text.hasSuffix("亿") { scale = 100_000_000; text.removeLast() }
        return Int((Double(text) ?? 0) * scale)
    }
}

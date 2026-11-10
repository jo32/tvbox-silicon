import Foundation

/// The live catalog of an installed AngelLive plugin (`LivePlugins`): its categories, rooms, search and streams,
/// in the shapes `LiveCatalog` gives the app. Rooms are `{roomId, userId, roomTitle, userName, roomCover,
/// userHeadImg, liveWatchedCount, liveState}`; streams are lines `[{cdn, qualitys: [{title, qn, url,
/// liveCodeType, userAgent, headers, playbackHints}]}]`. FLV streams play through `FLVLive`.
public enum LivePluginCatalog {
    /// The area that lists the plugin's home feed (`getHomeFeed`).
    static let homeArea = "\u{1}home"

    static func areas(_ plugin: String) async throws -> [LiveArea] {
        var areas: [LiveArea] = []
        if await LivePluginRuntime.shared.has(plugin, "getHomeFeed") { areas.append(LiveArea(id: homeArea, name: L10n.text("Recommended"))) }
        let reply = try await LivePluginRuntime.shared.call(plugin, "getCategories")
        for group in reply.array ?? reply.object?["categories"]?.array ?? [] {
            guard let group = group.object else { continue }
            let parent = text(group["id"])
            let subs = group["subList"]?.array ?? group["children"]?.array ?? []
            if subs.isEmpty {
                if let area = area(group, parent: "") { areas.append(area) }
            } else {
                // "全部" alone, or beside siblings, says nothing without its group's name.
                let groupTitle = text(group["title"]).isEmpty ? text(group["name"]) : text(group["title"])
                areas += subs.compactMap { $0.object.flatMap { area($0, parent: parent) } }.map { sub in
                    let all = ["全部", "all", "全部直播"].contains(sub.name.lowercased())
                    guard !groupTitle.isEmpty, subs.count == 1 || all else { return sub }
                    return LiveArea(id: sub.id, name: subs.count == 1 ? groupTitle : groupTitle + " · " + sub.name)
                }
            }
        }
        var seen = Set<String>()
        return areas.filter { seen.insert($0.id).inserted }
    }

    private static func area(_ json: [String: JSONValue], parent: String) -> LiveArea? {
        let id = text(json["id"]), title = text(json["title"]).isEmpty ? text(json["name"]) : text(json["title"])
        guard !title.isEmpty else { return nil }
        let parentID = text(json["parentId"]).isEmpty ? parent : text(json["parentId"])
        return LiveArea(id: parentID.isEmpty ? id : parentID + "\u{1F}" + id, name: title)
    }

    static func rooms(_ platform: LivePlatform, area: LiveArea, page: Int) async throws -> [LiveRoom] {
        guard let plugin = platform.plugin else { return [] }
        if area.id == homeArea {
            guard page == 1 else { return [] }
            return try await homeFeed(platform).sections.flatMap(\.rooms).uniqued()
        }
        let parts = area.id.components(separatedBy: "\u{1F}")
        let id = parts.last ?? area.id, parent = parts.count > 1 ? parts[0] : ""
        let reply = try await LivePluginRuntime.shared.call(plugin, "getRooms", ["id": .string(id), "parentId": .string(parent), "page": .number(Double(page))])
        return rooms(platform, reply, area: area.name)
    }

    static func search(_ platform: LivePlatform, keyword: String, page: Int) async throws -> [LiveRoom] {
        guard let plugin = platform.plugin else { return [] }
        // A pasted share link or text (`resolveShare`) is that one room; a bare room number leads the results.
        var shared: LiveRoom?
        let link = keyword.contains("://") || keyword.contains("/") || keyword.range(of: #"[a-z0-9-]+\.[a-z]{2,}"#, options: [.regularExpression, .caseInsensitive]) != nil
        let number = keyword.count >= 3 && keyword.allSatisfy(\.isNumber)
        if page == 1, link || number, await LivePluginRuntime.shared.has(plugin, "resolveShare"),
           let reply = try? await LivePluginRuntime.shared.call(plugin, "resolveShare", ["shareCode": .string(keyword)], timeout: 20).object {
            shared = room(platform, reply, area: "")
        }
        if link, let shared { return [shared] }
        if let shared {
            let found = (try? await LivePluginRuntime.shared.call(plugin, "search", ["keyword": .string(keyword), "page": .number(1)])).map { rooms(platform, $0, area: "") } ?? []
            return ([shared] + found).uniqued()
        }
        let reply = try await LivePluginRuntime.shared.call(plugin, "search", ["keyword": .string(keyword), "page": .number(Double(page))])
        return rooms(platform, reply, area: "")
    }

    /// A plugin's home page: banners, then sections of rooms.
    public struct HomeFeed: Sendable {
        public struct Banner: Sendable, Identifiable {
            public let id: String
            public let image: URL?
            public let title: String
            public let subtitle: String
            public let room: LiveRoom?
        }
        public struct Section: Sendable, Identifiable {
            public let id: String
            public let title: String
            public let rooms: [LiveRoom]
            /// The category with the rest of this section's rooms (`seeAllTarget`).
            public let more: LiveArea?
        }
        public var banners: [Banner] = []
        public var sections: [Section] = []
        public init() {}
    }

    static func homeFeed(_ platform: LivePlatform) async throws -> HomeFeed {
        guard let plugin = platform.plugin else { return HomeFeed() }
        let locale = Locale.preferredLanguages.first.map { $0.hasPrefix("zh-Hant") ? "zh-Hant" : $0.hasPrefix("zh") ? "zh-Hans" : String($0.prefix(2)) } ?? "zh-Hans"
        let reply = try await LivePluginRuntime.shared.call(plugin, "getHomeFeed", ["schemaVersion": .number(1), "locale": .string(locale)]).object ?? [:]
        var feed = HomeFeed()
        for (index, banner) in (reply["banners"]?.array ?? []).compactMap(\.object).enumerated() {
            let room = banner["target"]?.object?["room"]?.object.flatMap { self.room(platform, $0, area: "") }
            // A banner that opens nothing here, or whose picture isn't HTTPS, is left out.
            guard room != nil, text(banner["imageURL"]).lowercased().hasPrefix("https://") else { continue }
            feed.banners.append(.init(id: text(banner["id"]).isEmpty ? "\(index)" : text(banner["id"]), image: LiveText.imageURL(text(banner["imageURL"])),
                                      title: LiveText.plain(text(banner["title"])), subtitle: LiveText.plain(text(banner["subtitle"])), room: room))
        }
        for (index, section) in (reply["sections"]?.array ?? []).compactMap(\.object).enumerated() {
            let title = text(section["title"])
            let rooms = (section["items"]?.array ?? []).compactMap { item -> LiveRoom? in
                guard let item = item.object else { return nil }
                return (item["room"]?.object ?? item).flatMap { self.room(platform, $0, area: title) }
            }
            let target = section["seeAllTarget"]?.object
            let more = target?["type"]?.string == "category" ? target?["category"]?.object.flatMap { area($0, parent: "") } : nil
            if !rooms.isEmpty {
                feed.sections.append(.init(id: text(section["id"]).isEmpty ? "\(index)" : text(section["id"]), title: title, rooms: rooms.uniqued(), more: more))
            }
        }
        return feed
    }

    private static func rooms(_ platform: LivePlatform, _ reply: JSONValue, area: String) -> [LiveRoom] {
        let list = reply.array ?? reply.object?["rooms"]?.array ?? reply.object?["list"]?.array ?? reply.object?["items"]?.array ?? []
        return list.compactMap { $0.object.flatMap { room(platform, $0, area: area) } }.uniqued()
    }

    static func room(_ platform: LivePlatform, _ json: [String: JSONValue], area: String) -> LiveRoom? {
        let id = text(json["roomId"])
        guard !id.isEmpty, !id.contains("/") else { return nil }
        var room = LiveRoom(platform: platform, roomID: id, title: LiveText.plain(text(json["roomTitle"])), host: LiveText.plain(text(json["userName"])),
                            cover: text(json["roomCover"]), online: count(json["liveWatchedCount"]), area: area)
        room.userID = text(json["userId"])
        return room
    }

    /// The room's stream (the quality its address asks for, else the first, which plugins list best first).
    static func resolve(_ channel: Channel, platform: LivePlatform, room: String) async throws -> (channel: Channel, qualities: [StreamQuality], current: Int?) {
        guard let plugin = platform.plugin else { return (channel, [], nil) }
        let query = URLComponents(url: channel.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let user = query.first { $0.name == "u" }?.value ?? ""
        let asked = query.first { $0.name == "q" }?.value.flatMap(Int.init)
        var payload: [String: JSONValue] = ["roomId": .string(room)]
        if !user.isEmpty { payload["userId"] = .string(user) }
        let reply = try await LivePluginRuntime.shared.call(plugin, "getPlayback", payload, timeout: 40)
        let options = options(reply)
        guard var chosen = options.first(where: { $0.id == asked && ($0.url != nil || $0.refreshes) }) ?? options.first(where: { $0.url != nil }) else {
            throw TVError.unsupported(L10n.text("This live room has no stream this device can play."))
        }
        // A line or episode that has its address only once picked (`selectionBehavior: "refreshOnSelect"`).
        if chosen.refreshes, chosen.id != options.first(where: { $0.url != nil })?.id || chosen.url == nil {
            chosen = try await refreshed(chosen, plugin: plugin, payload: payload)
        }
        if chosen.encrypted && chosen.key == nil { throw TVError.unsupported(L10n.text("This video is encrypted, and Yingxia can't play it yet.")) }
        guard let url = chosen.url else { throw TVError.unsupported(L10n.text("This live room has no stream this device can play.")) }
        Diagnostics.shared.record(.info, "plugins", "\(plugin) play room=\(room) option=\(chosen.label) flv=\(chosen.flv) cenc=\(chosen.key != nil) host=\(url.host() ?? "-")")
        let address: URL
        if let key = chosen.key {
            // A CENC MP4 with its key (Hongguo's episodes): decrypted as it plays, as Yingxia's own Hongguo source does.
            address = try await HongguoStreams.open(url: url, key: key, headers: chosen.headers, http: HTTPClient())
        } else {
            // A server whose playlists contradicted themselves before is read through the loader that steadies them.
            address = chosen.flv ? try await FLVLive.open(url, headers: chosen.headers)
                : LiveRepair.contradicts(url) ? LiveRepair.address(url, headers: chosen.headers) : url
        }
        let qualities = options.compactMap { option -> StreamQuality? in
            var parts = URLComponents(url: channel.url, resolvingAgainstBaseURL: false)
            parts?.queryItems = (user.isEmpty ? [] : [URLQueryItem(name: "u", value: user)]) + [URLQueryItem(name: "q", value: String(option.id))]
            return parts?.url.map { StreamQuality(id: option.id, label: option.label, url: $0) }
        }
        let name = channel.name.isEmpty ? platform.name : channel.name
        return (Channel(name: name, group: channel.group.isEmpty ? platform.name : channel.group, url: address, logo: channel.logo,
                        headers: chosen.flv || chosen.key != nil ? [:] : chosen.headers), qualities, chosen.id)
    }

    /// One quality of one line from `getPlayback`, as the quality menu lists it.
    struct Option {
        let id: Int
        let label: String
        var url: URL?
        var headers: [String: String]
        var flv: Bool
        /// Its address comes from `refreshPlayback` (or `getPlayback` again) once picked.
        let refreshes: Bool
        var encrypted: Bool
        /// The AES key (32 hex digits) of a CENC-encrypted MP4.
        var key: String? = nil
        let line: [String: JSONValue]
        let quality: [String: JSONValue]
    }

    static func options(_ reply: JSONValue) -> [Option] {
        let lines = (reply.array ?? reply.object?["lines"]?.array ?? []).compactMap(\.object)
        var options: [Option] = []
        for (lineIndex, line) in lines.enumerated() {
            let cdn = text(line["cdn"])
            for (index, quality) in (line["qualitys"]?.array ?? line["qualities"]?.array ?? []).compactMap(\.object).enumerated() {
                let refreshes = text(quality["playbackHints"]?.object?["selectionBehavior"]) == "refreshOnSelect"
                let url = URL(string: text(quality["url"])).flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil }
                guard url != nil || refreshes else { continue }
                let title = text(quality["title"])
                let label = lines.count > 1 ? [text(line["displayName"]).isEmpty ? cdn : text(line["displayName"]), title].filter { !$0.isEmpty }.joined(separator: " · ") : title
                var option = Option(id: lineIndex * 100 + index, label: label.isEmpty ? "\(options.count + 1)" : label, url: nil, headers: [:],
                                    flv: false, refreshes: refreshes, encrypted: false, line: line, quality: quality)
                option.apply(quality, url: url)
                options.append(option)
            }
        }
        return options
    }

    /// A picked line's address: `refreshPlayback` where the plugin has it, else `getPlayback` with the line's request context.
    private static func refreshed(_ option: Option, plugin: String, payload: [String: JSONValue]) async throws -> Option {
        var option = option
        if await LivePluginRuntime.shared.has(plugin, "refreshPlayback") {
            var request = payload
            request["cdn"] = .object(option.line); request["quality"] = .object(option.quality)
            let reply = try await LivePluginRuntime.shared.call(plugin, "refreshPlayback", request, timeout: 40)
            let fresh = reply.object ?? [:]
            option.apply(fresh, url: URL(string: text(fresh["url"])))
            return option
        }
        var request = payload
        for (key, value) in option.line["requestContext"]?.object ?? [:] { request[key] = value }
        for (key, value) in option.quality["requestContext"]?.object ?? [:] { request[key] = value }
        for key in ["qn", "title", "liveCodeType"] { if let value = option.quality[key] { request[key] = value } }
        request["cdn"] = option.line["cdn"]
        let again = options(try await LivePluginRuntime.shared.call(plugin, "getPlayback", request, timeout: 40))
        let match = again.first { text($0.quality["qn"]) == text(option.quality["qn"]) && text($0.line["cdn"]) == text(option.line["cdn"]) && $0.url != nil }
            ?? again.first { $0.id == option.id && $0.url != nil }
        guard let match else { throw TVError.unsupported(L10n.text("This live room has no stream this device can play.")) }
        option.url = match.url; option.headers = match.headers; option.flv = match.flv; option.encrypted = match.encrypted; option.key = match.key
        return option
    }

    static func text(_ value: JSONValue?) -> String {
        switch value {
        case .string(let text): text
        case .number(let number): number == number.rounded() && abs(number) < 1e15 ? String(Int64(number)) : String(number)
        case .bool(let flag): flag ? "true" : "false"
        default: ""
        }
    }

    private static func count(_ value: JSONValue?) -> Int {
        if case .number(let number)? = value { return Int(number) }
        return LiveText.count(text(value))
    }
}

extension Array where Element == LiveRoom {
    func uniqued() -> [LiveRoom] {
        var seen = Set<String>()
        return filter { seen.insert($0.roomID).inserted }
    }
}

extension LivePluginCatalog.Option {
    /// Takes a quality's address, headers and format.
    mutating func apply(_ quality: [String: JSONValue], url: URL?) {
        typealias C = LivePluginCatalog
        self.url = url.flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil }
        var headers = (quality["headers"]?.object ?? [:]).compactMapValues(\.string)
        let agent = C.text(quality["userAgent"])
        if !agent.isEmpty, !headers.keys.contains(where: { $0.lowercased() == "user-agent" }) { headers["User-Agent"] = agent }
        self.headers = headers
        let hinted = C.text(quality["playbackHints"]?.object?["streamFormat"])
        let format = (hinted.isEmpty ? C.text(quality["liveCodeType"]) : hinted).lowercased()
        // Some label any non-HLS file "flv" (Hongguo's MP4s): the address decides when it says otherwise.
        let path = self.url?.path().lowercased() ?? ""
        let file = path.hasSuffix(".mp4") || path.hasSuffix(".m3u8") || path.contains("media-video")
        flv = self.url.map(FLVLive.names) ?? false || (format == "flv" && !file)
        let decryption = quality["decryption"]?.object
        encrypted = decryption != nil
        let method = C.text(decryption?["method"]).lowercased(), key = C.text(decryption?["key"]).lowercased()
        self.key = (method.isEmpty || method == "cenc") && key.count == 32 && key.allSatisfy(\.isHexDigit) ? key : nil
        if self.key != nil { flv = false }
    }
}

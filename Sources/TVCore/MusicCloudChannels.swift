import Foundation

/// The music channels: the services that turn a catalog song ID into a temporary audio address. None of them is
/// part of the app. The recommended sources' subscription (`CloudSources`) lists them under `yingxiaMusic`, with
/// what each is called, the catalogs it plays and the order to ask them in, and serves one script that asks them.
/// The app runs that script on the device, like the subscription's other sources, and probes whatever it answers.
///
/// The script's contract: `play(flag, id)` with `flag` the JSON `{channel, platform, quality, key}` answers
/// `{url, header?, claimed?, upstream?}` or `{error, detail?}`, where `error` names a `MusicProviderError`.
public enum CloudMusic {
    /// One channel, as the subscription describes it.
    public struct Channel: Identifiable, Hashable, Sendable {
        public let id: MusicProviderID
        public let platforms: Set<MusicPlatform>
        /// Requests the channel allows every five minutes (`MusicHealth.window`), when it sets a limit.
        public let budget: Int?
        let fallbackName: String
        let names: [String: String]
        let details: [String: String]
        let credits: [String: String]
        let keyLabels: [String: String]

        init?(json: [String: JSONValue]) {
            guard let id = json["id"]?.string, !id.isEmpty else { return nil }
            let platforms = Set((json["platforms"]?.array ?? []).compactMap { $0.string.flatMap(MusicPlatform.init(rawValue:)) }).subtracting([.ext])
            guard !platforms.isEmpty else { return nil }
            self.id = MusicProviderID(rawValue: id); self.platforms = platforms
            budget = json["budget"]?.int.flatMap { $0 > 0 ? $0 : nil }
            fallbackName = json["name"]?.string ?? id
            names = Self.texts(json["names"]); details = Self.texts(json["details"])
            credits = Self.texts(json["credit"]); keyLabels = Self.texts(json["key"])
        }

        public var name: String { Self.pick(names) ?? fallbackName }
        /// The catalogs it plays, in words.
        public var detail: String { Self.pick(details) ?? "" }
        /// What the player shows while the channel's audio plays, for a service that asks to be named.
        public var credit: String? { Self.pick(credits) }
        /// The name of the key the listener must enter before the channel is used; nil when it needs none.
        public var keyLabel: String? { Self.pick(keyLabels) }

        static func texts(_ json: JSONValue?) -> [String: String] { json?.object?.compactMapValues(\.string) ?? [:] }
        static func pick(_ texts: [String: String]) -> String? {
            (texts[L10n.resolvedLanguage()] ?? texts["en"]).flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    /// What `yingxiaMusic` says.
    public struct Listing: Sendable {
        /// The script's address, relative to the subscription's.
        public let api: String
        public let channels: [Channel]
        public let routes: MusicRoutes
        let noteTexts: [[String: String]]

        init?(json: JSONValue?) {
            guard let json = json?.object, let api = json["api"]?.string, !api.isEmpty else { return nil }
            let channels = (json["channels"]?.array ?? []).compactMap { $0.object.flatMap(Channel.init(json:)) }
            guard !channels.isEmpty else { return nil }
            self.api = api; self.channels = channels
            let order = (json["order"]?.array ?? []).compactMap { pair -> MusicRoutes.Route? in
                guard let pair = pair.array, pair.count == 2, let platform = pair[0].string.flatMap(MusicPlatform.init(rawValue:)), let id = pair[1].string,
                      channels.contains(where: { $0.id.rawValue == id && $0.platforms.contains(platform) }) else { return nil }
                return MusicRoutes.Route(platform, MusicProviderID(rawValue: id))
            }
            routes = MusicRoutes(order: order, primaries: max(0, min(order.count, json["primaries"]?.int ?? 0)))
            noteTexts = (json["notes"]?.array ?? []).map(Channel.texts)
        }

        public func channel(_ id: MusicProviderID) -> Channel? { channels.first { $0.id == id } }
        /// What the listener should know about the channels, under their switches.
        public var notes: [String] { noteTexts.compactMap(Channel.pick) }
    }

    /// The channels of the latest copy of the subscription; nil until the app has one.
    public static var current: Listing? { CloudSources.music }
}

/// The order channels are asked in: each catalog's first choice, then the fallbacks.
public struct MusicRoutes: Sendable {
    public struct Route: Hashable, Sendable {
        public var platform: MusicPlatform
        public var provider: MusicProviderID
        public init(_ platform: MusicPlatform, _ provider: MusicProviderID) { self.platform = platform; self.provider = provider }
    }
    public var order: [Route]
    /// How many of `order`, from the start, are first choices: these run side by side, the rest one at a time.
    public var primaries: Int

    public init(order: [Route], primaries: Int) { self.order = order; self.primaries = primaries }

    /// The subscription's order, then the LX Music sources the listener imported: third-party scripts, asked when
    /// the channels before them found nothing better.
    public static var current: MusicRoutes {
        var routes = CloudMusic.current?.routes ?? MusicRoutes(order: [], primaries: 0)
        routes.order += [MusicPlatform.qq, .netease, .kuwo, .migu].map { Route($0, .lx) }
        return routes
    }

    func isPrimary(_ candidate: MusicCandidate) -> Bool {
        order.prefix(primaries).contains(Route(candidate.platform, candidate.provider))
    }
}

/// One channel of the subscription, asked through its script.
public struct CloudMusicProvider: MusicStreamProvider {
    public let id: MusicProviderID
    public let platforms: Set<MusicPlatform>
    let api: String
    let key: String
    let health: MusicHealth

    public init(channel: CloudMusic.Channel, api: String, key: String = "", health: MusicHealth = .shared) {
        id = channel.id; platforms = channel.platforms; self.api = api; self.health = health
        self.key = key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func resolve(_ songID: String, platform: MusicPlatform, quality: MusicAudioQuality) async throws -> ResolvedMusicStream {
        try await health.admit(id.rawValue)
        let asked: [String: JSONValue] = ["channel": .string(id.rawValue), "platform": .string(platform.rawValue),
                                          "quality": .string(quality.rawValue), "key": .string(key)]
        let flag = String(decoding: try JSONEncoder().encode(asked), as: UTF8.self)
        // Each channel has a runtime of its own, so one waiting on its service never holds up another.
        let site = Site(key: "music." + id.rawValue, name: id.rawValue, type: 3, api: api,
                        raw: ["yingxia": .object(["builtin": .bool(true)]), "ext": .object([:])])
        let reply: [String: JSONValue]
        do {
            reply = try await ScriptRuntime.shared.request(site: site, scriptURL: try WebAddress.resolve(api, relativeTo: CloudSources.address),
                                                           params: ["play": songID, "flag": flag], http: HTTPClient(), origin: CloudSources.address)
        } catch let error as TVError {
            // The script could not be fetched or did not run; its own text never reaches the listener.
            if case .http = error { throw MusicProviderError.network("script") }
            throw MusicProviderError.invalidResponse("script")
        } catch { throw MusicProviderError(error) }
        return try Self.stream(reply)
    }

    /// The script's answer as a stream, or the failure it names.
    static func stream(_ reply: [String: JSONValue], now: Date = Date()) throws -> ResolvedMusicStream {
        if let failure = reply["error"]?.string {
            let detail = String((reply["detail"]?.string ?? "").prefix(80))
            switch failure {
            case "noResource": throw MusicProviderError.noResource
            case "upstreamRisk": throw MusicProviderError.upstreamRisk
            case "rateLimited": throw MusicProviderError.rateLimited(until: nil)
            case "authRequired": throw MusicProviderError.authRequired
            case "timeout": throw MusicProviderError.timeout
            case "network": throw MusicProviderError.network(detail.isEmpty ? "script request" : detail)
            default: throw MusicProviderError.invalidResponse(detail.isEmpty ? failure : detail)
            }
        }
        guard let address = reply["url"]?.string, let url = URL(string: address), url.host() != nil,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { throw MusicProviderError.noResource }
        return ResolvedMusicStream(url: url, headers: reply["header"]?.object?.compactMapValues(\.string) ?? [:],
                                   claimedQuality: reply["claimed"]?.string, resolvedAt: now, upstream: reply["upstream"]?.string)
    }
}

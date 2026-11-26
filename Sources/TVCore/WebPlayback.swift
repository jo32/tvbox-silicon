import Foundation

/// A subscription `parses` entry: a service that turns a web player page into a media address.
public struct ParseService: Hashable, Sendable {
    public let name: String
    /// TVBox parse type: 0 sniffs in a web view, 1 answers JSON, 2-4 aggregate the others.
    public let type: Int
    public let url: String
    public let headers: [String: String]
    /// Episode flags from `ext.flag`. Empty means this parser applies to every flag.
    public let flags: [String]
    /// TVBox parse `click`, used when a type 4 sniff runs this parser rather than the selected one.
    public let click: String
    public init(name: String, type: Int, url: String, headers: [String: String], flags: [String] = [], click: String = "") {
        self.name = name
        self.type = type
        self.url = url
        self.headers = headers
        self.flags = flags
        self.click = click
    }
}

extension Subscription {
    public var parseServices: [ParseService] {
        (raw["parses"]?.array ?? []).compactMap { item in
            guard let fields = item.object, let url = fields["url"]?.string, let type = fields["type"]?.int else { return nil }
            let headers = fields["ext"]?.object?["header"]?.object?.compactMapValues(\.string) ?? [:]
            return ParseService(name: fields["name"]?.string ?? url, type: type, url: url, headers: headers,
                                flags: Self.sniffStrings(fields["ext"]?.object?["flag"]), click: fields["click"]?.string ?? "")
        }
    }
    public var sniffAds: [String] { Self.sniffStrings(raw["ads"]) }
    public var sniffRules: [SniffRule] {
        (raw["rules"]?.array ?? []).compactMap { item in
            guard let fields = item.object else { return nil }
            return SniffRule(hosts: Self.sniffStrings(fields["hosts"]), regex: Self.sniffStrings(fields["regex"]),
                             script: Self.sniffStrings(fields["script"]), exclude: Self.sniffStrings(fields["exclude"]),
                             click: Self.sniffStrings(fields["click"]))
        }
    }
    private static func sniffStrings(_ value: JSONValue?) -> [String] {
        if let text = value?.string { return text.isEmpty ? [] : [text] }
        return value?.array?.compactMap(\.string).filter { !$0.isEmpty } ?? []
    }
}

/// Resolves web player pages without a web view, which tvOS does not have: first by reading the
/// address the page embeds, then by asking the subscription's JSON parse services in parallel.
enum WebPlayback {
    static func resolve(page: String, headers: [String: String], parses: [ParseService], http: HTTPClient) async -> (url: URL, headers: [String: String])? {
        guard let pageURL = try? WebAddress.resolve(page) else { return nil }
        if let (data, _) = try? await http.get(pageURL, headers: headers),
           let address = embeddedMedia(in: String(decoding: data, as: UTF8.self), base: pageURL) {
            return (address, headers)
        }
        // A dead JSON service hangs until the HTTP timeout. That wait sits in front of the
        // 15 second sniff, so the fast path gives up after 8 seconds and lets sniff start.
        return await first(within: 8) { await askParseServices(page: page, parses: parses, http: http) }
    }

    private static func first(within seconds: TimeInterval, _ operation: @escaping @Sendable () async -> (url: URL, headers: [String: String])?) async -> (url: URL, headers: [String: String])? {
        await withTaskGroup(of: (url: URL, headers: [String: String])?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let answer = await group.next() ?? nil
            group.cancelAll()
            return answer
        }
    }

    private static let playerData = try! NSRegularExpression(pattern: #"player_[A-Za-z0-9_]+\s*=\s*(\{.*?\})\s*[;<]"#, options: [.dotMatchesLineSeparators])
    private static let mediaAddress = try! NSRegularExpression(pattern: #"https?:(?:\\?/){2}[^"'\s<>()]+?\.(?:m3u8|mp4)(?:\?[^"'\s<>()]*)?"#, options: [.caseInsensitive])

    /// MacCMS pages embed `player_aaaa = {"url": ..., "encrypt": 0|1|2}`; other players write the address inline.
    static func embeddedMedia(in html: String, base: URL) -> URL? {
        let whole = NSRange(html.startIndex..., in: html)
        if let match = playerData.firstMatch(in: html, range: whole), let range = Range(match.range(at: 1), in: html),
           let object = try? JSONSerialization.jsonObject(with: Data(html[range].utf8)) as? [String: Any],
           var address = object["url"] as? String {
            switch (object["encrypt"] as? Int) ?? Int("\(object["encrypt"] ?? 0)") ?? 0 {
            case 1: address = address.removingPercentEncoding ?? address
            case 2: address = Data(base64Encoded: address).map { String(decoding: $0, as: UTF8.self) }?.removingPercentEncoding ?? address
            default: break
            }
            if let url = try? WebAddress.resolve(address, relativeTo: base), CatalogClient.isDirectMedia(url.absoluteString) { return url }
        }
        if let match = mediaAddress.firstMatch(in: html, range: whole), let range = Range(match.range, in: html) {
            return try? WebAddress.resolve(html[range].replacingOccurrences(of: "\\/", with: "/"))
        }
        return nil
    }

    /// TVBox's JSON parse contract: GET service + page address, answer `{"url": ...}` (sometimes under `data`).
    static func askJSON(service: String, page: String, headers requestHeaders: [String: String], http: HTTPClient) async -> (url: URL, headers: [String: String])? {
        guard let request = try? WebAddress.resolve(service + page),
              let (data, _) = try? await http.get(request, headers: requestHeaders, fresh: true),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let payload = (object["data"] as? [String: Any]) ?? object
        guard let address = payload["url"] as? String, address.lowercased().hasPrefix("http"),
              let url = try? WebAddress.resolve(address), url.absoluteString != page,
              CatalogClient.isDirectMedia(address) || address.contains(".m3u8") || address.contains(".mp4") else { return nil }
        var headers = (payload["header"] as? [String: String]) ?? (payload["headers"] as? [String: String]) ?? [:]
        if let agent = (payload["user-agent"] ?? payload["User-Agent"] ?? payload["ua"]) as? String, !agent.isEmpty { headers["User-Agent"] = agent }
        return (url, headers)
    }

    static func askParseServices(page: String, parses: [ParseService], http: HTTPClient) async -> (url: URL, headers: [String: String])? {
        // Loopback services are answered by a plugin's proxy, which only exists while that plugin runs.
        let services = parses.filter { $0.type == 1 && $0.url.lowercased().hasPrefix("http") && !$0.url.contains("127.0.0.1") && !$0.url.contains("localhost") }
        guard !services.isEmpty else { return nil }
        return await withTaskGroup(of: (url: URL, headers: [String: String])?.self) { group in
            var pending = services.prefix(24).makeIterator()
            func ask(_ service: ParseService) {
                group.addTask {
                    await askJSON(service: service.url, page: page, headers: service.headers, http: http)
                }
            }
            // Like TVBox's concurrent JSON parsing: a few services at a time, first usable answer wins.
            for _ in 0..<6 { if let next = pending.next() { ask(next) } }
            while let answer = await group.next() {
                if let answer { group.cancelAll(); return answer }
                if let next = pending.next() { ask(next) }
            }
            return nil
        }
    }
}

import Foundation

public enum TVError: LocalizedError, Sendable {
    case invalidURL, invalidConfiguration, emptyPlaylist, http(Int), unsupported(String)
    public var errorDescription: String? {
        switch self {
        case .invalidURL: L10n.text("Enter a valid HTTP or HTTPS URL.")
        case .invalidConfiguration: L10n.text("No valid TVBox sources or live playlists were found.")
        case .emptyPlaylist: L10n.text("No HTTP/HTTPS channels were found in this playlist.")
        case .http(let code): L10n.text("The server returned HTTP %lld.", code)
        case .unsupported(let reason): reason
        }
    }
}

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public var string: String? {
        switch self {
        case .string(let v): v
        case .number(let v): v.rounded() == v ? String(format: "%.0f", v) : String(v)
        default: nil
        }
    }
    public var int: Int? { string.flatMap(Int.init) }
    public var object: [String: JSONValue]? { if case .object(let v) = self { v } else { nil } }
    public var array: [JSONValue]? { if case .array(let v) = self { v } else { nil } }
}

public enum WebAddress {
    public static func resolve(_ text: String, relativeTo base: URL? = nil) throws -> URL {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Encode Unicode without re-encoding existing %HH sequences. Foundation's
        // automatic repair can otherwise turn %26 into %2526 in mixed Unicode URLs.
        var allowed = CharacterSet.urlFragmentAllowed
        allowed.insert(charactersIn: "#[]")
        guard !value.isEmpty, let escaped = value.addingPercentEncoding(withAllowedCharacters: allowed) else { throw TVError.invalidURL }
        let encoded = escaped.replacingOccurrences(of: "%25([0-9A-Fa-f]{2})", with: "%$1", options: .regularExpression)
        guard var components = URLComponents(string: encoded) else { throw TVError.invalidURL }
        // Setting the decoded host asks Foundation to apply IDNA (Punycode).
        if let host = components.host { components.host = host }
        guard let url = components.url(relativeTo: base)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { throw TVError.invalidURL }
        return url
    }
}

public struct Site: Identifiable, Codable, Hashable, Sendable {
    public let key: String
    public let name: String
    public let type: Int
    public let api: String
    public let raw: [String: JSONValue]
    public var id: String { key }
    public var native: Bool { type == 1 || type == 4 }
    public func pluginURL(origin: URL, fallback: URL?) throws -> URL? {
        guard let address = raw["jar"]?.string, !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallback }
        return try WebAddress.resolve(address.components(separatedBy: ";md5;")[0], relativeTo: origin)
    }
    func pluginExtension(origin: URL?) throws -> JSONValue? {
        guard let origin else { return raw["ext"] }
        func resolve(_ value: JSONValue) throws -> JSONValue {
            switch value {
            case .string(let text) where text.hasPrefix("./") || text.hasPrefix("../") || text.hasPrefix("//"):
                return .string(try WebAddress.resolve(text, relativeTo: origin).absoluteString)
            case .object(let fields): return .object(try fields.mapValues(resolve))
            case .array(let items): return .array(try items.map(resolve))
            default: return value
            }
        }
        return try raw["ext"].map(resolve)
    }
    public var compatibility: String {
        if native { return L10n.text("Standard API") }
        #if os(macOS)
        if type == 3 { return api.hasPrefix("csp_") ? L10n.text("Local JAR · Experimental") : L10n.text("Local JavaScript · Experimental") }
        #endif
        if type == 3 { return api.hasPrefix("csp_") ? L10n.text("Requires Android plugin") : L10n.text("Requires script engine") }
        return L10n.text("Unsupported API")
    }
    public static func == (lhs: Site, rhs: Site) -> Bool { lhs.key == rhs.key && lhs.raw == rhs.raw }
    public func hash(into hasher: inout Hasher) { hasher.combine(key) }
}

public struct LiveSource: Identifiable, Codable, Hashable, Sendable {
    public let name: String
    public let url: URL
    public let headers: [String: String]
    public var id: String { name + "|" + url.absoluteString }
    public init(name: String, url: URL, headers: [String: String] = [:]) {
        self.name = name; self.url = url; self.headers = headers
    }
}

public struct Subscription: Codable, Sendable {
    public let origin: URL
    public let importedAt: Date
    public let sites: [Site]
    public let lives: [LiveSource]
    public let raw: [String: JSONValue]
    public var spiderURL: URL? {
        guard let text = raw["spider"]?.string?.components(separatedBy: ";md5;").first else { return nil }
        return try? WebAddress.resolve(text, relativeTo: origin)
    }
    public static func parse(_ data: Data, origin: URL) throws -> Subscription {
        let raw = try SubscriptionDocument.decode(data)
        if raw["sites"] == nil, raw["lives"] == nil,
           raw["urls"] != nil || raw["storeHouse"] != nil {
            throw TVError.unsupported(L10n.text("This URL is a subscription directory. Import an individual subscription URL from it."))
        }
        var seen = Set<String>()
        let sites = (raw["sites"]?.array ?? []).compactMap { entry -> Site? in
            guard let v = entry.object, let key = v["key"]?.string, !key.isEmpty,
                  let api = v["api"]?.string, let type = v["type"]?.int, seen.insert(key).inserted else { return nil }
            return Site(key: key, name: v["name"]?.string ?? key, type: type, api: api, raw: v)
        }
        let lives = (raw["lives"]?.array ?? []).compactMap { entry -> LiveSource? in
            guard let v = entry.object, let address = v["url"]?.string,
                  let url = try? WebAddress.resolve(address, relativeTo: origin) else { return nil }
            var headers = v["header"]?.object?.compactMapValues(\.string) ?? [:]
            if let ua = v["ua"]?.string { headers["User-Agent"] = ua }
            return LiveSource(name: v["name"]?.string ?? L10n.text("Live TV"), url: url, headers: headers)
        }
        guard !sites.isEmpty || !lives.isEmpty else { throw TVError.invalidConfiguration }
        return Subscription(origin: origin, importedAt: Date(), sites: sites, lives: lives, raw: raw)
    }
}

public struct Channel: Identifiable, Codable, Hashable, Sendable {
    public let name: String
    public let group: String
    public let url: URL
    public let logo: URL?
    public let headers: [String: String]
    public var displayGroup: String { group.isEmpty ? L10n.text("Ungrouped") : group }
    public var id: String { group + "|" + name + "|" + url.absoluteString }
    public init(name: String, group: String = "", url: URL, logo: URL? = nil, headers: [String: String] = [:]) {
        self.name = name; self.group = group; self.url = url; self.logo = logo; self.headers = headers
    }
}

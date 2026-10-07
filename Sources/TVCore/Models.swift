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

/// A plugin host's error envelope: a user-facing reason, plus a diagnostics line that keeps the
/// error code and stack trace so a failing source can be fixed later without reproducing it.
public enum PluginFailure {
    public static func message(_ envelope: [String: JSONValue], language: String? = nil) -> String? {
        guard let detail = envelope["error"]?.string else { return nil }
        let missing = envelope["missingClass"]?.string
        switch envelope["errorCode"]?.string {
        case "source_http":
            if let host = envelope["host"]?.string, let status = envelope["status"]?.int {
                return L10n.text("The source %@ returned HTTP %lld.", host, status, language: language)
            }
        case "source_network":
            if let host = envelope["host"]?.string { return L10n.text("The source %@ could not be reached. Retry later.", host, language: language) }
        case "source_empty": return L10n.text("The plugin returned no content. Try another source.", language: language)
        case "unsupported_native_library": return L10n.text("This plugin is not supported: ftyguard_v8.so is missing.", language: language)
        case "unsupported_android":
            if let missing { return L10n.text("This source needs an Android feature that isn't supported yet: %@.", missing, language: language) }
            return L10n.text("This source requires Android features that the plugin runtime does not support yet.", language: language)
        case "class_conversion":
            return L10n.text("This plugin couldn't be prepared on this device (missing %@).", missing ?? detail, language: language)
        case "plugin_crash":
            return L10n.text("The source's plugin crashed. The site may have changed; try another source.", language: language)
        default: break
        }
        // The spider class is not in the JAR the subscription points at: a subscription error, not a site error.
        if let name = PluginClassMissing.className(in: detail) {
            return L10n.text("This subscription's plugin package doesn't include %@. Ask the subscription's maintainer or use another source.", name, language: language)
        }
        return L10n.text("Plugin error: %@", detail, language: language)
    }

    /// The plugin itself failed (crash, conversion, Android gap), as opposed to the site or network.
    static func inPlugin(_ envelope: [String: JSONValue]) -> Bool {
        switch envelope["errorCode"]?.string {
        case "plugin_crash", "unsupported_android", "class_conversion", nil: return envelope["error"] != nil
        default: return false
        }
    }

    public static func diagnostic(source: String, _ envelope: [String: JSONValue]) -> String {
        var line = "source=\(source) code=\(envelope["errorCode"]?.string ?? "unclassified") \(envelope["error"]?.string ?? "")"
        if let missing = envelope["missingClass"]?.string { line += " missingClass=\(missing)" }
        if let trace = envelope["trace"]?.string, !trace.isEmpty { line += "\n" + trace }
        return line
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

/// How a source runs, in preference order. `SourceStrategy` lists, searches, and defaults to lower
/// ranks first: a standard JSON API is one HTTP request, Python and Node start in well under a
/// second, and a JAR needs the JVM plus DEX conversion on first use.
public enum SourceRuntime: Int, Comparable, Sendable {
    case api, python, javascript, jar, unsupported
    public static func < (lhs: SourceRuntime, rhs: SourceRuntime) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct Site: Identifiable, Codable, Hashable, Sendable {
    public let key: String
    public let name: String
    public let type: Int
    public let api: String
    public let raw: [String: JSONValue]
    public var id: String { key }
    public var native: Bool { (type == 1 || type == 4) && !missingAPI }
    /// Merged subscriptions sometimes carry entries with an empty api; they cannot run anywhere.
    private var missingAPI: Bool { api.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
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
    /// Classified like TVBox: a `.js` api runs in the JavaScript host, a `.py` api (or a legacy
    /// `py_` key whose ext is the script) in the Python host, and any other type 3 api is a JAR class.
    public var runtime: SourceRuntime {
        if native { return .api }
        guard type == 3, !missingAPI else { return .unsupported }
        let path = api.lowercased()
        if path.hasSuffix(".js") || path.contains(".js?") { return .javascript }
        if path.contains(".py") || (api.hasPrefix("py_") && raw["ext"]?.string?.lowercased().contains(".py") == true) { return .python }
        return .jar
    }
    /// The script a JavaScript or Python source runs, relative to the subscription.
    public func scriptURL(origin: URL) throws -> URL {
        if runtime == .python, api.hasPrefix("py_"), let script = raw["ext"]?.string { return try WebAddress.resolve(script, relativeTo: origin) }
        return try WebAddress.resolve(api, relativeTo: origin)
    }
    public var compatibility: String {
        switch runtime {
        case .api: return L10n.text("Standard API")
        case .unsupported: return L10n.text("Unsupported API")
        case .javascript, .python:
            #if os(macOS)
            if runtime == .javascript { return L10n.text("Local JavaScript · Experimental") }
            if LocalJarHost.pythonAvailable { return L10n.text("Local Python · Experimental") }
            #else
            if runtime == .javascript, ScriptRuntime.available { return L10n.text("Local JavaScript · Experimental") }
            #endif
            return L10n.text("Requires script engine")
        case .jar:
            if runsLitePort { return L10n.text("Lite JavaScript · JAR fallback") }
            #if os(macOS) || os(iOS) || os(tvOS)
            if EmbeddedJarHost.available { return L10n.text("Local JAR · Experimental") }
            #endif
            return L10n.text("Requires Android plugin")
        }
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

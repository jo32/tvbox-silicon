import Foundation
import Observation

/// How one source (or a whole subscription) reaches its upstream.
///
/// A source that can be reached directly on this network may go down at any time; its domain may be
/// SNI-blocked, or its host may start refusing plain connections. `SourceRouting` remembers the viewer's
/// choice and, in `.auto`, follows `SourceHealth` so a source that stops answering directly is retried
/// through the relay and switched back once the direct line recovers.
public enum SourceRoute: String, Codable, CaseIterable, Sendable {
    /// Follow connectivity: direct first, relay when the direct line is failing.
    case auto
    /// Always hit the source's own address (its `api` as imported).
    case direct
    /// Always route through the relay, whatever the direct line is doing.
    case proxy

    public var title: String {
        switch self {
        case .auto: return L10n.text("Auto")
        case .direct: return L10n.text("Direct")
        case .proxy: return L10n.text("Proxy")
        }
    }
}

/// Subscription-qualified routing choices. The key scheme matches `PinnedSources` and `HiddenSources`,
/// so a choice survives re-imports and merges; a source not listed falls back to its subscription's route.
@MainActor @Observable public final class SourceRouting {
    private var values: [String: SourceRoute]
    /// Bumps when a choice changes, so a cached source list can be reused until then.
    public private(set) var revision = 0
    private let defaults: UserDefaults
    /// Called after the list changes here (not after `adopt`), for iCloud sync.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?
    private static let storageKey = "sourceRouting.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let raw = defaults.dictionary(forKey: Self.storageKey) as? [String: String] ?? [:]
        values = raw.compactMapValues { SourceRoute(rawValue: $0) }
    }

    private func key(_ site: Site, origin: URL) -> String {
        EpisodeSkipSettings.scope(origin: site.origin(or: origin), source: site.sourceKey, video: "")
    }

    /// The explicit route for this source, or nil when it follows its subscription (or `.auto`).
    public func route(_ site: Site, origin: URL) -> SourceRoute? { values[key(site, origin: origin)] }

    /// The route actually used: an explicit choice first, then the subscription's own route.
    public func effectiveRoute(_ site: Site, origin: URL, subscription: SourceRoute?) -> SourceRoute {
        values[key(site, origin: origin)] ?? subscription ?? .auto
    }

    public func set(_ route: SourceRoute, for site: Site, origin: URL) {
        let k = key(site, origin: origin)
        values[k] = route
        persist()
    }

    /// Clears an explicit choice so the source follows its subscription again.
    public func clear(_ site: Site, origin: URL) {
        let k = key(site, origin: origin)
        guard values.removeValue(forKey: k) != nil else { return }
        persist()
    }

    /// The saved choices, as iCloud sync compares them.
    public var savedValues: [String: String] { values.mapValues(\.rawValue) }
    /// The list merged with other devices'.
    public func adopt(_ raw: [String: String]) {
        let next = raw.compactMapValues { SourceRoute(rawValue: $0) }
        guard next != values else { return }
        values = next
        persist()
    }

    private func persist() {
        defaults.set(values.mapValues(\.rawValue), forKey: Self.storageKey)
        revision += 1
        onChange?()
    }
}

/// Rewrites a source's `api` between its own address and the relay address, so a viewer can flip a
/// whole subscription (or one source) between direct and proxied without editing the subscription.
public enum SourceRelay {
    /// The public relay that fronts a source's HTTP API and its media.
    public static let host = "149.104.28.149"
    public static let port = 8100
    /// The token that gates the relay.
    public static let token = "rex8f3a2c1d"

    /// The relay prefix used for the CMS (list/detail/search) API.
    public static var cmsPrefix: String { "http://\(host):\(port)/cms/\(token)/" }

    /// Whether an address already points at our relay.
    public static func isRelayed(_ api: String) -> Bool {
        api.contains("\(host):\(port)/cms/") || api.contains("\(host):\(port)/cmsr/")
    }

    /// The source's own (direct) address, stripping our relay prefix when present.
    public static func directAddress(_ api: String) -> String {
        let needle = "\(host):\(port)/"
        guard let range = api.range(of: needle) else { return api }
        let after = api[range.upperBound...]
        // /cms/<token>/<host>/<path> or /cmsr/<token>/<host>/<path>
        let parts = after.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return api }
        // parts[0] is cms|cmsr, parts[1] is the token, the rest is host + optional path
        guard parts.count >= 3 else { return api }
        // cmsr marks a source that was https; the relay itself is always http.
        let scheme = parts[0] == "cmsr" ? "https" : "http"
        return "\(scheme)://" + parts.dropFirst(2).joined(separator: "/")
    }

    /// The relay address for a source's own address. Non-HTTP apis (JAR/csp classes, local files)
    /// are returned unchanged: only native CMS endpoints are relayed.
    public static func relayedAddress(_ api: String) -> String {
        guard let url = URL(string: api), let sourceHost = url.host(),
              url.scheme == "http" || url.scheme == "https" else { return api }
        guard !isRelayed(api) else { return api }
        // Encode the whole direct address behind the relay so nothing is lost:
        // http — /cms/<token>/<host[:port]>/<path[?query]>; https — /cmsr/<token>/…
        let route = url.scheme == "https" ? "cmsr" : "cms"
        var target = sourceHost
        if let sourcePort = url.port { target += ":\(sourcePort)" }
        var path = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        if let query = url.query { path += "?\(query)" }
        return "http://\(host):\(port)/\(route)/\(token)/\(target)/\(path)"
    }

    /// Applies a route to a source's api string.
    public static func apply(_ route: SourceRoute, to api: String, directOK: Bool = true) -> String {
        switch route {
        case .direct: return directAddress(api)
        case .proxy: return relayedAddress(api)
        case .auto: return api
        }
    }
}

extension Site {
    /// A copy whose `api` is rewritten to the given route. Only native (type 1/4) CMS endpoints can be
    /// relayed; a JAR/csp class or built-in source is returned unchanged.
    public func routed(_ route: SourceRoute) -> Site {
        guard native, !api.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return self }
        let next = SourceRelay.apply(route, to: api)
        guard next != api else { return self }
        var raw = self.raw
        raw["api"] = .string(next)
        var copy = Site(key: key, name: name, type: type, api: next, raw: raw)
        copy.provenance = provenance
        copy.detectedRuntime = detectedRuntime
        return copy
    }
}

import Foundation
import Observation

/// Settings for the Web Cast feature: whether the embedded web server is on, and the port it listens
/// on for computers on the same network. Persisted like `CustomProxyStore` in `UserDefaults`.
///
/// The compile-time gate `WEBCAST` (an `SWIFT_ACTIVE_COMPILATION_CONDITIONS` flag set in `project.yml`)
/// makes the whole feature optional at build time: an IPA built without `WEBCAST` has no web server,
/// no settings row and no web UI. A build with it gets the feature, off by default, plus a default port
/// read from the Info.plist key `WebCastDefaultPort` (also settable per target in `project.yml`).
@MainActor @Observable public final class WebCastSettings {
    public static let shared = WebCastSettings()

    /// Whether the web server should run. Off by default; the viewer turns it on in Settings.
    public var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Self.enabledKey) }
    }
    /// The TCP port the web server listens on. Changing it restarts the server.
    public var port: Int {
        didSet { defaults.set(port, forKey: Self.portKey) }
    }
    /// Whether the login password is required. When off, anyone on the network can drive the app.
    public var requiresToken: Bool {
        didSet { defaults.set(requiresToken, forKey: Self.requiresTokenKey) }
    }
    /// The login password the viewer sets in Settings. Empty means no password; the web UI prompts for
    /// it and sends it back as an `X-WebCast-Token` header. Persisted, unlike the old random token.
    public var token: String {
        didSet { defaults.set(token, forKey: Self.tokenKey) }
    }
    /// Whether the web player relays streams through the phone's proxy (`/proxy`). On by default: the
    /// proxy solves Referer/HTTPS/anti-hotlink, but it consumes the phone's upload bandwidth. Turning it
    /// off makes the browser fetch streams directly — lighter on the phone, but only works for sources
    /// that allow a browser's direct request.
    public var proxyMedia: Bool {
        didSet { defaults.set(proxyMedia, forKey: Self.proxyMediaKey) }
    }

    private let defaults: UserDefaults
    private static let enabledKey = "webCast.enabled"
    private static let portKey = "webCast.port"
    private static let requiresTokenKey = "webCast.requiresToken"
    private static let tokenKey = "webCast.token"
    private static let proxyMediaKey = "webCast.proxyMedia"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? false
        self.port = (defaults.object(forKey: Self.portKey) as? Int) ?? Self.defaultPort
        self.requiresToken = defaults.object(forKey: Self.requiresTokenKey) as? Bool ?? false
        self.token = defaults.string(forKey: Self.tokenKey) ?? ""
        self.proxyMedia = defaults.object(forKey: Self.proxyMediaKey) as? Bool ?? true
    }

    /// The port a fresh install starts with: the Info.plist `WebCastDefaultPort`, else 8090.
    public static var defaultPort: Int {
        let configured = Bundle.main.object(forInfoDictionaryKey: "WebCastDefaultPort") as? NSNumber
        let value = configured?.intValue ?? 8090
        return (1...65535).contains(value) ? value : 8090
    }
}

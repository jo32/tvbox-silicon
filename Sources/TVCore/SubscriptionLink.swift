import Foundation

/// A link that asks Yingxia to add a subscription, as a web page shares one:
/// `yingxia://import?url=<percent-encoded address>&name=<optional>`. The app confirms it before fetching
/// anything, so a page can point at a subscription but never add one on its own (#167).
public struct SubscriptionImportLink: Sendable, Equatable, Identifiable {
    public static let scheme = "yingxia"
    public static let action = "import"

    /// The subscription's address, as it will be fetched.
    public let address: URL
    /// What to call it in Settings; nil leaves the address's own host, as typing one there without a name does.
    public let name: String?

    public var id: String { address.absoluteString }

    public init?(_ url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, url.host()?.lowercased() == Self.action,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let typed = items.first(where: { $0.name == "url" })?.value,
              // The same reading as an address typed in Settings: http or https with a host, IDN hosts in Punycode.
              let address = try? WebAddress.resolve(typed) else { return nil }
        self.address = address
        name = Self.clean(items.first(where: { $0.name == "name" })?.value)
    }

    /// The link a page writes for `address`, which is also how this type is tested: a link read back gives
    /// the same address and name.
    public init(address: URL, name: String? = nil) {
        self.address = address
        self.name = Self.clean(name)
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.action
        components.queryItems = [URLQueryItem(name: "url", value: address.absoluteString)]
            + (name.map { [URLQueryItem(name: "name", value: $0)] } ?? [])
        return components.url!
    }

    private static func clean(_ name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return name
    }
}

/// `yingxia://install-source?source=<key or address>`: a live plugin source to add (Settings › Live Plugins),
/// as plugin sites write `angellive://install-source` links.
public struct LivePluginSourceLink: Sendable, Equatable, Identifiable {
    public let source: String
    public var id: String { source }

    public init?(_ url: URL) {
        guard url.scheme?.lowercased() == SubscriptionImportLink.scheme, url.host()?.lowercased() == "install-source",
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "source" })?.value,
              case let source = value.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty,
              LivePlugins.sourceAddress(source) != nil else { return nil }
        self.source = source
    }
}

import Foundation

/// Telegram's public preview (`t.me`) is blocked on some networks, which leaves a channel's posts — and the
/// search over them — out of reach. A channel address may name the entry that reads it instead:
/// `https://proxy.example/https://t.me/<channel>`, the prefix-proxy form GitHub files already take
/// (`GitHubMirrors`). The channel is still t.me's own; only the address its pages come from changes, and that
/// entry is kept with the source (`ext.endpoint`) so a reloaded or merged subscription reads the same way (#2556).
struct TelegramEndpoint: Equatable, Sendable {
    /// The hosts a channel address names, and the only ones a preview page is read from.
    static let hosts: Set<String> = ["t.me", "telegram.me", "telegram.dog", "www.t.me"]

    /// `t.me` itself, or the proxy's prefix (`https://proxy.example`).
    let base: URL

    static let direct = TelegramEndpoint(base: URL(string: "https://t.me")!)

    var isDirect: Bool { Self.hosts.contains(base.host()?.lowercased() ?? "") }

    /// The entry `url` names, and the t.me address it names it for: the address as it is, or the proxy's prefix
    /// in front of it. Nil for any other address, whose host names no channel.
    static func split(_ url: URL) -> (endpoint: TelegramEndpoint, telegram: URL)? {
        if let host = url.host()?.lowercased(), hosts.contains(host) { return (.direct, url) }
        let text = url.absoluteString
        // The prefix, then the address it wraps; browsers take the inner slashes doubled or not.
        guard let range = text.range(of: #"/https?:/+((?:www\.)?t\.me|telegram\.me|telegram\.dog)(?=[/?#]|$)"#,
                                     options: .regularExpression) else { return nil }
        let prefix = String(text[text.startIndex..<range.lowerBound])
        let inner = String(text[range.lowerBound...].dropFirst())
            .replacingOccurrences(of: #"(?i)^(https?):/+"#, with: "$1://", options: .regularExpression)
        guard let base = URL(string: prefix), let host = base.host, !host.isEmpty,
              let telegram = URL(string: inner) else { return nil }
        return (TelegramEndpoint(base: base), telegram)
    }

    /// `telegram`, read through this entry: the address as it is, or the prefix in front of it.
    func address(_ telegram: URL) -> URL {
        let inner = Self.split(telegram)?.telegram ?? telegram
        guard !isDirect else { return inner }
        let prefix = base.absoluteString.hasSuffix("/") ? String(base.absoluteString.dropLast()) : base.absoluteString
        return URL(string: prefix + "/" + inner.absoluteString) ?? inner
    }

    /// The t.me page at `path`, with `query`, read through this entry.
    func address(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "t.me"
        components.path = path.hasPrefix("/") ? path : "/" + path
        if !query.isEmpty { components.queryItems = query }
        let telegram = components.url ?? URL(string: "https://t.me")!
        return address(telegram)
    }

    /// The entry a source keeps, written with it as `ext.endpoint`; a source that names none reads t.me directly.
    static func endpoint(of site: Site) -> TelegramEndpoint {
        guard let text = site.raw["ext"]?.object?["endpoint"]?.string,
              let base = URL(string: text), base.host != nil else { return .direct }
        return TelegramEndpoint(base: base)
    }
}

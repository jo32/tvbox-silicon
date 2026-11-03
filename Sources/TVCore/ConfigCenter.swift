import Foundation

/// A source's own config center: a page it serves from inside this app, which only this device can open. A CatPawOpen
/// bundle's (#311), or a Java plugin's, such as the Wex family's 配置中心 (#360).
public enum ConfigCenter {
    /// The page a source's entry sends the viewer to, as this device opens it, or nil.
    public static func page(of video: Video, site: Site) -> URL? {
        if let page = CatPawOpen.configCenter(of: video, site: site) { return page }
        // Wex answers every entry with "如果弹窗没有显示，请打开网页版配置中心：http://192.168.1.5:19988/config": the plugin's
        // own server, at this device's network address so that a phone could scan it.
        guard site.api.hasPrefix("csp_") else { return nil }
        let text = video.synopsis + "\n" + video.remarks
        guard let range = text.range(of: #"http://[0-9A-Za-z.-]+:[0-9]+/config\b"#, options: .regularExpression),
              let url = URL(string: String(text[range])) else { return nil }
        return local(url)
    }

    /// The address on loopback when it points at this device, for example at its Wi-Fi address; nil for another host.
    /// Wex's server redirects to the plugin proxy at this device's network address, but the proxy only listens on
    /// loopback, and loopback needs neither a network nor local network access.
    public static func local(_ url: URL) -> URL? {
        guard url.scheme == "http", let host = url.host() else { return nil }
        if ["127.0.0.1", "localhost", "::1"].contains(host) { return url }
        guard ownAddresses().contains(host), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.host = "127.0.0.1"
        return parts.url
    }

    /// The IPv4 and IPv6 addresses of this device's interfaces that are up.
    static func ownAddresses() -> Set<String> {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var found: Set<String> = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, entry.ifa_flags & UInt32(IFF_UP) != 0,
                  [UInt8(AF_INET), UInt8(AF_INET6)].contains(address.pointee.sa_family) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            // A link-local IPv6 address comes with its interface (fe80::1%en0); a URL's host has none.
            found.insert(String(text.prefix { $0 != "%" }))
        }
        return found
    }
}

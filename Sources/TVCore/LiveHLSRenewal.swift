import Foundation

/// The deliberately small class of signed live roots that can change without
/// replacing an HLS input. Masters, finished media and changed stream identities
/// need the normal playback preparation path instead.
public enum LiveHLSRenewal {
    public struct Endpoint: Hashable, Sendable {
        public let url: URL
        public let headers: [String: String]
        public init(url: URL, headers: [String: String]) {
            self.url = url
            var normalized: [String: String] = [:]
            for name in headers.keys.sorted() { normalized[name.lowercased()] = headers[name] }
            self.headers = normalized
        }
    }

    public static func directMedia(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first(where: { !$0.isEmpty }) == "#EXTM3U", lines.contains(where: { $0.hasPrefix("#EXTINF:") }),
              lines.contains(where: { !$0.isEmpty && !$0.hasPrefix("#") }), !text.contains("{$") else { return false }
        return !lines.contains { line in
            line == "#EXT-X-ENDLIST" || line == "#EXT-X-PLAYLIST-TYPE:VOD"
                || ["#EXT-X-STREAM-INF:", "#EXT-X-I-FRAME-STREAM-INF:", "#EXT-X-MEDIA:", "#EXT-X-DEFINE:"].contains(where: line.hasPrefix)
        }
    }

    public static func compatible(_ previous: URL, _ next: URL) -> Bool {
        guard let a = URLComponents(url: previous, resolvingAgainstBaseURL: false),
              let b = URLComponents(url: next, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(a.scheme?.lowercased() ?? ""),
              a.scheme?.lowercased() == b.scheme?.lowercased(), a.host?.lowercased() == b.host?.lowercased(),
              a.host != nil, port(a) == port(b), a.percentEncodedPath == b.percentEncodedPath,
              a.user == nil, a.password == nil, a.fragment == nil,
              b.user == nil, b.password == nil, b.fragment == nil else { return false }
        return identity(a) == identity(b)
    }

    private static func port(_ url: URLComponents) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
    private static let authentication: Set<String> = ["wssecret", "wstime", "txsecret", "txtime", "seqid", "u", "uid", "token", "sign", "signature", "expire", "expires", "timestamp", "ts", "nonce", "auth_key", "auth"]
    private static func identity(_ url: URLComponents) -> [String: [String?]] {
        let fields = (url.percentEncodedQueryItems ?? []).filter { !authentication.contains($0.name.lowercased()) }
        return Dictionary(grouping: fields, by: \.name).mapValues { $0.map(\.value) }
    }
}

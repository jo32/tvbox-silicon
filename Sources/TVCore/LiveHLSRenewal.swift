import Foundation

/// A signed live HLS playlist renewed in place (`HLSProxy.renewsLive(with:)`): when its server refuses a reload because
/// the signature in its address expired, the source gives a fresh address and the same player item reads on from it.
/// That is only safe for the same stream: the address but for its signature (`compatible`), a live media playlist
/// (`directMedia`), and a window that carries on from the one AVPlayer read last (`Window.continues(to:)`). Anything
/// else gets the refusal, and the player opens the stream again as it always did.
public enum LiveHLSRenewal {
    /// How soon after a renewal a refusal isn't renewed again: the fresh address was refused at once.
    public static let cooldown: Duration = .seconds(15)
    /// The most renewals of one stream: a signature that lasts two minutes, for more than six hours.
    public static let limit = 200

    /// Whether `text` is a live media playlist: segments, no end, and nothing (variants, renditions, definitions) that
    /// would make a fresh address another stream.
    public static func directMedia(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first(where: { !$0.isEmpty }) == "#EXTM3U", lines.contains(where: { $0.hasPrefix("#EXTINF:") }),
              lines.contains(where: { !$0.isEmpty && !$0.hasPrefix("#") }), !text.contains("{$") else { return false }
        return !lines.contains { line in
            line == "#EXT-X-ENDLIST" || line == "#EXT-X-PLAYLIST-TYPE:VOD"
                || ["#EXT-X-STREAM-INF:", "#EXT-X-I-FRAME-STREAM-INF:", "#EXT-X-MEDIA:", "#EXT-X-DEFINE:"].contains(where: line.hasPrefix)
        }
    }

    /// Whether `next` is `previous` but for its signature: the same scheme, host, port and path, and the same query
    /// fields in the same order once the signing ones (`authentication`) are left out.
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
    private static let authentication: Set<String> = ["wssecret", "wstime", "txsecret", "txtime", "seqid", "u", "uid", "token", "sign", "signature",
                                                      "expire", "expires", "timestamp", "ts", "nonce", "auth_key", "auth"]
    private static func identity(_ url: URLComponents) -> [String: [String?]] {
        let fields = (url.percentEncodedQueryItems ?? []).filter { !authentication.contains($0.name.lowercased()) }
        return Dictionary(grouping: fields, by: \.name).mapValues { $0.map(\.value) }
    }

    /// What a live media playlist lists: each segment by its media sequence number, with its address and discontinuity
    /// number, and the addresses its tags name (keys, initialization sections).
    public struct Window: Sendable, Equatable {
        public struct Segment: Sendable, Equatable {
            public let url: URL
            public let discontinuity: Int
        }
        public let segments: [Int: Segment]
        public let tags: [URL]
        public var first: Int { segments.keys.min() ?? 0 }
        public var last: Int { segments.keys.max() ?? -1 }

        /// The window of `text`, whose relative addresses resolve against `origin`; nil unless it is a live media playlist.
        public init?(_ text: String, origin: URL) {
            guard LiveHLSRenewal.directMedia(text) else { return nil }
            var sequence = 0, discontinuity = 0, started = false
            var segments: [Int: Segment] = [:], tags: [URL] = []
            func number(_ line: String, after tag: String) -> Int? { Int(line.dropFirst(tag.count).trimmingCharacters(in: .whitespaces)) }
            for raw in text.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
                if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                    if !started { sequence = number(line, after: "#EXT-X-MEDIA-SEQUENCE:") ?? 0 }
                } else if line.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE:") {
                    if !started { discontinuity = number(line, after: "#EXT-X-DISCONTINUITY-SEQUENCE:") ?? 0 }
                } else if line == "#EXT-X-DISCONTINUITY" {
                    discontinuity += 1
                } else if line.hasPrefix("#") {
                    if let address = HLSSanitizer.attribute("URI", in: line), let url = URL(string: address, relativeTo: origin)?.absoluteURL { tags.append(url) }
                } else {
                    guard let url = URL(string: line, relativeTo: origin)?.absoluteURL else { return nil }
                    segments[sequence] = Segment(url: url, discontinuity: discontinuity)
                    sequence += 1; started = true
                }
            }
            guard !segments.isEmpty else { return nil }
            self.segments = segments
            self.tags = tags
        }

        /// Whether `next`, the window of a fresh address, carries on from this one, which AVPlayer read last: they share
        /// a segment, `next` skips none after this one's last and doesn't end before it, and where they overlap each
        /// number is the same segment (but for its signature) with the same discontinuity number. A window in which two
        /// segments differ only by their signature can't be told apart from another stream's, so it doesn't carry on.
        public func continues(to next: Window) -> Bool {
            guard next.first <= last, next.last >= last, next.segments.keys.contains(where: { segments[$0] != nil }) else { return false }
            let ordered = next.segments.sorted { $0.key < $1.key }
            for (index, (number, segment)) in ordered.enumerated() {
                if let old = segments[number], !LiveHLSRenewal.compatible(old.url, segment.url) || old.discontinuity != segment.discontinuity { return false }
                if ordered[(index + 1)...].contains(where: { LiveHLSRenewal.compatible($0.value.url, segment.url) }) { return false }
            }
            return true
        }
    }
}

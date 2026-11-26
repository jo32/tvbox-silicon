import Foundation

/// Who asks for a playlist's guide: the source, where its playlist comes from, the headers it is asked with and the
/// time zone of its per-channel dates. The source's headers (an account's token or cookie) go only to the source's
/// own origin; a guide elsewhere gets only those that say who is asking.
public struct GuideRequestContext: Hashable, Sendable {
    public let sourceID: String
    public let origin: URL?
    public let headers: [String: String]
    public let timeZone: TimeZone

    public init(sourceID: String = "", origin: URL? = nil, headers: [String: String] = [:],
                timeZone: TimeZone = ProgramGuide.chinaTime) {
        self.sourceID = sourceID; self.origin = origin; self.timeZone = timeZone
        var normalized: [String: String] = [:]
        for key in headers.keys.sorted() { normalized[key.lowercased()] = headers[key] }
        self.headers = normalized
    }

    /// The headers a guide at `target` is asked with.
    func headers(for target: URL) -> [String: String] { Self.inherited(headers, from: origin, to: target) }

    /// All of `headers` on the same scheme, host and port as `origin`; elsewhere only User-Agent, Accept and
    /// Accept-Language.
    static func inherited(_ headers: [String: String], from origin: URL?, to target: URL) -> [String: String] {
        func port(_ url: URL) -> Int? { url.port ?? ["http": 80, "https": 443][url.scheme?.lowercased() ?? ""] }
        if let origin, origin.scheme?.lowercased() == target.scheme?.lowercased(),
           origin.host?.lowercased() == target.host?.lowercased(), port(origin) == port(target) { return headers }
        return headers.filter { ["user-agent", "accept", "accept-language"].contains($0.key.lowercased()) }
    }
}

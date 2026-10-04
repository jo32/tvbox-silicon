import Foundation
import Observation

public struct PosterResource: Hashable, Sendable {
    public let url: URL
    public let headers: [String: String]
    public init(url: URL, headers: [String: String] = [:]) { self.url = url; self.headers = headers }
    public init?(address: String, origin: URL) {
        // TVBox appends transport headers to artwork URLs. Do not send that suffix as part of the URL.
        let pattern = #"@(Headers|Cookie|Referer|User-Agent)="#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let text = address as NSString
        let matches = regex.matches(in: address, range: NSRange(location: 0, length: text.length))
        let endpoint = matches.first.map { text.substring(to: $0.range.location) } ?? address
        guard let url = try? WebAddress.resolve(endpoint, relativeTo: origin) else { return nil }
        var headers: [String: String] = [:]
        for (index, match) in matches.enumerated() {
            let start = NSMaxRange(match.range)
            let end = index + 1 < matches.count ? matches[index + 1].range.location : text.length
            let value = text.substring(with: NSRange(location: start, length: end - start))
            let name = text.substring(with: match.range(at: 1))
            if name.lowercased() == "headers", let data = value.data(using: .utf8),
               let values = try? JSONDecoder().decode([String: String].self, from: data) {
                headers.merge(values) { _, new in new }
            } else if name.lowercased() != "headers" { headers[name] = value }
        }
        self.init(url: url, headers: headers.filter { $0.key.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil && !$0.value.contains("\r") && !$0.value.contains("\n") })
    }
}

public struct Recommendation: Identifiable, Hashable, Sendable {
    public enum Destination: Hashable, Sendable {
        case search(String)
        case detail(Video)
    }
    public let id: String
    public let name: String
    public let poster: PosterResource?
    public let remarks: String
    public let destination: Destination

    public init?(json: [String: JSONValue], origin: URL, isIndex: Bool) {
        let title = (json["vod_name"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let video = Video(json: json, origin: origin)
        // Index actions are provider controls, not title recommendations.
        if (isIndex || video == nil), !(json["action"]?.string ?? "").isEmpty { return nil }
        name = title
        poster = json["vod_pic"]?.string.flatMap { PosterResource(address: $0, origin: origin) }
        remarks = json["vod_remarks"]?.string ?? ""
        if !isIndex, let video {
            id = "video:" + video.id; destination = .detail(video)
        } else {
            id = "search:" + title; destination = .search(title)
        }
    }
}

@MainActor @Observable public final class RecommendationModel {
    public private(set) var items: [Recommendation] = []
    public private(set) var site: Site?
    public private(set) var busy = false
    public private(set) var error: String?
    private struct Cached {
        let items: [Recommendation]
        let date: Date
    }
    private var cache: [String: Cached] = [:]
    private var identity: String?
    private var generation = UUID()
    public init() {}

    public func reset() {
        generation = UUID(); identity = nil; cache = [:]
        items = []; site = nil; busy = false; error = nil
    }

    public func load(client: CatalogClient, subscriptionDate: Date, force: Bool = false) async {
        let key = "\(client.origin)|\(subscriptionDate.timeIntervalSince1970)|\(client.site.key)"
        let token = UUID(); generation = token
        if identity != key { items = [] }
        identity = key; site = client.site; error = nil
        if !force, let cached = cache[key], Date().timeIntervalSince(cached.date) < 600 {
            items = cached.items; busy = false; return
        }
        busy = true
        do {
            let result = try await client.recommendations()
            try Task.checkCancellation()
            guard generation == token else { return }
            items = result; busy = false
            cache[key] = Cached(items: result, date: Date())
            if cache.count > 4, let oldest = cache.min(by: { $0.value.date < $1.value.date })?.key { cache[oldest] = nil }
        } catch {
            guard generation == token else { return }
            busy = false
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}

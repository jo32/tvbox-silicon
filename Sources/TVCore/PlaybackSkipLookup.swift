import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Looks up opening and ending markers independently: the first valid answer for each kind wins.
public enum PlaybackSkipLookup {
    /// The viewer's opt-in (Settings): off unless turned on, since each lookup tells three outside services what is
    /// playing (#2653).
    public static let enabledKey = "player.onlineSkipMarkers"
    public static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    public struct Media: Hashable, Sendable {
        public let tmdbID: Int?
        public let imdbID: String?
        public let season: Int?
        public let episode: Int?
        public let isMovie: Bool
        public let duration: Double

        public init(tmdbID: Int? = nil, imdbID: String? = nil, season: Int? = nil,
                    episode: Int? = nil, isMovie: Bool = false, duration: Double) {
            self.tmdbID = tmdbID
            self.imdbID = imdbID
            self.season = season
            self.episode = episode
            self.isMovie = isMovie
            self.duration = duration
        }
    }

    /// The duration must be known. Cancel the consuming task when the playing media changes.
    /// Each snapshot includes every marker already accepted, even if the other kind arrived later.
    /// A 15-second total deadline ends the stream even if a provider keeps sending data.
    public static func lookup(_ media: Media, session: URLSession = .shared) -> AsyncStream<[PlaybackSkip]> {
        lookup(media, transport: { try await session.data(for: $0) })
    }

    enum Provider: CaseIterable, Equatable, Sendable { case theOtherDB, theIntroDB, introDB }
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private enum Event: Sendable { case response([PlaybackSkip]), deadline }

    /// Injecting the transport and deadline keeps request contracts and completion races testable.
    static func lookup(_ media: Media, transport: @escaping Transport,
                       waitForDeadline: @escaping @Sendable () async throws -> Void = {
                           try await Task.sleep(for: .seconds(15))
                       }) -> AsyncStream<[PlaybackSkip]> {
        let requests = Provider.allCases.compactMap { provider in
            request(for: provider, media: media).map { (provider, $0) }
        }
        return AsyncStream { continuation in
            guard !requests.isEmpty else { continuation.finish(); return }
            let worker = Task {
                await withTaskGroup(of: Event.self) { group in
                    // Finish inside the group body: a slow child's cancellation cleanup must not
                    // delay the final snapshot or the consumer seeing the end of the stream.
                    defer { group.cancelAll(); continuation.finish() }
                    group.addTask {
                        try? await waitForDeadline()
                        return .deadline
                    }
                    for (provider, request) in requests {
                        group.addTask {
                            guard !Task.isCancelled else { return .response([]) }
                            do {
                                let (data, response) = try await transport(request)
                                guard !Task.isCancelled, let http = response as? HTTPURLResponse,
                                      (200..<300).contains(http.statusCode) else { return .response([]) }
                                return .response(parse(data, from: provider, duration: media.duration))
                            } catch {
                                // No-data, HTTP failures and one provider's own cancellation are local.
                                return .response([])
                            }
                        }
                    }
                    var intro: [PlaybackSkip]?, outro: [PlaybackSkip]?
                    var remaining = requests.count
                    for await event in group {
                        guard !Task.isCancelled, case .response(let segments) = event else { return }
                        remaining -= 1
                        var changed = false
                        if intro == nil {
                            let found = segments.filter { $0.kind == .intro }
                            if !found.isEmpty { intro = found; changed = true }
                        }
                        if outro == nil {
                            let found = segments.filter { $0.kind == .outro }
                            if !found.isEmpty { outro = found; changed = true }
                        }
                        if changed { continuation.yield((intro ?? []) + (outro ?? [])) }
                        if remaining == 0 || (intro != nil && outro != nil) { return }
                    }
                }
            }
            continuation.onTermination = { @Sendable _ in worker.cancel() }
        }
    }

    static func request(for provider: Provider, media: Media) -> URLRequest? {
        guard media.duration.isFinite, media.duration > 0 else { return nil }
        let tmdbID = media.tmdbID.flatMap { $0 > 0 ? $0 : nil }
        let imdbID = validIMDbID(media.imdbID)
        let minimumSeason = provider == .introDB ? 1 : 0
        if !media.isMovie {
            guard let season = media.season, season >= minimumSeason,
                  let episode = media.episode, episode >= 1 else { return nil }
            if provider == .theIntroDB, season > 9_999 || episode > 10_000 { return nil }
        }

        let address: String
        var query: [URLQueryItem] = []
        var body: Data?
        switch provider {
        case .theOtherDB:
            guard let tmdbID else { return nil }
            address = "https://playback.theotherdb.org/api/metadata"
            body = try? JSONEncoder().encode(MetadataQuery(
                platformType: media.isMovie ? "tmdb_id_movie" : "tmdb_id_tv", platformValue: String(tmdbID),
                seasonNumber: media.isMovie ? nil : media.season, episodeNumber: media.isMovie ? nil : media.episode))
            guard body != nil else { return nil }
        case .theIntroDB:
            address = "https://api.theintrodb.org/v4/media"
            if let tmdbID { query.append(.init(name: "tmdb_id", value: String(tmdbID))) }
            else if let imdbID { query.append(.init(name: "imdb_id", value: imdbID)) }
            else { return nil }
            if !media.isMovie {
                query += [.init(name: "season", value: media.season.map(String.init)),
                          .init(name: "episode", value: media.episode.map(String.init))]
            }
            let milliseconds = media.duration * 1_000
            if milliseconds.isFinite {
                query.append(.init(name: "duration_ms", value: String(format: "%.0f", milliseconds)))
            }
        case .introDB:
            guard let imdbID else { return nil }
            address = "https://api.introdb.app/segments"
            query.append(.init(name: "imdb_id", value: imdbID))
            if media.isMovie { query.append(.init(name: "is_movie", value: "true")) }
            else {
                query += [.init(name: "season", value: media.season.map(String.init)),
                          .init(name: "episode", value: media.episode.map(String.init))]
            }
        }
        guard var components = URLComponents(string: address) else { return nil }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private struct MetadataQuery: Encodable {
        let platformType: String, platformValue: String
        let seasonNumber: Int?, episodeNumber: Int?
        let includes = ["marker"]
        let page = 1, pageSize = 30
        enum CodingKeys: String, CodingKey {
            case platformType = "platform_type", platformValue = "platform_value"
            case seasonNumber = "season_number", episodeNumber = "episode_number"
            case includes, page, pageSize = "page_size"
        }
    }

    private static func validIMDbID(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.hasPrefix("tt"), (9...10).contains(value.utf8.count),
              value.utf8.dropFirst(2).allSatisfy({ (48...57).contains($0) }) else { return nil }
        return value
    }

    static func parse(_ data: Data, from provider: Provider, duration: Double) -> [PlaybackSkip] {
        guard duration.isFinite, duration > 0,
              let root = (try? JSONDecoder().decode(JSONValue.self, from: data))?.object else { return [] }
        let segments: [PlaybackSkip]
        switch provider {
        case .theOtherDB:
            // One version only, on the normal first page (up to 30). Never combine markers from
            // different cuts of an episode, or crawl a provider's version history in the background.
            var best: (distance: Double, segments: [PlaybackSkip])?
            for item in root["items"]?.array ?? [] {
                guard let item = item.object, let runtime = number(item["version_runtime"]), runtime > 0 else { continue }
                // Reject a different cut whose runtime is over a minute away: the times of a version that long or
                // short are the times of another cut.
                let distance = abs(runtime - duration)
                guard distance <= 60 else { continue }
                let found = (item["marker"]?.array ?? []).compactMap { value -> PlaybackSkip? in
                    guard let marker = value.object, case .string(let name) = marker["marker_type"],
                          let kind = markerKind(name), let start = number(marker["time_start"]),
                          let end = number(marker["time_end"]) else { return nil }
                    return validated(start: start, end: end, kind: kind, duration: duration)
                }
                if !found.isEmpty, distance < (best?.distance ?? .infinity) { best = (distance, found) }
            }
            segments = best?.segments ?? []
        case .theIntroDB:
            segments = [("intro", PlaybackSkip.Kind.intro), ("credits", .outro)].flatMap { name, kind in
                (root[name]?.array ?? []).compactMap { value -> PlaybackSkip? in
                    guard let marker = value.object else { return nil }
                    // Only explicit null has these meanings; missing or malformed fields do not.
                    let start = kind == .intro && marker["start_ms"] == .null ? 0 : milliseconds(marker["start_ms"])
                    let end = kind == .outro && marker["end_ms"] == .null ? duration : milliseconds(marker["end_ms"])
                    guard let start, let end else { return nil }
                    return validated(start: start, end: end, kind: kind, duration: duration)
                }
            }
        case .introDB:
            segments = [("intro", PlaybackSkip.Kind.intro), ("outro", .outro)].compactMap { name, kind in
                guard root["no_" + name] != .bool(true), let marker = root[name]?.object,
                      let start = milliseconds(marker["start_ms"]), let end = milliseconds(marker["end_ms"]) else { return nil }
                // start_sec/end_sec duplicate the millisecond fields: converting both would scale twice.
                return validated(start: start, end: end, kind: kind, duration: duration)
            }
        }
        return Array(Set(segments)).sorted {
            if $0.kind != $1.kind { return $0.kind == .intro }
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.end < $1.end
        }
    }

    private static func markerKind(_ name: String) -> PlaybackSkip.Kind? {
        switch name { case "intro": .intro; case "credits": .outro; default: nil }
    }

    // JSONValue.double also accepts strings elsewhere in TVCore. Remote marker fields must be numbers.
    private static func number(_ value: JSONValue?) -> Double? {
        guard case .number(let number) = value, number.isFinite else { return nil }
        return number
    }

    private static func milliseconds(_ value: JSONValue?) -> Double? { number(value).map { $0 / 1_000 } }

    private static func validated(start: Double, end: Double, kind: PlaybackSkip.Kind, duration: Double) -> PlaybackSkip? {
        // PlaybackSkip.current excludes the final second, so shorter markers cannot win.
        guard start.isFinite, end.isFinite, start >= 0, end - start > 1, end <= duration,
              !(start == 0 && end == duration) else { return nil }
        return PlaybackSkip(start: start, end: end, kind: kind)
    }
}

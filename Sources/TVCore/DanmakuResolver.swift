import Foundation

public struct DanmakuResolver: Sendable {
    public let cache: MediaCache
    public let http: DanmakuHTTP
    public let dandanServer: String
    public let dmkuServer: URL
    /// Asked for an official page's comments when dmku fails or has none. It takes `type=json&id=<page>`.
    public let backupServer: URL?
    public let officialLookup: Bool
    public static let defaultBackupServer = URL(string: "https://danmu.zxz.ee/")!
    public init(cache: MediaCache = .shared, http: DanmakuHTTP = .init(),
                dandanServer: String = CatalogDanmakuClient.defaultServer, dmkuServer: URL = URL(string: "https://dmku.hls.one/")!,
                backupServer: URL? = Self.defaultBackupServer, officialLookup: Bool = true) {
        self.cache = cache; self.http = http; self.dandanServer = (try? CatalogDanmakuClient(address: dandanServer).server.absoluteString) ?? dandanServer
        self.dmkuServer = dmkuServer; self.backupServer = backupServer; self.officialLookup = officialLookup
    }
    public static func episodeKey(_ context: PlaybackHistoryContext) -> String {
        CatalogDanmakuMatcher.episodeNumber(context.episodeName).map { "episode:\($0)" } ?? context.episodeName
    }
    private func lookupKey(_ context: PlaybackHistoryContext) -> String {
        String(data: try! JSONEncoder().encode([CatalogDanmakuMatcher.normalized(context.videoName), context.year ?? "", dandanServer, dmkuServer.absoluteString]), encoding: .utf8)!
    }
    private struct Outcome: Sendable {
        var result: AutomaticDanmakuResult?
        var mapping: DanmakuMapping?
        var responded = false
        /// Dandanplay answered and has no work with this title.
        var unlisted = false
    }
    public func remember(_ mapping: DanmakuMapping, for context: PlaybackHistoryContext, ticket: MediaCache.Ticket) {
        let key = lookupKey(context)
        var mappings = cache.data(for: key, kind: .lookup).flatMap { try? JSONDecoder().decode([DanmakuMapping].self, from: $0) } ?? []
        mappings.removeAll { $0.provider == mapping.provider }; mappings.append(mapping)
        if let data = try? JSONEncoder().encode(mappings) {
            cache.store(data, for: key, kind: .lookup, ttl: 30 * 86400, ticket: ticket)
        }
    }
    private func keep(_ mapping: DanmakuMapping?, in mappings: inout [DanmakuMapping], key: String, ticket: MediaCache.Ticket) {
        guard let mapping, !mapping.tracks.isEmpty else { return }
        mappings.removeAll { $0.provider == mapping.provider }; mappings.append(mapping)
        if let data = try? JSONEncoder().encode(mappings) {
            cache.store(data, for: key, kind: .lookup, ttl: 30 * 86400, ticket: ticket)
        }
    }
    private func keep(_ result: AutomaticDanmakuResult, context: PlaybackHistoryContext, ticket: MediaCache.Ticket) -> AutomaticDanmakuResult {
        if let data = try? JSONEncoder().encode(result) {
            cache.store(data, for: Self.episodeKey(context), kind: .danmaku, scope: context.id, ttl: 7 * 86400, ticket: ticket)
        }
        return result
    }
    public func resolve(_ context: PlaybackHistoryContext, ticket: MediaCache.Ticket? = nil) async throws -> AutomaticDanmakuResult {
        let ticket = ticket ?? cache.ticket()
        let key = Self.episodeKey(context)
        if let data = cache.data(for: key, kind: .danmaku, scope: context.id),
           var result = try? JSONDecoder().decode(AutomaticDanmakuResult.self, from: data),
           ["loaded", "unmatched", "unavailable"].contains(result.state) {
            result.cached = true; return result
        }
        let lookupKey = lookupKey(context)
        var mappings = cache.data(for: lookupKey, kind: .lookup).flatMap { try? JSONDecoder().decode([DanmakuMapping].self, from: $0) } ?? []
        let saved = mappings
        // Dandanplay allows this app few requests, shared by every install, so it goes last: only when the other
        // providers find nothing. A title that already matched there (automatically, or picked by hand) asks it
        // first, as that costs one request; the wait stays bounded so the others aren't held up.
        let dandanSaved = saved.first { $0.provider == "dandan" }
        let dandanFirst = dandanSaved?.track(for: context) != nil
        var responded = false
        if dandanFirst, let outcome = await askDandanplay(context, cached: dandanSaved, lookupKey: lookupKey, wait: 5, ticket: ticket) {
            try Task.checkCancellation()
            responded = outcome.responded
            keep(outcome.mapping, in: &mappings, key: lookupKey, ticket: ticket)
            if let result = outcome.result, !result.comments.isEmpty { return keep(result, context: context, ticket: ticket) }
        }
        let found: AutomaticDanmakuResult? = try await withThrowingTaskGroup(of: Outcome.self) { group in
            if let page = context.officialPage.flatMap({ OfficialVideoPage.validated($0.absoluteString) }) {
                group.addTask {
                    let mapping = DanmakuMapping(provider: "direct", title: context.videoName, year: context.year,
                        tracks: [DanmakuTrack(number: CatalogDanmakuMatcher.episodeNumber(context.episodeName), title: context.episodeName, page: page)])
                    return await self.official(context, provider: "direct", cached: mapping)
                }
            } else if officialLookup {
                for provider in ["iqiyi", "tencent"] {
                    group.addTask { await self.official(context, provider: provider, cached: saved.first { $0.provider == provider }) }
                }
            }
            for try await outcome in group {
                try Task.checkCancellation()
                responded = responded || outcome.responded
                keep(outcome.mapping, in: &mappings, key: lookupKey, ticket: ticket)
                if let result = outcome.result, !result.comments.isEmpty {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
        if let found { return keep(found, context: context, ticket: ticket) }
        if !dandanFirst, let outcome = await askDandanplay(context, cached: dandanSaved, lookupKey: lookupKey, wait: 15, ticket: ticket) {
            try Task.checkCancellation()
            responded = responded || outcome.responded
            keep(outcome.mapping, in: &mappings, key: lookupKey, ticket: ticket)
            if let result = outcome.result, !result.comments.isEmpty { return keep(result, context: context, ticket: ticket) }
        }
        try Task.checkCancellation()
        let result = AutomaticDanmakuResult(comments: [], track: "", source: "", state: responded ? "unmatched" : "unavailable")
        // Short negative caching prevents repeated searches during rapid revisits.
        // An explicit retry bypasses it, and failures expire much sooner than real tracks.
        if let data = try? JSONEncoder().encode(result) {
            cache.store(data, for: key, kind: .danmaku, scope: context.id, ttl: responded ? 300 : 30, ticket: ticket)
        }
        return result
    }
    /// Asks Dandanplay, waiting at most `wait` seconds. nil when it isn't asked: its limit was reached a short
    /// while ago, or it recently had no work with this title (kept a week, so every episode of a series it doesn't
    /// list costs one search, not one each).
    private func askDandanplay(_ context: PlaybackHistoryContext, cached: DanmakuMapping?, lookupKey: String,
                               wait: Int, ticket: MediaCache.Ticket) async -> Outcome? {
        let unlistedKey = "dandan-unlisted|" + lookupKey
        guard !DandanplayPause.isPaused(dandanServer),
              cached?.track(for: context) != nil || cache.data(for: unlistedKey, kind: .lookup) == nil else { return nil }
        let outcome = await withTaskGroup(of: Outcome.self) { group in
            group.addTask { await self.dandan(context, cached: cached) }
            group.addTask {
                try? await Task.sleep(for: .seconds(wait))
                return Outcome()
            }
            let result = await group.next() ?? Outcome()
            group.cancelAll()
            return result
        }
        if outcome.unlisted { cache.store(Data([1]), for: unlistedKey, kind: .lookup, ttl: 7 * 86400, ticket: ticket) }
        return outcome
    }
    private func official(_ context: PlaybackHistoryContext, provider: String, cached: DanmakuMapping?) async -> Outcome {
        let started = Date()
        var stage = "lookup"
        do {
            var mapping = cached
            if mapping?.track(for: context) == nil {
                let catalog = OfficialDanmakuCatalog(http: http)
                mapping = try await provider == "iqiyi" ? catalog.iqiyi(context) : catalog.tencent(context)
            }
            guard let mapping, let track = mapping.track(for: context), let page = track.page,
                  let safe = OfficialVideoPage.validated(page.absoluteString) else { return Outcome(mapping: mapping, responded: true) }
            stage = "comments"
            // dmku first; the backup only when dmku fails or has no comments for the page.
            var servers = [("dmku", dmkuServer, [URLQueryItem(name: "ac", value: "dm"), .init(name: "url", value: safe.absoluteString)])]
            if let backupServer {
                servers.append((backupServer.host() ?? "backup", backupServer, [.init(name: "type", value: "json"), .init(name: "id", value: safe.absoluteString)]))
            }
            var comments: [CatalogDanmakuComment] = [], source = "dmku", failure: Error? = nil, answered = false
            for (name, server, query) in servers {
                var url = URLComponents(url: server, resolvingAgainstBaseURL: false)!
                url.queryItems = query
                do {
                    comments = try CatalogDanmakuParser.parse(await http.send(URLRequest(url: url.url!, timeoutInterval: 35)))
                    source = name; answered = true
                    if !comments.isEmpty { break }
                } catch {
                    if error is CancellationError { throw error }
                    failure = error
                    Diagnostics.shared.record(.debug, "danmaku", "provider=\(provider) server=\(name) failed=\((error as NSError).domain):\((error as NSError).code)")
                }
            }
            if !answered, let failure { throw failure }
            try Task.checkCancellation()
            Diagnostics.shared.record(.debug, "danmaku", "provider=\(provider) server=\(source) comments=\(comments.count) seconds=\(Int(Date().timeIntervalSince(started)))")
            return Outcome(result: AutomaticDanmakuResult(comments: comments, track: mapping.title + " · " + track.title,
                source: source + " · " + provider, state: comments.isEmpty ? "unmatched" : "loaded"), mapping: mapping, responded: true)
        } catch {
            if !(error is CancellationError) {
                let failure = error as NSError
                Diagnostics.shared.record(.debug, "danmaku", "provider=\(provider) stage=\(stage) failed=\(failure.domain):\(failure.code) seconds=\(Int(Date().timeIntervalSince(started)))")
            }
            return Outcome()
        }
    }
    private func dandan(_ context: PlaybackHistoryContext, cached: DanmakuMapping?) async -> Outcome {
        do {
            let client = try CatalogDanmakuClient(address: dandanServer, transport: http)
            var mapping = cached
            if mapping?.track(for: context) == nil {
                guard let anime = CatalogDanmakuMatcher.anime(title: context.videoName, in: try await client.search(context.videoName)) else {
                    return Outcome(responded: true, unlisted: true)
                }
                let episodes = try await client.episodes(anime)
                mapping = DanmakuMapping(provider: "dandan", title: anime.title, year: nil,
                    tracks: episodes.map { DanmakuTrack(number: CatalogDanmakuMatcher.episodeNumber($0.title), title: $0.title, id: $0.id) })
            }
            guard let mapping, let track = mapping.track(for: context), let id = track.id else { return Outcome(mapping: mapping, responded: true) }
            let comments = try await client.comments(CatalogDanmakuEpisode(id: id, title: track.title))
            try Task.checkCancellation()
            return Outcome(result: AutomaticDanmakuResult(comments: comments, track: mapping.title + " · " + track.title,
                source: "Dandanplay", state: comments.isEmpty ? "unmatched" : "loaded"), mapping: mapping, responded: true)
        } catch is DandanplayLimitReached {
            DandanplayPause.pause(dandanServer)
            Diagnostics.shared.record(.debug, "danmaku", "provider=dandan limit reached; not asked for \(Int(DandanplayPause.length / 60)) min")
            return Outcome()
        } catch { return Outcome() }
    }
}

/// When a Dandanplay server last said its request limit was used up. Automatic matching leaves that server alone
/// for a while after, rather than spend each episode's wait on a request it would refuse. Picking comments by hand
/// still asks it and shows why when it refuses.
enum DandanplayPause {
    static let length: TimeInterval = 3600
    nonisolated(unsafe) private static var until: [String: Date] = [:]
    private static let lock = NSLock()
    static func isPaused(_ server: String, now: Date = .now) -> Bool { lock.withLock { (until[server] ?? .distantPast) > now } }
    static func pause(_ server: String, now: Date = .now) { lock.withLock { until[server] = now.addingTimeInterval(length) } }
}

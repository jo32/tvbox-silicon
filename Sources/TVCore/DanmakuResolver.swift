import Foundation

public struct DanmakuResolver: Sendable {
    public let cache: MediaCache
    public let http: DanmakuHTTP
    public let dandanServer: String
    public let dmkuServer: URL
    /// Asked for an official page's comments when dmku fails or has none. It takes `type=json&id=<page>`.
    public let backupServer: URL?
    public let officialLookup: Bool
    public let preferredSource: DanmakuProvider
    private let dandanCredentials: DandanplayCredentials?
    public var isCustomServer: Bool { DanmakuService.isCustomServer(dandanServer) }
    public static let defaultBackupServer = URL(string: "https://danmu.zxz.ee/")!
    public init(cache: MediaCache = .shared, http: DanmakuHTTP = .init(),
                dandanServer: String = CatalogDanmakuClient.defaultServer, dmkuServer: URL = URL(string: "https://dmku.hls.one/")!,
                backupServer: URL? = Self.defaultBackupServer, officialLookup: Bool = true,
                preferredSource: DanmakuProvider = .automatic, dandanCredentials: DandanplayCredentials? = .bundled) {
        self.cache = cache; self.http = http; self.dandanServer = (try? CatalogDanmakuClient(address: dandanServer).server.absoluteString) ?? dandanServer
        self.dmkuServer = dmkuServer; self.backupServer = backupServer; self.officialLookup = officialLookup
        self.preferredSource = preferredSource; self.dandanCredentials = dandanCredentials
    }
    /// Legacy unscoped episode identity. Use the instance method for reading, storing or removing comments.
    public static func episodeKey(_ context: PlaybackHistoryContext) -> String {
        CatalogDanmakuMatcher.explicitEpisodeNumber(context.episodeName).map { "episode:\($0)" } ?? context.episodeName
    }
    /// MediaCache key for this server/platform and episode; pair it with `kind: .danmaku, scope: context.id`.
    public func cacheKey(_ context: PlaybackHistoryContext) -> String {
        String(decoding: try! JSONEncoder().encode(["danmaku-v2", DanmakuService.cacheIdentity(server: dandanServer, preferredSource: preferredSource),
            CatalogDanmakuMatcher.normalized(context.videoName), context.year ?? "", Self.episodeKey(context)]), as: UTF8.self)
    }
    public func forget(_ context: PlaybackHistoryContext) { cache.remove(cacheKey(context), kind: .danmaku, scope: context.id) }
    /// The platform the official server's matching follows. It can follow Dandanplay, iQIYI and Tencent Video (through
    /// their catalogs), and any platform whose official page the source gave. For another one it matches as Automatic:
    /// asking no one and caching "no match" for every episode left the video without comments and gave no reason.
    func officialPreference(_ context: PlaybackHistoryContext) -> DanmakuProvider {
        switch preferredSource {
        case .automatic, .dandan: return preferredSource
        case .iqiyi where officialLookup, .tencent where officialLookup: return preferredSource
        default:
            guard let page = context.officialPage.flatMap({ OfficialVideoPage.validated($0.absoluteString) }),
                  DanmakuProvider(source: CatalogDanmakuMatcher.episodeSource(title: "", url: page)) == preferredSource else { return .automatic }
            return preferredSource
        }
    }
    /// A manual selection replaces prefetched episodes for this work and invalidates their in-flight tickets.
    /// Call after loading the selection, then use the returned ticket for `remember` and `cache`.
    public func invalidateEpisodes(for context: PlaybackHistoryContext) -> MediaCache.Ticket {
        cache.remove(kind: .danmaku, scope: context.id)
        return cache.ticket()
    }
    /// Store manual/imported results using precisely the same namespace as automatic resolution.
    public func cache(_ result: AutomaticDanmakuResult, for context: PlaybackHistoryContext, ticket: MediaCache.Ticket? = nil) {
        if let data = try? JSONEncoder().encode(result) {
            cache.store(data, for: cacheKey(context), kind: .danmaku, scope: context.id, ttl: 7 * 86400, ticket: ticket ?? cache.ticket())
        }
    }
    private func lookupKey(_ context: PlaybackHistoryContext) -> String {
        String(decoding: try! JSONEncoder().encode(["danmaku-mapping-v2", CatalogDanmakuMatcher.normalized(context.videoName), context.year ?? "",
            DanmakuService.cacheIdentity(server: dandanServer, preferredSource: preferredSource), dmkuServer.absoluteString]), as: UTF8.self)
    }
    private struct Outcome: Sendable {
        var result: AutomaticDanmakuResult?
        var mapping: DanmakuMapping?
        var responded = false
        /// Dandanplay answered and has no work with this title.
        var unlisted = false
        /// The episode's official page was found, but no comment server could be reached for it.
        var unreachable = false
    }
    /// How long a comment server that timed out or answered 5xx is left out of automatic matching, so later
    /// episodes don't each wait for it again (a Cloudflare 522 takes ~20 s to arrive).
    static let serverPause: TimeInterval = 600
    private static func pauseKey(_ server: URL) -> String { "danmaku-server-down|" + server.absoluteString }
    /// Whether the server itself failed, rather than had nothing for this page.
    static func serverFailed(_ error: Error) -> Bool {
        if case TVError.http(let code) = error { return code >= 500 }
        if let error = error as? URLError { return error.code != .cancelled }
        return false
    }
    /// Lets the comment servers be asked again at once, for a retry the viewer asked for.
    public func forgetUnreachableServers() {
        for server in [dmkuServer] + (backupServer.map { [$0] } ?? []) { cache.remove(Self.pauseKey(server), kind: .lookup) }
    }
    /// `picked`: the viewer chose this show by hand, so its next episodes follow it even with automatic matching off
    /// (`hasPick`, #963).
    public func remember(_ mapping: DanmakuMapping, for context: PlaybackHistoryContext, ticket: MediaCache.Ticket, picked: Bool = false) {
        // Older callers supplied a plain dandan mapping. Mark it as a custom catalog mapping so the
        // conservative episode matcher is also used for hand-selected custom tracks.
        let mapping = isCustomServer && mapping.source == nil ? DanmakuMapping(provider: mapping.provider,
            title: mapping.title, year: mapping.year, tracks: mapping.tracks, animeID: mapping.animeID, source: mapping.provider) : mapping
        let key = lookupKey(context)
        var mappings = cache.data(for: key, kind: .lookup).flatMap { try? JSONDecoder().decode([DanmakuMapping].self, from: $0) } ?? []
        mappings.removeAll { $0.provider == mapping.provider }; mappings.insert(mapping, at: 0)
        if let data = try? JSONEncoder().encode(mappings) {
            cache.store(data, for: key, kind: .lookup, ttl: 30 * 86400, ticket: ticket)
        }
        if picked { cache.store(Data([1]), for: pickKey(context), kind: .lookup, ttl: 30 * 86400, ticket: ticket) }
    }
    /// Whether the viewer matched this show (title, year, service) by hand.
    public func hasPick(for context: PlaybackHistoryContext) -> Bool { cache.data(for: pickKey(context), kind: .lookup) != nil }
    public func forgetPick(_ context: PlaybackHistoryContext) { cache.remove(pickKey(context), kind: .lookup) }
    private func pickKey(_ context: PlaybackHistoryContext) -> String { "danmaku-pick|" + lookupKey(context) }
    private func keep(_ mapping: DanmakuMapping?, in mappings: inout [DanmakuMapping], key: String, ticket: MediaCache.Ticket) {
        guard let mapping, !mapping.tracks.isEmpty else { return }
        mappings.removeAll { $0.provider == mapping.provider }; mappings.insert(mapping, at: 0)
        if let data = try? JSONEncoder().encode(mappings) {
            cache.store(data, for: key, kind: .lookup, ttl: 30 * 86400, ticket: ticket)
        }
    }
    private func keep(_ result: AutomaticDanmakuResult, context: PlaybackHistoryContext, ticket: MediaCache.Ticket) -> AutomaticDanmakuResult {
        cache(result, for: context, ticket: ticket)
        return result
    }
    /// `first` is asked before the comment servers: the source's own comments (a CatPawOpen bundle's, #506), or nil.
    /// `savedOnly`: automatic matching is off, so only a show matched before (by hand, `hasPick`) is followed and
    /// nothing is searched.
    public func resolve(_ context: PlaybackHistoryContext, ticket: MediaCache.Ticket? = nil,
                        first: (@Sendable (PlaybackHistoryContext) async -> AutomaticDanmakuResult?)? = nil,
                        savedOnly: Bool = false) async throws -> AutomaticDanmakuResult {
        let ticket = ticket ?? cache.ticket()
        try Task.checkCancellation()
        let key = cacheKey(context)
        if let data = cache.data(for: key, kind: .danmaku, scope: context.id),
           var result = try? JSONDecoder().decode(AutomaticDanmakuResult.self, from: data),
           ["loaded", "unmatched", "unavailable"].contains(result.state) {
            result.cached = true; return result
        }
        // A custom service is an explicit routing choice, including when it returns nothing or fails.
        if isCustomServer { return try await resolveCustom(context, ticket: ticket, savedOnly: savedOnly) }
        let preferredSource = officialPreference(context)
        if !savedOnly, preferredSource == .automatic, let first, let result = await first(context), !result.comments.isEmpty {
            try Task.checkCancellation()
            return keep(result, context: context, ticket: ticket)
        }
        try Task.checkCancellation()
        let lookupKey = lookupKey(context)
        var mappings = cache.data(for: lookupKey, kind: .lookup).flatMap { try? JSONDecoder().decode([DanmakuMapping].self, from: $0) } ?? []
        let saved = mappings
        // Dandanplay allows this app few requests, shared by every install, so it goes last: only when the other
        // providers find nothing. A title that already matched there (automatically, or picked by hand) asks it
        // first, as that costs one request; the wait stays bounded so the others aren't held up.
        let dandanSaved = saved.first { $0.provider == "dandan" }
        let allowsDandan = preferredSource == .automatic || preferredSource == .dandan
        // Mappings are kept per platform preference, so a Dandanplay one saved under another preference was picked by
        // hand there; it is used like a platform's hand pick on a custom server, not ignored.
        let dandanFirst = dandanSaved?.track(for: context) != nil
        var responded = preferredSource != .automatic, unreachable = false
        if dandanFirst, let outcome = await askDandanplay(context, cached: dandanSaved, lookupKey: lookupKey, wait: 5, ticket: ticket) {
            try Task.checkCancellation()
            responded = outcome.responded
            keep(outcome.mapping, in: &mappings, key: lookupKey, ticket: ticket)
            if let result = outcome.result, !result.comments.isEmpty { return keep(result, context: context, ticket: ticket) }
        }
        if savedOnly { return AutomaticDanmakuResult(comments: [], track: "", source: "", state: "unmatched") }
        let found: AutomaticDanmakuResult? = try await withThrowingTaskGroup(of: Outcome.self) { group in
            if let page = context.officialPage.flatMap({ OfficialVideoPage.validated($0.absoluteString) }),
               preferredSource == .automatic || DanmakuProvider(source: CatalogDanmakuMatcher.episodeSource(title: "", url: page)) == preferredSource {
                group.addTask {
                    let mapping = DanmakuMapping(provider: "direct", title: context.videoName, year: context.year,
                        tracks: [DanmakuTrack(number: CatalogDanmakuMatcher.episodeNumber(context.episodeName), title: context.episodeName, page: page)])
                    return await self.official(context, provider: "direct", cached: mapping, ticket: ticket)
                }
            } else if officialLookup {
                for provider in ["iqiyi", "tencent"] where preferredSource == .automatic || preferredSource.rawValue == provider {
                    group.addTask { await self.official(context, provider: provider, cached: saved.first { $0.provider == provider }, ticket: ticket) }
                }
            }
            for try await outcome in group {
                try Task.checkCancellation()
                responded = responded || outcome.responded
                unreachable = unreachable || outcome.unreachable
                keep(outcome.mapping, in: &mappings, key: lookupKey, ticket: ticket)
                if let result = outcome.result, !result.comments.isEmpty {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
        if let found { return keep(found, context: context, ticket: ticket) }
        if allowsDandan, !dandanFirst, let outcome = await askDandanplay(context, cached: dandanSaved, lookupKey: lookupKey, wait: 15, ticket: ticket) {
            try Task.checkCancellation()
            responded = responded || outcome.responded
            keep(outcome.mapping, in: &mappings, key: lookupKey, ticket: ticket)
            if let result = outcome.result, !result.comments.isEmpty { return keep(result, context: context, ticket: ticket) }
        }
        try Task.checkCancellation()
        // A page that has comments but whose servers are down is "unavailable", not "no match", even when another
        // provider answered that it doesn't list the title.
        let matched = responded && !unreachable
        let result = AutomaticDanmakuResult(comments: [], track: "", source: "", state: matched ? "unmatched" : "unavailable")
        // Short negative caching prevents repeated searches during rapid revisits.
        // An explicit retry bypasses it, and failures expire much sooner than real tracks.
        if let data = try? JSONEncoder().encode(result) {
            cache.store(data, for: key, kind: .danmaku, scope: context.id, ttl: matched ? 300 : 30, ticket: ticket)
        }
        return result
    }
    private func resolveCustom(_ context: PlaybackHistoryContext, ticket: MediaCache.Ticket, savedOnly: Bool = false) async throws -> AutomaticDanmakuResult {
        guard !DandanplayPause.isPaused(dandanServer) else { return customNegative(context, state: "unavailable", ticket: ticket) }
        let key = lookupKey(context)
        var mappings = cache.data(for: key, kind: .lookup).flatMap { try? JSONDecoder().decode([DanmakuMapping].self, from: $0) } ?? []
        // Mappings are kept per platform preference (`lookupKey`), so any saved one was found for this preference or
        // picked by hand under it, possibly from another platform; a hand pick is kept rather than searched again.
        let saved = mappings.first { $0.track(for: context) != nil }
        var mapping = saved
        do {
            let client = try CatalogDanmakuClient(address: dandanServer, transport: http, credentials: dandanCredentials)
            if mapping == nil {
                if savedOnly { return AutomaticDanmakuResult(comments: [], track: "", source: "", state: "unmatched") }
                mapping = try await customMapping(context, client: client)
            }
            if let selected = mapping, let track = selected.track(for: context), let id = track.id {
                let comments: [CatalogDanmakuComment]
                do {
                    comments = try await client.comments(CatalogDanmakuEpisode(id: id, title: track.title))
                } catch TVError.http(404) where saved != nil {
                    // Only a saved ID is stale. Refresh once, preserving the selected catalog/platform.
                    mapping = try await refreshedCustomMapping(context, saved: selected, client: client)
                    guard let refreshed = mapping, let fresh = refreshed.track(for: context), let freshID = fresh.id else {
                        return customNegative(context, state: "unmatched", ticket: ticket)
                    }
                    comments = try await client.comments(CatalogDanmakuEpisode(id: freshID, title: fresh.title))
                }
                try Task.checkCancellation()
                if let mapping, let selectedTrack = mapping.track(for: context) {
                    keep(mapping, in: &mappings, key: key, ticket: ticket)
                    let platform = DanmakuProvider(source: selectedTrack.source ?? mapping.source ?? mapping.provider)
                    let source = platform == .automatic ? mapping.source ?? mapping.provider : platform.title
                    let result = AutomaticDanmakuResult(comments: comments, track: mapping.title + " · " + selectedTrack.title,
                        source: source, state: comments.isEmpty ? "unmatched" : "loaded")
                    return comments.isEmpty ? customNegative(context, state: "unmatched", ticket: ticket) : keep(result, context: context, ticket: ticket)
                }
            }
            try Task.checkCancellation()
            return customNegative(context, state: "unmatched", ticket: ticket)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            if error is DandanplayLimitReached { DandanplayPause.pause(dandanServer) }
            // A refused token or address won't fix itself within seconds; ask again only as often as for "no match".
            if error is DanmakuAuthorizationRequired { return customNegative(context, state: "unavailable", ttl: 300, ticket: ticket) }
            // Keep a proven mapping through a transient outage; do not refresh IDs on transport/5xx failures.
            keep(mapping, in: &mappings, key: key, ticket: ticket)
            return customNegative(context, state: "unavailable", ticket: ticket)
        }
    }

    private func customNegative(_ context: PlaybackHistoryContext, state: String, ttl: TimeInterval? = nil,
                                ticket: MediaCache.Ticket) -> AutomaticDanmakuResult {
        let result = AutomaticDanmakuResult(comments: [], track: "", source: "", state: state)
        if let data = try? JSONEncoder().encode(result) {
            cache.store(data, for: cacheKey(context), kind: .danmaku, scope: context.id, ttl: ttl ?? (state == "unmatched" ? 300 : 30), ticket: ticket)
        }
        return result
    }

    private func customMapping(_ context: PlaybackHistoryContext, client: CatalogDanmakuClient,
                               selectedSource: DanmakuProvider? = nil) async throws -> DanmakuMapping? {
        let preference = selectedSource ?? preferredSource
        let results = try await client.search(context.videoName, source: preference)
        let candidates = CatalogDanmakuMatcher.animeCandidates(title: context.videoName, year: context.year, source: preference, in: results)
        let groups = Dictionary(grouping: candidates, by: { $0.source })
        // Platform order is stable, but no order within a platform resolves an ambiguous edition.
        let order = DanmakuProvider.allCases.filter { $0 != .automatic }
        let unique = groups.values.compactMap { $0.count == 1 ? $0.first : nil }.sorted { left, right in
            let l = order.firstIndex(of: left.provider) ?? order.count, r = order.firstIndex(of: right.provider) ?? order.count
            return l == r ? left.source < right.source : l < r
        }
        // A few episode lists at a time: one after another, twelve shows on a slow server took minutes. The earliest
        // show in the order above still wins.
        let shortlist = Array(unique.prefix(12))
        for start in stride(from: 0, to: shortlist.count, by: 4) {
            try Task.checkCancellation()
            let batch = Array(shortlist[start..<min(start + 4, shortlist.count)])
            let lists = try await withThrowingTaskGroup(of: (Int, [CatalogDanmakuEpisode]).self) { group in
                for (index, anime) in batch.enumerated() { group.addTask { (index, try await client.episodes(anime)) } }
                var lists = [[CatalogDanmakuEpisode]](repeating: [], count: batch.count)
                for try await (index, episodes) in group { lists[index] = episodes }
                return lists
            }
            for (anime, episodes) in zip(batch, lists) {
                if let mapping = customMapping(context, anime: anime, episodes: episodes, preference: preference) { return mapping }
            }
        }
        return nil
    }

    private func customMapping(_ context: PlaybackHistoryContext, anime: CatalogDanmakuAnime,
                               episodes: [CatalogDanmakuEpisode], preference: DanmakuProvider) -> DanmakuMapping? {
        let platforms = preference == .automatic ? DanmakuProvider.allCases.filter { $0 != .automatic } + [.automatic] : [preference]
        for platform in platforms {
            let filtered = episodes.filter { episode in
                platform == .automatic ? episode.provider == .automatic : episode.provider == platform
            }
            // Duplicate rows for the same service ID must not create false ambiguity.
            var seen = Set<CatalogDanmakuEpisode>()
            let unique = filtered.filter { seen.insert($0).inserted }
            guard CatalogDanmakuMatcher.episode(name: context.episodeName, seriesTitle: anime.title, in: unique) != nil else { continue }
            let source = platform == .automatic ? anime.source : platform.rawValue
            return DanmakuMapping(provider: source, title: anime.title, year: anime.year,
                tracks: unique.map { DanmakuTrack(number: $0.episodeNumber, title: $0.title, id: $0.id, source: $0.source) }, animeID: anime.id, source: source)
        }
        return nil
    }

    private func refreshedCustomMapping(_ context: PlaybackHistoryContext, saved: DanmakuMapping,
                                        client: CatalogDanmakuClient) async throws -> DanmakuMapping? {
        let platform = DanmakuProvider(source: saved.source ?? saved.provider)
        if let animeID = saved.animeID {
            let anime = CatalogDanmakuAnime(id: animeID, title: saved.title, source: saved.source ?? saved.provider, year: saved.year)
            do {
                return customMapping(context, anime: anime, episodes: try await client.episodes(anime), preference: platform)
            } catch TVError.http(404) {
                // Catalog IDs may also have changed. One title search is enough; never retry indefinitely.
            }
        }
        return try await customMapping(context, client: client, selectedSource: platform)
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
    private func official(_ context: PlaybackHistoryContext, provider: String, cached: DanmakuMapping?, ticket: MediaCache.Ticket) async -> Outcome {
        let started = Date()
        var stage = "lookup"
        var mapping = cached
        do {
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
            var comments: [CatalogDanmakuComment] = [], source = "dmku", failure: Error = URLError(.cannotConnectToHost), answered = false
            for (name, server, query) in servers {
                // A server that just failed is skipped for a while, and the next one asked at once.
                if cache.data(for: Self.pauseKey(server), kind: .lookup) != nil {
                    Diagnostics.shared.record(.debug, "danmaku", "provider=\(provider) server=\(name) skipped=paused")
                    continue
                }
                var url = URLComponents(url: server, resolvingAgainstBaseURL: false)!
                url.queryItems = query
                do {
                    comments = try CatalogDanmakuParser.parse(await http.send(URLRequest(url: url.url!, timeoutInterval: 35)))
                    source = name; answered = true
                    if !comments.isEmpty { break }
                } catch {
                    if error is CancellationError { throw error }
                    failure = error
                    if Self.serverFailed(error), !Task.isCancelled {
                        cache.store(Data([1]), for: Self.pauseKey(server), kind: .lookup, ttl: Self.serverPause, ticket: ticket)
                    }
                    Diagnostics.shared.record(.debug, "danmaku", "provider=\(provider) server=\(name) failed=\((error as NSError).domain):\((error as NSError).code)")
                }
            }
            if !answered { throw failure }
            try Task.checkCancellation()
            Diagnostics.shared.record(.debug, "danmaku", "provider=\(provider) server=\(source) comments=\(comments.count) seconds=\(Int(Date().timeIntervalSince(started)))")
            return Outcome(result: AutomaticDanmakuResult(comments: comments, track: mapping.title + " · " + track.title,
                source: source + " · " + provider, state: comments.isEmpty ? "unmatched" : "loaded"), mapping: mapping, responded: true)
        } catch {
            if !(error is CancellationError) {
                let failure = error as NSError
                Diagnostics.shared.record(.debug, "danmaku", "provider=\(provider) stage=\(stage) failed=\(failure.domain):\(failure.code) seconds=\(Int(Date().timeIntervalSince(started)))")
            }
            // The page was found: keep it for the next episode, and say its comments couldn't be fetched.
            return stage == "comments" ? Outcome(mapping: mapping, unreachable: true) : Outcome()
        }
    }
    private func dandan(_ context: PlaybackHistoryContext, cached: DanmakuMapping?) async -> Outcome {
        do {
            let client = try CatalogDanmakuClient(address: dandanServer, transport: http, credentials: dandanCredentials)
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

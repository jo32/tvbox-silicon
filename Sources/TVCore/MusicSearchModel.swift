import Foundation
import Observation

/// Music search across the catalogs, for songs, albums or playlists. Typing waits 350 ms before
/// searching; each catalog answers on its own, and results show as they arrive, merged and
/// ranked. A newer query cancels the older one, and a late answer never replaces newer results.
@MainActor @Observable public final class MusicSearchModel {
    public private(set) var query = ""
    public private(set) var kind: MusicSearchKind = .songs
    /// Narrows what shows, and stays on for the next query until changed (#649).
    public private(set) var filter = MusicSearchFilter()
    /// What shows: the catalogs' answers that pass the filter.
    public private(set) var results: [MusicTrack] = []
    public private(set) var collections: [MusicCollection] = []
    /// Everything the catalogs answered, before the filter.
    @ObservationIgnored private var allResults: [MusicTrack] = [] { didSet { results = allResults.filter(filter.admits) } }
    @ObservationIgnored private var allCollections: [MusicCollection] = [] { didSet { collections = allCollections.filter(filter.admits) } }
    public private(set) var busy = false
    /// Why a catalog failed this time, by catalog. One failing catalog is not a failed search.
    public private(set) var failures: [MusicPlatform: MusicProviderError] = [:]
    /// Set once every catalog answered a song search: the one track the query clearly means, if any.
    public private(set) var directHit: MusicTrack?
    private var nothingFound: Bool { allResults.isEmpty && allCollections.isEmpty }
    /// The catalogs found something, and the filter hides all of it.
    public var filteredOut: Bool { !query.isEmpty && !nothingFound && results.isEmpty && collections.isEmpty }
    /// The search finished and no catalog found anything.
    public var empty: Bool { !busy && !query.isEmpty && nothingFound && failures.count < catalogs.count }
    /// Every catalog failed: the search itself could not run.
    public var failed: Bool { !busy && !query.isEmpty && nothingFound && failures.count == catalogs.count }

    private let catalogs: [any MusicCatalogSource]
    private let health: MusicHealth
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private struct Cached { var results: [MusicTrack]; var collections: [MusicCollection]; var created: Date }
    private var cache: [String: Cached] = [:]
    static let debounce: Duration = .milliseconds(350)
    static let cacheLifetime: TimeInterval = 10 * 60

    public init(catalogs: [any MusicCatalogSource]? = nil, health: MusicHealth = .shared, kind: MusicSearchKind = .songs) {
        self.catalogs = catalogs ?? Self.defaultCatalogs(health: health)
        self.health = health
        self.kind = kind
    }

    /// Catalogs searched mainly so their channels can play what the others list.
    nonisolated static let supplementary: Set<MusicPlatform> = [.migu, .kuwo]

    /// Migu and Kuwo list many unlabelled versions of a song (concert recordings, re-uploads),
    /// most without a cover, which only repeated the title in the results. A song found only in
    /// them shows when no other result has its title and artists, and once.
    nonisolated static func withoutEchoes(_ tracks: [MusicTrack]) -> [MusicTrack] {
        func key(_ track: MusicTrack) -> String {
            MusicMatching.normalize(track.title) + "|" + track.artists.map(MusicMatching.normalize).sorted().joined(separator: ",")
        }
        let onlySupplementary = { (track: MusicTrack) in track.ids.keys.allSatisfy(supplementary.contains) }
        var seen = Set(tracks.filter { !onlySupplementary($0) }.map(key))
        return tracks.filter { !onlySupplementary($0) || seen.insert(key($0)).inserted }
    }

    public nonisolated static func defaultCatalogs(transport: MusicTransport = URLSessionMusicTransport(), health: MusicHealth = .shared) -> [any MusicCatalogSource] {
        [QQMusicCatalog(transport: transport), NeteaseMusicCatalog(transport: transport, health: health),
         MiguMusicCatalog(transport: transport), KuwoMusicCatalog(transport: transport)]
    }

    /// Where to fetch a collection's tracks.
    public func source(for platform: MusicPlatform) -> (any MusicCollectionSource)? {
        catalogs.first { $0.platform == platform } as? any MusicCollectionSource
    }

    /// Searches for `text` after the typing pause; `immediately` skips the pause (Return pressed).
    /// `kind` nil keeps the current kind.
    public func search(_ text: String, kind newKind: MusicSearchKind? = nil, immediately: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = newKind ?? self.kind
        guard trimmed != query || kind != self.kind || immediately || (nothingFound && failures.isEmpty && !busy) else { return }
        task?.cancel()
        let run = UUID(); generation = run
        query = trimmed; self.kind = kind; directHit = nil; failures = [:]
        guard !trimmed.isEmpty else { allResults = []; allCollections = []; busy = false; return }
        let deep = Self.searchesDeep(kind, filter)
        let key = kind.rawValue + "|" + MusicMatching.normalize(trimmed) + "|" + MusicMatching.tags(inQuery: trimmed).map(\.rawValue).sorted().joined()
            + (deep ? "|deep" : "")
        // An artist's songs are a list to choose from, not one song the query means.
        let findsSongs = kind == .songs || kind == .top
        if let cached = cache[key], Date().timeIntervalSince(cached.created) < Self.cacheLifetime {
            allResults = cached.results; allCollections = cached.collections; busy = false
            directHit = findsSongs ? MusicMatching.directHit(results, query: trimmed) : nil
            return
        }
        // What the new search won't replace goes now; the rest stays until its answers arrive.
        switch kind {
        case .songs, .artists: allCollections = []
        case .albums, .playlists: allResults = []; allCollections = allCollections.filter { $0.kind == kind.collectionKind }
        case .top: break
        }
        busy = true
        task = Task {
            if !immediately {
                try? await Task.sleep(for: Self.debounce)
                guard !Task.isCancelled, self.generation == run else { return }
            }
            if let collectionKind = kind.collectionKind {
                await self.searchCollections(trimmed, kind: collectionKind, run: run)
            } else if kind == .top {
                async let songs: Void = self.searchSongs(trimmed, byArtist: false, deep: deep, run: run)
                async let albums: Void = self.searchCollections(trimmed, kind: .album, run: run)
                async let playlists: Void = self.searchCollections(trimmed, kind: .playlist, run: run)
                _ = await (songs, albums, playlists)
            } else {
                await self.searchSongs(trimmed, byArtist: kind == .artists, deep: deep, run: run)
            }
            guard self.generation == run, !Task.isCancelled else { return }
            self.busy = false
            // With a catalog missing, the clearest result may only look clear: the viewer chooses.
            self.directHit = findsSongs && self.failures.isEmpty ? MusicMatching.directHit(self.results, query: trimmed) : nil
            if self.failures.isEmpty { self.cache[key] = Cached(results: self.allResults, collections: self.allCollections, created: Date()) }
        }
    }

    public func clear() { search("") }

    /// Shows the answers that pass `newFilter` at once. The first filter on songs also searches again for a
    /// second page from each catalog, since a filter keeps only part of one.
    public func setFilter(_ newFilter: MusicSearchFilter) {
        guard newFilter != filter else { return }
        let wasDeep = Self.searchesDeep(kind, filter)
        filter = newFilter
        results = allResults.filter(filter.admits); collections = allCollections.filter(filter.admits)
        if !query.isEmpty, !wasDeep, Self.searchesDeep(kind, filter) { search(query, immediately: true) }
        else if kind == .songs || kind == .top { directHit = busy || !failures.isEmpty ? nil : MusicMatching.directHit(results, query: query) }
    }

    /// Songs come two pages per catalog for an artist, and while a filter narrows them.
    nonisolated static func searchesDeep(_ kind: MusicSearchKind, _ filter: MusicSearchFilter) -> Bool {
        switch kind {
        case .artists: true
        case .songs, .top: !filter.isEmpty
        case .albums, .playlists: false
        }
    }

    private func searchSongs(_ query: String, byArtist: Bool, deep: Bool, run: UUID) async {
        var lists: [MusicPlatform: [MusicTrack]] = [:]
        await withTaskGroup(of: (MusicPlatform, Result<[MusicTrack], MusicProviderError>).self) { group in
            for catalog in catalogs {
                group.addTask {
                    do {
                        let first = try await catalog.search(query, page: 1)
                        // An artist's songs, or songs a filter narrows, fill more than one page: the second comes too, when there is one.
                        guard deep, !first.isEmpty, let second = try? await catalog.search(query, page: 2) else { return (catalog.platform, .success(first)) }
                        return (catalog.platform, .success(first + second))
                    }
                    catch { return (catalog.platform, .failure(MusicProviderError(error))) }
                }
            }
            for await (platform, result) in group {
                guard generation == run else { group.cancelAll(); return }
                guard let tracks = await record(platform, result) else { continue }
                lists[platform] = tracks
                guard generation == run else { group.cancelAll(); return }
                // In MusicPlatform's order: QQ's entries carry durations and covers the others join.
                let merged = Self.withoutEchoes(MusicMatching.merge(MusicPlatform.allCases.compactMap { lists[$0] }))
                allResults = byArtist ? MusicMatching.byArtist(merged, query: query) : MusicMatching.rank(merged, query: query)
            }
        }
    }

    private func searchCollections(_ query: String, kind: MusicCollection.Kind, run: UUID) async {
        var lists: [MusicPlatform: [MusicCollection]] = [:]
        await withTaskGroup(of: (MusicPlatform, Result<[MusicCollection], MusicProviderError>).self) { group in
            for catalog in catalogs {
                guard let source = catalog as? any MusicCollectionSource else { continue }
                group.addTask {
                    do { return (source.platform, .success(try await source.searchCollections(query, kind: kind, page: 1))) }
                    catch { return (source.platform, .failure(MusicProviderError(error))) }
                }
            }
            for await (platform, result) in group {
                guard generation == run else { group.cancelAll(); return }
                guard let found = await record(platform, result) else { continue }
                lists[platform] = found
                guard generation == run else { group.cancelAll(); return }
                // Top results search albums and playlists side by side: each replaces only its own kind.
                allCollections = allCollections.filter { $0.kind != kind }
                    + MusicCollections.rank(MusicPlatform.allCases.flatMap { lists[$0] ?? [] }, query: query)
            }
        }
    }

    /// Notes a catalog's answer in its health record; the results, or nil after a failure.
    private func record<T>(_ platform: MusicPlatform, _ result: Result<T, MusicProviderError>) async -> T? {
        let key = MusicHealth.key(platform.rawValue, platform, .search)
        switch result {
        case .success(let value):
            await health.record(key, error: nil)
            return value
        case .failure(let error):
            guard error != .cancelled else { return nil }
            failures[platform] = error
            await health.record(key, error: error)
            return nil
        }
    }
}

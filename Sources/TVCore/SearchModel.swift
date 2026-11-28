import Foundation
import Observation

@MainActor @Observable public final class SearchModel {
    public var draft = ""
    public var selectedSource: String?
    public var results: [SearchSourceResult] = []
    public private(set) var activeSources: [SearchSourceActivity] = []
    /// Sources this search has yet to ask, in the order it asks them; each leaves the list as it starts.
    public private(set) var waitingSources: [Site] = []
    public var busy = false
    public var completed = 0
    public var total = 0
    public var keyword = ""
    public var stopped = false
    /// A single bounded notice also covers answers omitted because even their error would exceed the budget.
    public private(set) var resultLimitMessage: String?
    @ObservationIgnored private var omittedSources = Set<String>()
    /// Sources this search left out because they are failing (`SourceHealth.paused`); a retry asks them.
    public private(set) var paused: [Site] = []
    /// Keys of the sources this search asks: searchable, not hidden by the viewer, not paused.
    public private(set) var asking: Set<String> = []
    /// Paused because the viewer left the results, not by Stop; `resumeSuspended` continues it.
    public private(set) var suspended = false
    /// The result at the top of the page, kept so a page built again opens where the viewer left it. SwiftUI
    /// writes it on every row scrolled past; observed, each write ran the whole search page again (TitleMatch over
    /// every result, the source chips) and scrolling a long list stuttered (#910). Nothing has to redraw when it changes.
    @ObservationIgnored public var scrollID: String?
    /// Later result pages, in the order they arrived, so the grid only ever grows at its end.
    public private(set) var batches: [SearchBatch] = []
    public private(set) var loadingMore = false
    /// The next page to ask each source for; `Int.max` once a source has no more.
    private var nextPage: [String: Int] = [:]
    /// Next pages that failed in a row, per source: one more try, then the source is done for this search.
    @ObservationIgnored private var pageFailures: [String: Int] = [:]
    private(set) var moreTask: Task<Void, Never>?
    private var pageGeneration = UUID()
    private var resultsVisible = true
    /// Changes only with a new search, unlike `generation`, which pausing also changes.
    private var runID = UUID()
    private static let sourceKey = "searchSource"
    /// When the current run began and how many sources were already done, for a time estimate.
    public private(set) var runStart: (date: Date, completed: Int)?
    private var generation = UUID()
    private(set) var task: Task<Void, Never>?

    private let http: HTTPClient
    private struct Cached {
        let results: [SearchSourceResult]
        let created: Date
        let cost: SearchPayloadBudget.Cost
    }
    private var cache: [String: Cached] = [:]
    private var payloadBudget = SearchPayloadBudget()
    private var subscriptionID: String?
    /// Each source's position in `SourceStrategy` order, or the viewer's own; matches are listed in this order.
    private var rank: [String: Int] = [:]
    private var excluded: @MainActor (Site) -> Bool = { _ in false }
    /// The viewer's source order; while it is on, it replaces `SourceStrategy`'s.
    public var order: SourceOrder?
    /// Told of each source's answer as it arrives, for a page that reads the answers once each instead of on every redraw
    /// (Discover's title page, `DiscoverSources`).
    @ObservationIgnored public var onResult: (@MainActor (SearchSourceResult) -> Void)?
    /// Progress can advance without a retained answer when its payload does not fit.
    @ObservationIgnored public var onProgress: (@MainActor () -> Void)?
    public init(http: HTTPClient = HTTPClient()) { self.http = http }

    public var failures: [SearchSourceResult] { results.filter { $0.error != nil } }
    public var matches: [SearchSourceResult] {
        results.filter { $0.page?.videos.isEmpty == false }.enumerated().sorted { lhs, rhs in
            let left = rank[lhs.element.id] ?? .max, right = rank[rhs.element.id] ?? .max
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }
    public var videoCount: Int { matches.reduce(0) { $0 + Set(videos(for: $1.id).map(\.id)).count } }

    /// A source's results so far: its first page, then each later page.
    public func videos(for source: String) -> [Video] {
        var seen = Set<String>()
        return ((results.first { $0.id == source }?.page?.videos ?? []) + batches.filter { $0.source == source }.flatMap(\.videos))
            .filter { seen.insert($0.id).inserted }
    }

    /// Shows one source's results (nil: every source). The choice carries over to later searches.
    public func select(_ source: String?) {
        selectedSource = source; scrollID = nil
        UserDefaults.standard.set(source, forKey: Self.sourceKey)
    }

    /// Whether a source (nil: any matching source) has another page of results.
    public func canLoadMore(_ source: String?) -> Bool {
        let candidates = source.map { id in matches.filter { $0.id == id } } ?? matches
        return candidates.contains { result in (nextPage[result.id] ?? 2) <= (result.page?.pageCount ?? 1) }
    }

    /// The keyword a source is asked for (#1364): simplified, the script the sources match against, so a Traditional
    /// name finds what their catalogues hold. `keyword` itself keeps what the viewer typed — it also fills the search
    /// field and the history, and decides whether a repeated search is the same one. `GlobalSearch` converts the
    /// keyword it is handed, so the first page and every later page reach a source through this. Pure, so the
    /// off-main `GlobalSearch` can use it too.
    nonisolated static func sourceKeyword(_ keyword: String) -> String {
        NovelScript.simplified.convert(keyword.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Fetches the next page of a source (nil: of every matching source that has one) and appends
    /// what is new; a source that answers nothing new is done.
    public func loadMore(_ source: String?, config: Subscription) {
        guard resultsVisible, !loadingMore, !suspended, !keyword.isEmpty else { return }
        let targets = (source.map { id in matches.filter { $0.id == id } } ?? matches)
            .filter { (nextPage[$0.id] ?? 2) <= ($0.page?.pageCount ?? 1) }
        guard !targets.isEmpty else { return }
        loadingMore = true
        let run = runID, pageToken = pageGeneration, keyword = Self.sourceKeyword(keyword), http = http
        moreTask = Task {
            // Pagination is one queue, not a second burst of six plugin requests.
            for result in targets.prefix(6) {
                guard !Task.isCancelled, self.pageGeneration == pageToken else { break }
                let page = self.nextPage[result.id] ?? 2
                let client = CatalogClient(site: result.site, origin: config.origin, http: http, jarURL: config.spiderURL)
                let answer = try? await client.list(category: nil, query: keyword, page: page)
                guard !Task.isCancelled, self.runID == run, self.pageGeneration == pageToken else { break }
                // A failed page is not the end of the source: it is asked once more. The end of the list asks for
                // more as soon as a pass ends while it is on screen, so a source that keeps failing would be asked
                // forever: a second failure in a row ends it for this search.
                guard let answer else {
                    let failures = (self.pageFailures[result.id] ?? 0) + 1
                    self.pageFailures[result.id] = failures
                    if failures >= 2 { self.nextPage[result.id] = .max }
                    continue
                }
                self.pageFailures[result.id] = nil
                var known = Set(self.videos(for: result.id).map(\.id))
                let fresh = answer.videos.filter { known.insert($0.id).inserted }
                self.nextPage[result.id] = fresh.isEmpty ? Int.max : page + 1
                if !fresh.isEmpty {
                    guard self.payloadBudget.reserve(SearchPayloadBudget.cost(fresh)) else {
                        self.nextPage[result.id] = .max
                        self.resultLimitMessage = SearchPayloadBudget.message
                        continue
                    }
                    self.batches.append(SearchBatch(source: result.id, page: page, videos: fresh))
                }
            }
            if self.runID == run, self.pageGeneration == pageToken {
                self.loadingMore = false; self.moreTask = nil
            }
        }
    }

    private func cancelPages() {
        pageGeneration = UUID()
        moreTask?.cancel(); moreTask = nil; loadingMore = false
    }

    private func clearPages() {
        cancelPages()
        batches = []; nextPage = [:]; pageFailures = [:]; loadingMore = false; runID = UUID()
        payloadBudget = SearchPayloadBudget()
        resultLimitMessage = nil; omittedSources = []
    }

    public func stop() {
        generation = UUID()
        task?.cancel(); task = nil
        activeSources = []; waitingSources = []
        cancelPages()
        stopped = busy; busy = false
        suspended = false
    }

    /// Pauses a running search while the viewer is on another page (a result's detail, another
    /// section), so its plugin calls stop competing with what they are looking at. Sources that
    /// already answered keep their results; the rest run again on `resumeSuspended`.
    public func suspend() {
        resultsVisible = false
        let unfinished = busy || suspended
        let wasStopped = stopped
        stop()
        stopped = wasStopped || unfinished
        suspended = unfinished
    }

    public func resumeSuspended(config: Subscription) {
        resultsVisible = true
        guard suspended else { return }
        suspended = false
        resume(config: config)
    }

    public func reset() {
        stop()
        draft = ""; keyword = ""; results = []; completed = 0; total = 0; paused = []; asking = []
        selectedSource = nil; scrollID = nil; stopped = false
        clearPages()
        cache = [:]; subscriptionID = nil
        excluded = { _ in false }
    }

    public static func eligible(_ sites: [Site], jarURL: URL?, excluding hidden: (Site) -> Bool) -> [Site] {
        var seen = Set<String>()
        return sites.filter { $0.searchable && $0.canBrowse(jarURL: jarURL) && !hidden($0) && seen.insert($0.id).inserted }
    }

    public static func visible(_ results: [SearchSourceResult], excluding hidden: (Site) -> Bool) -> [SearchSourceResult] {
        results.filter { !hidden($0.site) }
    }

    public func search(_ query: String, config: Subscription, excluding hidden: @escaping @MainActor (Site) -> Bool = { _ in false }) {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let identity = "\(config.origin)|\(config.importedAt.timeIntervalSince1970)"
        if subscriptionID != identity { reset(); subscriptionID = identity }
        excluded = hidden
        if busy && keyword == value { return }
        stop()
        keyword = value; draft = value; results = []; completed = 0
        clearPages()
        let eligible = Self.eligible(config.sites, jarURL: config.spiderURL, excluding: hidden)
        let now = Date()
        paused = eligible.filter { SourceHealth.shared.paused($0, origin: config.origin, now: now) }
        let held = Set(paused.map(\.id))
        let sites = eligible.filter { !held.contains($0.id) }
        asking = Set(sites.map(\.key))
        let preferred = UserDefaults.standard.string(forKey: Self.sourceKey)
        selectedSource = sites.contains { $0.id == preferred } ? preferred : nil; scrollID = nil
        rank = Dictionary(arrange(eligible, config: config, failing: failing(config)).enumerated().map { ($1.id, $0) }) { first, _ in first }
        total = sites.count
        if let hit = cache[value], Date().timeIntervalSince(hit.created) < 300,
           hit.results.count == total, Set(hit.results.map(\.id)) == asking {
            results = hit.results
            completed = results.count
            for result in results { _ = payloadBudget.reserve(SearchPayloadBudget.cost(result)) }
            stopped = false
            return
        }
        run(sites, config: config)
    }

    public func resume(config: Subscription, retryFailures: Bool = false) {
        guard !busy, !keyword.isEmpty, retryFailures || completed < total else { return }
        let finished = Set(results.map(\.id)).union(omittedSources)
        let failed = Set(failures.map(\.id))
        // A retry also asks the sources paused for failing: the viewer asked for them.
        let held = Set(paused.map(\.id))
        let sites = Self.eligible(config.sites, jarURL: config.spiderURL, excluding: excluded).filter {
            retryFailures ? failed.contains($0.id) || held.contains($0.id) : !finished.contains($0.id) && !held.contains($0.id)
        }
        if retryFailures {
            results.removeAll { failed.contains($0.id) }; completed = results.count + omittedSources.count
            rebuildPayloadBudget()
            total += paused.count; paused = []
        }
        asking.formUnion(sites.map(\.key))
        run(sites, config: config)
    }

    private func run(_ sites: [Site], config: Subscription) {
        let token = generation
        let keyword = keyword
        stopped = false; busy = !sites.isEmpty
        guard busy else { return }
        runStart = (Date(), completed)
        task = Task {
            // Already-running sources first, then `SourceStrategy` order (runtime, channel, subscription).
            var warm = Set<String>()
            #if os(macOS)
            warm = await LocalJarHost.shared.reusableSourceKeys()
            #endif
            let failing = self.failing(config)
            let arranged = self.arrange(sites, config: config, failing: failing)
            // Built-in sources answer first: they are quick and the ones most often filtered to.
            // The viewer's own order is asked as it is, top first.
            // Sources that keep failing go last, warm or not, so they never hold up the rest.
            let preferred = self.order?.enabled == true ? arranged
                : (arranged.filter { warm.contains($0.key) } + arranged.filter { !warm.contains($0.key) }).enumerated().sorted { ($0.element.isBuiltIn ? 0 : 1, $0.offset) < ($1.element.isBuiltIn ? 0 : 1, $1.offset) }.map(\.element)
            let ordered = preferred.filter { !failing($0) } + preferred.filter(failing)
            guard self.generation == token else { return }
            self.waitingSources = ordered
            await GlobalSearch.search(sites: ordered, origin: config.origin, jarURL: config.spiderURL, query: keyword, http: self.http, onStart: { site in
                await self.started(site, token: token)
            }) { result in
                await self.receive(result, token: token)
            }
            guard self.generation == token else { return }
            self.busy = false; self.task = nil; self.activeSources = []; self.waitingSources = []
            if self.completed == self.total {
                self.cacheResults(keyword)
            }
        }
    }

    /// `SourceStrategy` order, or the viewer's own while it is on (sources it doesn't list yet follow).
    private func arrange(_ sites: [Site], config: Subscription, failing: (Site) -> Bool) -> [Site] {
        let automatic = SourceStrategy.arrange(sites, where: { _ in true }, failing: failing)
        guard let order, order.enabled else { return automatic }
        return order.arrange(automatic, origin: config.origin)
    }

    /// Sources in a `SourceHealth` cooldown. Search leaves them out; when a retry asks them, they go
    /// after the others (and are listed after them unless the viewer's own order is on).
    private func failing(_ config: Subscription) -> @Sendable (Site) -> Bool {
        let now = Date()
        let down = Set(config.sites.filter { SourceHealth.shared.paused($0, origin: config.origin, now: now) }.map(\.id))
        return { down.contains($0.id) }
    }

    private func rebuildPayloadBudget() {
        payloadBudget = SearchPayloadBudget()
        for result in results { _ = payloadBudget.reserve(SearchPayloadBudget.cost(result)) }
        for batch in batches { _ = payloadBudget.reserve(SearchPayloadBudget.cost(batch.videos)) }
    }

    func retain(_ result: SearchSourceResult) -> SearchSourceResult? {
        let trimmed = SearchSourceResult(site: result.site, page: result.page.map(SearchPayloadBudget.trimmed), error: result.error)
        if payloadBudget.reserve(SearchPayloadBudget.cost(trimmed)) { return trimmed }
        resultLimitMessage = SearchPayloadBudget.message
        // An error retains its Site too. It needs its own successful reservation; never smuggle an
        // oversized source configuration (or another result after the item cap) into the failure list.
        let failure = SearchSourceResult(site: result.site, page: nil, error: SearchPayloadBudget.message)
        return payloadBudget.reserve(SearchPayloadBudget.cost(failure)) ? failure : nil
    }

    private func cacheResults(_ keyword: String) {
        cache[keyword] = nil
        guard resultLimitMessage == nil else { return }
        let cost = results.reduce(SearchPayloadBudget.Cost(bytes: keyword.utf8.count + 32)) { $0 + SearchPayloadBudget.cost($1) }
        guard cost.bytes <= 12 << 20, cost.items <= 12_000 else { return }
        cache = cache.filter { Date().timeIntervalSince($0.value.created) < 300 }
        while cache.count >= 6 || cache.values.reduce(cost.bytes, { $0 + $1.cost.bytes }) > 12 << 20 ||
              cache.values.reduce(cost.items, { $0 + $1.cost.items }) > 12_000 {
            guard let oldest = cache.min(by: { $0.value.created < $1.value.created })?.key else { break }
            cache[oldest] = nil
        }
        cache[keyword] = Cached(results: results, created: Date(), cost: cost)
    }

    private func started(_ site: Site, token: UUID) {
        guard generation == token else { return }
        guard !activeSources.contains(where: { $0.id == site.id }), !results.contains(where: { $0.id == site.id }) else { return }
        activeSources.append(SearchSourceActivity(site: site, started: Date()))
        waitingSources.removeAll { $0.id == site.id }
    }

    private func receive(_ result: SearchSourceResult, token: UUID) {
        guard generation == token else { return }
        record(result)
    }

    /// First answer wins within a run, including callbacks from a resumed source. Retrying failures
    /// removes their old answers before dispatch, so an explicit retry can still replace them. An answer too large
    /// to keep (`SearchPayloadBudget`) still counts as the source's answer.
    func record(_ result: SearchSourceResult) {
        guard !results.contains(where: { $0.id == result.id }), !omittedSources.contains(result.id) else { return }
        let token = generation
        activeSources.removeAll { $0.id == result.id }
        completed += 1
        if let result = retain(result) {
            results.append(result)
            onResult?(result)
        } else {
            omittedSources.insert(result.id)
        }
        if generation == token { onProgress?() }
    }
}


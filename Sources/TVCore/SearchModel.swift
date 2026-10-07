import Foundation
import Observation

@MainActor @Observable public final class SearchModel {
    public var draft = ""
    public var selectedSource: String?
    public var results: [SearchSourceResult] = []
    public var busy = false
    public var completed = 0
    public var total = 0
    public var keyword = ""
    public var stopped = false
    /// Paused because the viewer left the results, not by Stop; `resumeSuspended` continues it.
    public private(set) var suspended = false
    public var scrollID: String?
    /// When the current run began and how many sources were already done, for a time estimate.
    public private(set) var runStart: (date: Date, completed: Int)?
    private var generation = UUID()
    private(set) var task: Task<Void, Never>?

    private let http: HTTPClient
    private struct Cached {
        let results: [SearchSourceResult]
        let total: Int
        let created: Date
    }
    private var cache: [String: Cached] = [:]
    private var subscriptionID: String?
    /// Each source's position in `SourceStrategy` order; matches are listed in this order.
    private var rank: [String: Int] = [:]
    public init(http: HTTPClient = HTTPClient()) { self.http = http }

    public var failures: [SearchSourceResult] { results.filter { $0.error != nil } }
    public var matches: [SearchSourceResult] {
        results.filter { $0.page?.videos.isEmpty == false }.enumerated().sorted { lhs, rhs in
            let left = rank[lhs.element.id] ?? .max, right = rank[rhs.element.id] ?? .max
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }
    public var videoCount: Int { matches.reduce(0) { $0 + Set(($1.page?.videos ?? []).map(\.id)).count } }

    public func stop() {
        generation = UUID()
        task?.cancel(); task = nil
        stopped = busy; busy = false
        suspended = false
    }

    /// Pauses a running search while the viewer is on another page (a result's detail, another
    /// section), so its plugin calls stop competing with what they are looking at. Sources that
    /// already answered keep their results; the rest run again on `resumeSuspended`.
    public func suspend() {
        guard busy else { return }
        stop()
        suspended = true
    }

    public func resumeSuspended(config: Subscription) {
        guard suspended else { return }
        suspended = false
        resume(config: config)
    }

    public func reset() {
        stop()
        draft = ""; keyword = ""; results = []; completed = 0; total = 0
        selectedSource = nil; scrollID = nil; stopped = false
        cache = [:]; subscriptionID = nil
    }

    public func search(_ query: String, config: Subscription) {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let identity = "\(config.origin)|\(config.importedAt.timeIntervalSince1970)"
        if subscriptionID != identity { reset(); subscriptionID = identity }
        if busy && keyword == value { return }
        stop()
        keyword = value; draft = value; results = []; completed = 0
        selectedSource = nil; scrollID = nil
        let sites = config.sites.filter { $0.searchable && $0.canBrowse(jarURL: config.spiderURL) }
        rank = Dictionary(SourceStrategy.arrange(sites) { _ in true }.enumerated().map { ($1.id, $0) }) { first, _ in first }
        total = sites.count
        if let hit = cache[value], Date().timeIntervalSince(hit.created) < 300 {
            results = hit.results; total = hit.total; completed = results.count; stopped = false
            return
        }
        run(sites, config: config)
    }

    public func resume(config: Subscription, retryFailures: Bool = false) {
        guard !busy, !keyword.isEmpty else { return }
        let finished = Set(results.map(\.id))
        let failed = Set(failures.map(\.id))
        let sites = config.sites.filter {
            $0.searchable && $0.canBrowse(jarURL: config.spiderURL) &&
            (retryFailures ? failed.contains($0.id) : !finished.contains($0.id))
        }
        if retryFailures { results.removeAll { failed.contains($0.id) }; completed = results.count }
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
            let arranged = SourceStrategy.arrange(sites) { _ in true }
            let ordered = arranged.filter { warm.contains($0.key) } + arranged.filter { !warm.contains($0.key) }
            guard self.generation == token else { return }
            await GlobalSearch.search(sites: ordered, origin: config.origin, jarURL: config.spiderURL, query: keyword, http: self.http) { result in
                await self.receive(result, token: token)
            }
            guard self.generation == token else { return }
            self.busy = false; self.task = nil
            if self.completed == self.total {
                self.cache[keyword] = Cached(results: self.results, total: self.total, created: Date())
                if self.cache.count > 6, let oldest = self.cache.min(by: { $0.value.created < $1.value.created })?.key { self.cache[oldest] = nil }
            }
        }
    }

    private func receive(_ result: SearchSourceResult, token: UUID) {
        guard generation == token else { return }
        completed += 1
        results.append(result)
    }
}


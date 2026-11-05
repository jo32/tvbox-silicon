import Foundation
import Observation

/// Owns the requested catalog location so retries and overlapping requests stay consistent.
@MainActor @Observable public final class CatalogBrowser {
    public enum Request: Equatable, Sendable {
        case home
        /// `filters`: the category's filter choices, key to value (see `CategoryFilter`).
        case list(category: String?, query: String, page: Int, filters: [String: String] = [:])
    }
    public private(set) var categories: [Category] = []
    public private(set) var videos: [Video] = []
    public private(set) var category = ""
    /// The shown category's filter choices; kept when paging.
    public private(set) var filters: [String: String] = [:]
    public private(set) var query = ""
    public private(set) var page = 1
    public private(set) var pageCount = 1
    /// Whether the shown list has another page to append. A home page is never appended.
    public var hasMore: Bool {
        guard case .list = request else { return false }
        return page < pageCount
    }
    public private(set) var busy = false
    public private(set) var loaded = false
    public private(set) var error: String?
    /// Appending a page keeps the shown videos in place, so it has its own state instead of `busy`.
    public private(set) var loadingMore = false
    public private(set) var moreError: String?
    public private(set) var request: Request = .home
    private var generation = 0
    /// Shown from another page (`seed`) until the first home load answers; that load then refreshes it in place.
    private var seeded = false
    private var pending: Task<CatalogPage, Error>?
    private var pendingCategories: Task<CatalogPage, Error>?
    private var pendingMore: Task<CatalogPage, Error>?
    public init() {}

    /// Release this page's work without discarding already displayed content.
    public func cancel() {
        generation += 1
        pending?.cancel(); pending = nil
        pendingCategories?.cancel(); pendingCategories = nil
        pendingMore?.cancel(); pendingMore = nil
        loadingMore = false; moreError = nil
        if busy { loaded = false }
        busy = false
    }

    public func load(_ request: Request, client: CatalogClient) async {
        await load(request, context: client.reportContext) { request in
            switch request {
            case .home: return try await client.home()
            case let .list(category, query, page, filters): return try await client.list(category: category, query: query, page: page, filters: filters)
            }
        }
    }

    /// Appends the next page of the shown list, as scrolling to the end of it does.
    public func loadMore(client: CatalogClient) async {
        await loadMore(context: client.reportContext) { request in
            switch request {
            case .home: return try await client.home()
            case let .list(category, query, page, filters): return try await client.list(category: category, query: query, page: page, filters: filters)
            }
        }
    }

    /// Shows the home another page already has (Watch Now's picks for this source) at once. The next home load runs
    /// without clearing or dimming it and replaces it only if the source answers differently; a failure keeps it.
    public func seed(videos: [Video], categories: [Category]) {
        guard !loaded, !busy, self.videos.isEmpty, !videos.isEmpty else { return }
        var seen = Set<String>()
        self.videos = videos.filter { seen.insert($0.id).inserted }
        self.categories = categories
        request = .home; category = ""; query = ""; page = 1; pageCount = 1; filters = [:]
        seeded = true
    }

    /// The category bar for a page that opened on a search: categories only come with the home
    /// answer, so fetch it without touching the videos on screen.
    public func loadCategories(client: CatalogClient) async {
        guard !Task.isCancelled, categories.isEmpty, pendingCategories == nil else { return }
        let current = generation
        let task = Task { try await client.home() }
        pendingCategories = task
        defer { if generation == current { pendingCategories = nil } }
        let home = try? await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard generation == current, !Task.isCancelled, !task.isCancelled, categories.isEmpty, let home else { return }
        categories = home.categories
    }

    public func load(_ request: Request, context: String = "-", fetch: @escaping @Sendable (Request) async throws -> CatalogPage) async {
        guard !Task.isCancelled else { return }
        pending?.cancel()
        pendingCategories?.cancel(); pendingCategories = nil
        pendingMore?.cancel(); pendingMore = nil
        generation += 1
        let current = generation
        let refreshing = seeded && request == .home && !videos.isEmpty
        seeded = false
        self.request = request
        busy = !refreshing; loaded = false; error = nil
        loadingMore = false; moreError = nil
        switch request {
        case .home: category = ""; query = ""; page = 1; filters = [:]
        case let .list(category, query, page, filters):
            self.category = category ?? ""; self.query = query; self.page = page; self.filters = filters
        }
        if !refreshing { videos = []; pageCount = 1 }
        defer { if generation == current { pending = nil; busy = false; if !Task.isCancelled { loaded = true } } }
        func perform(_ request: Request) async throws -> CatalogPage {
            let task = Task { try await fetch(request) }
            pending = task
            return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        }
        do {
            var result = try await perform(request)
            guard generation == current, !Task.isCancelled else { return }
            if request == .home {
                if !refreshing || !result.categories.isEmpty { categories = result.categories }
                if result.videos.isEmpty, let first = categories.first {
                    category = first.id
                    filters = CategoryFilter.initialChoices(first.filters)
                    self.request = .list(category: first.id, query: "", page: 1, filters: filters)
                    result = try await perform(self.request)
                }
            }
            guard generation == current, !Task.isCancelled else { return }
            var seen = Set<String>()
            let fresh = result.videos.filter { seen.insert($0.id).inserted }
            // A refresh that answers the same leaves the shown covers untouched.
            if !refreshing || fresh != videos { videos = fresh }
            pageCount = result.pageCount
        } catch {
            guard generation == current, !Task.isCancelled else { return }
            Diagnostics.shared.failure("catalog", "\(request == .home ? "home" : "list") \(context)", error)
            if !refreshing { self.error = error.localizedDescription }
        }
    }

    /// Appends the next page without emptying what the list shows. The footer offers Retry from `moreError`;
    /// the page's own error state stays reserved for a first page that failed to load.
    public func loadMore(context: String = "-", fetch: @escaping @Sendable (Request) async throws -> CatalogPage) async {
        guard !Task.isCancelled, !busy, !loadingMore, hasMore,
              case let .list(category, query, current, filters) = request else { return }
        let currentGeneration = generation
        let next = current + 1
        loadingMore = true; moreError = nil
        defer { if generation == currentGeneration { pendingMore = nil; loadingMore = false } }
        let task = Task { try await fetch(.list(category: category, query: query, page: next, filters: filters)) }
        pendingMore = task
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard generation == currentGeneration, !Task.isCancelled, !task.isCancelled else { return }
            var seen = Set(videos.map(\.id))
            let fresh = result.videos.filter { seen.insert($0.id).inserted }
            videos += fresh
            page = next
            // A source that ignores the page number answers every page with the same list. One empty answer
            // ends the list instead of scrolling forever. A later page without `pagecount` reads as 1, so the
            // count only grows: the first page's count still holds.
            pageCount = fresh.isEmpty ? next : max(pageCount, result.pageCount)
            self.request = .list(category: category, query: query, page: next, filters: filters)
        } catch {
            guard generation == currentGeneration, !Task.isCancelled else { return }
            Diagnostics.shared.failure("catalog", "more \(context)", error)
            moreError = error.localizedDescription
        }
    }
}

import Foundation
import Observation

/// Owns the requested catalog location so retries and overlapping requests stay consistent.
@MainActor @Observable public final class CatalogBrowser {
    public enum Request: Equatable, Sendable {
        case home
        case list(category: String?, query: String, page: Int)
    }
    public private(set) var categories: [Category] = []
    public private(set) var videos: [Video] = []
    public private(set) var category = ""
    public private(set) var query = ""
    public private(set) var page = 1
    public private(set) var pageCount = 1
    public private(set) var busy = false
    public private(set) var loaded = false
    public private(set) var error: String?
    public private(set) var request: Request = .home
    private var generation = 0
    /// Shown from another page (`seed`) until the first home load answers; that load then refreshes it in place.
    private var seeded = false
    private var pending: Task<CatalogPage, Error>?
    private var pendingCategories: Task<CatalogPage, Error>?
    public init() {}

    /// Release this page's work without discarding already displayed content.
    public func cancel() {
        generation += 1
        pending?.cancel(); pending = nil
        pendingCategories?.cancel(); pendingCategories = nil
        if busy { loaded = false }
        busy = false
    }

    public func load(_ request: Request, client: CatalogClient) async {
        await load(request, context: client.reportContext) { request in
            switch request {
            case .home: return try await client.home()
            case let .list(category, query, page): return try await client.list(category: category, query: query, page: page)
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
        request = .home; category = ""; query = ""; page = 1; pageCount = 1
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
        generation += 1
        let current = generation
        let refreshing = seeded && request == .home && !videos.isEmpty
        seeded = false
        self.request = request
        busy = !refreshing; loaded = false; error = nil
        switch request {
        case .home: category = ""; query = ""; page = 1
        case let .list(category, query, page): self.category = category ?? ""; self.query = query; self.page = page
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
                    self.request = .list(category: first.id, query: "", page: 1)
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
}

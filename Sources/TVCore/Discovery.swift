import Foundation

extension Site {
    public var searchable: Bool { (raw["searchable"]?.int ?? 1) == 1 }
    /// TVBox's `hide: 1` keeps a search-only source out of the source lists.
    public var hidden: Bool { raw["hide"]?.int == 1 }
    public func canBrowse(jarURL: URL?) -> Bool {
        if native { return true }
        if runsLitePort { return true }
        #if os(macOS)
        let hasPlugin = jarURL != nil || raw["jar"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        switch runtime {
        case .javascript, .python: return LocalJarHost.available(runtime)
        case .jar: return hasPlugin && EmbeddedJarHost.available
        case .api, .unsupported: return false
        }
        #elseif os(iOS) || os(tvOS)
        if runtime == .javascript { return ScriptRuntime.available }
        return runtime == .jar && EmbeddedJarHost.available && (jarURL != nil || raw["jar"]?.string?.isEmpty == false)
        #else
        return false
        #endif
    }
}

public struct SearchSourceResult: Identifiable, Sendable {
    public let site: Site
    public let page: CatalogPage?
    public let error: String?
    public var id: String { site.id }
}

public enum GlobalSearch {
    /// Limit simultaneous plugin processes and publish each source independently.
    public static func search(sites: [Site], origin: URL, jarURL: URL?, query: String,
                              http: HTTPClient = HTTPClient(), concurrency: Int = 4,
                              onResult: @escaping @Sendable (SearchSourceResult) async -> Void) async {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        let eligible = sites.filter { $0.searchable && $0.canBrowse(jarURL: jarURL) }
        let began = ContinuousClock.now
        Diagnostics.shared.record(.info, "search", "begin sources=\(eligible.count) plugins=\(eligible.filter { !$0.native }.count) skipped=\(sites.count - eligible.count)")
        defer { Diagnostics.shared.record(.info, "search", "end elapsed=\(began.duration(to: .now)) cancelled=\(Task.isCancelled)") }
        #if os(iOS) || os(tvOS) || os(macOS)
        // Each runtime has its own lane, so slow JVM searches never hold up the cheaper sources.
        // The plugin JVM runs at most `searchWidth` plugin searches and turns away callers
        // beyond a short queue, so JAR sources never exceed that width.
        async let plugins: Void = run(eligible.filter { $0.preferredRuntime == .jar }, concurrency: EmbeddedJarHost.searchWidth, origin: origin, jarURL: jarURL,
                                      keyword: keyword, http: http, onResult: onResult)
        async let scripts: Void = run(eligible.filter { $0.preferredRuntime == .javascript || $0.preferredRuntime == .python }, concurrency: concurrency,
                                      origin: origin, jarURL: jarURL, keyword: keyword, http: http, onResult: onResult)
        await run(eligible.filter(\.native), concurrency: concurrency, origin: origin, jarURL: jarURL,
                  keyword: keyword, http: http, onResult: onResult)
        await scripts
        await plugins
        #else
        await run(eligible, concurrency: concurrency, origin: origin, jarURL: jarURL, keyword: keyword, http: http, onResult: onResult)
        #endif
    }

    private static func run(_ eligible: [Site], concurrency: Int, origin: URL, jarURL: URL?, keyword: String, http: HTTPClient,
                            onResult: @escaping @Sendable (SearchSourceResult) async -> Void) async {
        guard !eligible.isEmpty else { return }
        await withTaskGroup(of: SearchSourceResult.self) { group in
            var iterator = eligible.makeIterator()
            func enqueue(_ site: Site) {
                group.addTask {
                    let started = ContinuousClock.now
                    do {
                        try Task.checkCancellation()
                        let page = try await CatalogClient(site: site, origin: origin, http: http, jarURL: jarURL)
                            .list(category: nil, query: keyword, page: 1)
                        Diagnostics.shared.record(.debug, "search", "source=\(site.key) ok videos=\(page.videos.count) elapsed=\(started.duration(to: .now))")
                        return SearchSourceResult(site: site, page: page, error: nil)
                    } catch {
                        // localizedDescription hides the error type; keep the full value for diagnosis.
                        Diagnostics.shared.record(.warning, "search", "source=\(site.key) native=\(site.native) failed elapsed=\(started.duration(to: .now)) error=\(String(reflecting: error))")
                        return SearchSourceResult(site: site, page: nil, error: error.localizedDescription)
                    }
                }
            }
            for _ in 0..<min(max(1, concurrency), eligible.count) {
                if let site = iterator.next() { enqueue(site) }
            }
            for await result in group {
                guard !Task.isCancelled else { group.cancelAll(); break }
                await onResult(result)
                if let site = iterator.next() { enqueue(site) }
            }
        }
    }
}

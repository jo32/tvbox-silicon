import Foundation

extension Site {
    public var searchable: Bool { (raw["searchable"]?.int ?? 1) == 1 }
    public func canBrowse(jarURL: URL?) -> Bool {
        if native { return true }
        #if os(macOS)
        let hasPlugin = jarURL != nil || raw["jar"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return type == 3 && (api.hasPrefix("csp_") ? hasPlugin && LocalJarHost.available : LocalJarHost.scriptAvailable)
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
        await withTaskGroup(of: SearchSourceResult.self) { group in
            var iterator = eligible.makeIterator()
            func enqueue(_ site: Site) {
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let page = try await CatalogClient(site: site, origin: origin, http: http, jarURL: jarURL)
                            .list(category: nil, query: keyword, page: 1)
                        return SearchSourceResult(site: site, page: page, error: nil)
                    } catch { return SearchSourceResult(site: site, page: nil, error: error.localizedDescription) }
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

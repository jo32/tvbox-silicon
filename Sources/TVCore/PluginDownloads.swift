import Foundation

/// Coalesces downloads shared by multiple source sessions. Failures are never cached.
actor PluginDownloads {
    static let shared = PluginDownloads()
    private struct Cached {
        let data: Data
        let expires: Date
        var used: Date
    }
    private var cached: [URL: Cached] = [:]
    private var pending: [URL: Task<Data, Error>] = [:]
    private let lifetime: TimeInterval
    init(lifetime: TimeInterval = 300) { self.lifetime = lifetime }

    func data(at url: URL, http: HTTPClient) async throws -> Data {
        if var hit = cached[url], hit.expires > Date() {
            hit.used = Date(); cached[url] = hit
            return hit.data
        }
        if let download = pending[url] { return try await download.value }
        let download = Task { try await http.get(url).0 }
        pending[url] = download
        do {
            let data = try await download.value
            pending[url] = nil
            cached[url] = Cached(data: data, expires: Date().addingTimeInterval(lifetime), used: Date())
            while cached.count > 4 || cached.values.reduce(0, { $0 + $1.data.count }) > 40_000_000 {
                guard let oldest = cached.min(by: { $0.value.used < $1.value.used })?.key else { break }
                cached[oldest] = nil
            }
            return data
        } catch {
            pending[url] = nil
            throw error
        }
    }
}

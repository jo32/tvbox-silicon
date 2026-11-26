import Foundation

/// Conservative payload accounting, not a measurement of allocator RSS. Include retained metadata
/// as well as cards: plugins may return full episode lists or very long descriptions during search.
struct SearchPayloadBudget {
    struct Cost: Equatable {
        var bytes = 0
        var items = 0
        static func + (lhs: Self, rhs: Self) -> Self { Self(bytes: lhs.bytes + rhs.bytes, items: lhs.items + rhs.items) }
    }
    private(set) var used = Cost()
    let maximumBytes: Int
    let maximumItems: Int
    /// What one search keeps: thousands of ordinary cards use a few MB; a source that sends whole episode lists with
    /// each result uses far more.
    init(maximumBytes: Int = 64 << 20, maximumItems: Int = 24_000) {
        self.maximumBytes = maximumBytes; self.maximumItems = maximumItems
    }
    mutating func reserve(_ cost: Cost) -> Bool {
        guard cost.bytes <= maximumBytes - used.bytes, cost.items <= maximumItems - used.items else { return false }
        used = used + cost
        return true
    }
    static func cost(_ result: SearchSourceResult) -> Cost {
        var cost = cost(result.page?.videos ?? [])
        cost.bytes += 256
        cost.items += 1
        func text(_ value: String?) { cost.bytes += value.map { $0.utf8.count + 32 } ?? 0 }
        text(result.error); text(result.site.key); text(result.site.name); text(result.site.api)
        text(result.site.provenance?.origin.absoluteString); text(result.site.provenance?.spider?.absoluteString)
        // A cached result retains the source configuration after a subscription changes.
        var pending: [JSONValue] = [.object(result.site.raw)]
        while let value = pending.popLast() {
            switch value {
            case .string(let value): text(value)
            case .object(let values):
                cost.bytes += values.count * 48
                for (key, value) in values { text(key); pending.append(value) }
            case .array(let values): cost.bytes += values.count * 24; pending.append(contentsOf: values)
            default: cost.bytes += 16
            }
        }
        return cost
    }
    static func cost(_ videos: [Video]) -> Cost {
        var cost = Cost(items: videos.count)
        func text(_ value: String?) { cost.bytes += value.map { $0.utf8.count + 32 } ?? 0 }
        for video in videos {
            cost.bytes += 384
            for value in [video.id, video.name, video.poster?.absoluteString, video.year, video.remarks, video.synopsis, video.category, video.action] { text(value) }
            for (key, value) in video.posterHeaders { text(key); text(value) }
            for credit in video.credits ?? [] { cost.bytes += 64; text(credit.name); text(credit.category) }
            for episode in video.episodes {
                cost.bytes += 96
                for value in [episode.id, episode.name, episode.address, episode.flag, episode.videoID] { text(value) }
            }
        }
        return cost
    }
    static func trimmed(_ page: CatalogPage) -> CatalogPage { CatalogPage(videos: page.videos, pageCount: page.pageCount) }
    static var message: String { L10n.text("Search results reached the memory limit. Try a more specific search.") }
}

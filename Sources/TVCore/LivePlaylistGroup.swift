import Foundation

/// Live playlists that came from one subscription, as Live TV shows them (#815). `title` is nil for the section of
/// playlists that are subscriptions of their own (an M3U address), which are named after their subscriptions.
public struct LivePlaylistGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String?
    public let sources: [LiveSource]

    /// The playlists among `sources` by the subscription that lists them, in subscription order. A playlist two
    /// subscriptions list shows under the first, as the merge keeps it. A subscription that is only one playlist has no
    /// section of its own: those are gathered in one, where the first of them would be, each named after its subscription.
    public static func make(_ sources: [LiveSource], subscriptions: [(entry: SubscriptionEntry, document: Subscription)]) -> [LivePlaylistGroup] {
        var remaining = Set(sources.filter { !$0.isBuiltIn }.map(\.url))
        guard !remaining.isEmpty else { return [] }
        var groups: [LivePlaylistGroup] = [], single: [LiveSource] = [], singleAt: Int?
        for (entry, document) in subscriptions {
            let own = document.lives.filter { !$0.isBuiltIn && remaining.remove($0.url) != nil }
            guard !own.isEmpty else { continue }
            if document.isPlaylistOnly {
                singleAt = singleAt ?? groups.count
                single += own.map { LiveSource(name: entry.title, url: $0.url, headers: $0.headers, guide: $0.guide) }
            } else {
                groups.append(LivePlaylistGroup(id: entry.address, title: entry.title, sources: own))
            }
        }
        // Ones no subscription claims (none should be): with the single playlists, in the order given.
        let rest = sources.filter { !$0.isBuiltIn && remaining.contains($0.url) }
        if !single.isEmpty || !rest.isEmpty {
            groups.insert(LivePlaylistGroup(id: "", title: nil, sources: single + rest), at: singleAt ?? groups.count)
        }
        return groups
    }
}

extension Subscription {
    /// Just one live playlist (an M3U or TXT address added as a subscription): removing the playlist removes it.
    public var isPlaylistOnly: Bool { sites.isEmpty && lives.filter { !$0.isBuiltIn }.count == 1 }
}

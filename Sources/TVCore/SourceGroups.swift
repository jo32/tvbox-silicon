import Foundation

public enum SourceLists {
    /// Sources the home row, the home picker, and the More count may use.
    public static func browsable(_ sites: [Site], jarURL: URL?, userHidden: (Site) -> Bool) -> [Site] {
        SourceStrategy.arrange(sites) { !$0.hidden && $0.canBrowse(jarURL: jarURL) && !userHidden($0) }
    }
}

public struct SourceGroup: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case pinned, builtIn, subscription(String)
        /// The sources the viewer hid, last on the page.
        case hidden
    }
    public var kind: Kind
    public var title: String
    public var sites: [Site]
    public var id: String {
        switch kind {
        case .pinned: "pinned"
        case .builtIn: "builtIn"
        case .subscription(let address): address
        case .hidden: "hidden"
        }
    }
}

public enum SourceGroups {
    public static func make(entries: [SubscriptionEntry], documents: [String: Subscription], builtIns: [Site], builtInOrigin: URL, mergedSites: [Site], pinOrder: [Site], userHidden: (Site) -> Bool, includeHidden: Bool, jarURL: URL?) -> [SourceGroup] {
        func isPinned(_ site: Site, fallback: URL) -> Bool {
            let origin = site.origin(or: fallback)
            return pinOrder.contains { $0.sourceKey == site.sourceKey && $0.origin(or: fallback) == origin }
        }
        func eligible(_ site: Site) -> Bool {
            !site.hidden && site.canBrowse(jarURL: jarURL) && (includeHidden || !userHidden(site))
        }
        var groups: [SourceGroup] = []
        let pinnedSites = pinOrder.filter(eligible)
        if !pinnedSites.isEmpty { groups.append(SourceGroup(kind: .pinned, title: "Pinned Group", sites: pinnedSites)) }
        let builtInSites = builtIns.filter { eligible($0) && !isPinned($0, fallback: builtInOrigin) }
        if !builtInSites.isEmpty { groups.append(SourceGroup(kind: .builtIn, title: "Recommended", sites: builtInSites)) }
        for entry in entries where entry.enabled {
            guard let origin = documents[entry.address]?.origin else { continue }
            let own = mergedSites.filter { !$0.isBuiltIn && $0.provenance?.origin == origin && !isPinned($0, fallback: origin) && eligible($0) }
            let arranged = SourceStrategy.arrange(own, where: { _ in true })
            if !arranged.isEmpty { groups.append(SourceGroup(kind: .subscription(entry.address), title: entry.title, sites: arranged)) }
        }
        // Hidden sources leave their groups and wait in one group at the end, where they can be unhidden.
        if !includeHidden {
            let hidden = (builtIns + mergedSites.filter { !$0.isBuiltIn }).filter { !$0.hidden && $0.canBrowse(jarURL: jarURL) && userHidden($0) }
            if !hidden.isEmpty { groups.append(SourceGroup(kind: .hidden, title: "Hidden Sources", sites: hidden)) }
        }
        return groups
    }

    /// The Watch Now source row. Pinned and built-in sources keep the order they were given.
    /// Every other source follows the sources page: one subscription after another, in that page's order.
    /// Hidden sources stay in their group on the sources page and do not join this row.
    public static func homeRow(pinned: [Site], builtIn: [Site], groups: [SourceGroup]) -> [Site] {
        let placed = Set((pinned + builtIn).map(\.id))
        let directory = groups.filter { $0.kind != .hidden }.flatMap(\.sites)
        return pinned + builtIn + directory.filter { !placed.contains($0.id) }
    }
}

public enum SubscriptionOrder {
    /// The displayed addresses after `address` is dropped onto the header of `target`. Dropping onto an
    /// earlier header inserts before it, onto a later header inserts after it. Indexes are from before the removal.
    public static func moving(_ address: String, onto target: String, in displayed: [String]) -> [String] {
        guard address != target, let from = displayed.firstIndex(of: address), let to = displayed.firstIndex(of: target) else { return displayed }
        var next = displayed
        next.remove(at: from)
        // After the removal a later target sits at `to - 1`, so inserting at `to` lands after it.
        next.insert(address, at: to)
        return next
    }

    public static func applying(displayed: [String], to subscriptions: [SubscriptionEntry]) -> [SubscriptionEntry] {
        let shown = Set(displayed)
        var next = displayed.makeIterator()
        return subscriptions.map { entry in
            guard shown.contains(entry.address), let address = next.next(), let replacement = subscriptions.first(where: { $0.address == address }) else { return entry }
            return replacement
        }
    }
}

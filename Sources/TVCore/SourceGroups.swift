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
        /// Sources that reached the merged list but belong to no listed subscription: filed onto a
        /// subscription that is now off, or carried by a copy whose address changed. They are listed
        /// rather than dropped, because a source that exists and cannot be seen looks like a bug.
        case other
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
        case .other: "other"
        }
    }
}

public enum SourceGroups {
    /// `privacyHidden` marks a source the privacy vault keeps off the list *while locked*. Unlike a
    /// plain `userHidden` source — which waits in the "Hidden Sources" group so the viewer can unhide
    /// it — a privacy-hidden source must disappear entirely when locked, or the "Hidden Sources" group
    /// and its count would tell a locked-out viewer how much is in the vault. Unlock and it returns
    /// to its own group.
    public static func make(entries: [SubscriptionEntry], documents: [String: Subscription], builtIns: [Site], builtInOrigin: URL, mergedSites: [Site], pinOrder: [Site], userHidden: (Site) -> Bool, includeHidden: Bool, jarURL: URL?, privacyHidden: (Site) -> Bool = { _ in false }, reassign: (Site, String) -> String? = { _, _ in nil }) -> [SourceGroup] {
        /// An entry is known by the address the viewer typed; its copy is known by where the address
        /// finally landed — a redirect, a mirror, an http-to-https hop. Grouping used to compare the
        /// two directly, so every subscription that redirected filed nothing: its sources silently
        /// disappeared and only the built-in ones were left. Map one to the other instead.
        var addressOfOrigin: [String: String] = [:]
        for entry in entries {
            guard let origin = documents[entry.address]?.origin.absoluteString, addressOfOrigin[origin] == nil else { continue }
            addressOfOrigin[origin] = entry.address
        }
        /// The entry address of the subscription a source came from: what the viewer typed, which a
        /// refresh never changes. An origin no entry claims keeps itself.
        func ownAddress(_ site: Site) -> String {
            let origin = site.origin(or: builtInOrigin).absoluteString
            return addressOfOrigin[origin] ?? origin
        }
        /// The address a source belongs under: the one the viewer moved it to, else its own.
        func home(_ site: Site) -> String {
            let own = ownAddress(site)
            return reassign(site, own) ?? own
        }
        func isPinned(_ site: Site, fallback: URL) -> Bool {
            let origin = site.origin(or: fallback)
            return pinOrder.contains { $0.sourceKey == site.sourceKey && $0.origin(or: fallback) == origin }
        }
        func eligible(_ site: Site) -> Bool {
            !site.hidden && site.canBrowse(jarURL: jarURL) && !privacyHidden(site) && (includeHidden || !userHidden(site))
        }
        var groups: [SourceGroup] = []
        let pinnedSites = pinOrder.filter(eligible)
        if !pinnedSites.isEmpty { groups.append(SourceGroup(kind: .pinned, title: "Pinned Group", sites: pinnedSites)) }
        let builtInSites = builtIns.filter { eligible($0) && !isPinned($0, fallback: builtInOrigin) }
        if !builtInSites.isEmpty { groups.append(SourceGroup(kind: .builtIn, title: "Built-in", sites: builtInSites)) }
        // A source the viewer dragged onto another subscription files under that subscription instead of its own.
        for entry in entries where entry.enabled {
            guard let origin = documents[entry.address]?.origin else { continue }
            let own = mergedSites.filter { !$0.isBuiltIn && !isPinned($0, fallback: origin) && eligible($0) && home($0) == entry.address }
            let arranged = SourceStrategy.arrange(own, where: { _ in true })
            if !arranged.isEmpty { groups.append(SourceGroup(kind: .subscription(entry.address), title: entry.title, sites: arranged)) }
        }
        // Sources with no listed subscription of their own still show at the end rather than vanishing:
        // edited onto a subscription that is now off, or carried by a copy whose entry is gone.
        let placed = Set(groups.flatMap(\.sites).map(\.id))
        let unplaced = mergedSites.filter { !$0.isBuiltIn && !placed.contains($0.id) && eligible($0) && !isPinned($0, fallback: builtInOrigin) }
        if !unplaced.isEmpty { groups.append(SourceGroup(kind: .other, title: "Other Sources", sites: SourceStrategy.arrange(unplaced, where: { _ in true }))) }
        // Hidden sources leave their groups and wait in one group at the end, where they can be unhidden.
        // Privacy-hidden sources are not here: a locked vault must not reveal them, even as a count.
        if !includeHidden {
            let hidden = (builtIns + mergedSites.filter { !$0.isBuiltIn }).filter { !$0.hidden && $0.canBrowse(jarURL: jarURL) && userHidden($0) && !privacyHidden($0) }
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

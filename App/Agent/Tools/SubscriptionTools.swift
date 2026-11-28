import SwiftUI
import TVCore

/// The viewer's subscriptions and the video sources they bring. Addresses are shown by host only: the rest of one
/// can carry a token.
@MainActor enum SubscriptionTools {
    static func make(_ context: AgentToolContext) -> [AppTool] {
        let store = context.store
        return [
            AppTool("subscriptions_list", .read, """
                The viewer's subscriptions in their order: id, name, host (never the full address), on or off, \
                how many sources and live playlists each brings, and its last refresh error.
                """, Schema.object()) { _ in list(store) },

            AppTool("subscription_add", .change, """
                Adds a subscription by its address (a TVBox JSON config, an M3U/TXT live playlist, a source list for \
                novels or comics…), as Settings › Add Subscription does, and reports what was imported.
                """, Schema.object([
                    "address": Schema.string("The subscription's address (http, https, or a file the viewer imported)."),
                    "name": Schema.string("A name to show for it (optional)."),
                ], required: ["address"]), summary: { args in
                    let host = ((try? args.string("address")) ?? nil).map(AgentLookup.host) ?? ""
                    return (L10n.text("Add the subscription from %@?", host.isEmpty ? "?" : host), (try? args.string("name")) ?? nil)
                }) { args in try await add(args, store) },

            AppTool("subscription_refresh", .read, """
                Fetches subscriptions again (one by id, or every one that is on) and reports errors. A subscription \
                that fails keeps its last good copy.
                """, Schema.object([
                    "subscription_id": Schema.string("Only this subscription (an id from subscriptions_list)."),
                ])) { args in try await refresh(args, store) },

            AppTool("subscription_edit", .change, """
                Changes a subscription: turn it on or off, rename it (an empty name shows its host again), or move \
                it (to the top or bottom, or up or down one place; earlier subscriptions win when sources clash).
                """, Schema.object([
                    "subscription_id": Schema.string("An id from subscriptions_list."),
                    "enabled": Schema.boolean("Turn it on (true) or off (false)."),
                    "name": Schema.string("Its new name."),
                    "move": Schema.string("Where to move it.", enum: ["top", "bottom", "up", "down"]),
                ], required: ["subscription_id"]), summary: { args in editSummary(args, store) }) { args in try await edit(args, store) },

            AppTool("subscription_remove", .destructive, """
                Removes a subscription and the sources it brings.
                """, Schema.object([
                    "subscription_id": Schema.string("An id from subscriptions_list."),
                ], required: ["subscription_id"]), summary: { args in
                    let entry = (try? args.requiredString("subscription_id")).flatMap { try? AgentLookup.subscriptionEntry($0, store: store) }
                    return (L10n.text("Remove the subscription “%@”?", entry.map(title) ?? "?"), entry.map { AgentLookup.host($0.address) })
                }) { args in
                    let entry = try AgentLookup.subscriptionEntry(try args.requiredString("subscription_id"), store: store)
                    store.removeSubscription(entry)
                    return .obj(["removed": .str(title(entry)), "subscriptions_left": .num(store.subscriptions.count)])
                },

            AppTool("sources_list", .read, """
                The video sources of the subscriptions that are on, in the viewer's order: source_id, name, kind of \
                source, whether it searches, pinned, and its health (healthy, unstable, failing or unknown). Hidden \
                sources are left out.
                """, Schema.object([
                    "query": Schema.string("Only sources whose name contains this text."),
                    "health": Schema.string("Only sources with this health.", enum: ["healthy", "unstable", "failing", "unknown"]),
                    "offset": Schema.integer("Skip this many (for the next page).", minimum: 0),
                ])) { args in try sources(args, store) },
        ]
    }

    static func title(_ entry: SubscriptionEntry) -> String {
        let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? AgentLookup.host(entry.address) : name
    }

    private static func json(_ entry: SubscriptionEntry, _ store: Store) -> JSONValue {
        let document = store.documents[entry.address]
        return .obj([
            "subscription_id": .str(AgentLookup.subscriptionID(entry)), "name": .str(title(entry)),
            "host": .str(AgentLookup.host(entry.address)), "enabled": .bool(entry.enabled),
            "local_file": ImportedFiles.isImported(entry.address) ? .bool(true) : nil,
            "sources": document.map { .num($0.sites.count) }, "live_playlists": document.flatMap { $0.lives.isEmpty ? nil : .num($0.lives.count) },
            "error": .text(store.subscriptionErrors[entry.address].map { AgentToolKit.clip($0, 200) }),
        ])
    }

    private static func list(_ store: Store) -> JSONValue {
        .capped("subscriptions", store.subscriptions.map { json($0, store) }, limit: 30, extra: ["busy": store.importing ? .bool(true) : nil])
    }

    /// Waits for an import or refresh the viewer started to end, so the tool's own call isn't dropped.
    private static func waitIdle(_ store: Store) async throws {
        for _ in 0..<120 where store.importing { try await Task.sleep(for: .milliseconds(250)) }
        guard !store.importing else { throw AgentToolError("The app is still importing subscriptions; try again shortly.") }
    }

    private static func add(_ args: AgentArguments, _ store: Store) async throws -> JSONValue {
        let address = try args.requiredString("address")
        guard let url = try? WebAddress.resolve(typed: address) else { throw AgentToolError("That isn't a web address.") }
        try await waitIdle(store)
        let before = Set(store.subscriptions.map(\.address))
        await store.importSubscription(address: address, name: try args.string("name"))
        if let error = store.importError { store.importError = nil; throw AgentToolError(error) }
        let entry = store.subscriptions.first { $0.address == url.absoluteString }
        return .obj([
            "result": .text(store.notice),
            "subscription": entry.map { json($0, store) },
            "new": .bool(entry.map { !before.contains($0.address) } ?? false),
        ])
    }

    private static func refresh(_ args: AgentArguments, _ store: Store) async throws -> JSONValue {
        try await waitIdle(store)
        if let id = try args.string("subscription_id") {
            let entry = try AgentLookup.subscriptionEntry(id, store: store)
            guard entry.enabled else { throw AgentToolError("That subscription is off; turn it on with subscription_edit first.") }
            await store.refreshSubscription(entry)
            return .obj(["subscription": store.subscriptions.first { $0.address == entry.address }.map { json($0, store) }])
        }
        await store.refreshSubscriptions()
        let failed = store.subscriptions.filter { $0.enabled && store.subscriptionErrors[$0.address] != nil }
        return .obj(["refreshed": .num(store.subscriptions.filter(\.enabled).count), "failed": .list(failed.map { json($0, store) }),
                     "note": .text(store.notice)])
    }

    private static func editSummary(_ args: AgentArguments, _ store: Store) -> (summary: String, detail: String?) {
        guard let id = try? args.requiredString("subscription_id"), let entry = try? AgentLookup.subscriptionEntry(id, store: store) else {
            return (L10n.text("Change a subscription?"), nil)
        }
        let name = title(entry)
        if let on = try? args.bool("enabled") {
            return (on ? L10n.text("Turn on the subscription “%@”?", name) : L10n.text("Turn off the subscription “%@”?", name), nil)
        }
        if let new = try? args.string("name") { return (L10n.text("Rename the subscription “%@” to “%@”?", name, new), nil) }
        return (L10n.text("Move the subscription “%@”?", name), nil)
    }

    private static func edit(_ args: AgentArguments, _ store: Store) async throws -> JSONValue {
        var entry = try AgentLookup.subscriptionEntry(try args.requiredString("subscription_id"), store: store)
        let move = try args.choice("move", ["top", "bottom", "up", "down"])
        let enabled = try args.bool("enabled")
        guard enabled != nil || args.has("name") || move != nil else { throw AgentToolError("Give enabled, name or move.") }
        if let enabled, enabled != entry.enabled {
            try await waitIdle(store)
            await store.setSubscription(entry, enabled: enabled)
        }
        if args.has("name") {
            let name = (try args.text("name") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.count <= 80 else { throw AgentToolError("`name` is too long.") }
            if let current = store.subscriptions.first(where: { $0.address == entry.address }) { entry = current }
            store.renameSubscription(entry, to: name)
        }
        if let move, let current = store.subscriptions.first(where: { $0.address == entry.address }) {
            switch move {
            case "top": store.moveSubscription(current, toTop: true)
            case "bottom": store.moveSubscription(current, toTop: false)
            case "up": store.moveSubscription(current, by: -1)
            default: store.moveSubscription(current, by: 1)
            }
        }
        guard let updated = store.subscriptions.first(where: { $0.address == entry.address }) else { return list(store) }
        return .obj(["subscription": json(updated, store),
                     "position": .num((store.subscriptions.firstIndex(of: updated) ?? 0) + 1), "of": .num(store.subscriptions.count)])
    }

    static func health(_ site: Site, origin: URL) -> String {
        switch SourceHealth.shared.status(site, origin: origin) {
        case .unknown: "unknown"
        case .healthy: "healthy"
        case .unstable: "unstable"
        case .failing: "failing"
        }
    }

    private static func kind(_ site: Site) -> String {
        switch site.runtime {
        case .api: "api"
        case .python: "python"
        case .javascript: "javascript"
        case .jar: "jar"
        case .unsupported: "unsupported"
        }
    }

    private static func sources(_ args: AgentArguments, _ store: Store) throws -> JSONValue {
        let config = try AgentLookup.subscription(store)
        let query = try args.string("query")
        let wanted = try args.choice("health", ["healthy", "unstable", "failing", "unknown"])
        let offset = try args.int("offset") ?? 0
        let items: [JSONValue] = store.orderedSites(config).compactMap { site in
            guard !store.hiddenSources.contains(site, origin: config.origin) else { return nil }
            if let query, !site.name.localizedCaseInsensitiveContains(query) { return nil }
            let health = health(site, origin: config.origin)
            if let wanted, wanted != health { return nil }
            return .obj([
                "source_id": .str(AgentLookup.sourceID(site, origin: config.origin)), "name": .str(site.name),
                "kind": .str(kind(site)), "health": .str(health),
                "searchable": .bool(site.searchable), "pinned": store.pinnedSources.contains(site, origin: config.origin) ? .bool(true) : nil,
            ])
        }
        return .capped("sources", Array(items.dropFirst(offset)), limit: 30, extra: ["total": .num(items.count)])
    }
}

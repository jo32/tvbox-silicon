import SwiftUI
import TVCore

/// The viewer's settings: finding them, reading them, changing them and opening their row.
@MainActor enum SettingsTools {
    static func make(_ context: AgentToolContext) -> [AppTool] {
        let store = context.store
        AgentSettingsCatalog.store = store
        return [
            AppTool("settings_search", .read, """
                Finds the viewer's settings and Settings pages by words in any language ("dark mode", "弹幕透明度", \
                "skip intro"), with each setting's id, current value and allowed values. Without a query, lists every \
                setting. Use the ids with settings_get, settings_set and settings_open.
                """, Schema.object([
                    "query": Schema.string("Words to look for; leave out to list all settings."),
                ])) { args in try search(args, store) },

            AppTool("settings_get", .read, """
                Reads settings by id: the current value, its label, and every allowed value with its label.
                """, Schema.object([
                    "ids": Schema.strings("Setting ids from settings_search."),
                ], required: ["ids"])) { args in
                    let ids = try args.strings("ids") ?? []
                    guard !ids.isEmpty else { throw AgentToolError("Give at least one id in `ids`.") }
                    return .obj(["settings": .list(try ids.prefix(20).map { try AgentSettingsCatalog.setting($0, store: store).json(store, detailed: true) })])
                },

            AppTool("settings_set", .change, """
                Changes one setting, as its switch or picker in Settings would, and returns the old and the new value. \
                The value must be one settings_get lists for it: true or false for a switch, a listed value for a choice.
                """, Schema.object([
                    "id": Schema.string("The setting's id from settings_search."),
                    "value": Schema.value("The new value: true/false, a listed choice's value, a number or text."),
                ], required: ["id", "value"]), summary: { args in setSummary(args, store) }) { args in
                    let setting = try AgentSettingsCatalog.setting(try args.requiredString("id"), store: store)
                    guard let raw = args.values["value"], raw != .null else { throw AgentToolError("Missing required argument `value`.") }
                    let value = try setting.validate(raw)
                    let old = setting.read(store)
                    setting.write(store, value)
                    let new = setting.read(store)
                    return .obj([
                        "id": .str(setting.id), "title": .str(setting.title()),
                        "old": old, "new": new, "old_label": .str(setting.label(old)), "new_label": .str(setting.label(new)),
                        "changed": .bool(!AgentSetting.same(old, new)),
                    ])
                },

            AppTool("settings_open", .read, """
                Opens Settings at a setting's row or a Settings page (an id from settings_search), so the viewer \
                sees it highlighted.
                """, Schema.object([
                    "id": Schema.string("A setting or page id from settings_search."),
                ], required: ["id"])) { args in try await open(try args.requiredString("id"), context) },
        ]
    }

    private static func search(_ args: AgentArguments, _ store: Store) throws -> JSONValue {
        guard let query = try args.string("query") else {
            let all = AgentSettingsCatalog.available(store)
            return .obj(["settings": .list(all.map { $0.json(store, detailed: false) })])
        }
        let found = AgentSettingsCatalog.search(query, store: store)
        let items: [JSONValue] = found.map { match in
            if let setting = match.setting { return setting.json(store, detailed: false) }
            guard let link = match.link else { return .null }
            return .obj(["id": .str(link.id), "title": .str(link.title()), "page": .str(link.page()), "type": .str("page")])
        }
        return .capped("settings", items, limit: 20, extra: ["query": .str(query), "note": items.isEmpty ? .str("Nothing matched; try other words, or call without a query for the full list.") : nil])
    }

    private static func setSummary(_ args: AgentArguments, _ store: Store) -> (summary: String, detail: String?) {
        guard let id = try? args.requiredString("id"), let setting = try? AgentSettingsCatalog.setting(id, store: store) else {
            return (L10n.text("Change a setting?"), nil)
        }
        let value = args.values["value"].flatMap { try? setting.validate($0) }
        let new = value.map(setting.label) ?? (args.values["value"]?.string ?? "")
        let old = setting.label(setting.read(store))
        return (L10n.text("Change “%@” to %@?", setting.title(), new), L10n.text("Now: %@", old))
    }

    /// Opens Settings at a setting's row or a Settings page.
    static func open(_ id: String, _ context: AgentToolContext) async throws -> JSONValue {
        let store = context.store
        let setting = AgentSettingsCatalog.available(store).first { $0.id == id }
        let link = AgentSettingsCatalog.links.first { $0.id == id && $0.available(store) }
        guard setting != nil || link != nil else { throw AgentToolError("No setting or Settings page has the id `\(id)`. Use settings_search.") }
        let title = setting?.title() ?? link?.title() ?? ""
        if let subpage = setting?.subpage {
            try await AgentNavigator.push(Route(build: subpage), in: .settings, store: store)
            return .obj(["opened": .str(id), "title": .str(title)])
        }
        let changes = store.section != .settings
        try AgentNavigator.open(.settings, in: store)
        if changes { try? await Task.sleep(for: .milliseconds(450)) }
        #if os(tvOS)
        // Apple TV's Settings has no rows to jump to.
        return .obj(["opened": .str(id), "title": .str(title), "note": .str("Settings is open; on Apple TV the viewer scrolls to the row.")])
        #else
        if let name = setting?.anchor ?? link?.anchor, let anchor = SettingsRowAnchor.named(name) {
            store.agentSettingsAnchor = anchor
        }
        return .obj(["opened": .str(id), "title": .str(title)])
        #endif
    }
}

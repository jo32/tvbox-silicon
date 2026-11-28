import SwiftUI
import TVCore

/// The app as a whole: where the viewer is and what plays (`app_state`), opening a page (`open_page`), and the
/// app's recent diagnostic lines (`recent_log`).
@MainActor enum AppTools {
    static func make(_ context: AgentToolContext) -> [AppTool] {
        let store = context.store
        let sectionNames = AgentNavigator.sections(store).map(AgentNavigator.name)
        return [
            AppTool("app_state", .read, """
                What the viewer sees now: the page, the sections they can open, what plays in the video player and \
                the music player, the platform, the app's language and how many subscriptions and sources are on. \
                Call it first when a request depends on the screen ("pause this", "what is playing").
                """, Schema.object()) { _ in state(context) },

            AppTool("open_page", .read, """
                Opens a page for the viewer: a section of the app, or a video's details page (video_id from \
                search_videos), a source's page (source_id from sources_list) or a Settings item (setting_id from \
                settings_search). Give exactly one of page, video_id, source_id or setting_id.
                """, Schema.object([
                    "page": Schema.string("The section to open.", enum: sectionNames),
                    "video_id": Schema.string("A video id from search_videos, video_details, history_list or favorites_list."),
                    "source_id": Schema.string("A source id from sources_list."),
                    "setting_id": Schema.string("A setting or Settings page id from settings_search."),
                ])) { args in try await open(args, context) },

            AppTool("recent_log", .read, """
                The app's most recent diagnostic log lines (already scrubbed of addresses and secrets), newest last: \
                for finding out why a source, a subscription, a script or playback failed.
                """, Schema.object([
                    "limit": Schema.integer("How many lines, newest last (default 40).", minimum: 1, maximum: 100),
                    "level": Schema.string("Only lines at this level or worse.", enum: ["info", "warning", "error"]),
                    "category": Schema.string("Only lines whose category contains this text, e.g. catalog, subscription, player, python, script."),
                ])) { args in try await log(args) },
        ]
    }

    static var platform: String {
        #if os(macOS)
        "macOS"
        #elseif os(tvOS)
        "tvOS"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        #endif
    }

    private static func state(_ context: AgentToolContext) -> JSONValue {
        let store = context.store
        // What plays, as player_control's status tells it.
        let playing = store.playing.map { VideoTools.status($0, PlaybackSession.current, store) }
        var music: JSONValue?
        if let track = store.music.track, context.isAvailable(.music) {
            music = .obj(["title": .str(track.title), "artists": .text(track.artists.joined(separator: ", ")), "album": .text(track.album)])
        }
        let config = store.subscription
        return .obj([
            "platform": .str(platform),
            "language": .str(L10n.resolvedLanguage()),
            "page": .str(AgentNavigator.name(store.section)),
            "page_title": .str(store.section.title),
            "sections": .list(AgentNavigator.sections(store).map { .str(AgentNavigator.name($0)) }),
            "playing": playing ?? .null,
            "music": music,
            "subscriptions": .num(store.subscriptions.count),
            "subscriptions_on": .num(store.subscriptions.filter(\.enabled).count),
            "sources": .num(config.map { config in config.sites.filter { !store.hiddenSources.contains($0, origin: config.origin) }.count } ?? 0),
            "live_sources": .num(store.liveSources.count),
            "busy": store.importing ? .bool(true) : nil,
        ])
    }

    private static func open(_ args: AgentArguments, _ context: AgentToolContext) async throws -> JSONValue {
        let store = context.store
        let given = ["page", "video_id", "source_id", "setting_id"].filter(args.has)
        guard given.count == 1 else { throw AgentToolError("Give exactly one of page, video_id, source_id or setting_id.") }
        if let name = try args.string("page") {
            guard let section = AgentNavigator.section(named: name) else {
                throw AgentToolError("Unknown page `\(name)`. Pages: \(AgentNavigator.sections(store).map(AgentNavigator.name).joined(separator: ", ")).")
            }
            try AgentNavigator.open(section, in: store)
            return .obj(["opened": .str(name), "title": .str(section.title)])
        }
        if let id = try args.string("video_id") {
            let (_, client, videoID) = try AgentLookup.video(id, store: store)
            let title = context.videoTitles[id] ?? ""
            let video = Video(id: videoID, name: title)
            try await AgentNavigator.push(Route { AnyView(CatalogDestination(video: video, client: client)) },
                                          in: AgentNavigator.currentStack(store), store: store)
            return .obj(["opened": .str("video"), "title": .text(title)])
        }
        if let id = try args.string("source_id") {
            let (site, config) = try AgentLookup.site(sourceID: id, store: store)
            try await AgentNavigator.push(Route { AnyView(SiteView(site: site, origin: config.origin, jarURL: config.spiderURL)) },
                                          in: AgentNavigator.currentStack(store), store: store)
            return .obj(["opened": .str("source"), "title": .str(site.name)])
        }
        return try await SettingsTools.open(try args.requiredString("setting_id"), context)
    }

    private static func log(_ args: AgentArguments) async throws -> JSONValue {
        let limit = try args.int("limit", in: 1...100, default: 40)
        let level = try args.choice("level", ["info", "warning", "error"])
        let category = try args.string("category")?.lowercased()
        let rank: [String: Int] = ["debug": 0, "info": 1, "warning": 2, "error": 3]
        let wanted = level.flatMap { rank[$0] } ?? 0
        let snapshot = await Diagnostics.shared.snapshot()
        let entries = snapshot.entries.filter { entry in
            (rank[entry.level.rawValue] ?? 1) >= wanted && (category.map { entry.category.lowercased().contains($0) } ?? true)
        }
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX"); time.dateFormat = "HH:mm:ss"
        let lines = entries.suffix(limit).map { entry in
            JSONValue.str("\(time.string(from: entry.date)) \(entry.level.rawValue) \(entry.category): \(AgentToolKit.clip(entry.message, 300))")
        }
        return .obj(["lines": .list(lines), "earlier": entries.count > limit ? .num(entries.count - limit) : nil])
    }
}

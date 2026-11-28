import SwiftUI
import TVCore

/// The viewer's library: playback history, favorites and downloads.
@MainActor enum LibraryTools {
    static func make(_ context: AgentToolContext) -> [AppTool] {
        let store = context.store
        return [
            AppTool("history_list", .read, """
                The viewer's playback history, most recent first: title, episode, progress and when, with a \
                history_id for play (resumes it) and history_remove, and the video_id where the source is still there.
                """, Schema.object([
                    "query": Schema.string("Only titles containing this text."),
                    "limit": Schema.integer("How many (default 20).", minimum: 1, maximum: 30),
                ])) { args in try historyList(args, store) },

            AppTool("history_remove", .destructive, """
                Removes titles from the viewer's playback history (their progress is lost).
                """, Schema.object([
                    "history_ids": Schema.strings("Ids from history_list."),
                ], required: ["history_ids"]), summary: { args in
                    let entries = ((try? args.strings("history_ids")) ?? []).compactMap { historyEntry($0, store) }
                    return (L10n.text("Remove %@ from history?", names(entries.map(\.context.videoName))), nil)
                }) { args in
                    let ids = try args.strings("history_ids") ?? []
                    guard !ids.isEmpty else { throw AgentToolError("Give at least one id in `history_ids`.") }
                    let entries = try ids.map { id in
                        guard let entry = historyEntry(id, store) else { throw AgentToolError("No history entry has the id `\(id)`.") }
                        return entry
                    }
                    store.playbackHistory.remove(Set(entries.map(\.id)))
                    return .obj(["removed": .list(entries.map { .str($0.context.videoName) })])
                },

            AppTool("favorites_list", .read, """
                The viewer's favorites: videos, episodes, live channels, songs and cloud files, newest first, with a \
                favorite_id for play and favorites_remove.
                """, Schema.object([
                    "kind": Schema.string("Only this kind.", enum: ["video", "episode", "live", "music", "cloud"]),
                    "query": Schema.string("Only names containing this text."),
                ])) { args in try favoritesList(args, context) },

            AppTool("favorites_add", .change, """
                Adds a video (video_id from search_videos or video_details) to the viewer's favorites.
                """, Schema.object([
                    "video_id": Schema.string("A video id."),
                ], required: ["video_id"]), summary: { args in
                    guard let title = context.title(ofVideo: try? args.string("video_id")) else { return (L10n.text("Allow the assistant to use %@?", "favorites_add"), nil) }
                    return (L10n.text("Add “%@” to Favorites?", title), nil)
                }) { args in try await addFavorite(args, context) },

            AppTool("favorites_remove", .change, """
                Removes items from the viewer's favorites.
                """, Schema.object([
                    "favorite_ids": Schema.strings("Ids from favorites_list."),
                ], required: ["favorite_ids"]), summary: { args in
                    let items = ((try? args.strings("favorite_ids")) ?? []).compactMap { favorite($0, store) }
                    return (L10n.text("Remove %@ from Favorites?", names(items.map(title))), nil)
                }) { args in
                    let ids = try args.strings("favorite_ids") ?? []
                    guard !ids.isEmpty else { throw AgentToolError("Give at least one id in `favorite_ids`.") }
                    let items = try ids.map { id in
                        guard let item = favorite(id, store) else { throw AgentToolError("No favorite has the id `\(id)`.") }
                        return item
                    }
                    for item in items where store.favorites.contains(item) { store.favorites.toggle(item) }
                    return .obj(["removed": .list(items.map { .str(title($0)) })])
                },

            AppTool("downloads_list", .read, """
                The viewer's video downloads: title, episode, status and progress, with a download_id for play \
                (finished ones), downloads_pause and downloads_remove.
                """, Schema.object([
                    "status": Schema.string("Only downloads in this state.", enum: ["active", "paused", "completed", "failed"]),
                ])) { args in try downloadsList(args) },

            AppTool("downloads_start", .change, """
                Downloads episodes of a video to the device, for watching offline. Give video_id, optionally the \
                line, and the episodes (1-based numbers or names; default: the first episode).
                """, Schema.object([
                    "video_id": Schema.string("A video id."),
                    "line": Schema.numberOrText("The line's name or 1-based number (default: the first)."),
                    "episodes": .obj(["type": .str("array"), "items": .object(["type": .array([.str("integer"), .str("string")])]),
                                      "description": .str("Episodes by 1-based number or name; at most 50.")]),
                ], required: ["video_id"]), summary: { args in
                    let title = context.title(ofVideo: try? args.string("video_id")) ?? "?"
                    let count = args.values["episodes"]?.array?.count ?? 1
                    return (L10n.text("Download “%@”?", title), L10n.text("Episodes: %@", String(count)))
                }) { args in try await startDownloads(args, context) },

            AppTool("downloads_pause", .change, """
                Pauses or resumes downloads.
                """, Schema.object([
                    "download_ids": Schema.strings("Ids from downloads_list."),
                    "resume": Schema.boolean("true resumes them instead (default false)."),
                ], required: ["download_ids"])) { args in
                    let resume = try args.bool("resume") ?? false
                    let items = try downloads(args)
                    for item in items { if resume { DownloadLibrary.shared.resume(item.id) } else { DownloadLibrary.shared.pause(item.id) } }
                    return .obj([resume ? "resumed" : "paused": .list(items.map { .str($0.displayName) })])
                },

            AppTool("downloads_remove", .destructive, """
                Deletes downloads and their files from the device.
                """, Schema.object([
                    "download_ids": Schema.strings("Ids from downloads_list."),
                ], required: ["download_ids"]), summary: { args in
                    let items = ((try? args.strings("download_ids")) ?? []).compactMap { DownloadLibrary.shared.item(id: $0) }
                    return (L10n.text("Delete %@ from Downloads?", names(items.map(\.displayName))), nil)
                }) { args in
                    let items = try downloads(args)
                    DownloadLibrary.shared.remove(items.map(\.id))
                    return .obj(["removed": .list(items.map { .str($0.displayName) })])
                },
        ]
    }

    /// “A”, “A, B”, or “A, B and 3 more”, for a confirmation card.
    static func names(_ names: [String]) -> String {
        let quoted = names.map { "“\($0)”" }
        guard quoted.count > 2 else { return quoted.joined(separator: ", ") }
        return L10n.text("%@ and %@ more", quoted.prefix(2).joined(separator: ", "), String(quoted.count - 2))
    }

    // MARK: History

    static func historyID(_ entry: PlaybackHistoryEntry) -> String { "h_" + AgentToolKit.digest(entry.id).prefix(12) }

    static func historyEntry(_ id: String, _ store: Store) -> PlaybackHistoryEntry? {
        store.visibleHistory.first { historyID($0) == id }
    }

    private static func historyList(_ args: AgentArguments, _ store: Store) throws -> JSONValue {
        let limit = try args.int("limit", in: 1...30, default: 20)
        let query = try args.string("query")
        let entries = store.visibleHistory.filter { entry in
            query.map { entry.context.videoName.localizedCaseInsensitiveContains($0) } ?? true
        }
        let config = store.subscription
        let items: [JSONValue] = entries.map { entry in
            var videoID: String?
            if let config, let site = config.sites.first(where: { $0.origin(or: config.origin) == entry.context.origin && $0.sourceKey == entry.context.sourceKey }) {
                videoID = AgentLookup.videoID(site, origin: config.origin, video: entry.context.videoID)
            }
            return .obj([
                "history_id": .str(historyID(entry)), "title": .str(entry.context.videoName),
                "episode": .text(entry.context.episodeName), "source": .text(entry.context.sourceName),
                "progress": entry.duration > 0 ? .str("\(Int((entry.progress * 100).rounded()))%") : nil,
                "completed": entry.completed ? .bool(true) : nil,
                "watched": .str(AgentLookup.isoDate(entry.updatedAt)),
                "video_id": videoID.map { .str($0) },
            ])
        }
        return .capped("history", items, limit: limit)
    }

    // MARK: Favorites

    static func favoriteID(_ item: FavoriteItem) -> String { "f_" + AgentToolKit.digest(item.key).prefix(12) }

    static func favorite(_ id: String, _ store: Store) -> FavoriteItem? { store.favorites.items.first { favoriteID($0) == id } }

    static func title(_ item: FavoriteItem) -> String {
        switch item {
        case .live(let channel): channel.name
        case .video(let video): video.videoName
        case .episode(let episode): episode.video.videoName + " · " + episode.episodeName
        case .music(let track): track.title
        case .cloud(let file): file.fileName
        }
    }

    private static func favoritesList(_ args: AgentArguments, _ context: AgentToolContext) throws -> JSONValue {
        let store = context.store
        let kind = try args.choice("kind", ["video", "episode", "live", "music", "cloud"])
        let query = try args.string("query")
        let config = store.subscription
        let items: [JSONValue] = store.favorites.items.reversed().compactMap { item in
            let name = title(item)
            if let query, !name.localizedCaseInsensitiveContains(query) { return nil }
            var fields: [String: JSONValue?] = ["favorite_id": .str(favoriteID(item)), "title": .str(name)]
            let saved: FavoriteVideo? = switch item {
            case .video(let video): video
            case .episode(let episode): episode.video
            default: nil
            }
            switch item {
            case .video, .episode:
                guard let video = saved else { return nil }
                fields["kind"] = .str(item.kind == .video ? "video" : "episode")
                fields["source"] = .str(video.sourceName)
                if let config, let site = config.sites.first(where: { $0.origin(or: config.origin) == video.origin && $0.sourceKey == video.sourceKey }) {
                    let id = AgentLookup.videoID(site, origin: config.origin, video: video.videoID)
                    context.videoTitles[id] = video.videoName
                    fields["video_id"] = .str(id)
                }
            case .live(let channel):
                fields["kind"] = .str("live"); fields["group"] = .text(channel.group)
            case .music(let track):
                guard context.isAvailable(.music) else { return nil }
                fields["kind"] = .str("music"); fields["artists"] = .text(track.artists.joined(separator: ", "))
                context.tracks[track.id] = track
            case .cloud:
                fields["kind"] = .str("cloud")
            }
            if let kind, fields["kind"] != .str(kind) { return nil }
            return .obj(fields)
        }
        return .capped("favorites", items, limit: 30)
    }

    private static func addFavorite(_ args: AgentArguments, _ context: AgentToolContext) async throws -> JSONValue {
        let store = context.store
        let id = try args.requiredString("video_id")
        let (site, client, videoID) = try AgentLookup.video(id, store: store)
        // The poster and year come from the details, as the page's heart button saves them.
        let video = try await AgentToolKit.withTimeout(30, "The source") { try await client.detail(videoID, cached: true) }
        context.videoTitles[id] = video.name
        let item = FavoriteItem.video(FavoriteVideo(origin: client.origin, site: site, video: video))
        if store.favorites.contains(item) { return .obj(["title": .str(video.name), "already_favorite": .bool(true)]) }
        store.favorites.toggle(item)
        return .obj(["added": .str(video.name), "favorite_id": .str(favoriteID(item))])
    }

    static func playFavorite(_ id: String, _ context: AgentToolContext) async throws -> JSONValue {
        let store = context.store
        guard let item = favorite(id, store) else { throw AgentToolError("No favorite has the id `\(id)`. Call favorites_list.") }
        switch item {
        case .episode(let episode):
            guard store.catalogClient(for: episode.video) != nil else { throw AgentToolError("This favorite's source is no longer in the subscriptions that are on.") }
            store.play(episode)
            return try await VideoTools.started(store, title: title(item))
        case .cloud(let file):
            store.play(file)
            return try await VideoTools.started(store, title: file.fileName)
        case .live(let channel):
            store.playing = channel
            return .obj(["playing": .str(channel.name)])
        case .music(let track):
            try context.require(.music)
            store.music.play(track)
            return .obj(["playing": .str(track.title)])
        case .video(let video):
            guard let client = store.catalogClient(for: video) else { throw AgentToolError("This favorite's source is no longer in the subscriptions that are on.") }
            let videoID = AgentLookup.videoID(client.site, origin: client.origin, video: video.videoID)
            context.videoTitles[videoID] = video.videoName
            throw AgentToolError("This favorite is a whole video: call play with video_id `\(videoID)` (and an episode if wanted).")
        }
    }

    // MARK: Downloads

    private static func downloads(_ args: AgentArguments) throws -> [DownloadItem] {
        let ids = try args.strings("download_ids") ?? []
        guard !ids.isEmpty else { throw AgentToolError("Give at least one id in `download_ids`.") }
        return try ids.map { id in
            guard let item = DownloadLibrary.shared.item(id: id) else { throw AgentToolError("No download has the id `\(id)`.") }
            return item
        }
    }

    private static func downloadsList(_ args: AgentArguments) throws -> JSONValue {
        let wanted = try args.choice("status", ["active", "paused", "completed", "failed"])
        let items: [JSONValue] = DownloadLibrary.shared.items.reversed().compactMap { item in
            let status: String = switch item.status {
            case .queued, .downloading, .finishing: "active"
            case .paused: "paused"
            case .completed: "completed"
            case .failed: "failed"
            }
            if let wanted, wanted != status { return nil }
            return .obj([
                "download_id": .str(item.id), "title": .str(item.title), "episode": .text(item.episode),
                "status": .str(item.status.rawValue),
                "progress": item.status == .completed ? nil : .str("\(Int((item.fraction * 100).rounded()))%"),
                "size_mb": item.size > 0 ? .num(Int(item.size / 1_000_000)) : nil,
                "failure": .text(item.failure.map { AgentToolKit.clip($0, 160) }),
            ])
        }
        return .capped("downloads", items, limit: 30)
    }

    private static func startDownloads(_ args: AgentArguments, _ context: AgentToolContext) async throws -> JSONValue {
        let store = context.store
        let id = try args.requiredString("video_id")
        let (site, client, videoID) = try AgentLookup.video(id, store: store)
        let video = try await AgentToolKit.withTimeout(30, "The source") { try await client.detail(videoID) }
        context.videoTitles[id] = video.name
        let line = try AgentLookup.line(args.values["line"]?.string, in: video)
        var episodes: [Episode] = []
        if let values = args.values["episodes"]?.array {
            guard values.count <= 50 else { throw AgentToolError("At most 50 episodes at a time.") }
            episodes = try values.compactMap { try AgentLookup.episode($0, in: line.episodes) }
        }
        if episodes.isEmpty, let first = line.episodes.first { episodes = [first] }
        guard !episodes.isEmpty else { throw AgentToolError("This line has no episodes.") }
        let items = episodes.map { episode in
            DownloadLibrary.shared.download(DownloadSource(site: site, videoID: video.id, episode: episode), title: video.name,
                                            poster: video.poster, posterHeaders: video.posterHeaders)
        }
        return .obj(["started": .list(items.map { .obj(["download_id": .str($0.id), "episode": .text($0.episode), "status": .str($0.status.rawValue)]) })])
    }
}

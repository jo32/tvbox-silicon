import AVFoundation
import SwiftUI
import TVCore

/// Videos: Global Search, a video's lines and episodes, playing one, and the player.
@MainActor enum VideoTools {
    static func make(_ context: AgentToolContext) -> [AppTool] {
        let store = context.store
        return [
            AppTool("search_videos", .read, """
                Searches the viewer's video sources for a title, as Global Search does, and waits for the sources to \
                answer (up to wait_seconds). Results are grouped by title; each source's copy has its own video_id \
                for video_details, play, open_page and favorites_add. If sources are still searching, call again \
                with the same query to collect more.
                """, Schema.object([
                    "query": Schema.string("The title or words to search for."),
                    "source_id": Schema.string("Search only this source (an id from sources_list)."),
                    "wait_seconds": Schema.integer("How long to wait for sources (default 12).", minimum: 2, maximum: 30),
                    "show": Schema.boolean("Also show the search on the Global Search page (default false)."),
                ], required: ["query"])) { args in try await search(args, context) },

            AppTool("video_details", .read, """
                A video's details from its source: synopsis, year, the lines (playback routes, each with its own \
                episode list) and the episodes, and where the viewer stopped watching it.
                """, Schema.object([
                    "video_id": Schema.string("A video id from search_videos, history_list or favorites_list."),
                    "line": Schema.numberOrText("Show all episodes of this line (name or 1-based number); otherwise each line's are abbreviated."),
                ], required: ["video_id"])) { args in try await details(args, context) },

            AppTool("play", .read, """
                Starts playing in the app's player: an episode of a video (video_id, optionally line and episode; \
                without episode it resumes where the viewer stopped, or starts the first), a history entry \
                (history_id: resumes it), a favorite (favorite_id) or a finished download (download_id). Give one \
                of video_id, history_id, favorite_id or download_id.
                """, Schema.object([
                    "video_id": Schema.string("A video id."),
                    "line": Schema.numberOrText("The line's name or 1-based number (default: the first)."),
                    "episode": Schema.numberOrText("The episode's 1-based number in the line, or its name."),
                    "history_id": Schema.string("An id from history_list."),
                    "favorite_id": Schema.string("An id from favorites_list."),
                    "download_id": Schema.string("A finished download's id from downloads_list."),
                ]), summary: { args in playSummary(args, context) }) { args in try await play(args, context) },

            AppTool("player_control", .read, """
                Controls the video player: status (what plays, position, speed, tracks), pause, resume, seek to a \
                time, skip by seconds (negative goes back), next_episode, previous_episode, or stop (close the player).
                """, Schema.object([
                    "action": Schema.string("What to do.", enum: ["status", "pause", "resume", "seek", "skip", "next_episode", "previous_episode", "stop"]),
                    "seconds": Schema.value("For seek: the time to go to (seconds, or 1:02:03). For skip: seconds to move, negative to go back."),
                ], required: ["action"])) { args in try await control(args, context) },

            AppTool("player_set", .change, """
                Changes the playing video's speed, subtitle track or audio track. player_control status lists the \
                tracks. Speed only applies to this video; the start speed for new videos is the setting start_speed.
                """, Schema.object([
                    "speed": Schema.number("Playback speed, 0.25 to 4."),
                    "subtitle": Schema.string("A subtitle track's name, or \"off\"."),
                    "audio": Schema.string("An audio track's name."),
                ]), summary: { args in playerSetSummary(args) }) { args in try setPlayer(args, context) },
        ]
    }

    // MARK: Search

    private static func search(_ args: AgentArguments, _ context: AgentToolContext) async throws -> JSONValue {
        let store = context.store
        let query = try args.requiredString("query")
        let wait = try args.int("wait_seconds", in: 2...30, default: 12)
        let config = try AgentLookup.subscription(store)
        if let sourceID = try args.string("source_id") {
            let (site, config) = try AgentLookup.site(sourceID: sourceID, store: store)
            let client = CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL).applying(config)
            let page = try await AgentToolKit.withTimeout(Double(wait), "The source") { try await client.list(category: nil, query: query, page: 1) }
            let results = page.videos.filter { !$0.isFolder }.map { video -> JSONValue in
                let id = AgentLookup.videoID(site, origin: config.origin, video: video.id)
                context.videoTitles[id] = video.name
                return .obj(["video_id": .str(id), "title": .str(video.name), "year": .text(video.year), "remarks": .text(AgentToolKit.clip(video.remarks, 40))])
            }
            return .capped("results", results, limit: 30, extra: ["query": .str(query), "source": .str(site.name)])
        }
        let model = context.search
        let same = model.keyword == query && (model.busy || !model.results.isEmpty)
        if !same {
            model.search(query, config: config) { [hiddenSources = store.hiddenSources] site in
                hiddenSources.contains(site, origin: config.origin)
            }
        }
        if try args.bool("show") == true { store.searchVideos(query) }
        let deadline = Date().addingTimeInterval(Double(wait))
        // Waits for every source, or for enough of them with results, or the deadline.
        while model.busy, Date() < deadline {
            if model.matches.count >= 12, model.completed * 3 >= model.total * 2 { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        // Group copies of the same title from different sources.
        var order: [String] = []
        var groups: [String: (title: String, year: String?, copies: [JSONValue])] = [:]
        for match in model.matches {
            for video in model.videos(for: match.id) where !video.isFolder {
                let key = video.name.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
                let id = AgentLookup.videoID(match.site, origin: config.origin, video: video.id)
                context.videoTitles[id] = video.name
                if groups[key] == nil { order.append(key); groups[key] = (video.name, video.year, []) }
                groups[key]?.copies.append(.obj(["video_id": .str(id), "source": .str(match.site.name),
                                                  "remarks": .text(AgentToolKit.clip(video.remarks, 40))]))
            }
        }
        // Titles that match the query best first, then by how many sources have them.
        let needle = query.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
        let ranked = order.enumerated().sorted { a, b in
            let ea = a.element == needle, eb = b.element == needle
            if ea != eb { return ea }
            let ca = groups[a.element]?.copies.count ?? 0, cb = groups[b.element]?.copies.count ?? 0
            return ca != cb ? ca > cb : a.offset < b.offset
        }.map(\.element)
        let items: [JSONValue] = ranked.compactMap { key in
            guard let group = groups[key] else { return nil }
            let (copies, more) = AgentToolKit.capped(group.copies, limit: 5)
            return .obj(["title": .str(group.title), "year": .text(group.year), "copies": .list(copies),
                         "more_copies": more > 0 ? .num(more) : nil])
        }
        return .capped("titles", items, limit: 15, extra: [
            "query": .str(query),
            "sources_answered": .num(model.completed), "sources_total": .num(model.total),
            "still_searching": model.busy ? .bool(true) : nil,
            "failed_sources": model.failures.isEmpty ? nil : .num(model.failures.count),
        ])
    }

    // MARK: Details

    private static func details(_ args: AgentArguments, _ context: AgentToolContext) async throws -> JSONValue {
        let store = context.store
        let id = try args.requiredString("video_id")
        let (site, client, videoID) = try AgentLookup.video(id, store: store)
        let video = try await AgentToolKit.withTimeout(30, "The source") { try await client.detail(videoID) }
        context.videoTitles[id] = video.name
        let lines = AgentLookup.lines(video)
        let full = try args.has("line") ? AgentLookup.line(args.values["line"]?.string, in: video).name : nil
        let lineItems: [JSONValue] = lines.enumerated().map { index, line in
            let names = line.episodes.map(\.name)
            let shown: [String]
            if line.name == full || names.count <= 12 { shown = Array(names.prefix(200)) }
            else { shown = Array(names.prefix(6)) + ["…"] + Array(names.suffix(3)) }
            return .obj(["line": .num(index + 1), "name": .str(line.name), "episode_count": .num(names.count),
                         "episodes": .list(shown.map { .str($0) })])
        }
        let watched = store.playbackHistory.entries.first { entry in
            entry.context.sourceKey == site.sourceKey && entry.context.videoID == videoID
        }
        return .obj([
            "video_id": .str(id), "title": .str(video.name), "source": .str(site.name), "year": .text(video.year),
            "category": .text(video.category), "remarks": .text(video.remarks),
            "synopsis": .text(AgentToolKit.clip(video.synopsis, 500)),
            "lines": .list(lineItems),
            "watched": watched.map { entry in
                .obj(["episode": .text(entry.context.episodeName), "line": .text(entry.context.episodeFlag),
                      "position": .num(entry.position), "duration": entry.duration > 0 ? .num(entry.duration) : nil,
                      "completed": .bool(entry.completed)])
            },
            "is_favorite": .bool(store.favorites.contains(.video(FavoriteVideo(origin: site.origin(or: client.origin), site: site, video: video)))),
        ])
    }

    // MARK: Play

    private static func playSummary(_ args: AgentArguments, _ context: AgentToolContext) -> (summary: String, detail: String?) {
        if let id = try? args.string("video_id"), let title = context.videoTitles[id] {
            let episode = args.values["episode"]?.string
            return (L10n.text("Play “%@”?", title), episode.map { L10n.text("Episode: %@", $0) })
        }
        if let id = try? args.string("history_id"), let entry = LibraryTools.historyEntry(id, context.store) {
            return (L10n.text("Play “%@”?", entry.context.videoName), entry.context.episodeName.isEmpty ? nil : entry.context.episodeName)
        }
        return (L10n.text("Play a video?"), nil)
    }

    private static func play(_ args: AgentArguments, _ context: AgentToolContext) async throws -> JSONValue {
        let store = context.store
        let given = ["video_id", "history_id", "favorite_id", "download_id"].filter(args.has)
        guard given.count == 1 else { throw AgentToolError("Give exactly one of video_id, history_id, favorite_id or download_id.") }
        if let id = try args.string("history_id") {
            guard let entry = LibraryTools.historyEntry(id, store) else { throw AgentToolError("No history entry has the id `\(id)`. Call history_list.") }
            guard entry.context.sourceKey == CloudFiles.sourceKey || store.historyClient(entry) != nil else {
                throw AgentToolError("This title's source is no longer in the subscriptions that are on.")
            }
            store.resume(entry)
            return try await started(store, title: entry.context.videoName)
        }
        if let id = try args.string("favorite_id") {
            return try await LibraryTools.playFavorite(id, context)
        }
        if let id = try args.string("download_id") {
            guard let item = DownloadLibrary.shared.item(id: id) else { throw AgentToolError("No download has the id `\(id)`. Call downloads_list.") }
            guard item.status == .completed else { throw AgentToolError("That download hasn't finished yet.") }
            store.playing = store.savedChannel(item)
            return .obj(["playing": .str(item.title)])
        }
        let id = try args.requiredString("video_id")
        let (site, client, videoID) = try AgentLookup.video(id, store: store)
        let video = try await AgentToolKit.withTimeout(30, "The source") { try await client.detail(videoID) }
        context.videoTitles[id] = video.name
        let watched = store.playbackHistory.entries.first { $0.context.sourceKey == site.sourceKey && $0.context.videoID == videoID }
        let line: (name: String, episodes: [Episode])
        if args.has("line") { line = try AgentLookup.line(args.values["line"]?.string, in: video) }
        else if let flag = watched?.context.episodeFlag, let match = AgentLookup.lines(video).first(where: { $0.name == flag }) { line = match }
        else { line = try AgentLookup.line(nil, in: video) }
        guard !line.episodes.isEmpty else { throw AgentToolError("This line has no episodes.") }
        var episode = try AgentLookup.episode(args.values["episode"], in: line.episodes)
        var resume: Double?
        if episode == nil, let watched {
            // Without an episode: where the viewer stopped, as Continue Watching does.
            episode = line.episodes.first { $0.id == watched.context.episodeID } ?? line.episodes.first { $0.name == watched.context.episodeName }
            if episode != nil, !watched.completed { resume = watched.position }
        } else if let episode, let watched, watched.context.episodeID == episode.id, !watched.completed {
            resume = watched.position
        }
        let chosen = episode ?? line.episodes[0]
        if let saved = DownloadLibrary.shared.item(for: DownloadSource(site: site, videoID: video.id, episode: chosen)), saved.status == .completed {
            store.playing = store.savedChannel(saved)
            return .obj(["playing": .str(video.name), "episode": .str(chosen.name), "from": .str("download")])
        }
        let playback = store.subscription.map { client.applying($0) } ?? client
        let channel = try await AgentToolKit.withTimeout(45, "Getting the video's address") {
            let plan = try await client.preparePlayback(chosen)
            guard !plan.choices.isEmpty else { throw AgentToolError("The source gave no address for this episode.") }
            let remembered = await RememberedQuality.remembered(for: client.site.key)
            let choice = plan.choices.first { $0.name == remembered } ?? plan.choices[0]
            return try await playback.resolvePlayback(plan, choice: choice)
        }
        store.playing = store.catalogChannel(channel, video: video, episode: chosen, client: playback, resumePosition: resume)
        return .obj(["playing": .str(video.name), "line": .str(line.name), "episode": .str(chosen.name),
                     "resumes_at": resume.map { .num($0) }])
    }

    /// Waits briefly for a resumed title to reach the player, and says what happened.
    static func started(_ store: Store, title: String) async throws -> JSONValue {
        for _ in 0..<60 {
            if store.playing != nil { return .obj(["playing": .str(title)]) }
            if let error = store.error { store.error = nil; throw AgentToolError(error) }
            try await Task.sleep(for: .milliseconds(250))
        }
        return .obj(["starting": .str(title), "note": .str("Still loading; check with player_control status.")])
    }

    // MARK: Player

    private static func session(_ store: Store) throws -> (Channel, PlaybackSession?) {
        guard let channel = store.playing else { throw AgentToolError("Nothing is playing in the video player.") }
        return (channel, PlaybackSession.current)
    }

    private static func control(_ args: AgentArguments, _ context: AgentToolContext) async throws -> JSONValue {
        let store = context.store
        let action = try args.choice("action", ["status", "pause", "resume", "seek", "skip", "next_episode", "previous_episode", "stop"]) ?? "status"
        let (channel, session) = try session(store)
        switch action {
        case "pause":
            if let session, !session.paused { session.togglePlayback() }
        case "resume":
            if let session, session.paused { session.togglePlayback() }
        case "seek", "skip":
            guard let session, session.hasTimeline else { throw AgentToolError("This video can't seek (a live stream).") }
            guard let seconds = try args.seconds("seconds") else { throw AgentToolError("Give `seconds`.") }
            if action == "seek" {
                let target = session.duration > 0 ? min(max(0, seconds), session.duration - 1) : max(0, seconds)
                session.jump(to: target)
            } else {
                session.skip(seconds)
            }
        case "next_episode", "previous_episode":
            let next = action == "next_episode"
            if let episode = next ? store.nextEpisode(after: channel) : store.previousEpisode(before: channel) {
                store.selectEpisode(episode, from: channel)
                return .obj(["switching_to": .str(episode.name)])
            }
            if let file = next ? store.nextFile(after: channel) : store.previousFile(before: channel) {
                store.playing = file
                return .obj(["switching_to": .str(file.name)])
            }
            throw AgentToolError(next ? "This is the last episode." : "This is the first episode.")
        case "stop":
            store.playing = nil
            return .obj(["stopped": .bool(true)])
        default: break
        }
        if action != "status" { try? await Task.sleep(for: .milliseconds(300)) }
        return status(channel, session, store)
    }

    private static func status(_ channel: Channel, _ session: PlaybackSession?, _ store: Store) -> JSONValue {
        let history = channel.historyContext
        var fields: [String: JSONValue?] = [
            "title": .str(history?.videoName ?? channel.name), "episode": .text(history?.episodeName),
            "line": .text(history?.episodeFlag), "source": .text(history?.sourceName),
        ]
        if let session {
            fields["paused"] = .bool(session.paused)
            fields["live"] = .bool(session.isLive)
            fields["position"] = .num(session.position)
            fields["duration"] = session.duration > 0 ? .num(session.duration) : nil
            fields["speed"] = .num(Double(session.player.defaultRate))
            let tracks = session.mediaTracks
            if let legible = tracks.legible, !legible.options.isEmpty {
                fields["subtitles"] = .list(legible.options.map { .str(legible.name($0)) })
                fields["subtitle"] = tracks.selected(in: legible).map { .str(legible.name($0)) } ?? .str("off")
            }
            if let audio = tracks.audio, audio.options.count > 1 {
                fields["audio_tracks"] = .list(audio.options.map { .str(audio.name($0)) })
                fields["audio"] = tracks.selected(in: audio).map { .str(audio.name($0)) }
            } else if session.audioChoices.count > 1 {
                fields["audio_tracks"] = .list(session.audioChoices.map { .str($0.name) })
            }
        }
        fields["has_next_episode"] = .bool(store.nextEpisode(after: channel) != nil || store.nextFile(after: channel) != nil)
        return .obj(fields)
    }

    private static func playerSetSummary(_ args: AgentArguments) -> (summary: String, detail: String?) {
        if let speed = try? args.double("speed") { return (L10n.text("Play at %@?", PlaybackSpeed.speedLabel(Float(speed))), nil) }
        if let name = try? args.string("subtitle") { return (L10n.text("Switch subtitles to “%@”?", name), nil) }
        if let name = try? args.string("audio") { return (L10n.text("Switch audio to “%@”?", name), nil) }
        return (L10n.text("Change the player?"), nil)
    }

    private static func setPlayer(_ args: AgentArguments, _ context: AgentToolContext) throws -> JSONValue {
        let (channel, session) = try session(context.store)
        guard let session else { throw AgentToolError("The player is still loading.") }
        guard ["speed", "subtitle", "audio"].contains(where: args.has) else { throw AgentToolError("Give speed, subtitle or audio.") }
        if let speed = try args.double("speed") {
            guard (0.25...4).contains(speed) else { throw AgentToolError("`speed` must be between 0.25 and 4.") }
            guard !session.isLive else { throw AgentToolError("A live stream plays at normal speed only.") }
            session.setSpeed(Float(speed))
        }
        let tracks = session.mediaTracks
        if let name = try args.string("subtitle") {
            guard let legible = tracks.legible, !legible.options.isEmpty else { throw AgentToolError("This video has no subtitle tracks of its own.") }
            if ["off", "none"].contains(name.lowercased()) {
                session.chooseSubtitle(nil, in: legible.group)
            } else {
                guard let option = legible.options.first(where: { legible.name($0) == name })
                        ?? legible.options.first(where: { legible.name($0).localizedCaseInsensitiveContains(name) }) else {
                    throw AgentToolError("No subtitle track is called “\(name)”. Tracks: \(legible.options.map(legible.name).joined(separator: ", ")).")
                }
                session.chooseSubtitle(option, in: legible.group)
            }
        }
        if let name = try args.string("audio") {
            if let audio = tracks.audio, audio.options.count > 1 {
                guard let option = audio.options.first(where: { audio.name($0) == name })
                        ?? audio.options.first(where: { audio.name($0).localizedCaseInsensitiveContains(name) }) else {
                    throw AgentToolError("No audio track is called “\(name)”. Tracks: \(audio.options.map(audio.name).joined(separator: ", ")).")
                }
                session.chooseAudioTrack(option, in: audio.group)
            } else if let choice = session.audioChoices.first(where: { $0.name == name })
                        ?? session.audioChoices.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
                session.chooseAudio(choice.id)
            } else {
                throw AgentToolError("This video has no other audio track called “\(name)”.")
            }
        }
        return status(channel, session, context.store)
    }
}

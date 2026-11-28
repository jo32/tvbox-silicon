import SwiftUI
import TVCore

/// Live TV, music, novels and manga. A section the app hides (the App Store build's Music before a subscription,
/// Manga and Novels without source lists) has no tools: they are left out of the list and refuse if called.
@MainActor enum MediaTools {
    static func make(_ context: AgentToolContext) -> [AppTool] {
        var tools: [AppTool] = []
        if context.isAvailable(.live) { tools += live(context) }
        if context.isAvailable(.music) { tools += music(context) }
        if context.isAvailable(.novels) { tools += novels(context) }
        if context.isAvailable(.manga) { tools += manga(context) }
        return tools
    }

    // MARK: Live TV

    static func liveID(_ source: LiveSource) -> String { "l_" + AgentToolKit.digest(source.id).prefix(10) }

    private static func live(_ context: AgentToolContext) -> [AppTool] {
        let store = context.store
        func source(_ id: String) throws -> LiveSource {
            try context.require(.live)
            guard let source = store.liveSources.first(where: { liveID($0) == id }) else {
                throw AgentToolError("No live playlist has the id `\(id)`. Call live_list without a playlist.")
            }
            return source
        }
        func channels(_ source: LiveSource) async throws -> [Channel] {
            let key = liveID(source)
            if let cached = context.playlists[key], Date().timeIntervalSince(cached.at) < 600 { return cached.channels }
            let playlist = try await AgentToolKit.withTimeout(30, "The playlist") { try await HTTPClient().playlist(source) }
            context.playlists[key] = (playlist.channels, playlist.guide, Date())
            return playlist.channels
        }
        return [
            AppTool("live_list", .read, """
                Without playlist_id: the viewer's live TV playlists. With one: its channels (name, group), \
                optionally only those matching query or in group, with a channel number for live_play.
                """, Schema.object([
                    "playlist_id": Schema.string("A playlist id from live_list."),
                    "query": Schema.string("Only channels whose name contains this text."),
                    "group": Schema.string("Only channels in this group."),
                ])) { args in
                    try context.require(.live)
                    guard let id = try args.string("playlist_id") else {
                        let items = store.liveSources.map { JSONValue.obj(["playlist_id": .str(liveID($0)), "name": .str($0.name)]) }
                        return .capped("playlists", items, limit: 30)
                    }
                    let all = try await channels(try source(id))
                    let query = try args.string("query"), group = try args.string("group")
                    let matching = all.enumerated().filter { _, channel in
                        (query.map { channel.name.localizedCaseInsensitiveContains($0) } ?? true) && (group.map { channel.group == $0 } ?? true)
                    }
                    var groups: [String] = []
                    for channel in all where !groups.contains(channel.group) { groups.append(channel.group) }
                    return .capped("channels", matching.map { index, channel in
                        .obj(["channel": .num(index + 1), "name": .str(channel.name), "group": .text(channel.group)])
                    }, limit: 30, extra: ["total": .num(all.count), "groups": .list(groups.prefix(30).map { .str($0) })])
                },

            AppTool("live_play", .read, """
                Plays a live channel of a playlist, by its number from live_list or its name.
                """, Schema.object([
                    "playlist_id": Schema.string("A playlist id from live_list."),
                    "channel": Schema.numberOrText("The channel's number from live_list, or its name."),
                ], required: ["playlist_id", "channel"])) { args in
                    let source = try source(try args.requiredString("playlist_id"))
                    let all = try await channels(source)
                    let value = args.values["channel"] ?? .null
                    let channel: Channel?
                    if case .number(let number) = value { channel = all.indices.contains(Int(number) - 1) ? all[Int(number) - 1] : nil }
                    else if let name = value.string {
                        channel = all.first { $0.name == name } ?? Int(name).flatMap { all.indices.contains($0 - 1) ? all[$0 - 1] : nil }
                            ?? all.first { $0.name.localizedCaseInsensitiveContains(name) }
                    } else { channel = nil }
                    guard let channel else { throw AgentToolError("No such channel in this playlist.") }
                    let address = LiveGuide.address(for: source, playlist: context.playlists[liveID(source)]?.guide, in: store)
                    let guide = address.map { LiveGuide(address: $0, context: GuideRequestContext(sourceID: source.id, origin: source.url, headers: source.headers)) }
                    if let guide, case .xmltv = guide.address { Task { await guide.load(all) } }
                    store.watch(channel, in: LiveLineup(title: source.name, channels: all), guide: guide)
                    return .obj(["playing": .str(channel.name), "playlist": .str(source.name)])
                },
        ]
    }

    // MARK: Music

    private static func music(_ context: AgentToolContext) -> [AppTool] {
        let store = context.store
        return [
            AppTool("music_search", .read, """
                Searches songs by title or artist, as Music's search does, and returns tracks with a track_id for music_play.
                """, Schema.object([
                    "query": Schema.string("Song, artist or album."),
                ], required: ["query"])) { args in
                    try context.require(.music)
                    let query = try args.requiredString("query")
                    let model = context.musicSearch
                    model.search(query, kind: .songs, immediately: true)
                    try await Task.sleep(for: .milliseconds(300))
                    let deadline = Date().addingTimeInterval(20)
                    while model.busy, Date() < deadline { try await Task.sleep(for: .milliseconds(250)) }
                    for track in model.results { context.tracks[track.id] = track }
                    let items = model.results.map { track in
                        JSONValue.obj(["track_id": .str(track.id), "title": .str(track.title), "artists": .text(track.artists.joined(separator: ", ")),
                                       "album": .text(track.album), "seconds": track.duration.map { .num(Int($0)) }])
                    }
                    return .capped("tracks", items, limit: 20, extra: ["query": .str(query), "still_searching": model.busy ? .bool(true) : nil])
                },

            AppTool("music_play", .read, """
                Plays songs from music_search (or music favorites) in the music player; several make a queue in order.
                """, Schema.object([
                    "track_ids": Schema.strings("Track ids, played in this order."),
                ], required: ["track_ids"])) { args in
                    try context.require(.music)
                    let ids = try args.strings("track_ids") ?? []
                    let tracks = try ids.prefix(100).map { id in
                        guard let track = context.tracks[id] ?? store.favorites.items.lazy.compactMap({ item -> MusicTrack? in
                            if case .music(let track) = item, track.id == id { return track } else { return nil }
                        }).first else { throw AgentToolError("Unknown track `\(id)`; search first with music_search.") }
                        return track
                    }
                    guard let first = tracks.first else { throw AgentToolError("Give at least one track id.") }
                    if tracks.count == 1 { store.music.play(first) } else { store.music.play(MusicQueue(tracks: tracks)) }
                    return .obj(["playing": .str(first.title), "queued": .num(tracks.count)])
                },
        ]
    }

    // MARK: Novels

    private static func novelID(_ book: NovelBook) -> String { AgentToolKit.encodeID("n", [book.sourceKey, book.url]) }

    private static func novels(_ context: AgentToolContext) -> [AppTool] {
        let store = context.store
        return [
            AppTool("novels_search", .read, """
                Searches the viewer's novel (book) sources for a title or author; books found on several sources are \
                merged. Returns a book_id for novels_open.
                """, Schema.object([
                    "query": Schema.string("Title or author."),
                    "wait_seconds": Schema.integer("How long to wait for sources (default 15).", minimum: 3, maximum: 30),
                ], required: ["query"])) { args in
                    try context.require(.novels)
                    let query = try args.requiredString("query")
                    let wait = try args.int("wait_seconds", in: 3...30, default: 15)
                    let sources = NovelStore.shared.searchScope
                    guard !sources.isEmpty else { throw AgentToolError("No book sources can search.") }
                    var hits: [NovelSearchHit] = [], answered = 0
                    let deadline = Date().addingTimeInterval(Double(wait))
                    let stream = NovelBooks.search(query, in: sources)
                    let collect = Task { @MainActor in
                        for await answer in stream {
                            answered += 1
                            if case .success(let books) = answer.result { NovelBooks.merge(books, into: &hits, keyword: query) }
                            if Date() >= deadline { break }
                        }
                    }
                    while Date() < deadline, answered < sources.count { try await Task.sleep(for: .milliseconds(250)) }
                    collect.cancel()
                    for hit in hits { context.books[novelID(hit.book)] = hit }
                    let items = hits.map { hit in
                        JSONValue.obj(["book_id": .str(novelID(hit.book)), "title": .str(hit.book.name), "author": .text(hit.book.author),
                                       "sources": .num(hit.books.count), "intro": .text(AgentToolKit.clip(hit.book.intro, 120))])
                    }
                    return .capped("books", items, limit: 20, extra: ["sources_answered": .num(answered), "sources_total": .num(sources.count)])
                },

            AppTool("novels_open", .read, """
                Opens a book from novels_search on its page in Novels, where the viewer reads it.
                """, Schema.object([
                    "book_id": Schema.string("A book id from novels_search."),
                ], required: ["book_id"])) { args in
                    try context.require(.novels)
                    let id = try args.requiredString("book_id")
                    guard let hit = context.books[id] else { throw AgentToolError("Unknown book `\(id)`; search first with novels_search.") }
                    try await AgentNavigator.push(Route { AnyView(NovelDetailView(book: hit.book, alternatives: hit.books)) }, in: .novels, store: store)
                    return .obj(["opened": .str(hit.book.name)])
                },
        ]
    }

    // MARK: Manga

    private static func mangaID(_ comic: MangaComic) -> String { AgentToolKit.encodeID("m", [comic.sourceKey, comic.id]) }

    private static func manga(_ context: AgentToolContext) -> [AppTool] {
        let store = context.store
        return [
            AppTool("manga_search", .read, """
                Searches the viewer's comic (manga) sources for a title. Returns a comic_id for manga_open.
                """, Schema.object([
                    "query": Schema.string("The title."),
                ], required: ["query"])) { args in
                    try context.require(.manga)
                    let query = try args.requiredString("query")
                    let sources = MangaStore.shared.sources
                    guard !sources.isEmpty else { throw AgentToolError("No comic sources are installed.") }
                    var found: [JSONValue] = [], failures = 0
                    // Every source at once, each with its own time limit.
                    let searches = sources.prefix(12).map { source in
                        Task { () -> (String, [MangaComic]?) in
                            do {
                                let comics = try await AgentToolKit.withTimeout(20, "The source") {
                                    let info = try await MangaRuntime.shared.info(source.key)
                                    guard info.canSearch else { return [MangaComic]() }
                                    return try await MangaRuntime.shared.search(source.key, keyword: query,
                                                                                options: MangaOptionRows.defaults(info.searchOptions).map(Optional.some), cursor: nil).comics
                                }
                                return (source.name, comics)
                            } catch { return (source.name, nil) }
                        }
                    }
                    for search in searches {
                        let (name, comics) = await search.value
                        guard let comics else { failures += 1; continue }
                        for comic in comics.prefix(5) {
                            context.comics[mangaID(comic)] = comic
                            found.append(.obj(["comic_id": .str(mangaID(comic)), "title": .str(comic.title), "source": .str(name),
                                               "subtitle": .text(AgentToolKit.clip(comic.subtitle, 60))]))
                        }
                    }
                    return .capped("comics", found, limit: 30, extra: ["failed_sources": failures > 0 ? .num(failures) : nil])
                },

            AppTool("manga_open", .read, """
                Opens a comic from manga_search on its page in Manga, where the viewer reads it.
                """, Schema.object([
                    "comic_id": Schema.string("A comic id from manga_search."),
                ], required: ["comic_id"])) { args in
                    try context.require(.manga)
                    let id = try args.requiredString("comic_id")
                    guard let comic = context.comics[id] else { throw AgentToolError("Unknown comic `\(id)`; search first with manga_search.") }
                    try await AgentNavigator.push(Route { AnyView(MangaDetailView(comic: comic)) }, in: .manga, store: store)
                    return .obj(["opened": .str(comic.title)])
                },
        ]
    }
}

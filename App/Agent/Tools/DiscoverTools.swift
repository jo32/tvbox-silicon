import SwiftUI
import TVCore

/// Discover's TMDB catalogue: films and shows to recommend, found as Discover finds them, and their Discover pages.
/// The viewer sees each title as a card that opens its page, where they find it in their sources.
@MainActor enum DiscoverTools {
    static func make(_ context: AgentToolContext) -> [AppTool] {
        guard context.isAvailable(.discover) else { return [] }
        return [
            AppTool("discover_search", .read, """
                Finds films and shows in TMDB, as Discover does: by title or words (query); without a query, what is \
                trending (feed), or with genres, original_language, years or sort, the titles that match. Use it \
                whenever you recommend or name titles, so the viewer gets their covers to tap (each opens the title's \
                Discover page). Returns a title_id for discover_open; search_videos finds a title in the viewer's sources.
                """, Schema.object([
                    "query": Schema.string("A title, or words from one."),
                    "kind": Schema.string("Only films or only shows (default: both).", enum: ["movie", "tv"]),
                    "feed": Schema.string("Without a query or filters: trending today, this week, or popular (default week).", enum: ["day", "week", "popular"]),
                    "genres": Schema.strings("Genres a title must all have: " + genres.keys.sorted().joined(separator: ", ") + "."),
                    "original_language": Schema.string("The original language's ISO 639-1 code, e.g. zh, ko, ja, en."),
                    "from_year": Schema.integer("Released in or after this year.", minimum: 1900, maximum: 2100),
                    "to_year": Schema.integer("Released in or before this year.", minimum: 1900, maximum: 2100),
                    "sort": Schema.string("With filters: most popular (default), best rated, or newest.", enum: ["popular", "rating", "newest"]),
                ])) { args in try await search(args, context) },

            AppTool("discover_open", .read, """
                Opens a title from discover_search on its Discover page: overview, cast, seasons, and where to watch \
                it in the viewer's sources.
                """, Schema.object([
                    "title_id": Schema.string("A title_id from discover_search."),
                    "title": Schema.string("Its title, shown until the page has loaded."),
                ], required: ["title_id"])) { args in try await open(args, context) },
        ]
    }

    /// TMDB's genre ids for films and for shows (shows have no horror, romance or thriller of their own).
    private static let genres: [String: (movie: Int?, tv: Int?)] = [
        "action": (28, 10759), "adventure": (12, 10759), "animation": (16, 16), "comedy": (35, 35), "crime": (80, 80),
        "documentary": (99, 99), "drama": (18, 18), "family": (10751, 10751), "fantasy": (14, 10765), "history": (36, nil),
        "horror": (27, nil), "kids": (nil, 10762), "mystery": (9648, 9648), "reality": (nil, 10764), "romance": (10749, nil),
        "science_fiction": (878, 10765), "thriller": (53, nil), "war": (10752, 10768),
    ]

    private static func search(_ args: AgentArguments, _ context: AgentToolContext) async throws -> JSONValue {
        try context.require(.discover)
        let query = (try args.string("query") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let kinds: [TMDBCatalog.SearchKind] = try args.choice("kind", ["movie", "tv"]).flatMap(TMDBCatalog.SearchKind.init) .map { [$0] } ?? [.tv, .movie]
        let feed = try args.choice("feed", ["day", "week", "popular"]).flatMap(TMDBCatalog.SearchFeed.init) ?? .week
        let genreNames = (try args.strings("genres") ?? []).map { $0.lowercased().replacingOccurrences(of: " ", with: "_") }
        if let unknown = genreNames.first(where: { genres[$0] == nil }) {
            throw AgentToolError("Unknown genre `\(unknown)`. Genres: \(genres.keys.sorted().joined(separator: ", ")).")
        }
        let language = try args.string("original_language")?.lowercased()
        let from = try args.int("from_year"), to = try args.int("to_year")
        let sort = try args.choice("sort", ["popular", "rating", "newest"])
        let filtered = query.isEmpty && (!genreNames.isEmpty || language != nil || from != nil || to != nil || sort != nil)
        var requests: [(TMDBCatalog.SearchKind, TMDBCatalog.Filter?)] = []
        for kind in kinds {
            guard filtered else { requests.append((kind, nil)); continue }
            let ids = genreNames.compactMap { kind == .movie ? genres[$0]?.movie : genres[$0]?.tv }
            // A genre this kind doesn't have (a horror show): only the other kind can match.
            guard ids.count == genreNames.count else { continue }
            var filter = TMDBCatalog.Filter()
            filter.kind = kind
            filter.genres = Set(ids)
            filter.originalLanguage = language ?? ""
            filter.from = from.map(String.init) ?? ""
            filter.to = to.map(String.init) ?? ""
            switch sort {
            case "rating": filter.sort = "vote_average.desc"; filter.votes = 200
            case "newest": filter.sort = "date.desc"; filter.votes = 10
            default: break
            }
            requests.append((kind, filter))
        }
        guard !requests.isEmpty else { throw AgentToolError("No titles have all of these genres; try fewer.") }
        let pages = await withTaskGroup(of: (Int, TMDBCatalog.SearchPage?).self) { group in
            for (index, request) in requests.enumerated() {
                group.addTask { (index, try? await TMDBCatalog.search(query: query, kind: request.0, feed: feed, filter: request.1)) }
            }
            var pages: [Int: TMDBCatalog.SearchPage] = [:]
            for await (index, page) in group { if let page { pages[index] = page } }
            return requests.indices.compactMap { pages[$0] }
        }
        guard !pages.isEmpty else { throw AgentToolError("TMDB didn't answer; try again in a moment.") }
        // Films and shows taken in turn, so both kinds lead.
        var items: [TMDBCatalog.Item] = [], seen = Set<String>()
        for rank in 0..<(pages.map(\.items.count).max() ?? 0) {
            for page in pages where rank < page.items.count && seen.insert(page.items[rank].key).inserted { items.append(page.items[rank]) }
        }
        items = Array(items.prefix(20))
        for item in items { context.titles[item.key] = item }
        let results = items.map { item in
            JSONValue.obj([
                "title_id": .str(item.key), "title": .str(item.name),
                "original_title": item.originalName == item.name ? nil : .text(item.originalName),
                "kind": .str(item.mediaType.rawValue), "year": item.year.map { .num($0) },
                "rating": item.rating.flatMap { $0 > 0 ? .num($0) : nil },
                "overview": .text(AgentToolKit.clip(item.overview, 100)),
            ])
        }
        let cards = items.map { item in
            AgentCard(id: item.key, title: item.name, subtitle: subtitle(item), poster: item.poster,
                      play: ["title_id": .str(item.key), "title": .str(item.name)], action: "discover_open",
                      symbol: item.mediaType == .tv ? "tv" : "film")
        }
        return AgentCard.attach(cards, to: .obj(["query": .text(query), "titles": .list(results),
                                                 "note": results.isEmpty ? .str("Nothing matched; try other words or fewer filters.") : nil]))
    }

    /// The card's second line: the year and TMDB's rating.
    private static func subtitle(_ item: TMDBCatalog.Item) -> String? {
        let parts = [item.year.map(String.init), item.rating.flatMap { $0 > 0 ? String(format: "★ %.1f", $0) : nil }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func open(_ args: AgentArguments, _ context: AgentToolContext) async throws -> JSONValue {
        try context.require(.discover)
        let id = try args.requiredString("title_id")
        let item: TMDBCatalog.Item
        if let known = context.titles[id] {
            item = known
        } else {
            // A card from an earlier launch: its page loads the rest from TMDB.
            let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let type = TMDBMatch.MediaType(rawValue: parts[0]), let number = Int(parts[1]) else {
                throw AgentToolError("No title has the id `\(id)`; use a title_id from discover_search.")
            }
            let title = try args.string("title") ?? ""
            item = TMDBCatalog.Item(id: number, mediaType: type, name: title, originalName: title, year: nil, overview: "",
                                    poster: nil, backdrop: nil, rating: nil, genreIDs: [])
        }
        try await AgentNavigator.push(Route { AnyView(DiscoverDetailView(item: item)) }, in: AgentNavigator.currentStack(context.store), store: context.store)
        return .obj(["opened": .str(item.name)])
    }
}

import SwiftUI
import TVCore

/// A typed destination prevents movie genres and company IDs from becoming TV network queries.
struct DiscoverBrowseView: View {
    let title: String
    @State private var filter: TMDBCatalog.Filter
    let logo: URL?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var items: [TMDBCatalog.Item] = []
    @State private var page = 0
    @State private var totalPages = 1
    @State private var loading = false
    @State private var failed = false
    @State private var sort = "popularity.desc"
    @State private var layout = "grid"
    @State private var generation = UUID()
    init(title: String, filter: TMDBCatalog.Filter, logo: URL? = nil) {
        self.title = title; self.logo = logo; _filter = State(initialValue: filter)
    }
    private var request: TMDBCatalog.Filter { var value = filter; value.sort = sort; return value }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                if let logo {
                    TMDBArtwork(url: logo, maxPixels: 600, fill: false).frame(height: 48).padding(.top, 14).padding(.bottom, 14)
                }
                if layout == "grid" {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: geometry.size.width < 600 ? 3 : 5), spacing: 14) {
                        ForEach(items, id: \.key) { item in
                            RouteLink { DiscoverDetailView(item: item) } label: { tile(item) }.buttonStyle(.plain)
                                .accessibilityIdentifier("discover.browse.item.\(item.key)")
                        }
                    }.padding(.horizontal, 14).padding(.top, 14)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(items, id: \.key) { item in
                            RouteLink { DiscoverDetailView(item: item) } label: { DiscoverSearchRow(item: item) }.buttonStyle(.plain)
                                .accessibilityIdentifier("discover.browse.item.\(item.key)")
                        }
                    }.padding(14)
                }
                if failed {
                    Button(L10n.text("Try Again")) { Task { await load(reset: page == 0) } }.padding(24)
                        .accessibilityIdentifier("discover.browse.retry")
                } else if loading { ProgressView().padding(24) }
                else if items.isEmpty { ContentUnavailableView(L10n.text("No Results"), systemImage: "film") }
                else if page < totalPages {
                    Button(L10n.text("Load More")) { Task { await load(reset: false) } }.padding(24)
                        .accessibilityIdentifier("discover.browse.more")
                        .onAppear { Task { await load(reset: false) } }
                }
                Color.clear.frame(height: 90)
            }.scrollIndicators(.hidden)
                .overlay(alignment: .bottomTrailing) { sortMenu.padding(20) }
        }
        .background { DiscoverSearchAtmosphere() }
        .navigationTitle(title)
        #if !os(macOS)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Menu(L10n.text("Genres")) {
                        ForEach(DiscoverGenres.ids(for: filter.kind), id: \.self) { id in
                            Button {
                                filter.genres = filter.genres.contains(id) ? [] : [id]
                            } label: {
                                if filter.genres.contains(id) { Label(L10n.text(DiscoverGenres.names[id] ?? ""), systemImage: "checkmark") }
                                else { Text(L10n.text(DiscoverGenres.names[id] ?? "")) }
                            }
                        }
                    }
                    if filter.company.isEmpty {
                        Picker(L10n.text("Content Type"), selection: $filter.kind) {
                            Text(L10n.text("Movies")).tag(TMDBCatalog.SearchKind.movie)
                            Text(L10n.text("Series")).tag(TMDBCatalog.SearchKind.tv)
                        }
                    }
                    Divider()

                    Button { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { layout = layout == "grid" ? "list" : "grid" } } label: {
                        Label(L10n.text(layout == "grid" ? "List View" : "Grid View"), systemImage: layout == "grid" ? "list.bullet" : "square.grid.3x3")
                    }
                } label: { Image(systemName: "ellipsis") }
                    .accessibilityIdentifier("discover.browse.layout")
            }
        }
        .onChange(of: filter.kind) { _, kind in filter.genres.formIntersection(DiscoverGenres.ids(for: kind)) }
        .task(id: request) { await load(reset: true) }
    }
    private func tile(_ item: TMDBCatalog.Item) -> some View {
        VStack(spacing: 5) {
            PosterImage(url: item.poster).aspectRatio(2.0 / 3.0, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 9))
            Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Text(item.date ?? item.year.map(String.init) ?? "—").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity)
    }
    private var sortMenu: some View {
        Menu {
            Picker(L10n.text("Sort By"), selection: $sort) {
                Text(L10n.text("Popularity ↓")).tag("popularity.desc")
                Text(L10n.text("Rating ↓")).tag("vote_average.desc")
                Text(L10n.text("Most Votes")).tag("vote_count.desc")
                Text(L10n.text("Newest First")).tag("date.desc")
                Text(L10n.text("Oldest First")).tag("date.asc")
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease").font(.system(size: 20)).frame(width: 48, height: 48).glassSurface(.regular, in: Circle())
        }.accessibilityLabel(L10n.text("Sort By")).accessibilityIdentifier("discover.browse.sort")
    }
    @MainActor private func load(reset: Bool) async {
        if reset { generation = UUID(); page = 0; totalPages = 1; items = [] }
        else if loading || page >= totalPages { return }
        let token = generation
        loading = true; failed = false
        defer { if token == generation { loading = false } }
        do {
            var request = filter; request.sort = sort
            let value = try await TMDBCatalog.search(page: page + 1, filter: request)
            try Task.checkCancellation()
            guard token == generation else { return }
            var seen = Set(items.map(\.key))
            let incoming = value.items.filter { seen.insert($0.key).inserted }
            withAnimation(reduceMotion || !reset ? nil : .easeOut(duration: 0.25)) { items += incoming }
            page = value.page; totalPages = value.totalPages
        } catch { if token == generation && !Task.isCancelled { failed = true } }
    }
}

extension TMDBCatalog.Filter {
    static func genre(_ id: Int, type: TMDBMatch.MediaType) -> Self {
        var value = Self(); value.kind = type == .tv ? .tv : .movie; value.genres = [id]; return value
    }
    static func studio(_ id: Int, type: TMDBMatch.MediaType) -> Self {
        var value = Self(); value.kind = type == .tv ? .tv : .movie; value.company = String(id); return value
    }
}

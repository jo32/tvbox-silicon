import SwiftUI
import TVCore

/// The Novels section: the bookshelf, then a book source's explore lists. Search looks through every source at once,
/// as Legado does, and joins the same book from several sources into one result.
struct NovelView: View {
    @State private var store = NovelStore.shared
    @Environment(\.openRoute) private var openRoute

    var body: some View {
        Group {
            if store.enabledSources.isEmpty && store.shelf.isEmpty {
                NovelWelcome()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                        #if os(tvOS)
                        HStack(spacing: 16) {
                            RouteLink { NovelSearchView() } label: { Label(L10n.text("Search Books"), systemImage: "magnifyingglass") }
                                .controlButton(prominent: true)
                                .accessibilityIdentifier("novel.search")
                            if !store.shelf.isEmpty {
                                RouteLink { NovelShelfView() } label: { Label(L10n.text("Bookshelf"), systemImage: "books.vertical") }.controlButton()
                            }
                        }
                        .padding(.horizontal, Layout.gutter)
                        .tvFocusSection()
                        #endif
                        if !store.shelf.isEmpty {
                            NovelShelfRow(title: L10n.text("Bookshelf"), items: Array(store.shelf.prefix(20)),
                                          route: Route { AnyView(NovelShelfView()) }) { entry in
                                NovelBookLink(book: entry.book, caption: NovelProgressText.short(entry))
                            }
                        }
                        if let source = store.currentExplore {
                            NovelExploreBrowse(source: source).id(source.key + source.revision)
                        } else if store.searchable.isEmpty {
                            EmptyResults(symbol: "books.vertical", title: L10n.text("No Book Sources"),
                                         message: L10n.text("Turn on book sources in Settings › Book Sources to read here."))
                        } else {
                            EmptyResults(symbol: "magnifyingglass", title: L10n.text("Search Books"),
                                         message: L10n.text("Your sources have no explore pages. Search for a title or an author."))
                        }
                    }
                    .padding(.vertical, Layout.gutter)
                    .frame(maxWidth: Layout.maxWidth).frame(maxWidth: .infinity)
                }
            }
        }
        .background { Backdrop() }
        .tabTitle(L10n.text("Novels"))
        #if !os(tvOS)
        .toolbar {
            ToolbarItemGroup {
                if !store.searchable.isEmpty {
                    RouteLink { NovelSearchView() } label: { Image(systemName: "magnifyingglass") }
                        .accessibilityLabel(L10n.text("Search"))
                        .accessibilityIdentifier("novel.search")
                }
            }
        }
        #endif
        #if DEBUG
        .task { await NovelQA.start(openRoute: openRoute) }
        #endif
    }
}

/// Nothing to read yet: sources come from a Legado list added as a subscription.
private struct NovelWelcome: View {
    #if os(tvOS)
    private let icon: CGFloat = 132, titleSize: CGFloat = 46, text: CGFloat = 28, width: CGFloat = 960
    #else
    private let icon: CGFloat = 84, titleSize: CGFloat = 24, text: CGFloat = 15, width: CGFloat = 440
    #endif
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "text.book.closed.fill")
                .font(.system(size: icon * 0.42, weight: .bold)).foregroundStyle(Brand.accent)
                .frame(width: icon, height: icon).background(Brand.accent.opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            Text(L10n.text("Read Novels")).font(.system(size: titleSize, weight: .bold))
            Text(L10n.text("Turn on book sources in Settings › Book Sources to read here."))
                .font(.system(size: text)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: width)
            // Also the page's only focusable control on Apple TV, so Back works when the section opens directly.
            RouteLink { NovelSourcesView() } label: { Label(L10n.text("Book Sources"), systemImage: "books.vertical") }
                .controlButton(prominent: true).padding(.top, 10)
                .accessibilityIdentifier("novel.welcome.sources")
        }
        .padding(Layout.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tvFocusSection()
    }
}

// MARK: - Explore

/// One source's explore lists (`exploreUrl`): its categories as chips, the chosen one as a grid.
struct NovelExploreBrowse: View {
    let source: NovelSource
    @State private var store = NovelStore.shared
    @State private var kinds: [NovelExploreKind]?
    @State private var failure: String?
    @State private var selected = ""

    private var lists: [NovelExploreKind] { (kinds ?? []).filter { !$0.url.isEmpty } }
    private var current: NovelExploreKind? { lists.first { $0.id == selected } ?? lists.first }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.headerSpacing) {
            header
            if let current {
                NovelBookGrid(id: source.key + current.id) { page in
                    try await NovelBooks.shared.explore(source.key, url: current.url, page: page)
                }
            } else if let failure {
                EmptyResults(symbol: "exclamationmark.triangle", title: L10n.text("Unable to Load"), message: failure, action: L10n.text("Try Again")) {
                    Task { await load() }
                }
            } else if kinds == nil {
                ProgressView().frame(maxWidth: .infinity).padding(40)
            } else {
                EmptyResults(symbol: "magnifyingglass", title: L10n.text("Search Books"), message: L10n.text("This source has no explore lists. Search it instead."))
            }
        }
        .task { await load() }
    }

    private func load() async {
        failure = nil
        do { kinds = try await NovelBooks.shared.exploreKinds(source.key) } catch { failure = error.novelMessage }
    }

    @ViewBuilder private var header: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: Layout.headerSpacing) {
            ChipRow {
                HStack(spacing: 10) {
                    ForEach(store.explorable) { item in
                        Chip(title: item.name, selected: item.key == source.key) { store.exploreSource = item.key }
                    }
                }
            }
            if lists.count > 1 {
                ChipRow {
                    HStack(spacing: 10) {
                        ForEach(lists) { kind in Chip(title: kind.title, selected: kind.id == current?.id) { selected = kind.id } }
                    }
                }
            }
        }
        .padding(.horizontal, Layout.gutter)
        .tvFocusSection()
        #else
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("Browse Books")).font(.system(size: DiscoverLayout.heading, weight: .semibold)).lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 8) {
                Menu {
                    Picker(L10n.text("Book Sources"), selection: Binding(get: { source.key }, set: { store.exploreSource = $0 })) {
                        ForEach(store.explorable) { Text($0.name).tag($0.key) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    HStack(spacing: 6) {
                        Text(source.name).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).frame(height: SourceStrip.controlSize)
                    .glassOrFill(.regular.interactive(), Color.primary.opacity(0.06), in: Capsule())
                    .contentShape(Capsule())
                }
                .menuStyle(.button).buttonStyle(.plain).tint(.primary)
                .accessibilityIdentifier("novel.explore.source")
                Spacer(minLength: 0)
            }
            if lists.count > 1 {
                SourceStrip(items: lists.map { .init(id: $0.id, name: $0.title) }, selection: current?.id ?? "") { selected = $0 }
                    // Plain chips: glass ones in the scrolling page made SwiftUI rework their glass every frame, a
                    // dropped frame in five while scrolling (measured with -qaNovelAutoScroll; plain: none).
                    .environment(\.glassControls, false)
            }
        }
        .padding(.horizontal, DiscoverLayout.gutter)
        #endif
    }
}

/// An endless grid of books, a page at a time.
struct NovelBookGrid: View {
    var id: String
    let load: (Int) async throws -> [NovelBook]
    @State private var books: [NovelBook] = []
    @State private var page = 0
    @State private var finished = false
    @State private var loading = false
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            LazyVGrid(columns: NovelLayout.columns, alignment: .leading, spacing: Layout.gridRowSpacing) {
                ForEach(books) { book in
                    NovelBookLink(book: book)
                        .onAppear { if book.id == books.last?.id { Task { await more() } } }
                }
            }
            .padding(.horizontal, Layout.gutter)
            if books.isEmpty, loading, failure == nil { ProgressView().padding(.top, 60) }
            footer
        }
        .task(id: id) { await reset() }
    }

    @ViewBuilder private var footer: some View {
        if let failure {
            EmptyResults(symbol: "exclamationmark.triangle", title: books.isEmpty ? L10n.text("Unable to Load") : L10n.text("Unable to Load More"),
                         message: failure, action: L10n.text("Try Again")) { Task { await more() } }
        } else if books.isEmpty, finished {
            EmptyResults(symbol: "books.vertical", title: L10n.text("No Books"))
        } else if loading, !books.isEmpty {
            ProgressView().frame(maxWidth: .infinity).padding(24)
        } else if !finished, !books.isEmpty {
            // Apple TV has no scrolling past the end to trigger the next page: a button does it.
            Button(L10n.text("Load More")) { Task { await more() } }.controlButton().frame(maxWidth: .infinity).padding(24)
        }
    }

    private func reset() async {
        books = []; page = 0; finished = false; failure = nil
        await more()
    }

    private func more() async {
        guard !loading, !finished else { return }
        loading = true; failure = nil
        defer { loading = false }
        do {
            let found = try await load(page + 1)
            let known = Set(books.map(\.id))
            let fresh = found.filter { !known.contains($0.id) }
            books += fresh
            page += 1
            // A list without pages answers every page with the same books.
            finished = fresh.isEmpty
        } catch is CancellationError {
        } catch {
            failure = error.novelMessage
        }
    }
}

// MARK: - Search

/// Searches every switched-on source, a few at a time; the same book from several sources is one result.
struct NovelSearchView: View {
    @State private var store = NovelStore.shared
    @State private var query = ""
    @State private var submitted = ""
    @State private var hits: [NovelSearchHit] = []
    @State private var searched = 0
    @State private var failed = 0
    @State private var total = 0
    @State private var running = false
    @State private var stopping = false
    @Environment(\.openRoute) private var openRoute
    /// Bumped to search the same words again (after the scope changes).
    @State private var round = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.headerSpacing) {
                #if os(tvOS)
                scopeChips
                #endif
                if submitted.isEmpty {
                    EmptyResults(symbol: "magnifyingglass", title: L10n.text("Search Books"),
                                 message: store.searchGroup == nil ? L10n.text("Searches all %lld switched-on book sources.", store.searchScope.count)
                                    : L10n.text("Searches the %lld switched-on sources in %@.", store.searchScope.count, store.searchGroup ?? ""))
                } else {
                    progress.padding(.horizontal, Layout.gutter)
                    LazyVGrid(columns: NovelLayout.columns, alignment: .leading, spacing: Layout.gridRowSpacing) {
                        ForEach(hits) { hit in
                            NovelBookLink(book: hit.book, alternatives: hit.books, caption: caption(hit))
                        }
                    }
                    .padding(.horizontal, Layout.gutter)
                    if !running, hits.isEmpty {
                        EmptyResults(symbol: "books.vertical", title: L10n.text("No Results"),
                                     message: L10n.text("No source found “%@”. Try a shorter title, or the author's name.", submitted))
                    }
                }
            }
            .padding(.vertical, Layout.gutter)
            .frame(maxWidth: Layout.maxWidth).frame(maxWidth: .infinity)
        }
        .background { Backdrop() }
        .catalogSearchable(text: $query, prompt: L10n.text("Title or author"))
        .onSubmit(of: .search) { submit(query) }
        #if os(tvOS)
        // The tvOS keyboard has no return key that submits: search as the text settles.
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(1100))
            if !Task.isCancelled { submit(query) }
        }
        #endif
        .screenTitle(L10n.text("Search Books"))
        #if !os(tvOS)
        .toolbar { ToolbarItem { scopeMenu } }
        #endif
        .onChange(of: store.searchGroup) { _, _ in if !submitted.isEmpty { submittedFromMemory = false; round += 1 } }
        .task(id: "\(submitted)#\(round)") { await search() }
        .onAppear {
            if submitted.isEmpty, !store.lastSearch.keyword.isEmpty {
                query = store.lastSearch.keyword; hits = store.lastSearch.hits; submittedFromMemory = true; submitted = store.lastSearch.keyword
            }
            #if DEBUG
            if let text = UserDefaults.standard.string(forKey: "qaNovelQuery"), submitted.isEmpty { query = text; submitted = text }
            #endif
        }
    }

    @State private var openedFirst = false
    /// Set when the results came back from the store: they are shown, not searched again.
    @State private var submittedFromMemory = false

    private func submit(_ text: String) {
        let keyword = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty, keyword != submitted else { return }
        submittedFromMemory = false
        submitted = keyword
    }

    private func caption(_ hit: NovelSearchHit) -> String {
        let count = hit.books.count
        let sources = count == 1 ? store.name(of: hit.book.sourceKey) : L10n.text("%lld sources", count)
        return hit.book.author.isEmpty ? sources : hit.book.author + " · " + sources
    }

    @ViewBuilder private var progress: some View {
        if running || failed > 0 {
            HStack(spacing: 10) {
                if running { ProgressView().appControlSize(.small) }
                Text(running ? L10n.text("Searched %lld of %lld sources", searched, total)
                             : L10n.text("%lld sources didn't answer", failed))
                    .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                if running {
                    Button(L10n.text("Stop")) { stopping = true }
                        #if os(tvOS)
                        .controlButton()
                        #else
                        .buttonStyle(.borderless).font(.footnote.weight(.semibold))
                        #endif
                        .accessibilityIdentifier("novel.search.stop")
                }
            }
        }
    }

    private var scopeTitle: String { store.searchGroup ?? L10n.text("All Sources") }

    #if !os(tvOS)
    /// Where to search: every source that is on, or one group of them (big lists file thousands under groups).
    private var scopeMenu: some View {
        Menu {
            Picker(L10n.text("Search In"), selection: Binding(get: { store.searchGroup ?? "" }, set: { store.searchGroup = $0.isEmpty ? nil : $0 })) {
                Text(L10n.text("All Sources (%lld)", store.searchable.count)).tag("")
                ForEach(store.searchGroups, id: \.name) { group in Text("\(group.name) (\(group.count))").tag(group.name) }
            }
            .pickerStyle(.inline)
        } label: {
            Label(scopeTitle, systemImage: "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel(L10n.text("Search In"))
        .accessibilityIdentifier("novel.search.scope")
    }
    #else
    private var scopeChips: some View {
        ChipRow {
            HStack(spacing: 10) {
                Chip(title: L10n.text("All Sources (%lld)", store.searchable.count), selected: store.searchGroup == nil) { store.searchGroup = nil }
                ForEach(store.searchGroups.prefix(30), id: \.name) { group in
                    Chip(title: "\(group.name) (\(group.count))", selected: store.searchGroup == group.name) { store.searchGroup = group.name }
                }
            }
        }
        .padding(.horizontal, Layout.gutter)
        .tvFocusSection()
    }
    #endif

    private func search() async {
        guard !submitted.isEmpty else { return }
        if submittedFromMemory { submittedFromMemory = false; return }
        let keyword = submitted
        let sources = store.searchScope
        hits = []; searched = 0; failed = 0; total = sources.count; running = true; stopping = false
        defer { running = false; stopping = false }
        for await answer in NovelBooks.search(keyword, in: sources) {
            // Leaving the loop drops the stream, which cancels the searches still running.
            if stopping { break }
            searched += 1
            switch answer.result {
            case .success(let books): NovelBooks.merge(books, into: &hits, keyword: keyword)
            case .failure: failed += 1
            }
            store.lastSearch = (keyword, hits)
            #if DEBUG
            // `-qaNovelOpenFirst 1`: opens the first exact match once a few sources have it.
            if UserDefaults.standard.bool(forKey: "qaNovelOpenFirst"), let hit = hits.first, hit.books.count >= 2, !openedFirst {
                openedFirst = true
                openRoute?(Route { AnyView(NovelDetailView(book: hit.book, alternatives: hit.books)) })
            }
            #endif
        }
    }
}

// MARK: - Shelf

struct NovelShelfView: View {
    @State private var store = NovelStore.shared
    var body: some View {
        ScrollView {
            LazyVGrid(columns: NovelLayout.columns, alignment: .leading, spacing: Layout.gridRowSpacing) {
                ForEach(store.shelf) { entry in
                    NovelBookLink(book: entry.book, caption: NovelProgressText.short(entry))
                        .contextMenu {
                            Button(L10n.text("Remove from Bookshelf"), systemImage: "trash", role: .destructive) { store.remove(entry) }
                        }
                }
            }
            .padding(Layout.gutter)
            .frame(maxWidth: Layout.maxWidth).frame(maxWidth: .infinity)
        }
        .background { Backdrop() }
        .screenTitle(L10n.text("Bookshelf"))
    }
}


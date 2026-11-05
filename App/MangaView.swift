import SwiftUI
import TVCore

/// The Manga section: what the viewer is reading and saved, then the chosen Venera source's explore pages.
struct MangaView: View {
    @State private var store = MangaStore.shared
    @Environment(\.openRoute) private var openRoute

    var body: some View {
        Group {
            if store.sources.isEmpty && store.history.isEmpty && store.favorites.isEmpty {
                MangaWelcome()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                        if !store.history.isEmpty {
                            MangaShelfRow(title: L10n.text("Continue Reading"), comics: store.history.prefix(20).map(\.comic),
                                          captions: Dictionary(store.history.prefix(20).map { ($0.id, MangaProgressText.short($0)) }, uniquingKeysWith: { a, _ in a }),
                                          route: Route { AnyView(MangaLibraryView(kind: .history)) })
                        }
                        if !store.favorites.isEmpty {
                            MangaShelfRow(title: L10n.text("Favorites"), comics: store.favorites.prefix(30).map(\.comic), showsSource: store.sources.count > 1,
                                          route: Route { AnyView(MangaLibraryView(kind: .favorites)) })
                        }
                        if store.sources.isEmpty {
                            EmptyResults(symbol: "books.vertical", title: L10n.text("No Comic Sources"),
                                         message: L10n.text("Add comic sources in Settings › Comic Sources to read comics here."))
                        } else {
                            #if os(tvOS)
                            MangaSourceBar()
                            #endif
                            if let source = store.currentSource {
                                MangaSourceBrowse(source: source.key).id(source.key + source.revision)
                            }
                        }
                    }
                    .padding(.vertical, Layout.gutter)
                    .frame(maxWidth: Layout.maxWidth).frame(maxWidth: .infinity)
                }
            }
        }
        .background { Backdrop() }
        .modifier(MangaNoticeBanner())
        .tabTitle(L10n.text("Manga"))
        #if !os(tvOS)
        .toolbar {
            ToolbarItemGroup {
                if !store.sources.isEmpty {
                    RouteLink { MangaSearchView() } label: { Image(systemName: "magnifyingglass") }.accessibilityLabel(L10n.text("Search"))
                }
            }
        }
        #endif
        #if DEBUG
        .task { await MangaQA.start(openRoute: openRoute) }
        #endif
    }
}

/// Nothing to read yet: sources are managed in Settings (the section shows once one is installed).
private struct MangaWelcome: View {
    #if os(tvOS)
    private let icon: CGFloat = 132, titleSize: CGFloat = 46, text: CGFloat = 28, width: CGFloat = 960
    #else
    private let icon: CGFloat = 84, titleSize: CGFloat = 24, text: CGFloat = 15, width: CGFloat = 440
    #endif
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: icon * 0.42, weight: .bold)).foregroundStyle(Brand.accent)
                .frame(width: icon, height: icon).background(Brand.accent.opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            Text(L10n.text("Read Comics")).font(.system(size: titleSize, weight: .bold))
            Text(L10n.text("Add comic sources in Settings › Comic Sources to read comics here."))
                .font(.system(size: text)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: width)
            // Goes straight to the sources. On Apple TV it is also the page's only focusable control: with none, focus
            // had nowhere to land when the section opened directly, and Back did nothing.
            RouteLink { MangaSourcesView() } label: { Label(L10n.text("Comic Sources"), systemImage: "books.vertical") }
                .controlButton(prominent: true).padding(.top, 10)
                .accessibilityIdentifier("manga.welcome.sources")
        }
        .padding(Layout.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tvFocusSection()
    }
}

/// The installed sources as chips; the chosen one fills the page under it.
private struct MangaSourceBar: View {
    @State private var store = MangaStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: Layout.headerSpacing) {
            SectionHeader(title: L10n.text("Comic Sources")).padding(.horizontal, Layout.gutter)
            ChipRow {
                HStack(spacing: 10) {
                    ForEach(store.sources) { source in
                        Chip(title: source.name, selected: source.key == store.currentSource?.key) { store.selectedSource = source.key }
                    }
                    #if os(tvOS)
                    RouteLink { MangaSearchView() } label: { Label(L10n.text("Search"), systemImage: "magnifyingglass") }.mangaPill()
                    #endif
                }
            }
            .padding(.horizontal, Layout.gutter)
        }
        .tvFocusSection()
    }
}

/// One source's explore pages (shelves or a grid), with its categories and ranking a tap away.
struct MangaSourceBrowse: View {
    let source: String
    @Environment(\.openRoute) private var openRoute
    @State private var info: MangaSourceInfo?
    @State private var failure: String?
    @State private var page = 0
    @State private var shelves: [MangaShelf] = []
    @State private var loadingShelves = false
    @State private var shelfFailure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.headerSpacing) {
            if let info {
                #if os(tvOS)
                header(info)
                #else
                phoneHeader(info)
                #endif
                content(info)
            } else if let failure {
                EmptyResults(symbol: "exclamationmark.triangle", title: L10n.text("Unable to Load"), message: failure, action: L10n.text("Try Again")) {
                    Task { await load() }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(40)
            }
        }
        .task { await load() }
    }

    private func load() async {
        failure = nil
        do { info = try await MangaRuntime.shared.info(source) } catch { failure = error.mangaMessage }
    }

    #if !os(tvOS)
    /// As Watch Now's Recommendations: a heading, then the source as a glass capsule that opens its categories and a
    /// switch beside it for another source; a source with several explore pages lists them under it.
    private func phoneHeader(_ info: MangaSourceInfo) -> some View {
        let hasCategories = !info.categoryParts.isEmpty || !info.rankingOptions.isEmpty
        return VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("Browse Comics")).font(.system(size: DiscoverLayout.heading, weight: .semibold)).lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 8) {
                Button {
                    if hasCategories { openRoute?(Route { AnyView(MangaCategoriesView(source: source)) }) }
                } label: {
                    HStack(spacing: 6) {
                        Text(info.name).lineLimit(1)
                        if hasCategories { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).frame(height: SourceStrip.controlSize)
                    .glassOrFill(.regular.interactive(), Color.primary.opacity(0.06), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("manga.source.open")
                MangaSourceSwitch()
            }
            if info.explore.count > 1 {
                SourceStrip(items: info.explore.indices.map { .init(id: "\($0)", name: info.text(info.explore[$0].title)) }, selection: "\(page)") { page = Int($0) ?? 0 }
            }
        }
        .padding(.horizontal, DiscoverLayout.gutter)
    }
    #endif

    /// Where a shelf's heading leads: the source's own "more" link, else the shelf as a grid.
    private func shelfRoute(_ shelf: MangaShelf, _ info: MangaSourceInfo) -> Route {
        let title = info.text(shelf.title), source = source, comics = shelf.comics
        if let jump = shelf.viewMore { return Route { AnyView(MangaJumpView(source: source, jump: jump, title: title)) } }
        return Route { AnyView(MangaShelfPage(title: title, comics: comics)) }
    }

    @ViewBuilder private func header(_ info: MangaSourceInfo) -> some View {
        let hasCategories = !info.categoryParts.isEmpty || !info.rankingOptions.isEmpty
        if info.explore.count > 1 || hasCategories {
            ChipRow {
                HStack(spacing: 10) {
                    if info.explore.count > 1 {
                        ForEach(Array(info.explore.enumerated()), id: \.offset) { index, item in
                            Chip(title: info.text(item.title), selected: index == page) { page = index }
                        }
                    }
                    if hasCategories {
                        RouteLink { MangaCategoriesView(source: source) } label: {
                            Label(info.text(info.categoryTitle ?? "").isEmpty ? L10n.text("Categories") : info.text(info.categoryTitle ?? ""), systemImage: "square.grid.2x2")
                        }
                        .mangaPill()
                    }
                }
            }
            .padding(.horizontal, Layout.gutter)
            .tvFocusSection()
        }
    }

    @ViewBuilder private func content(_ info: MangaSourceInfo) -> some View {
        if info.explore.isEmpty {
            EmptyResults(symbol: "magnifyingglass", title: L10n.text("Search This Source"),
                         message: L10n.text("This source has no explore page. Search it, or open its categories."))
        } else {
            let item = info.explore[min(page, info.explore.count - 1)]
            switch item.type {
            case "multiPartPage", "singlePageWithMultiPart":
                VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                    if loadingShelves && shelves.isEmpty { ProgressView().frame(maxWidth: .infinity).padding(40) }
                    if let shelfFailure {
                        EmptyResults(symbol: "exclamationmark.triangle", title: L10n.text("Unable to Load"), message: shelfFailure, action: L10n.text("Try Again")) {
                            Task { await loadShelves() }
                        }
                    }
                    ForEach(shelves) { shelf in
                        MangaShelfRow(title: info.text(shelf.title), comics: shelf.comics, route: shelfRoute(shelf, info))
                    }
                }
                .task(id: page) { await loadShelves() }
            case "mixed":
                MangaMixedPage(source: source, page: page)
            default:
                MangaComicGrid(load: { cursor in try await MangaRuntime.shared.explore(source, page: page, cursor: cursor).page }, id: "\(source)-\(page)")
            }
        }
    }

    private func loadShelves() async {
        loadingShelves = true; shelfFailure = nil
        defer { loadingShelves = false }
        do {
            let result = try await MangaRuntime.shared.explore(source, page: page, cursor: nil)
            await MangaImages.shared.prepareCovers(source: source, urls: result.shelves.flatMap { $0.comics.map(\.cover) })
            shelves = result.shelves
        } catch { shelves = []; shelfFailure = error.mangaMessage }
    }
}

/// A "mixed" explore page: shelves and loose comics, page by page.
private struct MangaMixedPage: View {
    let source: String
    let page: Int
    @State private var shelves: [MangaShelf] = []
    var body: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            ForEach(shelves) { shelf in
                MangaShelfRow(title: shelf.title, comics: shelf.comics, route: Route { AnyView(MangaShelfPage(title: shelf.title, comics: shelf.comics)) })
            }
            MangaComicGrid(load: { cursor in
                let result = try await MangaRuntime.shared.explore(source, page: page, cursor: cursor ?? .page(1))
                if cursor == nil { await MainActor.run { shelves = result.shelves } }
                return result.page
            }, id: "\(source)-mixed-\(page)")
        }
    }
}

/// Where a shelf's See All or a tag leads: a search or a category of the source.
struct MangaJumpView: View {
    let source: String
    let jump: MangaJump
    let title: String
    var body: some View {
        switch jump {
        case .search(let keyword): MangaSourceResults(source: source, keyword: keyword)
        case .category(let name, let param): MangaCategoryComicsView(source: source, category: name, param: param, title: title.isEmpty ? name : title)
        }
    }
}

// MARK: - Categories

struct MangaCategoriesView: View {
    let source: String
    @State private var info: MangaSourceInfo?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                if let info {
                    if !info.rankingOptions.isEmpty {
                        RouteLink { MangaRankingView(source: source) } label: { Label(L10n.text("Ranking"), systemImage: "chart.bar.fill") }
                            .controlButton().padding(.horizontal, Layout.gutter)
                    }
                    ForEach(Array(info.categoryParts.enumerated()), id: \.offset) { _, part in
                        VStack(alignment: .leading, spacing: Layout.headerSpacing) {
                            if !part.name.isEmpty { SectionHeader(title: info.text(part.name)) }
                            MangaFlow(spacing: 10) {
                                ForEach(Array(part.categories.enumerated()), id: \.offset) { index, name in
                                    let param = part.params.indices.contains(index) ? part.params[index] : nil
                                    RouteLink {
                                        if part.itemType == "search" { MangaSourceResults(source: source, keyword: param ?? name) }
                                        else { MangaCategoryComicsView(source: source, category: name, param: param, title: info.text(name)) }
                                    } label: { Text(info.text(name)).lineLimit(1) }
                                    .mangaPill()
                                }
                            }
                        }
                        .padding(.horizontal, Layout.gutter)
                        .tvFocusSection()
                    }
                } else { ProgressView().frame(maxWidth: .infinity).padding(40) }
            }
            .padding(.vertical, Layout.gutter)
            .frame(maxWidth: Layout.maxWidth).frame(maxWidth: .infinity)
        }
        .background { Backdrop() }
        .screenTitle(info.map { $0.text($0.categoryTitle ?? "") }.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.text("Categories"))
        .task { info = try? await MangaRuntime.shared.info(source) }
    }
}

/// Option chips of a source (sort order, time range), one row per option.
struct MangaOptionRows: View {
    let options: [MangaSourceInfo.Option]
    let info: MangaSourceInfo
    @Binding var values: [String]
    var body: some View {
        #if os(tvOS)
        ForEach(Array(options.enumerated()), id: \.offset) { index, option in
            ChipRow {
                HStack(spacing: 10) {
                    ForEach(option.choices, id: \.value) { choice in
                        Chip(title: info.text(choice.text), selected: values.indices.contains(index) && values[index] == choice.value) {
                            if values.indices.contains(index) { values[index] = choice.value }
                        }
                    }
                }
            }
            .padding(.horizontal, Layout.gutter)
            .tvFocusSection()
        }
        #else
        // As a source's category filters on Watch Now: one glass "Sort: Popular" chip per option, each a menu.
        if !options.isEmpty {
            CategoryFilterBar(filters: filters, choices: Dictionary(uniqueKeysWithValues: values.enumerated().map { ("\($0.offset)", $0.element) })) { next in
                for index in options.indices where values.indices.contains(index) {
                    if let value = next["\(index)"] { values[index] = value }
                }
            }
            .padding(.horizontal, Layout.gutter)
        }
        #endif
    }

    private var filters: [CategoryFilter] {
        options.enumerated().map { index, option in
            CategoryFilter(key: "\(index)", name: info.text(option.label),
                           options: option.choices.map { CategoryFilter.Option(name: info.text($0.text), value: $0.value) },
                           initial: option.defaultValue ?? option.choices.first?.value)
        }
    }

    static func defaults(_ options: [MangaSourceInfo.Option]) -> [String] { options.map { $0.defaultValue ?? $0.choices.first?.value ?? "" } }
}

struct MangaCategoryComicsView: View {
    let source: String
    let category: String
    let param: String?
    let title: String
    @State private var info: MangaSourceInfo?
    @State private var values: [String] = []
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.headerSpacing) {
                if let info {
                    MangaOptionRows(options: info.categoryOptions, info: info, values: $values)
                    MangaComicGrid(load: { cursor in
                        try await MangaRuntime.shared.category(source, name: category, param: param, options: values, cursor: cursor)
                    }, id: values.joined(separator: "|"))
                }
            }
            .padding(.vertical, Layout.gutter)
            .frame(maxWidth: Layout.maxWidth).frame(maxWidth: .infinity)
        }
        .background { Backdrop() }
        .screenTitle(title)
        .task {
            info = try? await MangaRuntime.shared.info(source)
            if values.isEmpty, let info { values = MangaOptionRows.defaults(info.categoryOptions) }
        }
    }
}

struct MangaRankingView: View {
    let source: String
    @State private var info: MangaSourceInfo?
    @State private var option = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.headerSpacing) {
                if let info {
                    #if os(tvOS)
                    ChipRow {
                        HStack(spacing: 10) {
                            ForEach(info.rankingOptions, id: \.value) { choice in
                                Chip(title: info.text(choice.text), selected: choice.value == option) { option = choice.value }
                            }
                        }
                    }
                    .padding(.horizontal, Layout.gutter)
                    #else
                    SourceStrip(items: info.rankingOptions.map { .init(id: $0.value, name: info.text($0.text)) }, selection: option) { option = $0 }
                        .padding(.horizontal, Layout.gutter)
                    #endif
                    if !option.isEmpty {
                        MangaComicGrid(load: { cursor in try await MangaRuntime.shared.ranking(source, option: option, cursor: cursor) }, id: option)
                    }
                }
            }
            .padding(.vertical, Layout.gutter)
            .frame(maxWidth: Layout.maxWidth).frame(maxWidth: .infinity)
        }
        .background { Backdrop() }
        .screenTitle(L10n.text("Ranking"))
        .task {
            info = try? await MangaRuntime.shared.info(source)
            if option.isEmpty { option = info?.rankingOptions.first?.value ?? "" }
        }
    }
}

// MARK: - Search

/// Searches every installed source at once: one shelf per source, best first.
struct MangaSearchView: View {
    @State private var store = MangaStore.shared
    @State private var query = ""
    @State private var submitted = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                if submitted.isEmpty {
                    EmptyResults(symbol: "magnifyingglass", title: L10n.text("Search Comics"),
                                 message: L10n.text("Searches all %d installed sources.", store.sources.count))
                } else {
                    ForEach(store.sources) { source in
                        MangaSearchShelf(source: source, keyword: submitted)
                    }
                }
            }
            .padding(.vertical, Layout.gutter)
            .frame(maxWidth: Layout.maxWidth).frame(maxWidth: .infinity)
        }
        .background { Backdrop() }
        .catalogSearchable(text: $query, prompt: L10n.text("Comic title or author"))
        .onSubmit(of: .search) { submitted = query.trimmingCharacters(in: .whitespacesAndNewlines) }
        #if os(tvOS)
        // The tvOS keyboard has no return key that submits: search as the text settles.
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(900))
            if !Task.isCancelled { submitted = query.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        #endif
        .screenTitle(L10n.text("Search Comics"))
        .task {
            #if DEBUG
            if let text = UserDefaults.standard.string(forKey: "qaMangaQuery"), submitted.isEmpty { query = text; submitted = text }
            #endif
        }
    }
}

private struct MangaSearchShelf: View {
    let source: MangaInstalledSource
    let keyword: String
    @State private var comics: [MangaComic]?
    @State private var failure: String?
    var body: some View {
        Group {
            if let comics, !comics.isEmpty {
                MangaShelfRow(title: source.name, comics: comics,
                              route: Route { [source, keyword] in AnyView(MangaSourceResults(source: source.key, keyword: keyword)) })
            } else if comics == nil, failure == nil {
                HStack(spacing: 10) { Text(source.name).font(.headline); ProgressView() }.padding(.horizontal, Layout.gutter)
            } else {
                HStack(spacing: 8) {
                    Text(source.name).font(.headline)
                    Text(failure ?? L10n.text("No results")).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, Layout.gutter)
            }
        }
        .task(id: keyword) {
            comics = nil; failure = nil
            do {
                let info = try await MangaRuntime.shared.info(source.key)
                guard info.canSearch else { comics = []; return }
                let page = try await MangaRuntime.shared.search(source.key, keyword: keyword, options: MangaOptionRows.defaults(info.searchOptions).map(Optional.some), cursor: nil)
                await MangaImages.shared.prepareCovers(source: source.key, urls: page.comics.map(\.cover))
                comics = page.comics
            } catch { failure = error.mangaMessage }
        }
    }
}

/// One source's search results, with its search options.
struct MangaSourceResults: View {
    let source: String
    let keyword: String
    @State private var info: MangaSourceInfo?
    @State private var values: [String] = []
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.headerSpacing) {
                if let info {
                    MangaOptionRows(options: info.searchOptions.filter { $0.type != "multi-select" }, info: info, values: $values)
                    MangaComicGrid(load: { cursor in
                        try await MangaRuntime.shared.search(source, keyword: keyword, options: values.map(Optional.some), cursor: cursor)
                    }, id: keyword + values.joined(separator: "|"))
                }
            }
            .padding(.vertical, Layout.gutter)
            .frame(maxWidth: Layout.maxWidth).frame(maxWidth: .infinity)
        }
        .background { Backdrop() }
        .screenTitle(keyword)
        .task {
            info = try? await MangaRuntime.shared.info(source)
            if values.isEmpty, let info { values = MangaOptionRows.defaults(info.searchOptions) }
        }
    }
}

// MARK: - Library

struct MangaLibraryView: View {
    enum Kind { case favorites, history }
    let kind: Kind
    @State private var store = MangaStore.shared
    var body: some View {
        ScrollView {
            LazyVGrid(columns: MangaLayout.columns, alignment: .leading, spacing: Layout.gridRowSpacing) {
                switch kind {
                case .favorites:
                    ForEach(store.favorites) { favorite in
                        MangaComicLink(comic: favorite.comic, showsSource: true)
                            .contextMenu { Button(L10n.text("Remove from Favorites"), systemImage: "heart.slash", role: .destructive) { store.toggleFavorite(favorite.comic) } }
                    }
                case .history:
                    ForEach(store.history) { progress in
                        MangaComicLink(comic: progress.comic, caption: MangaProgressText.short(progress))
                            .contextMenu { Button(L10n.text("Remove from History"), systemImage: "trash", role: .destructive) { store.forget(progress) } }
                    }
                }
            }
            .padding(Layout.gutter)
            .frame(maxWidth: Layout.maxWidth).frame(maxWidth: .infinity)
        }
        .background { Backdrop() }
        .screenTitle(kind == .favorites ? L10n.text("Favorites") : L10n.text("Continue Reading"))
        #if !os(tvOS)
        .toolbar {
            if kind == .history, !store.history.isEmpty {
                Button(L10n.text("Clear"), role: .destructive) { store.clearHistory() }
            }
        }
        #endif
    }
}

enum MangaProgressText {
    static func short(_ progress: MangaLibrary.Progress) -> String {
        let page = L10n.text("p. %d", progress.page + 1)
        return progress.chapterTitle.isEmpty ? page : "\(progress.chapterTitle) · \(page)"
    }
}

/// Wrapping rows of chips.
struct MangaFlow: SwiftUI.Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }
    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (items: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.items.isEmpty, current.width + spacing + size.width > width { rows.append(current); current = ([], 0, 0) }
            current.width += (current.items.isEmpty ? 0 : spacing) + size.width
            current.height = max(current.height, size.height)
            current.items.append(index)
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}

#if !os(tvOS)
/// The switch beside the source, as Watch Now's: another installed source (they are managed in Settings).
private struct MangaSourceSwitch: View {
    @State private var store = MangaStore.shared
    var body: some View {
        Menu {
            Picker(L10n.text("Comic Sources"), selection: Binding(get: { store.currentSource?.key ?? "" }, set: { store.selectedSource = $0 })) {
                ForEach(store.sources) { Text($0.name).tag($0.key) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.left.arrow.right").font(.subheadline.weight(.semibold))
                .frame(width: SourceStrip.controlSize, height: SourceStrip.controlSize)
                .glassOrFill(.regular.interactive(), Color.primary.opacity(0.06), in: Circle())
                .contentShape(Circle())
        }
        .menuStyle(.button).buttonStyle(.plain).tint(.primary)
        .accessibilityLabel(L10n.text("Comic Sources"))
        .accessibilityIdentifier("manga.source.switch")
    }
}
#endif

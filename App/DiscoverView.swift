import SwiftUI
import TVCore

/// Catalog browsing is independent of the subscription; opening a title can search the viewer's sources.
@MainActor @Observable private final class DiscoverModel {
    private(set) var pages: [TMDBCatalog.Feed: TMDBCatalog.Page] = [:]
    private(set) var failures = Set<TMDBCatalog.Feed>()
    private(set) var collections: TMDBCatalog.Collections?
    private(set) var collectionsFailed = false
    private(set) var loading = false
    static let feeds: [TMDBCatalog.Feed] = [.trending, .nowPlaying, .onTheAir, .variety, .chinese, .animation, .topMovies, .topTelevision, .family, .kids, .netflix, .disney, .appleTV, .hbo, .warner, .universal, .paramount, .sony]
    func items(_ feed: TMDBCatalog.Feed) -> [TMDBCatalog.Item] { pages[feed]?.items ?? [] }

    func load(refresh: Bool = false) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let pending = Self.feeds.filter { refresh || pages[$0] == nil }
        async let metadata = try? TMDBCatalog.collections()
        await withTaskGroup(of: (TMDBCatalog.Feed, TMDBCatalog.Page?).self) { group in
            for feed in pending {
                group.addTask { (feed, try? await TMDBCatalog.page(feed)) }
            }
            for await (feed, page) in group {
                guard !Task.isCancelled else { continue }
                if let page { pages[feed] = page; failures.remove(feed) }
                else { failures.insert(feed) }
            }
        }
        let fresh = await metadata
        if !Task.isCancelled {
            if let fresh { collections = fresh; collectionsFailed = false }
            else { collectionsFailed = true }
        }
    }
}

/// Catalog layout: a 1.5:1 portrait hero, 17 pt gutters,
/// 116 × 174 pt covers, and a wider landscape rail for the weekly trend list.
struct DiscoverView: View {
    @State private var model = DiscoverModel()
    @State private var heroState = DiscoverHeroState()
    @State private var onScreen = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var editing = false
    @State private var searchShown = false
    @AppStorage("discover.hiddenSections") private var hiddenSections = ""
    private var featured: [TMDBCatalog.Item] { Array(model.items(.trending).filter { $0.poster != nil }.prefix(8)) }
    var body: some View {
        GeometryReader { proxy in
            let heroHeight = proxy.size.width < 600 ? proxy.size.width * 1.5 : min(720, proxy.size.width * 0.65)
            ZStack(alignment: .top) {
                DiscoverHeroBackground(state: heroState, items: featured, width: proxy.size.width, height: heroHeight,
                                       active: onScreen && scenePhase == .active)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 30) {
                        if featured.isEmpty, model.loading {
                            ProgressView().frame(maxWidth: .infinity).frame(height: min(proxy.size.width * 1.5, 660))
                        }
                        ForEach(DiscoverSection.allCases.filter { !hiddenSections.split(separator: ",").contains(Substring($0.rawValue)) }) { section in
                            sectionView(section, width: proxy.size.width)
                        }
                        if !model.failures.isEmpty || model.collectionsFailed {
                            Button { Task { await model.load() } } label: {
                                Label(L10n.text("Some lists couldn't load. Try again."), systemImage: "arrow.clockwise")
                                    .font(.subheadline).frame(maxWidth: .infinity).padding()
                            }.buttonStyle(.plain).accessibilityIdentifier("discover.retry")
                        }
                        if !model.loading, model.pages.values.allSatisfy({ $0.items.isEmpty }) {
                            ContentUnavailableView(L10n.text("No Titles Available"), systemImage: "film",
                                                   description: Text(L10n.text("Please try again later.")))
                        }
                        Button { editing = true } label: {
                            Label(L10n.text("Edit Layout"), systemImage: "slider.horizontal.3")
                                .font(.subheadline).padding(18).glassSurface(.regular, in: Capsule())
                        }.buttonStyle(.plain).frame(maxWidth: .infinity).padding(.top, 10)
                        HStack(spacing: 8) {
                            TMDBBadge()
                            Text(L10n.text("This product uses the TMDB API but is not endorsed or certified by TMDB."))
                                .font(.caption2).foregroundStyle(.white.opacity(0.5))
                        }.padding(.horizontal, 17).padding(.vertical, 20)
                    }
                    .padding(.bottom, 28)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: DiscoverScrollKey.self, value: -geometry.frame(in: .named("discoverScroll")).minY)
                        }
                    }
                }
                .coordinateSpace(name: "discoverScroll")
                .modifier(DiscoverScrollObserver(offset: Binding(get: { heroState.scrollY }, set: { heroState.scrollY = $0 })))
                .scrollIndicators(.hidden)
                .refreshable { await model.load(refresh: true) }
            }
        }
        .modifier(DiscoverHeroTheme(state: heroState))
        .navigationTitle("")
        #if !os(macOS)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(heroState.paint?.isDark == false ? .light : .dark, for: .navigationBar)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { searchShown = true } label: { Image(systemName: "text.magnifyingglass") }
                    .accessibilityLabel(L10n.text("Search Catalog"))
                    .accessibilityIdentifier("discover.home.search")
            }
        }
        .modifier(DiscoverSearchPresentation(isPresented: $searchShown))
        .ignoresSafeArea(edges: .top)
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .task { await model.load() }
        .sheet(isPresented: $editing) {
            NavigationStack {
                Form {
                    ForEach(DiscoverSection.allCases) { section in
                        Toggle(section.title, isOn: Binding(get: {
                            !hiddenSections.split(separator: ",").contains(Substring(section.rawValue))
                        }, set: { shown in
                            var hidden = Set(hiddenSections.split(separator: ",").map(String.init))
                            if shown { hidden.remove(section.rawValue) } else { hidden.insert(section.rawValue) }
                            hiddenSections = hidden.sorted().joined(separator: ",")
                        }))
                    }
                }
                .navigationTitle(L10n.text("Edit Layout"))
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { editing = false } } }
            }.preferredColorScheme(.dark).discoverSheetSize(width: 420, height: 560)
        }
    }

    @ViewBuilder private func sectionView(_ section: DiscoverSection, width: CGFloat) -> some View {
        switch section {
        case .hero: if !featured.isEmpty { DiscoverHeroCarousel(items: featured, state: heroState, width: width).padding(.bottom, -15) }
        case .nowPlaying: shelf(.nowPlaying)
        case .onTheAir: shelf(.onTheAir)
        case .trending: shelf(.trending, landscape: true)
        case .collections: collections(width: width)
        case .animation: shelf(.animation)
        case .people: people
        case .networks: brands(model.collections?.networks ?? [], title: section.title, width: 302)
        case .genres: genreCards
        case .rankings: rankings(width: width)
        case .companies: brands(model.collections?.companies ?? [], title: section.title, width: 197)
        }
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title).font(.system(size: 16, weight: .semibold))
            .frame(maxWidth: .infinity, alignment: .leading).frame(height: 32, alignment: .top)
            .padding(.horizontal, 17)
    }

    @ViewBuilder private var people: some View {
        if let people = model.collections?.people, !people.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeading(L10n.text("People"))
                DiscoverRail(arrowCenter: 41.5) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(people) { person in
                            RouteLink {
                                DiscoverPersonView(id: person.id, name: person.name, profile: person.profile)
                            } label: {
                                VStack(spacing: 7) {
                                    PosterImage(url: person.profile, symbol: "person.fill").frame(width: 83, height: 83).clipShape(Circle())
                                    Text(person.name).font(.system(size: 13)).lineLimit(1)
                                }.frame(width: 83)
                            }.tmdbCardButton()
                        }
                    }.padding(.horizontal, 17)
                }
            }
        }
    }

    @ViewBuilder private func brands(_ brands: [TMDBCatalog.Brand], title: String, width: CGFloat) -> some View {
        if !brands.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeading(title)
                DiscoverRail {
                    LazyHStack(spacing: 13) {
                        ForEach(brands) { brand in
                            RouteLink { DiscoverBrowseView(title: brand.name, filter: brand.feed.brandFilter, logo: brand.logo) } label: {
                                DiscoverBrandCard(brand: brand, items: Array(model.items(brand.feed).prefix(4)), width: width)
                            }.tmdbCardButton().accessibilityLabel(brand.name)
                        }
                    }.padding(.horizontal, 17)
                }
            }
        }
    }

    private var genreCards: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeading(L10n.text("Browse by Genre"))
            DiscoverRail {
                HStack(spacing: 13) {
                    ForEach([TMDBCatalog.Feed.family, .animation, .kids], id: \.self) { feed in
                        RouteLink { DiscoverBrowseView(title: feed.title, filter: .genre(feed == .family ? 10751 : feed == .kids ? 10762 : 16, type: feed == .family ? .movie : .tv)) } label: {
                            HStack(spacing: 15) {
                                ZStack {
                                    ForEach(Array(model.items(feed).prefix(3).enumerated()).reversed(), id: \.element.key) { index, item in
                                        PosterImage(url: item.poster).frame(width: 49, height: 73).clipShape(RoundedRectangle(cornerRadius: 6))
                                            .rotationEffect(.degrees(Double(index) * 5)).offset(x: CGFloat(index) * 9)
                                    }
                                }.frame(width: 72, height: 80)
                                Text(feed.title).font(.system(size: 19, weight: .semibold))
                            }
                            .frame(width: 197, height: 92).background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 22))
                        }.tmdbCardButton()
                    }
                }.padding(.horizontal, 17)
            }
        }
    }

    private func rankings(width: CGFloat) -> some View {
        DiscoverRail {
            HStack(spacing: 13) {
                ForEach([TMDBCatalog.Feed.topTelevision, .topMovies], id: \.self) { feed in
                    RouteLink { DiscoverListView(feed: feed, initial: model.pages[feed]) } label: {
                        DiscoverRankingCard(feed: feed, items: Array(model.items(feed).prefix(15)), width: min(width - 33, 520))
                    }.tmdbCardButton()
                }
            }.padding(.horizontal, 17)
        }
    }

    @ViewBuilder private func shelf(_ feed: TMDBCatalog.Feed, landscape: Bool = false) -> some View {
        let items = model.items(feed)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                RouteLink { DiscoverListView(feed: feed, initial: model.pages[feed]) } label: {
                    HStack {
                        Text(feed.title).font(.system(size: 16, weight: .semibold))
                        Spacer()
                        Image(systemName: "chevron.forward").font(.system(size: 14, weight: .semibold))
                    }.frame(height: 32, alignment: .top).contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.horizontal, 17)
                .accessibilityIdentifier("discover.more.\(feed.rawValue)")
                DiscoverRail(arrowCenter: landscape ? 50 : 87) {
                    LazyHStack(alignment: .top, spacing: 13) {
                        ForEach(items, id: \.key) { item in
                            RouteLink { DiscoverDetailView(item: item) } label: {
                                DiscoverTile(item: item, landscape: landscape)
                                    .frame(width: landscape ? 177 : 116)
                            }
                            .tmdbCardButton()
                            .accessibilityIdentifier("discover.title.\(feed.rawValue).\(item.key)")
                        }
                    }.padding(.horizontal, 17)
                    #if os(tvOS)
                    .padding(.vertical, 20)
                    #endif
                }
            }
        }
    }

    @ViewBuilder private func collections(width: CGFloat) -> some View {
        let feeds: [TMDBCatalog.Feed] = [.variety, .chinese]
        if feeds.contains(where: { !model.items($0).isEmpty }) {
            DiscoverRail {
                HStack(spacing: 13) {
                    ForEach(feeds, id: \.self) { feed in
                        if !model.items(feed).isEmpty {
                            DiscoverCollection(feed: feed, items: Array(model.items(feed).prefix(8)))
                                .frame(width: min(width - 33, 520))
                        }
                    }
                }.padding(.horizontal, 17)
            }
        }
    }
}

/// Interaction state is read only by the hero and its background. A scroll offset or page
/// change must not re-evaluate all of the poster rails and their navigation destinations.
@MainActor @Observable private final class DiscoverHeroState {
    var id: String?
    var scrollY: CGFloat = 0
    var details: [String: TMDBMatch.Details] = [:]
    var paints: [String: DiscoverPaint] = [:]
    var firstKey: String?
    var pageProgress: CGFloat = 0
    var dragging = false
    var paint: DiscoverPaint? { paints[id ?? firstKey ?? ""] ?? paints[firstKey ?? ""] }
    var trailer: TMDBMatch.Trailer? { details[id ?? firstKey ?? ""]?.trailer }
}

private struct DiscoverHeroTheme: ViewModifier {
    let state: DiscoverHeroState
    func body(content: Content) -> some View {
        content.foregroundStyle(state.paint?.isDark == false ? Color.black : Color.white)
            .environment(\.colorScheme, state.paint?.isDark == false ? .light : .dark)
    }
}

private struct DiscoverHeroBackground: View {
    let state: DiscoverHeroState
    let items: [TMDBCatalog.Item]
    let width: CGFloat
    let height: CGFloat
    let active: Bool
    var body: some View {
        Group {
            if state.dragging, !items.isEmpty {
                let position = min(max(state.pageProgress, 0), CGFloat(items.count - 1))
                let first = Int(position.rounded(.down))
                let next = min(first + 1, items.count - 1)
                let mix = position - CGFloat(first)
                ZStack {
                    DiscoverBackdrop(paint: state.paints[items[first].key] ?? state.paint, width: width, heroHeight: height, scrollY: state.scrollY,
                                     trailer: nil, playsTrailer: false)
                    DiscoverBackdrop(paint: state.paints[items[next].key] ?? state.paint, width: width, heroHeight: height, scrollY: state.scrollY,
                                     trailer: nil, playsTrailer: false).opacity(mix)
                }
            } else {
                DiscoverBackdrop(paint: state.paint, width: width, heroHeight: height, scrollY: state.scrollY,
                                 trailer: state.trailer, playsTrailer: active && state.scrollY < height * 0.35)
            }
        }
            .task(id: items.first?.key) {
                state.firstKey = items.first?.key
                // A small bounded warm-up runs outside the main actor. Cache logos and processed
                // covers before a swipe so the drag itself performs no image decode or network work.
                await withTaskGroup(of: (String, TMDBMatch.Details?, DiscoverPaint?).self) { group in
                    var remaining = items.makeIterator()
                    func enqueue(_ item: TMDBCatalog.Item) {
                        group.addTask {
                            let details = try? await TMDBMatch.details(item.mediaType, id: item.id, season: nil)
                            let url = details?.heroPoster ?? item.poster
                            let paint = if let url { await DiscoverPainter.shared.paint(url) } else { nil as DiscoverPaint? }
                            return (item.key, details, paint)
                        }
                    }
                    for _ in 0..<2 { if let item = remaining.next() { enqueue(item) } }
                    for await (key, details, paint) in group {
                        guard !Task.isCancelled else { group.cancelAll(); break }
                        if let details { state.details[key] = details }
                        if let paint { state.paints[key] = paint }
                        if let item = remaining.next() { enqueue(item) }
                    }
                }
            }
    }
}

private struct DiscoverHeroCarousel: View {
    let items: [TMDBCatalog.Item]
    let state: DiscoverHeroState
    let width: CGFloat
    #if os(macOS)
    @State private var hovering = false
    #endif
    var body: some View {
        let height = width < 600 ? width * 1.5 : min(720, width * 0.65)
        let selectedID = state.id ?? items.first?.key
        ZStack(alignment: .bottom) {
            #if os(iOS)
            DiscoverNativeHeroPager(items: items, details: state.details, dark: state.paint?.isDark ?? true, selection: Binding(get: { selectedID }, set: { state.id = $0 }),
                                    progress: { state.pageProgress = $0 }, dragging: { state.dragging = $0 })
            #elseif os(macOS)
            // One title at a time: in the split view's detail a horizontal scroll view takes the sidebar's width as
            // a content inset, which shifted every page. The arrows and the dots move between titles.
            let index = items.firstIndex { $0.key == selectedID } ?? 0
            RouteLink { DiscoverDetailView(item: items[index]) } label: {
                DiscoverHero(item: items[index], details: state.details[items[index].key])
                    .frame(width: width, height: height)
            }
            .buttonStyle(.plain).id(items[index].key).transition(.opacity)
            .accessibilityIdentifier("discover.hero.\(items[index].key)")
            .overlay {
                HStack {
                    heroArrow("chevron.left", label: L10n.text("Previous"), to: index - 1)
                    Spacer()
                    heroArrow("chevron.right", label: L10n.text("Next"), to: index + 1)
                }.padding(.horizontal, 20).opacity(hovering ? 1 : 0).animation(.easeOut(duration: 0.2), value: hovering)
            }
            .onHover { hovering = $0 }
            #else
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(items, id: \.key) { item in
                        RouteLink { DiscoverDetailView(item: item) } label: {
                            DiscoverHero(item: item, details: state.details[item.key])
                                .frame(width: width, height: height)
                        }
                        .buttonStyle(.plain).id(item.key)
                        .accessibilityIdentifier("discover.hero.\(item.key)")
                    }
                }.scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: Binding(get: { state.id ?? items.first?.key }, set: { state.id = $0 }))
            .scrollIndicators(.hidden)
            #endif
            #if os(iOS)
            DiscoverPageControl(count: items.count, selection: Binding(get: {
                items.firstIndex { $0.key == (state.id ?? items.first?.key) } ?? 0
            }, set: { index in
                guard items.indices.contains(index) else { return }
                state.dragging = true
                withAnimation(.easeInOut(duration: 0.35)) { state.id = items[index].key }
            })).frame(height: 24).padding(.bottom, 0)
            #else
            HStack(spacing: 8) {
                ForEach(items, id: \.key) { item in
                    Button {
                        withAnimation(.easeInOut(duration: 0.35)) { state.id = item.key }
                    } label: {
                        Circle().fill(Color.primary.opacity(item.key == (state.id ?? items.first?.key) ? 1 : 0.3))
                            .frame(width: 7, height: 7).frame(width: 18, height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.name)
                    .accessibilityIdentifier("discover.pageDot.\(item.key)")
                    .accessibilityAddTraits(item.key == (state.id ?? items.first?.key) ? [.isSelected] : [])
                }
            }.padding(.bottom, 0)
            #endif
        }
        .frame(height: height)
    }

    #if os(macOS)
    private func heroArrow(_ symbol: String, label: String, to index: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.35)) { state.id = items[(index + items.count) % items.count].key }
        } label: {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44).glassSurface(.regular, in: Circle())
        }.buttonStyle(.plain).accessibilityLabel(label)
    }
    #endif
}

#if os(iOS)
/// Native paging keeps touch tracking and deceleration in UIKit. Cells and destinations stay
/// stable while the finger moves; SwiftUI receives only the final selection and backdrop progress.
private struct DiscoverNativeHeroPager: UIViewRepresentable {
    @Environment(\.openRoute) private var openRoute
    let items: [TMDBCatalog.Item]
    let details: [String: TMDBMatch.Details]
    let dark: Bool
    @Binding var selection: String?
    let progress: (CGFloat) -> Void
    let dragging: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0; layout.minimumInteritemSpacing = 0
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear; view.isPagingEnabled = true
        view.isDirectionalLockEnabled = true; view.decelerationRate = .fast
        view.showsHorizontalScrollIndicator = false
        view.contentInsetAdjustmentBehavior = .never
        view.dataSource = context.coordinator; view.delegate = context.coordinator
        view.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "hero")
        return view
    }
    func updateUIView(_ view: UICollectionView, context: Context) {
        let previous = context.coordinator.parent
        context.coordinator.parent = self
        if previous.items != items || previous.details != details || previous.dark != dark { context.coordinator.needsReload = true }
        guard !view.isDragging, !view.isDecelerating else { return }
        if context.coordinator.needsReload { context.coordinator.needsReload = false; view.reloadData() }
        if let selection, let index = items.firstIndex(where: { $0.key == selection }), view.bounds.width > 0 {
            let target = CGFloat(index) * view.bounds.width
            if abs(view.contentOffset.x - target) > 1 {
                dragging(true)
                view.setContentOffset(CGPoint(x: target, y: 0), animated: context.transaction.animation != nil)
                if context.transaction.animation == nil { context.coordinator.finish(view) }
            }
        }
    }
    @MainActor final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
        var parent: DiscoverNativeHeroPager
        var needsReload = false
        init(_ parent: DiscoverNativeHeroPager) { self.parent = parent }
        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { parent.items.count }
        func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize { collectionView.bounds.size }
        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "hero", for: indexPath)
            let item = parent.items[indexPath.item]
            let details = parent.details[item.key]
            let open = parent.openRoute
            let dark = parent.dark
            cell.backgroundColor = .clear
            cell.contentConfiguration = UIHostingConfiguration {
                Button { open?(Route { AnyView(DiscoverDetailView(item: item)) }) } label: {
                    DiscoverHero(item: item, details: details).frame(maxWidth: .infinity, maxHeight: .infinity)
                }.buttonStyle(.plain).foregroundStyle(dark ? Color.white : Color.black)
                    .accessibilityIdentifier("discover.hero.\(item.key)")
            }.margins(.all, 0)
            return cell
        }
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { parent.dragging(true) }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard scrollView.bounds.width > 0 else { return }
            parent.progress(scrollView.contentOffset.x / scrollView.bounds.width)
        }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { finish(scrollView) }
        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { finish(scrollView) }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { finish(scrollView) } }
        func finish(_ scrollView: UIScrollView) {
            guard scrollView.bounds.width > 0, !parent.items.isEmpty else { parent.dragging(false); return }
            let index = min(max(Int((scrollView.contentOffset.x / scrollView.bounds.width).rounded()), 0), parent.items.count - 1)
            parent.selection = parent.items[index].key
            parent.dragging(false)
            if needsReload, let view = scrollView as? UICollectionView { needsReload = false; view.reloadData() }
        }
    }
}

private struct DiscoverPageControl: UIViewRepresentable {
    let count: Int
    @Binding var selection: Int
    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }
    func makeUIView(context: Context) -> UIPageControl {
        let view = UIPageControl()
        view.numberOfPages = count
        view.pageIndicatorTintColor = UIColor.label.withAlphaComponent(0.3)
        view.currentPageIndicatorTintColor = .label
        view.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        view.accessibilityIdentifier = "discover.pageControl"
        return view
    }
    func updateUIView(_ view: UIPageControl, context: Context) {
        context.coordinator.selection = $selection
        view.numberOfPages = count
        view.currentPage = selection
    }
    @MainActor final class Coordinator: NSObject {
        var selection: Binding<Int>
        init(selection: Binding<Int>) { self.selection = selection }
        @objc func changed(_ sender: UIPageControl) { selection.wrappedValue = sender.currentPage }
    }
}
#endif

private struct DiscoverCanvas: View {
    let poster: URL?
    @State private var paint: DiscoverPaint?
    var body: some View {
        (paint?.color ?? Color(white: 0.06))
            .overlay(.black.opacity(0.4)).discoverFullBleed()
            .task(id: poster) {
                guard let poster else { return }
                let value = await DiscoverPainter.shared.paint(poster)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.4)) { paint = value }
            }
    }
}

/// A horizontal rail. On the Mac, where a mouse wheel scrolls only up and down, it is a `ScrollStrip`: it can be
/// dragged like a swipe, and arrows float over its ends, centred `arrowCenter` from the top (the middle of the
/// artwork rather than of artwork and caption).
struct DiscoverRail<Content: View>: View {
    var arrowCenter: CGFloat? = nil
    @ViewBuilder let content: Content
    var body: some View {
        #if os(macOS)
        ScrollStrip(leftLabel: "Previous", rightLabel: "Next", overlayArrows: true, arrowCenter: arrowCenter) { content }
        #else
        ScrollView(.horizontal) { content }.scrollIndicators(.hidden)
        #endif
    }
}

/// A button in a rail. On the Mac the card under the pointer gets the mouse-up that ends a drag, which must not
/// press it.
struct DiscoverButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Label
    @Environment(\.stripDrag) private var drag
    var body: some View { Button { if drag?.active != true { action() } } label: { label } }
}

private struct DiscoverScrollKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct DiscoverScrollObserver: ViewModifier {
    @Binding var offset: CGFloat
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18, macOS 15, tvOS 18, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, value in offset = value }
        } else {
            content.onPreferenceChange(DiscoverScrollKey.self) { offset = $0 }
        }
    }
}

private struct DiscoverHero: View {
    let item: TMDBCatalog.Item
    let details: TMDBMatch.Details?
    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Group {
                    if let logo = details?.logo {
                        TMDBArtwork(url: logo, maxPixels: 1000, fill: false)
                            .accessibilityLabel(item.name)
                    } else {
                        Text(item.name).font(.system(size: 40, weight: .semibold))
                            .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.6)
                    }
                }
                .frame(width: proxy.size.width * 0.8, height: 145, alignment: .bottom)
                .padding(.bottom, 15)
                Text([details?.genres.prefix(2).joined(separator: " / ") ?? item.genreNames,
                      details?.date ?? item.year.map(String.init) ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 14)).lineLimit(1).frame(height: 17)
                Text("「\(item.name)」" + item.overview)
                    .font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.center)
                    .frame(height: 29, alignment: .top).padding(.top, 5)
                HStack(spacing: 4) {
                    if let rating = item.rating {
                        TMDBBadge()
                        Text(rating, format: .number.precision(.fractionLength(1))).font(.system(size: 11))
                    }
                }.frame(height: 14).padding(.top, 5)
            }
            .padding(.horizontal, 30).padding(.bottom, 42)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .combine)
    }
}

struct DiscoverTile: View {
    let item: TMDBCatalog.Item
    var landscape = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.aspectRatio(landscape ? 16.0 / 9 : 2.0 / 3, contentMode: .fit)
                .overlay { PosterImage(url: landscape ? item.backdrop ?? item.poster : item.poster) }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5) }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.system(size: 13)).lineLimit(1)
                HStack(spacing: 5) {
                    if let year = item.year { Text(String(year)) }
                    if landscape, !item.genreNames.isEmpty { Text(item.genreNames).lineLimit(1) }
                }.font(.system(size: 11, design: .rounded)).foregroundStyle(.primary.opacity(0.56))
            }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 46)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Scale the 450-point editorial composition as a unit to preserve its proportions across phones.
private struct DiscoverCollection: View {
    let feed: TMDBCatalog.Feed
    let items: [TMDBCatalog.Item]
    @State private var paint: DiscoverPaint?
    var body: some View {
        GeometryReader { proxy in
            let scale = proxy.size.width / 450
            VStack(alignment: .leading, spacing: 0) {
                RouteLink { DiscoverListView(feed: feed, initial: nil) } label: {
                    ZStack(alignment: .bottom) {
                        PosterImage(url: items.first?.backdrop ?? items.first?.poster)
                        LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                        HStack(spacing: 12) {
                            Image(systemName: "laurel.leading").font(.system(size: 38))
                            VStack(spacing: 4) {
                                Text(feed.collectionTitle).font(.system(size: 34, weight: .semibold))
                                Text(items.first?.name ?? "").font(.system(size: 14)).opacity(0.8)
                            }
                            Image(systemName: "laurel.trailing").font(.system(size: 38))
                        }.padding(.horizontal, 16).padding(.bottom, 24)
                    }.frame(width: 450, height: 270).clipped()
                }.buttonStyle(.plain)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 27.5) {
                        ForEach(items, id: \.key) { item in
                            RouteLink { DiscoverDetailView(item: item) } label: {
                                DiscoverTile(item: item, landscape: true).frame(width: 160)
                            }.tmdbCardButton()
                        }
                    }.padding(.horizontal, 20).padding(.top, 20)
                }.scrollIndicators(.hidden).frame(height: 180, alignment: .top)
            }
            .frame(width: 450, height: 450)
            .background(paint?.color ?? Color(white: 0.12))
            .foregroundStyle(.white)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: proxy.size.width, height: proxy.size.width, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5) }
        }.aspectRatio(1, contentMode: .fit)
        .task(id: items.first?.poster) {
            if let url = items.first?.poster { paint = await DiscoverPainter.shared.paint(url) }
        }
    }
}

private struct DiscoverBrandCard: View {
    let brand: TMDBCatalog.Brand
    let items: [TMDBCatalog.Item]
    let width: CGFloat
    var body: some View {
        ZStack(alignment: .trailing) {
            Color(white: 0.06)
            if let url = items.first?.backdrop {
                TMDBArtwork(url: url, maxPixels: 100).blur(radius: 28).opacity(0.3)
            }
            HStack(spacing: 8) {
                ForEach(items, id: \.key) { item in
                    PosterImage(url: item.poster).frame(width: width * 0.21, height: width * 0.44)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.15), lineWidth: 0.5) }
                }
            }.rotationEffect(.degrees(16)).offset(x: width * 0.38, y: 6)
            LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .leading, endPoint: .trailing)
            HStack {
                AsyncImage(url: brand.logo) { phase in
                    if let image = phase.image { image.renderingMode(.template).resizable().scaledToFit() }
                    else { Text(brand.name).font(.system(size: 24, weight: .semibold)) }
                }.frame(width: width * 0.44, height: 64)
                Spacer(minLength: 0)
            }.padding(.leading, 20)
        }
        .frame(width: width, height: width == 302 ? 144.667 : 92)
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5) }
    }
}

private struct DiscoverRankingCard: View {
    let feed: TMDBCatalog.Feed
    let items: [TMDBCatalog.Item]
    let width: CGFloat
    var body: some View {
        ZStack(alignment: .bottom) {
            Color(white: 0.1)
            HStack(alignment: .top, spacing: width * 0.025) {
                ForEach(0..<5) { column in
                    VStack(spacing: width * 0.025) {
                        ForEach(Array(items.enumerated()).filter { $0.offset % 5 == column }, id: \.element.key) { _, item in
                            PosterImage(url: item.poster).frame(width: width * 0.215, height: width * 0.3225)
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                    }.offset(y: column.isMultiple(of: 2) ? -width * 0.1 : -width * 0.22)
                }
            }.frame(width: width, height: width, alignment: .top)
            LinearGradient(stops: [.init(color: .clear, location: 0.4), .init(color: .black.opacity(0.85), location: 0.88)], startPoint: .top, endPoint: .bottom)
            Text(feed.title).font(.system(size: 31, weight: .semibold)).padding(.bottom, 28)
        }
        .frame(width: width, height: width).foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 0.5) }
    }
}

private struct DiscoverListView: View {
    let feed: TMDBCatalog.Feed
    let initial: TMDBCatalog.Page?
    @State private var items: [TMDBCatalog.Item] = []
    @State private var page = 0
    @State private var totalPages = 1
    @State private var loading = false
    @State private var failed = false
    init(feed: TMDBCatalog.Feed, initial: TMDBCatalog.Page?) {
        self.feed = feed; self.initial = initial
        _items = State(initialValue: initial?.items ?? [])
        _page = State(initialValue: initial?.page ?? 0)
        _totalPages = State(initialValue: initial?.totalPages ?? 1)
    }
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 13)], alignment: .leading, spacing: 22) {
                ForEach(items, id: \.key) { item in
                    RouteLink { DiscoverDetailView(item: item) } label: { DiscoverTile(item: item) }.tmdbCardButton()
                        .accessibilityIdentifier("discover.list.title.\(item.key)")
                        .task {
                            if item.key == items.last?.key { await loadMore() }
                        }
                }
            }.padding(17)
            if failed {
                Button(L10n.text("Try Again")) { Task { await loadMore() } }.padding()
            } else if loading {
                ProgressView().padding()
            } else if page < totalPages {
                Button(L10n.text("More")) { Task { await loadMore() } }.padding()
                    .accessibilityIdentifier("discover.loadMore")
            }
        }
        .background { DiscoverCanvas(poster: items.first?.poster) }
        .foregroundStyle(.white).preferredColorScheme(.dark)
        .navigationTitle(feed.title)
        .task {
            if items.isEmpty { await loadMore() }
        }
    }
    private func loadMore() async {
        guard !loading, page < totalPages else { return }
        loading = true; failed = false
        defer { loading = false }
        do {
            let result = try await TMDBCatalog.page(feed, page: page + 1)
            guard !Task.isCancelled else { return }
            var seen = Set(items.map(\.key))
            items += result.items.filter { seen.insert($0.key).inserted }
            page = result.page; totalPages = result.totalPages
        } catch { if !Task.isCancelled { failed = true } }
    }
}

private extension TMDBCatalog.Feed {
    var title: String {
        switch self {
        case .trending: L10n.text("Trending This Week")
        case .nowPlaying: L10n.text("In Theaters")
        case .onTheAir: L10n.text("On the Air")
        case .animation: L10n.text("Popular Animation")
        case .movies: L10n.text("Popular Movies")
        case .television: L10n.text("Popular TV Shows")
        case .topMovies: L10n.text("Top Rated Movies")
        case .topTelevision: L10n.text("Top Rated TV Shows")
        case .upcoming: L10n.text("Coming Soon")
        case .chinese: L10n.text("Chinese TV Shows")
        case .korean: L10n.text("Korean TV Shows")
        case .variety: L10n.text("Variety Shows")
        case .family: L10n.text("Family")
        case .kids: L10n.text("Kids")
        case .netflix: "Netflix"
        case .disney: "Disney+"
        case .appleTV: "Apple TV+"
        case .hbo: "HBO"
        case .warner: "Warner Bros."
        case .universal: "Universal"
        case .paramount: "Paramount"
        case .sony: "Sony Pictures"
        }
    }
    var collectionTitle: String {
        self == .variety ? L10n.text("Popular Variety Shows") : L10n.text("Popular Chinese Dramas")
    }
}

private enum DiscoverSection: String, CaseIterable, Identifiable {
    case hero, nowPlaying, onTheAir, trending, collections, animation, people, networks, genres, rankings, companies
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hero: L10n.text("Featured Titles")
        case .nowPlaying: L10n.text("In Theaters")
        case .onTheAir: L10n.text("On the Air")
        case .trending: L10n.text("Trending This Week")
        case .collections: L10n.text("Featured Collections")
        case .animation: L10n.text("Popular Animation")
        case .people: L10n.text("People")
        case .networks: L10n.text("Networks")
        case .genres: L10n.text("Browse by Genre")
        case .rankings: L10n.text("Top Rated Collections")
        case .companies: L10n.text("Film Studios")
        }
    }
}

extension TMDBCatalog.Item {
    var genreNames: String { genreIDs.prefix(2).compactMap { DiscoverGenres.names[$0] }.map { L10n.text($0) }.joined(separator: " / ") }
}

enum DiscoverGenres {
    static func ids(for kind: TMDBCatalog.SearchKind) -> [Int] {
        kind == .tv ? [10759,16,35,80,99,18,10751,10762,9648,10763,10764,10765,10766,10767,10768,37]
            : [28,12,16,35,80,99,18,10751,14,36,27,10402,9648,10749,878,10770,53,10752,37]
    }

    static let names = [28: "Action", 12: "Adventure", 16: "Animation", 35: "Comedy", 80: "Crime", 99: "Documentary",
                        18: "Drama", 10751: "Family", 14: "Fantasy", 36: "Historical", 27: "Horror", 10402: "Music",
                        9648: "Mystery", 10749: "Romance", 878: "Science Fiction", 53: "Thriller", 10752: "War", 37: "Western",
                        10759: "Action & Adventure", 10762: "Kids", 10763: "News", 10764: "Reality", 10765: "Sci-Fi & Fantasy", 10767: "Talk", 10770: "TV Movie", 10766: "Soap", 10768: "War & Politics"]
}

private extension TMDBMatch.SearchResult {
    var catalogItem: TMDBCatalog.Item {
        // Both server responses share the same title identity and artwork fields.
        TMDBCatalog.Item(id: id, mediaType: mediaType, name: name, originalName: originalName ?? "", year: year,
                         overview: overview ?? "", poster: poster, backdrop: backdrop, rating: nil, genreIDs: [])
    }
}

extension TMDBMatch.Candidate {
    var catalogItem: TMDBCatalog.Item {
        TMDBCatalog.Item(id: id, mediaType: mediaType, name: name, originalName: originalName ?? "", year: year,
                         overview: overview ?? "", poster: poster, backdrop: nil, rating: nil, genreIDs: [])
    }
}

private extension TMDBCatalog.Feed {
    var brandFilter: TMDBCatalog.Filter {
        let mapping: [Self: (Int, TMDBMatch.MediaType)] = [.netflix: (213, .tv), .disney: (2739, .tv), .appleTV: (2552, .tv), .hbo: (49, .tv), .warner: (174, .movie), .universal: (33, .movie), .paramount: (4, .movie), .sony: (34, .movie)]
        let value = mapping[self]!
        return .studio(value.0, type: value.1)
    }
}

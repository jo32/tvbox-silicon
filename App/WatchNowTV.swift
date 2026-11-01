import SwiftUI
import TVCore

#if os(tvOS)
/// Watch Now on Apple TV, laid out as Discover is: what you were watching last fills the top of the screen over its own
/// artwork, which tints the page, and every section below is a row of covers that lift under focus, with captions that
/// move down with them.
struct WatchNowTVPage: View {
    @Environment(Store.self) private var store
    let config: Subscription
    let sections: Set<HomeSection>
    @State private var hero = WatchNowHeroState()

    /// The newest titles not finished yet, for the hero.
    private var upNext: [PlaybackHistoryEntry] {
        guard sections.contains(.upNext) else { return [] }
        return Array(store.playbackHistory.entries.filter { !$0.completed }.prefix(5))
    }

    var body: some View {
        GeometryReader { proxy in
            let heroHeight = DiscoverLayout.heroHeight(proxy.size.width)
            let entries = upNext
            ZStack(alignment: .top) {
                WatchNowTVBackdrop(state: hero, width: proxy.size.width, height: heroHeight)
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 30) {
                            if entries.isEmpty {
                                Color.clear.frame(height: 40)
                            } else {
                                WatchNowTVHero(entries: entries, state: hero).frame(width: proxy.size.width, height: heroHeight)
                            }
                            rows
                        }
                        .padding(.bottom, 60)
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(key: DiscoverScrollKey.self, value: -geometry.frame(in: .named("watchNowScroll")).minY)
                            }
                        }
                    }
                    .coordinateSpace(name: "watchNowScroll")
                    .modifier(DiscoverScrollObserver(offset: Binding(get: { hero.scrollY }, set: { hero.scrollY = $0 })))
                    .scrollIndicators(.hidden)
                    .scrollClipDisabled()
                    #if DEBUG
                    // `-qaScroll <row>` (continue, recommendations, favorites, live) scrolls there, for screenshots.
                    .task { if let target = QALaunch.scrollTarget { try? await Task.sleep(for: .seconds(8)); reader.scrollTo(target, anchor: .top) } }
                    #endif
                }
            }
            .task(id: entries.map(\.id)) { await hero.load(entries) }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
    }

    @ViewBuilder private var rows: some View {
        if sections.contains(.continueWatching), !store.playbackHistory.entries.isEmpty {
            WatchNowTVRail(title: L10n.text("Continue Watching"), seeAll: WatchNowTVSeeAll(height: WatchNowTVCover.height) { store.section = .history }) {
                ForEach(store.playbackHistory.entries.prefix(12)) { HistoryCard(entry: $0) }
            }
            .id("continue")
        }
        if sections.contains(.pinnedSources) {
            let pinned = store.orderedSites(config).filter { store.pinnedSources.contains($0, origin: config.origin) }
            if !pinned.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    WatchNowTVHeading(title: L10n.text("Pinned Sources"))
                    LazyVGrid(columns: Layout.cardColumns, spacing: Layout.cardSpacing) {
                        ForEach(pinned) { site in
                            RouteLink { SiteView(site: site, origin: config.origin, jarURL: config.spiderURL) } label: { SiteCard(site: site, marksPinned: false) }
                                .tileButton().contextMenu { PinSourceButton(site: site, origin: config.origin) }
                                .accessibilityIdentifier("home.pinned." + site.key)
                        }
                    }
                    .padding(.horizontal, DiscoverLayout.gutter).padding(.vertical, 24)
                    .focusSection()
                }
                .accessibilityIdentifier("home.pinnedSources")
            }
        }
        if sections.contains(.recommendations) { RecommendationsView(config: config, rails: true).id("recommendations") }
        if sections.contains(.favorites), !store.favorites.items.isEmpty {
            WatchNowTVRail(title: L10n.text("Favorites"), seeAll: WatchNowTVSeeAll(height: WatchNowTVCover.height) { store.section = .favorites }) {
                ForEach(Array(store.favorites.items.prefix(20))) { WatchNowTVFavorite(item: $0) }
            }
            .id("favorites")
        }
        if sections.contains(.liveTV), !config.lives.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                WatchNowTVHeading(title: L10n.text("Live TV"))
                // Every platform, then one row of playlists.
                LiveSourceGrid(sources: config.lives.filter(\.isBuiltIn) + config.lives.filter { !$0.isBuiltIn }.prefix(3), titled: false)
                    .padding(.horizontal, DiscoverLayout.gutter).padding(.vertical, 24)
                    .focusSection()
            }
            .id("live")
        }
    }
}

/// The shown title's artwork behind the whole page, fading as the page scrolls, as on Discover.
private struct WatchNowTVBackdrop: View {
    let state: WatchNowHeroState
    let width: CGFloat
    let height: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        DiscoverBackdrop(paint: state.paint, width: width, heroHeight: height, scrollY: state.scrollY, trailer: nil, playsTrailer: false)
            .id(state.selected)
            .transition(.opacity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: state.selected)
    }
}

/// Up Next: the title's logo or name, where you are in it, Resume and its page; the dots move between the newest
/// titles not finished yet, and Select on one resumes it.
private struct WatchNowTVHero: View {
    @Environment(Store.self) private var store
    @Environment(\.openHistoryDetails) private var openDetails
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let entries: [PlaybackHistoryEntry]
    let state: WatchNowHeroState
    @FocusState private var focus: Focus?
    private enum Focus: Hashable { case resume, details, page(Int) }

    private var entry: PlaybackHistoryEntry { entries.first { $0.id == state.selected } ?? entries[0] }

    var body: some View {
        let entry = entry
        let details = state.details[entry.id]
        VStack(alignment: .leading, spacing: 12) {
            Spacer(minLength: 0)
            Text(L10n.text("Up Next")).font(.system(size: 24, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
            Group {
                if let logo = details?.logo {
                    WatchNowTVLogo(url: logo).id(logo)
                } else {
                    Text(entry.context.videoName).font(.system(size: 64, weight: .bold)).lineLimit(2)
                        .frame(maxWidth: 900, alignment: .leading)
                }
            }
            .accessibilityAddTraits(.isHeader)
            Text([entry.context.episodeName, SourceLabel(entry.context.sourceName).text, HistoryFormat.status(entry)]
                .filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: 24)).monospacedDigit().lineLimit(1)
            if let overview = details?.overview, !overview.isEmpty {
                Text(overview).font(.system(size: 24)).lineSpacing(4).lineLimit(2)
                    .frame(width: 760, alignment: .leading).foregroundStyle(.white.opacity(0.85))
            }
            if entry.duration > 0, !entry.completed {
                Capsule().fill(.white.opacity(0.25)).frame(width: 420, height: 6)
                    .overlay(alignment: .leading) { Capsule().fill(.white).frame(width: 420 * entry.progress) }
                    .padding(.top, 4)
                    .accessibilityHidden(true)
            }
            HStack(spacing: 20) {
                GlassGroup(spacing: 20) {
                    HStack(spacing: 20) {
                        Button { store.resume(entry) } label: {
                            Label(L10n.text("Resume"), systemImage: store.resumingHistoryID == entry.id ? "hourglass" : "play.fill")
                        }
                        .focused($focus, equals: .resume)
                        .accessibilityIdentifier("home.upNext.resume")
                        if let route = detailsRoute(entry) {
                            Button { openDetails?(route) } label: { Label(L10n.text("Show Details"), systemImage: "info.circle") }
                                .focused($focus, equals: .details)
                                .accessibilityIdentifier("home.upNext.details")
                        }
                    }
                    .controlButton()
                }
                if entries.count > 1 { dots }
            }
            .padding(.top, 18)
        }
        .multilineTextAlignment(.leading)
        .padding(.horizontal, DiscoverLayout.gutter).padding(.bottom, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .background(alignment: .trailing) {
            // No TMDB backdrop: the page is tinted by the title's own cover, blurred, so show that cover itself too.
            if state.paints[entry.id] != nil, details?.backdrop == nil, let poster = entry.context.poster {
                WatchNowTVHeroCover(url: poster, headers: entry.context.posterHeaders ?? [:])
                    .id(entry.id).transition(.opacity)
                    .padding(.trailing, DiscoverLayout.gutter)
            }
        }
        .focusSection()
        .defaultFocus($focus, .resume)
        .onChange(of: focus) { _, value in
            guard case .page(let index) = value, entries.indices.contains(index) else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { state.selected = entries[index].id }
        }
    }

    /// One dot a title; focus shows it, Select resumes it.
    private var dots: some View {
        HStack(spacing: 0) {
            ForEach(entries.indices, id: \.self) { index in
                let shown = entries[index].id == entry.id
                Button { store.resume(entries[index]) } label: {
                    Circle().fill(.white.opacity(shown ? 1 : 0.35))
                        .frame(width: focus == .page(index) ? 13 : 8, height: focus == .page(index) ? 13 : 8)
                        .frame(width: 28, height: 48).contentShape(Rectangle())
                }
                .buttonStyle(WatchNowTVDotStyle())
                .focused($focus, equals: .page(index))
                .accessibilityLabel(entries[index].context.videoName)
                .accessibilityAddTraits(shown ? [.isSelected] : [])
                .accessibilityIdentifier("home.upNext.page.\(index)")
            }
        }
        .padding(.horizontal, 16)
        .background { Capsule().fill(.white.opacity(isPage ? 0.16 : 0)) }
        .overlay { Capsule().strokeBorder(.white.opacity(isPage ? 0.6 : 0), lineWidth: 2).allowsHitTesting(false) }
        .padding(.leading, 12)
    }

    private var isPage: Bool { if case .page = focus { true } else { false } }

    private func detailsRoute(_ entry: PlaybackHistoryEntry) -> Route? {
        guard openDetails != nil, let client = store.historyClient(entry) else { return nil }
        let video = entry.listVideo
        return Route { AnyView(VideoDetailView(video: video, client: client)) }
    }
}

/// A title's own cover, whole and sharp, on the right of the hero: portrait or landscape, it keeps its shape.
private struct WatchNowTVHeroCover: View {
    let url: URL
    let headers: [String: String]
    @State private var aspect: CGFloat?
    var body: some View {
        GeometryReader { proxy in
            let box = CGSize(width: proxy.size.width * 0.4, height: proxy.size.height * 0.62)
            let shape = aspect ?? 2.0 / 3.0
            let size = shape > box.width / max(box.height, 1)
                ? CGSize(width: box.width, height: box.width / shape) : CGSize(width: box.height * shape, height: box.height)
            PosterImage(url: url, headers: headers, aspect: $aspect)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1) }
                .shadow(color: .black.opacity(0.5), radius: 34, y: 18)
                .opacity(aspect == nil ? 0 : 1)
                .animation(.easeOut(duration: 0.25), value: aspect == nil)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .trailing)
                .offset(y: 36)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

private struct WatchNowTVDotStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label.scaleEffect(configuration.isPressed ? 0.85 : 1) }
}

private struct WatchNowTVLogo: View {
    let url: URL
    @State private var aspect: CGFloat?
    var body: some View {
        TMDBArtwork(url: url, maxPixels: 1200, fill: false, aspect: $aspect)
            .frame(width: min(580, 160 * (aspect ?? 3.2)), height: 160, alignment: .leading)
    }
}

/// A section's name, as Discover's: plain, large, and not a button.
struct WatchNowTVHeading: View {
    let title: String
    var body: some View {
        Text(title).font(.system(size: DiscoverLayout.heading, weight: .semibold)).lineLimit(1)
            .frame(height: DiscoverLayout.headingHeight, alignment: .top)
            .padding(.horizontal, DiscoverLayout.gutter)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A section as a row of covers under its name.
struct WatchNowTVRail<Content: View>: View {
    let title: String
    var seeAll: WatchNowTVSeeAll? = nil
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WatchNowTVHeading(title: title)
            WatchNowTVRow(seeAll: seeAll, content: content)
        }
    }
}

/// A row of covers with room for the focus lift. See All waits at the start of the row, as on Discover: a sliver in the
/// margin, invisible, that Left from the first cover lands on and opens; it closes again when focus leaves it.
struct WatchNowTVRow<Content: View>: View {
    var seeAll: WatchNowTVSeeAll? = nil
    @ViewBuilder let content: () -> Content
    @FocusState private var seeAllFocused: Bool
    @State private var revealed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: DiscoverLayout.spacing) {
                if let seeAll { seeAll.revealing(revealed).focused($seeAllFocused) }
                content()
            }
            .padding(.leading, seeAll != nil && !revealed ? DiscoverLayout.gutter - DiscoverLayout.spacing - 1 : DiscoverLayout.gutter)
            .padding(.trailing, DiscoverLayout.gutter).padding(.vertical, 24)
        }
        .scrollClipDisabled().scrollIndicators(.hidden)
        .focusSection()
        .onChange(of: seeAllFocused) { _, focused in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { revealed = focused }
        }
    }
}

/// A title as Discover shows one on the TV: the cover, lifted by the system under focus, over centred captions.
struct WatchNowTVCover: View {
    static let width = DiscoverLayout.posterWidth
    static let height = DiscoverLayout.posterWidth * 1.5
    let title: String
    let detail: String
    let poster: URL?
    var headers: [String: String] = [:]
    var body: some View {
        VStack(spacing: 5) {
            PosterImage(url: poster, headers: headers).frame(width: Self.width, height: Self.height)
            VStack(spacing: 0) {
                Text(title).font(.system(size: 26))
                Text(detail.isEmpty ? " " : detail).font(.system(size: 22, weight: .medium)).foregroundStyle(.white.opacity(0.5))
            }
            .lineLimit(1).cardCaption()
        }
        .frame(width: Self.width)
    }
}

/// The end of a row: a dim plate as tall as the covers that turns light under focus, as Discover's See All.
struct WatchNowTVSeeAll: View {
    let height: CGFloat
    var destination: Route? = nil
    var action: () -> Void = {}
    /// Hidden to a one-point sliver until the row opens it (`WatchNowTVRow`).
    private var isRevealed = true
    init(height: CGFloat, action: @escaping () -> Void) { self.height = height; self.action = action }
    init(height: CGFloat, route: Route) { self.height = height; self.destination = route }
    func revealing(_ revealed: Bool) -> Self { var copy = self; copy.isRevealed = revealed; return copy }
    @Environment(\.openRoute) private var openRoute
    var body: some View {
        Button { if let destination { openRoute?(destination) } else { action() } } label: {
            VStack(spacing: 12) {
                Text(L10n.text("See All")).font(.system(size: 26, weight: .medium)).multilineTextAlignment(.center)
                Image(systemName: "chevron.right.circle.fill").font(.system(size: 26, weight: .medium))
            }
            .fixedSize()
            .frame(width: isRevealed ? 120 : 1, height: height)
            .clipped()
        }
        .buttonStyle(WatchNowTVPlateStyle())
        // Not 0: the focus engine passes over a fully transparent view, and Left from the first cover then opened the
        // sidebar instead of See All. A one-point sliver this faint is still invisible.
        .opacity(isRevealed ? 1 : 0.02)
        // As tall as a cover with its captions: it opens the row, and a lazy row takes its height from its first item.
        .frame(height: height + DiscoverLayout.captionHeight, alignment: .top)
        .accessibilityHidden(!isRevealed)
        .accessibilityLabel(L10n.text("See All"))
        .accessibilityIdentifier("watchnow.more")
    }
}

/// A card that draws its own plate: dim at rest, light with dark text and lifted under focus.
struct WatchNowTVPlateStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Plate(configuration: configuration) }
    private struct Plate: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var focused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        var body: some View {
            configuration.label
                .foregroundStyle(focused ? Color.black : Color.white)
                .background(Color(white: focused ? 0.88 : 1, opacity: focused ? 1 : 0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .scaleEffect(configuration.isPressed ? 1.04 : focused ? 1.08 : 1)
                .shadow(color: .black.opacity(focused ? 0.35 : 0), radius: 18, y: 10)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: focused)
        }
    }
}

/// A favorite in the Favorites row: videos and episodes by their cover; channels, songs and drive files on a plate
/// with their logo, artwork or symbol, the same size. Press and hold removes it.
private struct WatchNowTVFavorite: View {
    @Environment(Store.self) private var store
    let item: FavoriteItem

    var body: some View {
        switch item {
        case .video(let video):
            let cover = WatchNowTVCover(title: video.videoName, detail: SourceLabel(video.sourceName).text, poster: video.poster, headers: video.posterHeaders)
            if let listing = video.listingVideo(), let client = store.catalogClient(for: video) {
                RouteLink { VideoDetailView(video: listing, client: client) } label: { cover }
                    .cardButton().contextMenu { FavoriteMenuButton(item: item, name: video.videoName) }
            } else {
                Button { store.reportMissingFavoriteSource() } label: { cover }
                    .cardButton().contextMenu { FavoriteMenuButton(item: item, name: video.videoName) }
            }
        case .episode(let episode):
            Button { store.play(episode) } label: {
                WatchNowTVCover(title: episode.video.videoName, detail: episode.episodeName, poster: episode.video.poster, headers: episode.video.posterHeaders)
            }
            .cardButton().contextMenu { FavoriteMenuButton(item: item, name: episode.video.videoName) }
        case .live(let channel):
            plate(title: channel.name, detail: channel.displayGroup, action: { store.playing = channel }) {
                ChannelLogo(channel: channel).frame(width: 140, height: 140)
            }
        case .music(let track):
            plate(title: track.title, detail: track.artistLine, action: { store.music.play(track) }) {
                MusicArtwork(url: track.artwork, size: 170)
            }
        case .cloud(let file):
            let cloud = CloudFile(id: file.fileID, name: file.fileName, isFolder: false, size: file.size)
            plate(title: file.fileName, detail: CloudFiles.drive(key: file.driveKey)?.name ?? file.driveKey, action: { store.play(file) }) {
                Image(systemName: cloud.symbol).font(.system(size: 72, weight: .medium)).foregroundStyle(cloud.tint)
            }
        }
    }

    private var name: String {
        switch item {
        case .live(let channel): channel.name
        case .music(let track): track.title
        case .cloud(let file): file.fileName
        case .video(let video): video.videoName
        case .episode(let episode): episode.video.videoName
        }
    }

    private func plate<Art: View>(title: String, detail: String, action: @escaping () -> Void, @ViewBuilder art: () -> Art) -> some View {
        Button(action: action) {
            VStack(spacing: 14) {
                art().frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(spacing: 2) {
                    Text(title).font(.system(size: 24, weight: .semibold))
                    Text(detail.isEmpty ? " " : detail).font(.system(size: 20)).opacity(0.6)
                }
                .lineLimit(1).padding(.horizontal, 12)
            }
            .padding(.vertical, 22)
            .frame(width: WatchNowTVCover.width, height: WatchNowTVCover.height)
        }
        .buttonStyle(WatchNowTVPlateStyle())
        .contextMenu { FavoriteMenuButton(item: item, name: name) }
    }
}

/// A row of a source's category on Watch Now: its first page. Rows come and go as the page scrolls (it is lazy), so
/// what they loaded is kept in `WatchNowRows`: scrolling back shows it at once instead of loading it again.
struct WatchNowTVCategoryRail: View {
    @Environment(Store.self) private var store
    let title: String
    let category: String
    let client: CatalogClient
    let seeAll: Route
    private var isIndex: Bool { (client.site.raw["indexs"]?.int ?? 0) == 1 }
    private var key: String { WatchNowRows.key(category: category, client: client) }

    var body: some View {
        let row = WatchNowRows.shared.rows[key]
        Group {
            if let row, row.videos.isEmpty {
                // An empty or failing category leaves no row behind.
                Color.clear.frame(height: 0)
            } else {
                WatchNowTVRail(title: title, seeAll: row == nil ? nil : WatchNowTVSeeAll(height: WatchNowTVCover.height, route: seeAll)) {
                    if let row {
                        ForEach(row.videos.prefix(20)) { video in
                            let cover = WatchNowTVCover(title: video.name, detail: video.remarks, poster: video.poster, headers: video.posterHeaders)
                            if isIndex {
                                Button { store.searchVideos(video.name) } label: { cover }.cardButton()
                            } else {
                                RouteLink { CatalogDestination(video: video, client: client) } label: { cover }.cardButton()
                            }
                        }
                    } else {
                        // As tall as the covers and captions that replace them, so nothing below moves when they come.
                        ForEach(0..<6, id: \.self) { _ in
                            SkeletonBlock(cornerRadius: 12).frame(width: WatchNowTVCover.width, height: WatchNowTVCover.height)
                                .frame(height: WatchNowTVCover.height + DiscoverLayout.captionHeight, alignment: .top)
                        }
                    }
                }
            }
        }
        .task(id: key) { WatchNowRows.shared.load(category: category, client: client) }
    }
}

#endif

/// The hero's selection and artwork, read only by the hero and the backdrop: scrolling and paging must not evaluate the
/// rows again.
@MainActor @Observable final class WatchNowHeroState {
    var selected: String?
    var scrollY: CGFloat = 0
    var paints: [String: DiscoverPaint] = [:]
    var details: [String: TMDBMatch.Details] = [:]
    var paint: DiscoverPaint? { selected.flatMap { paints[$0] } }

    /// Artwork for each title, two at a time, the shown one first: on Apple TV the TMDB backdrop this device already has
    /// for it (from its page), else its own poster, blurred; on iPhone the TMDB cover, else its own. Never a new TMDB lookup.
    func load(_ entries: [PlaybackHistoryEntry]) async {
        if selected == nil || !entries.contains(where: { $0.id == selected }) { selected = entries.first?.id }
        let missing = entries.filter { paints[$0.id] == nil }
        await withTaskGroup(of: (String, TMDBMatch.Details?, DiscoverPaint?).self) { group in
            var remaining = missing.makeIterator()
            func enqueue(_ entry: PlaybackHistoryEntry) {
                group.addTask {
                    let details = await Self.knownDetails(entry.context)
                    #if os(tvOS)
                    let paint: DiscoverPaint? = if let backdrop = details?.backdrop {
                        await DiscoverPainter.shared.paint(backdrop)
                    } else if let poster = entry.context.poster {
                        await DiscoverPainter.shared.paint(poster, headers: entry.context.posterHeaders ?? [:], soft: true)
                    } else { nil }
                    #else
                    // The phone's hero is portrait: a cover fills it, sharp at the top, as Discover's.
                    let paint: DiscoverPaint? = if let poster = details?.heroPoster ?? details?.poster {
                        await DiscoverPainter.shared.paint(poster)
                    } else if let poster = entry.context.poster {
                        await DiscoverPainter.shared.paint(poster, headers: entry.context.posterHeaders ?? [:])
                    } else { nil }
                    #endif
                    return (entry.id, details, paint)
                }
            }
            for _ in 0..<2 { if let entry = remaining.next() { enqueue(entry) } }
            for await (id, details, paint) in group {
                guard !Task.isCancelled else { group.cancelAll(); break }
                if let details { self.details[id] = details }
                if let paint { paints[id] = paint }
                if let entry = remaining.next() { enqueue(entry) }
            }
        }
    }

    /// The details the title's page found: the work the viewer chose for it, else a match kept on this device.
    nonisolated static func knownDetails(_ context: PlaybackHistoryContext) async -> TMDBMatch.Details? {
        guard TMDBMatch.enabled else { return nil }
        let key = TMDBMatchStore.key(source: context.sourceKey, video: context.videoID)
        switch await TMDBMatchStore.shared.choice(for: key) {
        case .some(.none): return nil
        case .some(.work(let type, let id, let season)): return try? await TMDBMatch.details(type, id: id, season: season)
        case nil: return await TMDBMatchStore.shared.answer(for: key)?.details
        }
    }
}

/// Watch Now's category rows, kept for the app's life. A row older than ten minutes loads again when it comes on
/// screen, showing the old covers until the new ones arrive; a load runs to the end even if the row scrolls away. Apple TV and iPhone share it.
@MainActor @Observable final class WatchNowRows {
    static let shared = WatchNowRows()
    struct Row { var videos: [Video]; var date: Date }
    private(set) var rows: [String: Row] = [:]
    @ObservationIgnored private var loading: Set<String> = []

    static func key(category: String, client: CatalogClient) -> String { "\(client.origin)|\(client.site.key)|\(category)" }

    func load(category: String, client: CatalogClient) {
        let key = Self.key(category: category, client: client)
        if let row = rows[key], Date().timeIntervalSince(row.date) < 600 { return }
        guard loading.insert(key).inserted else { return }
        Task {
            defer { loading.remove(key) }
            do {
                let page = try await client.list(category: category, query: "", page: 1)
                var seen = Set<String>()
                let videos = page.videos.filter { seen.insert($0.id).inserted }
                if rows[key]?.videos != videos { rows[key] = Row(videos: videos, date: Date()) } else { rows[key]?.date = Date() }
            } catch {
                Diagnostics.shared.failure("catalog", "watch now row \(client.reportContext)", error)
                // Keep covers already shown; a row that never loaded goes away.
                if rows[key] == nil { rows[key] = Row(videos: [], date: Date()) }
            }
            if rows.count > 40, let oldest = rows.min(by: { $0.value.date < $1.value.date })?.key { rows[oldest] = nil }
        }
    }
}

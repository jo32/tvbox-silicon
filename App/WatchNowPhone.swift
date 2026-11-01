import SwiftUI
import TVCore

#if !os(tvOS)
/// Watch Now on iPhone and the Mac, laid out as Discover is there: what you were watching last fills the top of the screen over its
/// own cover, which tints the page, and every section below is a row of covers under a heading that opens all of it.
struct WatchNowPhonePage: View {
    @Environment(Store.self) private var store
    let config: Subscription
    let sections: Set<HomeSection>
    @State private var hero = WatchNowHeroState()
    /// Scrolled past the hero: the bar is over the app's own background again.
    @State private var pastHero = false

    /// The newest titles not finished yet, for the hero.
    private var upNext: [PlaybackHistoryEntry] {
        guard sections.contains(.upNext) else { return [] }
        return Array(store.playbackHistory.entries.filter { !$0.completed }.prefix(5))
    }

    var body: some View {
        let entries = upNext
        GeometryReader { proxy in
            let heroHeight = DiscoverLayout.heroHeight(proxy.size.width)
            ZStack(alignment: .top) {
                WatchNowPhoneBackdrop(state: hero, width: proxy.size.width, height: heroHeight)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 30) {
                        if !entries.isEmpty {
                            WatchNowPhoneHero(entries: entries, state: hero, width: proxy.size.width, height: heroHeight)
                                .modifier(WatchNowPhoneTheme(state: hero))
                        }
                        rows
                    }
                    .padding(.top, entries.isEmpty ? 8 : 0)
                    .padding(.bottom, 28)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: DiscoverScrollKey.self, value: -geometry.frame(in: .named("watchNowScroll")).minY)
                        }
                    }
                }
                .coordinateSpace(name: "watchNowScroll")
                .modifier(DiscoverScrollObserver(offset: Binding(get: { hero.scrollY }, set: { value in
                    hero.scrollY = value
                    // Only crossing the hero's foot changes the bar, so scrolling doesn't evaluate the page again.
                    let past = value > heroHeight - 140
                    if pastHero != past { pastHero = past }
                })))
                .scrollIndicators(.hidden)
            }
            .task(id: entries.map(\.id)) { await hero.load(entries) }
        }
        // Over the hero the page has no title, as Discover; without one it keeps its name.
        .navigationTitle(entries.isEmpty ? L10n.text("Watch Now") : "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(entries.isEmpty ? .automatic : .hidden, for: .navigationBar)
        .toolbarColorScheme(entries.isEmpty || pastHero || hero.paint == nil ? nil : hero.paint?.isDark == false ? .light : .dark, for: .navigationBar)
        #endif
        .ignoresSafeArea(edges: entries.isEmpty ? [] : .top)
    }

    @ViewBuilder private var rows: some View {
        if sections.contains(.continueWatching), !store.playbackHistory.entries.isEmpty {
            WatchNowPhoneShelf(title: L10n.text("Continue Watching"), action: { store.section = .history }) {
                ForEach(store.playbackHistory.entries.prefix(12)) { HistoryCard(entry: $0) }
            }
            .accessibilityIdentifier("home.continueWatching")
        }
        if sections.contains(.pinnedSources) {
            let pinned = store.orderedSites(config).filter { store.pinnedSources.contains($0, origin: config.origin) }
            if !pinned.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    WatchNowPhoneHeading(title: L10n.text("Pinned Sources"), action: { store.section = .sites })
                    LazyVGrid(columns: Layout.cardColumns, spacing: Layout.cardSpacing) {
                        ForEach(pinned) { site in
                            RouteLink { SiteView(site: site, origin: config.origin, jarURL: config.spiderURL) } label: { SiteCard(site: site, marksPinned: false) }
                                .tileButton().contextMenu { PinSourceButton(site: site, origin: config.origin) }
                                .accessibilityIdentifier("home.pinned." + site.key)
                        }
                    }
                    .padding(.horizontal, DiscoverLayout.gutter)
                }
                .accessibilityIdentifier("home.pinnedSources")
            }
        }
        if sections.contains(.recommendations) { RecommendationsView(config: config, rails: true) }
        if sections.contains(.favorites), !store.favorites.items.isEmpty {
            WatchNowPhoneShelf(title: L10n.text("Favorites"), action: { store.section = .favorites }) {
                ForEach(Array(store.favorites.items.prefix(20))) { WatchNowPhoneFavorite(item: $0) }
            }
        }
        if sections.contains(.liveTV), !config.lives.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                WatchNowPhoneHeading(title: L10n.text("Live TV"), action: { store.section = .live })
                // Every platform, then one row of playlists.
                LiveSourceGrid(sources: config.lives.filter(\.isBuiltIn) + config.lives.filter { !$0.isBuiltIn }.prefix(3), titled: false)
                    .padding(.horizontal, DiscoverLayout.gutter)
            }
            .id("live")
        }
    }
}

/// Dark text over a light cover and light text over a dark one, for the hero only: the rows below are on the app's own
/// background.
private struct WatchNowPhoneTheme: ViewModifier {
    let state: WatchNowHeroState
    func body(content: Content) -> some View {
        content.foregroundStyle(state.paint?.isDark == false ? Color.black : Color.white)
            .environment(\.colorScheme, state.paint?.isDark == false ? .light : .dark)
    }
}

/// The shown title's cover behind the hero, in the cover's own colour, fading into the app's background below it as on
/// Discover on Apple TV: the rows under it are not tinted. It moves up with the page and stretches when pulled down.
private struct WatchNowPhoneBackdrop: View {
    let state: WatchNowHeroState
    let width: CGFloat
    let height: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// How far below the hero's foot the colour fades out.
    private static let fade: CGFloat = 90

    var body: some View {
        ZStack(alignment: .top) {
            Backdrop()
            ZStack(alignment: .top) {
                if let paint = state.paint {
                    layer(paint).id(state.selected).transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: state.selected)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: state.paint == nil)
        }
        // Under the bar only, as Discover's: on the Mac the split view's sidebar is a leading safe area, and spreading
        // under it shifted the cover left by the sidebar's width, leaving the right side bare.
        .discoverFullBleed()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func layer(_ paint: DiscoverPaint) -> some View {
        let total = height + Self.fade
        let pull = max(0, -state.scrollY)
        return ZStack(alignment: .top) {
            paint.color
            Image(decorative: paint.image, scale: 1).resizable().scaledToFill()
                .frame(width: width, height: height)
                .scaleEffect(1 + pull / max(height, 1), anchor: .top)
                .frame(width: width, height: height, alignment: .top).clipped()
                .mask {
                    LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.72),
                                           .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
                }
        }
        .frame(width: width, height: total + pull, alignment: .top)
        .mask {
            // An eased fade, so the colour leaves gradually rather than at a line.
            let start = (height * 0.7 + pull) / (total + pull)
            LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: start),
                                   .init(color: .black.opacity(0.75), location: start + (1 - start) * 0.3),
                                   .init(color: .black.opacity(0.35), location: start + (1 - start) * 0.62),
                                   .init(color: .black.opacity(0.1), location: start + (1 - start) * 0.85),
                                   .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
        }
        .offset(y: -max(0, state.scrollY))
    }
}

/// Up Next: a page for each of the newest titles not finished yet, with its logo or name, where you are in it and
/// Resume. A swipe moves between them, as Discover's hero.
private struct WatchNowPhoneHero: View {
    @Environment(Store.self) private var store
    @Environment(\.openRoute) private var openRoute
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #else
    @State private var hovering = false
    #endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let entries: [PlaybackHistoryEntry]
    let state: WatchNowHeroState
    let width: CGFloat
    let height: CGFloat

    private var selectedID: String? { state.selected ?? entries.first?.id }

    var body: some View {
        ZStack(alignment: .bottom) {
            #if os(macOS)
            // One title at a time, as Discover on the Mac: in the split view's detail a horizontal scroll view takes
            // the sidebar's width as a content inset. The arrows and the dots move between titles.
            let index = entries.firstIndex { $0.id == selectedID } ?? 0
            page(entries[index]).frame(width: width, height: height)
                .id(entries[index].id).transition(.opacity)
                .overlay {
                    if entries.count > 1 {
                        HStack {
                            arrow("chevron.left", label: L10n.text("Previous"), to: index - 1)
                            Spacer()
                            arrow("chevron.right", label: L10n.text("Next"), to: index + 1)
                        }
                        .padding(.horizontal, 20).opacity(hovering ? 1 : 0).animation(.easeOut(duration: 0.2), value: hovering)
                    }
                }
                .onHover { hovering = $0 }
            #else
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(entries) { entry in
                        page(entry).frame(width: width, height: height).id(entry.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: Binding(get: { selectedID }, set: { id in
                guard let id, id != state.selected else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) { state.selected = id }
            }))
            .scrollIndicators(.hidden)
            #endif
            if entries.count > 1 { dots.padding(.bottom, 8) }
        }
        .frame(height: height)
        .accessibilityIdentifier("home.upNext")
    }

    private func page(_ entry: PlaybackHistoryEntry) -> some View {
        let details = state.details[entry.id]
        let dark = state.paints[entry.id]?.isDark ?? true
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            Text(L10n.text("Up Next")).font(.system(size: 13, weight: .semibold)).opacity(0.7)
                .padding(.bottom, 10)
            Group {
                if let logo = details?.logo {
                    TMDBArtwork(url: logo, maxPixels: 1000, fill: false).accessibilityLabel(entry.context.videoName)
                } else {
                    Text(entry.context.videoName).font(.system(size: 34, weight: .bold))
                        .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.6)
                }
            }
            .frame(width: width * 0.8, height: 120, alignment: .bottom)
            .accessibilityAddTraits(.isHeader)
            Text([entry.context.episodeName, SourceLabel(entry.context.sourceName).text].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: 14)).lineLimit(1).padding(.top, 14)
            if entry.duration > 0 {
                HStack(spacing: 8) {
                    Capsule().fill(.primary.opacity(0.25)).frame(width: 90, height: 4)
                        .overlay(alignment: .leading) { Capsule().fill(.primary).frame(width: 90 * entry.progress) }
                    Text(HistoryFormat.status(entry)).font(.system(size: 12).monospacedDigit()).opacity(0.75)
                }
                .padding(.top, 8)
            }
            Button { resume(entry) } label: {
                Label(L10n.text("Resume"), systemImage: store.resumingHistoryID == entry.id ? "hourglass" : "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .padding(.horizontal, 28).frame(height: 44)
                    .foregroundStyle(dark ? Color.black : Color.white)
                    .background(dark ? Color.white : Color.black, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 18)
            .accessibilityIdentifier("home.upNext.resume")
        }
        .padding(.horizontal, 24)
        .padding(.bottom, entries.count > 1 ? 44 : 30)
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        // The cover itself opens the title too, as Discover's hero does.
        .onTapGesture { resume(entry) }
    }

    /// On an iPhone the title's watch page opens and resumes it at the top, as a Continue Watching card does.
    private func resume(_ entry: PlaybackHistoryEntry) {
        #if os(macOS)
        store.resume(entry)
        #else
        if WatchPage.applies(horizontalSizeClass, verticalSizeClass), let openRoute, let client = store.historyClient(entry) {
            let video = entry.listVideo
            openRoute(Route { AnyView(VideoDetailView(video: video, client: client, resume: entry)) })
        } else {
            store.resume(entry)
        }
        #endif
    }

    #if os(macOS)
    private func arrow(_ symbol: String, label: String, to index: Int) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) { state.selected = entries[(index + entries.count) % entries.count].id }
        } label: {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44).glassSurface(.regular, in: Circle())
        }
        .buttonStyle(.plain).accessibilityLabel(label)
    }
    #endif

    private var dots: some View {
        HStack(spacing: 0) {
            ForEach(entries) { entry in
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) { state.selected = entry.id }
                } label: {
                    Circle().fill(.primary.opacity(entry.id == selectedID ? 1 : 0.3))
                        .frame(width: 7, height: 7).frame(width: 18, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(entry.context.videoName)
                .accessibilityAddTraits(entry.id == selectedID ? [.isSelected] : [])
            }
        }
    }
}

/// A section's name, as Discover's on iPhone: the whole line opens all of it.
struct WatchNowPhoneHeading: View {
    @Environment(\.openRoute) private var openRoute
    let title: String
    var route: Route? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        Button {
            if let route { openRoute?(route) } else { action?() }
        } label: {
            HStack {
                Text(title).font(.system(size: DiscoverLayout.heading, weight: .semibold)).lineLimit(1)
                Spacer()
                if route != nil || action != nil {
                    Image(systemName: "chevron.forward").font(.system(size: 14, weight: .semibold))
                }
            }
            .frame(height: DiscoverLayout.headingHeight, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(route == nil && action == nil)
        .padding(.horizontal, DiscoverLayout.gutter)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A section as a row of covers under its name.
struct WatchNowPhoneShelf<Content: View>: View {
    let title: String
    var route: Route? = nil
    var action: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WatchNowPhoneHeading(title: title, route: route, action: action)
            WatchNowPhoneRow(content: content)
        }
    }
}

struct WatchNowPhoneRow<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        DiscoverRail {
            LazyHStack(alignment: .top, spacing: DiscoverLayout.spacing) { content() }
                .padding(.horizontal, DiscoverLayout.gutter)
        }
    }
}

/// A title as Discover shows one on iPhone: the cover over two lines of caption.
struct WatchNowPhoneCover: View {
    static let width = DiscoverLayout.posterWidth
    let title: String
    let detail: String
    let poster: URL?
    var headers: [String: String] = [:]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.aspectRatio(2.0 / 3, contentMode: .fit)
                .overlay { PosterImage(url: poster, headers: headers) }
                .posterClip(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5) }
            WatchNowPhoneCaption(title: title, detail: detail)
        }
        .frame(width: Self.width)
        .accessibilityElement(children: .combine)
    }
}

private struct WatchNowPhoneCaption: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: DiscoverLayout.caption)).lineLimit(1)
            Text(detail.isEmpty ? " " : detail).font(.system(size: DiscoverLayout.secondary, design: .rounded))
                .foregroundStyle(.primary.opacity(0.56)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading).frame(height: DiscoverLayout.captionHeight)
    }
}

/// Placeholders for a row still loading, as tall as the covers and captions that replace them.
struct WatchNowPhoneSkeletonRow: View {
    var body: some View {
        HStack(alignment: .top, spacing: DiscoverLayout.spacing) {
            ForEach(0..<4, id: \.self) { _ in
                SkeletonBlock(cornerRadius: 12)
                    .frame(width: WatchNowPhoneCover.width, height: WatchNowPhoneCover.width * 1.5)
                    .frame(height: WatchNowPhoneCover.width * 1.5 + DiscoverLayout.captionHeight, alignment: .top)
            }
        }
        .padding(.horizontal, DiscoverLayout.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("Loading…"))
    }
}

/// A favorite in the Favorites row: videos and episodes by their cover; channels, songs and drive files on a plate the
/// same size, with their logo, artwork or symbol. Press and hold removes it.
private struct WatchNowPhoneFavorite: View {
    @Environment(Store.self) private var store
    let item: FavoriteItem

    var body: some View {
        switch item {
        case .video(let video):
            let cover = WatchNowPhoneCover(title: video.videoName, detail: SourceLabel(video.sourceName).text, poster: video.poster, headers: video.posterHeaders)
            if let listing = video.listingVideo(), let client = store.catalogClient(for: video) {
                RouteLink { VideoDetailView(video: listing, client: client) } label: { cover }
                    .tmdbCardButton().contextMenu { FavoriteMenuButton(item: item, name: video.videoName) }
            } else {
                Button { store.reportMissingFavoriteSource() } label: { cover }
                    .tmdbCardButton().contextMenu { FavoriteMenuButton(item: item, name: video.videoName) }
            }
        case .episode(let episode):
            Button { store.play(episode) } label: {
                WatchNowPhoneCover(title: episode.video.videoName, detail: episode.episodeName, poster: episode.video.poster, headers: episode.video.posterHeaders)
            }
            .tmdbCardButton().contextMenu { FavoriteMenuButton(item: item, name: episode.video.videoName) }
        case .live(let channel):
            plate(title: channel.name, detail: channel.displayGroup, action: { store.playing = channel }) {
                ChannelLogo(channel: channel, size: 64)
            }
        case .music(let track):
            plate(title: track.title, detail: track.artistLine, action: { store.music.play(track) }) {
                MusicArtwork(url: track.artwork, size: 88)
            }
        case .cloud(let file):
            let cloud = CloudFile(id: file.fileID, name: file.fileName, isFolder: false, size: file.size)
            plate(title: file.fileName, detail: CloudFiles.drive(key: file.driveKey)?.name ?? file.driveKey, action: { store.play(file) }) {
                Image(systemName: cloud.symbol).font(.system(size: 40, weight: .medium)).foregroundStyle(cloud.tint)
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
            VStack(alignment: .leading, spacing: 0) {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(0.08))
                    .aspectRatio(2.0 / 3, contentMode: .fit)
                    .overlay { art() }
                WatchNowPhoneCaption(title: title, detail: detail)
            }
            .frame(width: WatchNowPhoneCover.width)
            .accessibilityElement(children: .combine)
        }
        .tmdbCardButton()
        .contextMenu { FavoriteMenuButton(item: item, name: name) }
    }
}

/// A row of a source's category on Watch Now: its first page, kept in `WatchNowRows` as on Apple TV.
struct WatchNowPhoneCategoryRail: View {
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
                VStack(alignment: .leading, spacing: 0) {
                    WatchNowPhoneHeading(title: title, route: seeAll)
                    if let row {
                        WatchNowPhoneRow {
                            ForEach(row.videos.prefix(20)) { video in
                                let cover = WatchNowPhoneCover(title: video.name, detail: video.remarks, poster: video.poster, headers: video.posterHeaders)
                                if isIndex {
                                    Button { store.searchVideos(video.name) } label: { cover }.tmdbCardButton()
                                } else {
                                    RouteLink { CatalogDestination(video: video, client: client) } label: { cover }.tmdbCardButton()
                                }
                            }
                        }
                    } else {
                        WatchNowPhoneSkeletonRow()
                    }
                }
            }
        }
        .task(id: key) { WatchNowRows.shared.load(category: category, client: client) }
    }
}
#endif

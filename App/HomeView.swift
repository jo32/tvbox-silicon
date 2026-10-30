import SwiftUI
import TVCore

struct HomeView: View {
    @Environment(Store.self) private var store
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    #if os(tvOS)
    @FocusState private var primaryFocused: Bool
    #endif
    @AppStorage(HomeSection.continueWatching.key) private var showsContinueWatching = true
    @AppStorage(HomeSection.pinnedSources.key) private var showsPinnedSources = true
    @AppStorage(HomeSection.recommendations.key) private var showsRecommendations = true
    @AppStorage(HomeSection.favorites.key) private var showsFavorites = true
    @AppStorage(HomeSection.liveTV.key) private var showsLiveTV = true
    /// The first frame is only the section placeholders. The source row is built on the next turn, so the page can appear before that layout.
    @State private var settled = false

    var body: some View {
        // The column width, not the placeholders' own width. A row of fixed cards is wider than the
        // detail column and NavigationSplitView then gives it that width, crushing the sidebar.
        GeometryReader { proxy in
            ScrollViewReader { reader in
                ScrollView {
                    Group {
                        if let config = store.subscription, !settled, showsPlaceholder(config) {
                            placeholders(config)
                        } else {
                            sections
                        }
                    }
                    .pageContainer()
                    .frame(width: proxy.size.width, alignment: .top)
                }
                #if DEBUG
                .task { if let target = QALaunch.scrollTarget { try? await Task.sleep(for: .seconds(8)); reader.scrollTo(target, anchor: .bottom) } }
                #endif
            }
        }
        .screenBackdrop()
        .historyDetailsDestination()
        .task {
            // Yield so this navigation paints the placeholders before the source row and posters are laid out.
            await Task.yield()
            guard !Task.isCancelled else { return }
            settled = true
        }
        #if os(tvOS)
        // The tab sidebar already names this page; a second heading just repeats it.
        .toolbar(.hidden, for: .navigationBar)
        #else
        .screenTitle(L10n.text("Watch Now"))
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// A section that will be on the page once it is built. Empty data is skipped so a placeholder does not appear and then vanish.
    private func showsPlaceholder(_ config: Subscription) -> Bool {
        (showsContinueWatching && !store.playbackHistory.entries.isEmpty)
            || (showsPinnedSources && !store.pinnedSources.isEmpty)
            || showsRecommendations
            || (showsFavorites && !store.favorites.items.isEmpty)
            || (showsLiveTV && !config.lives.isEmpty)
    }

    @ViewBuilder private var sections: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            if showsContinueWatching, !store.playbackHistory.entries.isEmpty { continueWatching }
            if let config = store.subscription {
                if showsPinnedSources, store.orderedSites(config).contains(where: { store.pinnedSources.contains($0, origin: config.origin) }) {
                    pinnedSources(config)
                }
                if showsRecommendations { RecommendationsView(config: config) }
                if showsFavorites, !store.favorites.items.isEmpty { favorites }
                if showsLiveTV, !config.lives.isEmpty { playlists(config).id("live") }
                if !(showsContinueWatching || showsPinnedSources || showsRecommendations || showsFavorites || showsLiveTV) { allHidden }
            } else {
                welcome
            }
        }
    }

    private func placeholders(_ config: Subscription) -> some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            if showsContinueWatching, !store.playbackHistory.entries.isEmpty {
                loadingSection(HomeSection.continueWatching.title, action: { store.section = .history }) { cardRow }
            }
            if showsPinnedSources, !store.pinnedSources.isEmpty {
                loadingSection(HomeSection.pinnedSources.title, action: { store.section = .sites }) { cardRow }
            }
            if showsRecommendations {
                VStack(alignment: .leading, spacing: 16) {
                    ChipSkeletonRow()
                    PosterSkeletonGrid()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.text("Loading…"))
            }
            if showsFavorites, !store.favorites.items.isEmpty {
                loadingSection(HomeSection.favorites.title, action: { store.section = .favorites }) { cardRow }
            }
            if showsLiveTV, !config.lives.isEmpty {
                loadingSection(HomeSection.liveTV.title, action: { store.section = .live }) { ChannelSkeletonGrid(count: 3) }
            }
        }
    }

    private func loadingSection<Content: View>(_ title: String, action: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Layout.headerSpacing) {
            SectionHeader(title: title, action: action)
            content()
        }
    }

    private var cardRow: some View {
        HStack(spacing: Layout.cardSpacing) {
            ForEach(0..<4, id: \.self) { _ in
                SkeletonBlock(cornerRadius: 16)
                    .frame(maxWidth: .infinity)
                    .frame(height: 92)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: Welcome

    /// First run: one clear action, a way to bring your own URL, and artwork so the empty
    /// screen reads as an invitation rather than a missing page.
    private var welcome: some View {
        HStack(alignment: .center, spacing: welcomeInset > 0 ? 40 : Layout.gutter) {
            welcomeCopy.frame(maxWidth: .infinity, alignment: .leading)
            if showsPosterWall {
                PosterWall().frame(maxWidth: .infinity).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, welcomeInset)
        .containerRelativeFrame(.vertical, alignment: .center) { height, _ in height * 0.82 }
        #if os(tvOS)
        // Moving right out of the sidebar lands on the primary action, not the secondary one.
        .defaultFocus($primaryFocused, true, priority: .userInitiated)
        #endif
    }

    /// The welcome's title size. On an iPad or iPhone Duo's inner display (regular width) a phone's 34 pt title and
    /// the page's 16 pt margin left the copy small and pressed against the edge of a large, empty screen.
    private var heroTitle: CGFloat {
        #if os(iOS)
        sizeClass == .regular ? 52 : Layout.heroTitle
        #else
        Layout.heroTitle
        #endif
    }

    private var welcomeInset: CGFloat {
        #if os(iOS)
        sizeClass == .regular ? 48 : 0
        #else
        0
        #endif
    }

    private var welcomeCopy: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                AppMark(size: heroTitle * 1.4)
                Text(L10n.text("Yingxia")).font(.title3.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.bottom, 32)
            Text(L10n.text("Your cinema,\non every screen."))
                .font(.system(size: heroTitle, weight: .bold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 18)
            Text(L10n.text("Connect your subscription to watch on Mac, iPhone, iPad, and Apple TV."))
                .font(.title3).foregroundStyle(.secondary)
                .frame(maxWidth: heroTitle * 10, alignment: .leading)
                .padding(.bottom, 40)
            Group {
                #if os(tvOS)
                HStack(spacing: 16) { welcomeButtons }
                #else
                // Side by side when both fit on one line each, else stacked: on an iPad in portrait the copy
                // column is about 430 pt and "Sign In to Cloud Drive" wrapped onto two lines.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { welcomeButtons }
                    VStack(alignment: .leading, spacing: 12) { welcomeButtons }
                }
                #endif
            }
            .controlSize(.large)
            if store.importing {
                LoadingCard { .server(URL(string: store.subscriptionAddress)?.host(), title: L10n.text("Importing…")) }
                    .frame(maxWidth: heroTitle * 9)
                    .padding(.top, 24)
            }
        }
    }

    @ViewBuilder private var welcomeButtons: some View {
        // There is no default subscription. A cloud drive works without one (Cloud Files), and a
        // subscription address is added in Settings.
        RouteLink { CloudDriveView() } label: {
            Label(L10n.text("Sign In to Cloud Drive"), systemImage: "externaldrive.fill.badge.person.crop").lineLimit(1)
        }
        .controlButton(prominent: true).tint(Brand.accent)
        #if os(tvOS)
        .focused($primaryFocused)
        #endif
        Button { store.section = .settings } label: {
            Label(L10n.text("Add Subscription"), systemImage: "plus.circle.fill").lineLimit(1)
        }
        .controlButton().disabled(store.importing)
    }

    private var showsPosterWall: Bool {
        #if os(iOS)
        sizeClass != .compact
        #else
        true
        #endif
    }

    // MARK: Sections

    /// Every section switched off in Settings: say so, rather than leave a blank page.
    private var allHidden: some View {
        ContentUnavailableView {
            Label(L10n.text("Watch Now"), systemImage: AppSection.home.icon)
        } description: {
            Text(L10n.text("Choose what Watch Now shows in Settings."))
        } actions: {
            Button(L10n.text("Settings")) { store.section = .settings }.controlButton()
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }

    private func pinnedSources(_ config: Subscription) -> some View {
        VStack(alignment: .leading, spacing: Layout.headerSpacing) {
            SectionHeader(title: L10n.text("Pinned Sources")) { store.section = .sites }
            LazyVGrid(columns: Layout.cardColumns, spacing: Layout.cardSpacing) {
                ForEach(store.orderedSites(config).filter { store.pinnedSources.contains($0, origin: config.origin) }) { site in
                    RouteLink { SiteView(site: site, origin: config.origin, jarURL: config.spiderURL) } label: { SiteCard(site: site, marksPinned: false) }
                        .tileButton().contextMenu { PinSourceButton(site: site, origin: config.origin) }
                        .accessibilityIdentifier("home.pinned." + site.key)
                }
            }
        }.accessibilityIdentifier("home.pinnedSources")
    }

    private var continueWatching: some View {
        VStack(alignment: .leading, spacing: Layout.headerSpacing) {
            SectionHeader(title: L10n.text("Continue Watching")) { store.section = .history }
            ChipRow {
                HStack(spacing: Layout.cardSpacing) {
                    ForEach(store.playbackHistory.entries.prefix(12)) { HistoryCard(entry: $0) }
                }.padding(.vertical, 6)
            }
        }
    }

    private var favorites: some View {
        VStack(alignment: .leading, spacing: Layout.headerSpacing) {
            SectionHeader(title: L10n.text("Favorites")) { store.section = .favorites }
            ChipRow {
                HStack(spacing: Layout.cardSpacing) {
                    ForEach(Array(store.favorites.items.prefix(12))) { item in
                        HomeFavoriteCard(item: item).frame(width: Layout.cardMin)
                    }
                }.padding(.vertical, 6)
            }
        }
    }

    private func playlists(_ config: Subscription) -> some View {
        VStack(alignment: .leading, spacing: Layout.headerSpacing) {
            SectionHeader(title: L10n.text("Live TV")) { store.section = .live }
            // Every platform, then one row of playlists.
            LiveSourceGrid(sources: config.lives.filter(\.isBuiltIn) + config.lives.filter { !$0.isBuiltIn }.prefix(3), titled: false)
        }
    }

}

#if os(tvOS)
/// A favorite on Watch Now as one tile: quiet at rest, a white plate with dark text under focus. No heart: everything in
/// the row is a favorite.
private struct FavoriteTile<Content: View>: View {
    @Environment(\.isFocused) private var focused
    @ViewBuilder let content: Content
    var body: some View {
        content
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { TileSurface(focused: focused, radius: 16) }
        // Primary and secondary text turn dark on the white plate.
        .environment(\.colorScheme, focused ? .light : .dark)
    }
}
#endif

/// One of the 12 newest favorites on Watch Now, in the same panel as a channel card.
private struct HomeFavoriteCard: View {
    @Environment(Store.self) private var store
    @Environment(\.stripDrag) private var drag
    let item: FavoriteItem
    #if os(tvOS)
    private static let thumb: CGFloat = 72
    #else
    private static let thumb: CGFloat = 50
    #endif
    private static let posterWidth = thumb * 2 / 3

    var body: some View {
        #if os(tvOS)
        tvBody
        #else
        cardBody
        #endif
    }

    #if os(tvOS)
    /// One focusable tile per favorite, lit up on focus like the source cards. A heart button beside the card's own focus
    /// plate stuck out of it, and the remote could not press it: the tile's menu (press and hold) removes the favorite.
    @ViewBuilder private var tvBody: some View {
        switch item {
        case .live(let channel):
            tvButton(name: channel.name) { store.playing = channel } label: {
                media(ChannelLogo(channel: channel), title: channel.name, subtitle: channel.displayGroup)
            }
        case .video(let video):
            let label = media(poster(url: video.poster, headers: video.posterHeaders), title: video.videoName, subtitle: video.sourceName)
            if let listing = video.listingVideo(), let client = store.catalogClient(for: video) {
                RouteLink { VideoDetailView(video: listing, client: client) } label: { FavoriteTile { label } }
                    .tileButton()
                    .contextMenu { FavoriteMenuButton(item: item, name: video.videoName) }
            } else {
                tvButton(name: video.videoName) { store.reportMissingFavoriteSource() } label: { label }
            }
        case .episode(let episode):
            tvButton(name: episode.video.videoName) { store.play(episode) } label: {
                media(poster(url: episode.video.poster, headers: episode.video.posterHeaders), title: episode.video.videoName, subtitle: episode.episodeName)
            }
        case .music(let track):
            tvButton(name: track.title) { store.music.play(track) } label: {
                media(MusicArtwork(url: track.artwork, size: Self.thumb), title: track.title, subtitle: track.artistLine)
            }
        case .cloud(let file):
            let cloud = CloudFile(id: file.fileID, name: file.fileName, isFolder: false, size: file.size)
            tvButton(name: file.fileName) { store.play(file) } label: {
                FileRowLabel(symbol: cloud.symbol, tint: cloud.tint, title: file.fileName,
                             subtitle: CloudFiles.drive(key: file.driveKey)?.name ?? file.driveKey)
            }
        }
    }

    private func tvButton<Label: View>(name: String, action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) { FavoriteTile { label() } }
            .tileButton()
            .contextMenu { FavoriteMenuButton(item: item, name: name) }
    }
    #endif

    @ViewBuilder private var cardBody: some View {
        switch item {
        case .live(let channel):
            ChannelCard(channel: channel)
        case .video(let video):
            videoCard(video)
        case .episode(let episode):
            episodeCard(episode)
        case .music(let track):
            musicCard(track)
        case .cloud(let file):
            cloudCard(file)
        }
    }

    private func videoCard(_ video: FavoriteVideo) -> some View {
        HStack(spacing: 10) {
            FavoriteVideoOpener(video: video) {
                media(poster(url: video.poster, headers: video.posterHeaders), title: video.videoName, subtitle: video.sourceName)
            }
            FavoriteHeartButton(item: .video(video), name: video.videoName)
                .fixedSize()
                .allowsHitTesting(drag?.active != true)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .contentPanel()
    }

    private func episodeCard(_ episode: FavoriteEpisode) -> some View {
        HStack(spacing: 10) {
            Button {
                if drag?.active != true { store.play(episode) }
            } label: {
                media(poster(url: episode.video.poster, headers: episode.video.posterHeaders), title: episode.video.videoName, subtitle: episode.episodeName)
            }
            .cardButton()
            FavoriteHeartButton(item: .episode(episode), name: episode.video.videoName)
                .fixedSize()
                .allowsHitTesting(drag?.active != true)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .contentPanel()
    }

    private func musicCard(_ track: MusicTrack) -> some View {
        HStack(spacing: 10) {
            Button {
                if drag?.active != true { store.music.play(track) }
            } label: {
                media(MusicArtwork(url: track.artwork, size: Self.thumb), title: track.title, subtitle: track.artistLine)
            }
            .cardButton()
            FavoriteHeartButton(item: .music(track), name: track.title)
                .fixedSize()
                .allowsHitTesting(drag?.active != true)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .contentPanel()
    }

    private func cloudCard(_ file: FavoriteCloudFile) -> some View {
        let cloud = CloudFile(id: file.fileID, name: file.fileName, isFolder: false, size: file.size)
        let driveName = CloudFiles.drive(key: file.driveKey)?.name ?? file.driveKey
        return HStack(spacing: 10) {
            Button {
                if drag?.active != true { store.play(file) }
            } label: {
                FileRowLabel(symbol: cloud.symbol, tint: cloud.tint, title: file.fileName, subtitle: driveName)
            }
            .rowCardButton()
            FavoriteHeartButton(item: .cloud(file), name: file.fileName)
                .fixedSize()
                .allowsHitTesting(drag?.active != true)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .contentPanel()
    }

    private func poster(url: URL?, headers: [String: String]) -> some View {
        PosterImage(url: url, headers: headers)
            .frame(width: Self.posterWidth, height: Self.thumb)
            .posterClip(RoundedRectangle(cornerRadius: Self.thumb * 0.28, style: .continuous))
    }

    private func media<Art: View>(_ art: Art, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            art
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).foregroundStyle(.primary).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// The app icon artwork, masked like a home-screen icon.
struct AppMark: View {
    var size: CGFloat
    var body: some View {
        Image("YingxiaLogo").resizable().interpolation(.high).scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .shadow(color: Color(red: 0.1, green: 0.55, blue: 1).opacity(0.35), radius: size * 0.22, y: size * 0.06)
    }
}

/// Decorative poster tiles: staggered columns in the icon's blues, fading into the canvas.
private struct PosterWall: View {
    private static let hues: [Color] = [Brand.cyan, Brand.indigo, Brand.teal, Brand.cyan.opacity(0.6)]
    private static let symbols = ["film", "sparkles.tv", "theatermasks", "music.note.tv", "popcorn", "star"]
    var body: some View {
        GeometryReader { proxy in
            let spacing = proxy.size.width * 0.045
            let width = (proxy.size.width - spacing * 2) / 3
            HStack(alignment: .top, spacing: spacing) {
                ForEach(0..<3, id: \.self) { column in
                    VStack(spacing: spacing) {
                        ForEach(0..<4, id: \.self) { row in tile(column * 4 + row, width: width) }
                    }
                    .offset(y: column == 1 ? -width * 0.55 : column == 2 ? -width * 0.15 : 0)
                }
            }
            .rotationEffect(.degrees(-6))
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
            .background { EllipticalGradient(colors: [Brand.cyan.opacity(0.3), .clear], endRadiusFraction: 0.5) }
            // An ellipse that reaches clear at the frame's edges, so no tile meets a hard clip.
            .mask { EllipticalGradient(stops: [.init(color: .black, location: 0), .init(color: .black.opacity(0.75), location: 0.45), .init(color: .clear, location: 1)], endRadiusFraction: 0.5) }
        }
    }

    private func tile(_ index: Int, width: CGFloat) -> some View {
        let hue = Self.hues[index % Self.hues.count]
        let lit = index % 3 != 1
        return RoundedRectangle(cornerRadius: width * 0.08, style: .continuous)
            .fill(LinearGradient(colors: lit ? [hue.opacity(0.7), hue.opacity(0.28)] : [PosterSurface.raised, PosterSurface.base],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                Image(systemName: Self.symbols[index % Self.symbols.count])
                    .font(.system(size: width * 0.26, weight: .semibold))
                    .foregroundStyle(.white.opacity(lit ? 0.55 : 0.18))
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: width * 0.04) {
                    Capsule().frame(width: width * 0.55, height: width * 0.05)
                    Capsule().frame(width: width * 0.32, height: width * 0.05)
                }
                .foregroundStyle(.white.opacity(lit ? 0.35 : 0.12))
                .padding(width * 0.09)
            }
            .frame(width: width, height: width * 1.45)
    }
}

/// Neutral tile fills that track the canvas on every platform.
private enum PosterSurface {
    static let base = Color(light: Color(red: 0.88, green: 0.905, blue: 0.94), dark: Color(red: 0.065, green: 0.09, blue: 0.165))
    static let raised = Color(light: Color(red: 0.83, green: 0.86, blue: 0.91), dark: Color(red: 0.11, green: 0.15, blue: 0.25))
}

/// A section of Watch Now that Settings can hide. Each one shows until it is switched off.
enum HomeSection: String, CaseIterable, Identifiable {
    case continueWatching, pinnedSources, recommendations, favorites, liveTV
    var id: String { rawValue }
    /// The switch's key in the user defaults.
    var key: String { "homeShows." + rawValue }
    var title: String {
        switch self {
        case .continueWatching: L10n.text("Continue Watching")
        case .pinnedSources: L10n.text("Pinned Sources")
        case .recommendations: L10n.text("Recommendations")
        case .favorites: L10n.text("Favorites")
        case .liveTV: L10n.text("Live TV")
        }
    }
    var symbol: String {
        switch self {
        case .continueWatching: AppSection.history.icon
        case .pinnedSources: "pin.fill"
        case .recommendations: "sparkles"
        case .favorites: AppSection.favorites.icon
        case .liveTV: AppSection.live.icon
        }
    }
    var tint: Color {
        switch self {
        case .continueWatching: Brand.amber
        case .pinnedSources: .purple
        case .recommendations: .orange
        case .favorites: Brand.rose
        case .liveTV: .red
        }
    }
}

/// Settings → Watch Now: which sections the page shows.
struct WatchNowSettingsView: View {
    var body: some View {
        SettingsPage(title: L10n.text("Watch Now"), symbol: AppSection.home.icon) {
            SettingsGroup(title: L10n.text("Show on Watch Now"),
                          footer: L10n.text("A section you switch off only leaves Watch Now: Playback History, Favorites, Sources and Live TV still have everything.")) {
                ForEach(HomeSection.allCases) { HomeSectionToggle(section: $0) }
            }
        }
    }
}

/// One section's switch, stored under the section's own key.
private struct HomeSectionToggle: View {
    let section: HomeSection
    @AppStorage private var shown: Bool
    init(section: HomeSection) {
        self.section = section
        _shown = AppStorage(wrappedValue: true, section.key)
    }
    var body: some View {
        Group {
            #if os(tvOS)
            TVSettingsToggle(title: section.title, isOn: $shown)
            #else
            Toggle(isOn: $shown) { FormLabel(symbol: section.symbol, tint: section.tint, title: section.title) }
                .settingsSwitch()
            #endif
        }
        .accessibilityIdentifier("settings.home." + section.rawValue)
    }
}

import SwiftUI
import TVCore

struct LiveView: View {
    @Environment(Store.self) private var store
    @State private var query = ""
    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        Group {
            if let config = store.subscription, !config.lives.isEmpty {
                ScrollView {
                    Group {
                        if trimmed.isEmpty {
                            LiveSourceGrid(sources: config.lives)
                        } else {
                            LiveSearchResults(query: trimmed, sources: config.lives)
                        }
                    }.pageContainer()
                }
                .catalogSearchable(text: $query, prompt: L10n.text("Search live rooms and channels"))
                #if DEBUG
                // `-qaSection live -qaQuery <text>` shows the Live tab's search.
                .task { if QALaunch.page == nil, let text = UserDefaults.standard.string(forKey: "qaQuery") { query = text } }
                #endif
            } else {
                EmptyPage(symbol: AppSection.live.icon, title: L10n.text("Connect a Live Subscription"),
                          message: L10n.text("Import a TVBox configuration containing live playlists in Settings first."),
                          action: AppSection.settings.title, actionSymbol: AppSection.settings.icon, perform: { store.section = .settings })
            }
        }
        .screenBackdrop()
        .tabTitle(L10n.text("Live TV"))
    }
}

/// Live sources as the Live tab and Home show them: the built-in platforms as a row of brand cards
/// showing a room that is live now, then the subscription's playlists as launcher tiles.
struct LiveSourceGrid: View {
    let sources: [LiveSource]
    /// Section titles; Home's Live TV section has its own header and leaves them out.
    var titled = true
    var body: some View {
        let platforms = sources.compactMap(\.platform)
        let playlists = sources.filter { !$0.isBuiltIn }
        VStack(alignment: .leading, spacing: titled ? Layout.sectionSpacing : Layout.cardSpacing) {
            if !platforms.isEmpty {
                VStack(alignment: .leading, spacing: Layout.headerSpacing) {
                    if titled { SectionHeader(title: L10n.text("Live Platforms")) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: Layout.tileMin), spacing: Layout.cardSpacing)], spacing: Layout.cardSpacing) {
                        ForEach(platforms) { platform in
                            RouteLink { LivePlatformView(platform: platform) } label: { LivePlatformCard(platform: platform) }.tileButton()
                        }
                    }
                }.tvFocusSection()
            }
            if !playlists.isEmpty {
                VStack(alignment: .leading, spacing: Layout.headerSpacing) {
                    if titled { SectionHeader(title: L10n.text("Live Playlists")) }
                    LazyVGrid(columns: Layout.cardColumns, spacing: Layout.cardSpacing) {
                        ForEach(playlists) { source in
                            RouteLink { ChannelListView(source: source) } label: { LiveSourceCard(source: source) }.tileButton()
                        }
                    }
                }.tvFocusSection()
            }
        }
    }
}

/// A live playlist as a launcher tile, like a source card: a monogram icon, its name, and the note
/// its name carries in brackets ("需开启V6网络") as a quiet second line. Use with `tileButton()`.
struct LiveSourceCard: View {
    @Environment(\.isFocused) private var isFocused
    let source: LiveSource
    #if os(tvOS)
    private var focused: Bool { isFocused }
    private let icon: CGFloat = 88, padding: CGFloat = 20, radius: CGFloat = 28
    #else
    private let focused = false
    private let icon: CGFloat = 48, padding: CGFloat = 12, radius: CGFloat = 16
    #endif
    var body: some View {
        let name = Self.split(source.name)
        let label = SourceLabel(name.title)
        let detail = (label.parts.dropFirst() + [name.note].compactMap { $0 }).joined(separator: " · ")
        HStack(spacing: padding) {
            MonogramIcon(seed: source.name, label: label, size: icon)
            VStack(alignment: .leading, spacing: 4) {
                Text(label.parts[0]).font(.headline).lineLimit(1)
                    .foregroundStyle(focused ? Color.black : Color.primary)
                if !detail.isEmpty {
                    Text(detail).font(.subheadline).lineLimit(1)
                        .foregroundStyle(focused ? Color.black.opacity(0.6) : Color.secondary)
                }
            }
            Spacer(minLength: 0)
            #if !os(tvOS)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            #endif
        }
        .padding(padding).frame(maxWidth: .infinity, alignment: .leading)
        .background { TileSurface(focused: focused, radius: radius) }
        .accessibilityElement(children: .combine)
    }

    /// "范明明（需开启V6网络）" → ("范明明", "需开启V6网络").
    static func split(_ name: String) -> (title: String, note: String?) {
        let text = name.trimmingCharacters(in: .whitespaces)
        guard let last = text.last, "）)".contains(last),
              let open = text.lastIndex(where: { "（(".contains($0) }), open > text.startIndex else { return (text, nil) }
        let note = text[text.index(after: open)..<text.index(before: text.endIndex)].trimmingCharacters(in: .whitespaces)
        return (text[..<open].trimmingCharacters(in: .whitespaces), note.isEmpty ? nil : note)
    }
}

struct ChannelListView: View {
    let source: LiveSource
    @Environment(\.dismiss) private var dismiss
    @State private var channels: [Channel] = []
    @State private var query = ""
    @State private var group: String?
    @State private var loading = false
    @State private var loaded = false
    @State private var error: String?
    private var waiting: Bool { channels.isEmpty && error == nil && (loading || !loaded) }
    private var groups: [String] { Array(Set(channels.map(\.group))).sorted() }
    private var filtered: [Channel] {
        channels.filter { (group == nil || $0.group == group) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
    }
    var body: some View {
        #if os(tvOS)
        TVChannelGuide(source: source, channels: channels, query: $query, group: $group,
                       loading: waiting, refreshing: loading, error: error,
                       reload: { Task { await load() } })
            .task(id: source.id) { if !loaded { await load() } }
        #else
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                #if os(tvOS)
                HStack {
                    Spacer()
                    Button { Task { await load() } } label: { Label(L10n.text("Refresh"), systemImage: "arrow.clockwise") }
                        .controlButton().disabled(loading)
                }
                #endif
                if !channels.isEmpty { filterBar } else if waiting { ChipSkeletonRow() }
                if waiting {
                    LoadingCard { .server(source.url.host(), title: L10n.text("Loading channels…")) }
                    ChannelSkeletonGrid()
                }
                if let error {
                    ErrorStateCard(
                        title: L10n.text("Unable to Load Channels"),
                        message: L10n.text("Try again, or choose another source to keep watching."),
                        details: error,
                        retry: { Task { await load() } },
                        goBack: { dismiss() },
                        busy: loading
                    ).padding(.vertical, 24).tvFocusSection()
                }
                if !waiting && error == nil && filtered.isEmpty {
                    ContentUnavailableView(L10n.text("No Matching Channels"), systemImage: "magnifyingglass").frame(maxWidth: .infinity)
                }
                if !filtered.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: Layout.cardMin), spacing: 12)], spacing: 12) {
                        ForEach(filtered) { ChannelCard(channel: $0) }
                    }
                }
            }.pageContainer()
        }
        .screenBackdrop()
        .catalogSearchable(text: $query, prompt: L10n.text("Search channels")).screenTitle(source.name)
        .toolbar { Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.disabled(loading).accessibilityLabel(L10n.text("Refresh")) }
        .task(id: source.id) { if !loaded { await load() } }
        #endif
    }
    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            ChipRow {
                GlassGroup(spacing: 8) {
                    HStack(spacing: 8) {
                        Chip(title: L10n.text("All"), selected: group == nil) { group = nil }
                        ForEach(groups, id: \.self) { value in
                            Chip(title: value.isEmpty ? L10n.text("Ungrouped") : value, selected: group == value) { group = value }
                        }
                    }
                }.padding(.vertical, 4)
            }
            Text(L10n.text("Channels: %lld", filtered.count)).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func load() async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false; if !Task.isCancelled { loaded = true } }
        do { channels = try await HTTPClient().channels(source); if let group, !groups.contains(group) { self.group = nil } }
        catch is CancellationError { }
        catch {
            guard !Task.isCancelled else { return }
            Diagnostics.shared.failure("live", "playlist host=\(source.url.host() ?? "-")", error)
            self.error = error.localizedDescription
        }
    }
}

#if os(tvOS)
/// Channel-only adaptation of a living-room guide. Programme data is not supplied by playlists.
private struct TVChannelGuide: View {
    let source: LiveSource
    let channels: [Channel]
    @Binding var query: String
    @Binding var group: String?
    let loading: Bool
    let refreshing: Bool
    let error: String?
    let reload: () -> Void
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedChannel: String?
    @State private var showingSearch = false
    private var groups: [String] { Array(Set(channels.map(\.group))).sorted() }
    private var filtered: [Channel] {
        channels.filter { (group == nil || $0.group == group) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
    }
    private var highlighted: Channel? { filtered.first { $0.id == focusedChannel } ?? filtered.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 18) {
                Text(source.name).font(.system(size: 28, weight: .semibold)).lineLimit(1)
                Spacer()
                Button { showingSearch = true } label: {
                    Label(query.isEmpty ? L10n.text("Search channels") : query, systemImage: "magnifyingglass")
                        .lineLimit(1)
                }.controlButton()
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark") }
                        .controlButton().accessibilityLabel(L10n.text("Clear search"))
                }
                Button(action: reload) { Image(systemName: "arrow.clockwise") }
                    .controlButton().disabled(refreshing).accessibilityLabel(L10n.text("Refresh"))
            }.tvFocusSection()

            if let channel = highlighted {
                HStack(alignment: .center, spacing: 48) {
                    VStack(alignment: .leading, spacing: 18) {
                        Label(L10n.text("Live TV"), systemImage: "dot.radiowaves.left.and.right")
                            .font(.system(size: 21, weight: .semibold)).foregroundStyle(.secondary)
                        Text(channel.name).font(.system(size: 52, weight: .bold)).lineLimit(2)
                        HStack(spacing: 18) {
                            Text(channel.displayGroup)
                            if store.isFavorite(channel) { Image(systemName: "heart.fill") }
                        }.font(.system(size: 24)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    TVGuideLogo(channel: channel, size: 112)
                        .frame(width: 350, height: 198)
                        .background(TVStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                }.frame(height: 218)
            }

            if !channels.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        category(L10n.text("All"), value: nil)
                        ForEach(groups, id: \.self) { value in
                            category(value.isEmpty ? L10n.text("Ungrouped") : value, value: value)
                        }
                    }.padding(4)
                }.scrollClipDisabled().tvFocusSection()
            }

            if loading {
                LoadingCard(maxWidth: LoadingCard.compact) { .server(source.url.host(), title: L10n.text("Loading channels…")) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ErrorStateCard(title: L10n.text("Unable to Load Channels"),
                               message: L10n.text("Try again, or choose another source to keep watching."),
                               details: error, retry: reload, goBack: { dismiss() }, busy: refreshing)
                Spacer()
            } else if filtered.isEmpty {
                ContentUnavailableView(L10n.text("No Matching Channels"), systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(L10n.text("Channels: %lld", filtered.count))
                        Spacer()
                        Text(L10n.text("Live TV"))
                    }.font(.system(size: 20)).foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(filtered) { channel in
                                channelRow(channel)
                                    .focused($focusedChannel, equals: channel.id)
                            }
                        }.padding(4)
                    }.scrollClipDisabled().tvFocusSection()
                }
            }
        }
        .padding(.horizontal, Layout.gutter).padding(.top, 24).padding(.bottom, 24)
        .screenBackdrop()
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(isPresented: $showingSearch) {
            NavigationStack {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(filtered) { channel in
                            Button {
                                showingSearch = false
                                store.playing = channel
                            } label: {
                                HStack(spacing: 24) {
                                    TVGuideLogo(channel: channel, size: 54)
                                    Text(channel.name)
                                    Spacer()
                                    Image(systemName: "play.fill")
                                }.padding(20)
                            }.buttonStyle(TVGuideRowStyle())
                        }
                        if filtered.isEmpty { Text(L10n.text("No Matching Channels")) }
                    }.padding(48)
                }
                .searchable(text: $query, prompt: Text(L10n.text("Search channels")))
                .screenBackdrop()
            }.onExitCommand { showingSearch = false }
        }
    }

    private func category(_ title: String, value: String?) -> some View {
        Button { group = value; focusedChannel = nil } label: { Text(title) }
            .buttonStyle(TVGuideCategoryStyle(selected: group == value))
            .accessibilityAddTraits(group == value ? [.isSelected] : [])
    }

    private func channelRow(_ channel: Channel) -> some View {
        Button { store.playing = channel } label: {
            HStack(spacing: 26) {
                TVGuideLogo(channel: channel, size: 52).frame(width: 100)
                Rectangle().fill(.primary.opacity(0.12)).frame(width: 1, height: 48)
                Text(channel.name).font(.system(size: 28, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 20)
                Text(channel.displayGroup).font(.system(size: 22)).opacity(0.65).lineLimit(1)
                if store.isFavorite(channel) { Image(systemName: "heart.fill").font(.system(size: 20)) }
                Image(systemName: "play.fill").font(.system(size: 20)).frame(width: 44)
            }.padding(.horizontal, 22).frame(height: 90)
        }
        .buttonStyle(TVGuideRowStyle())
        .contextMenu {
            Button { store.toggleFavorite(channel) } label: {
                Label(store.isFavorite(channel) ? L10n.text("Remove %@ from favorites", channel.name) : L10n.text("Add %@ to favorites", channel.name),
                      systemImage: store.isFavorite(channel) ? "heart.slash" : "heart")
            }
        }
        .accessibilityLabel("\(channel.name), \(channel.displayGroup), \(L10n.text("Play"))")
    }
}

private struct TVGuideLogo: View {
    let channel: Channel
    let size: CGFloat
    var body: some View {
        ZStack {
            Text(String(channel.name.prefix(1))).font(.system(size: size * 0.55, weight: .bold))
                .foregroundStyle(Color.white)
            if let url = channel.logo {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit().padding(5).background(TVStyle.raised)
                    }
                }
            }
        }.frame(width: size, height: size)
            .background(TVStyle.raised, in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct TVGuideRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Row(configuration: configuration) }
    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var focused
        var body: some View {
            configuration.label
                .foregroundStyle(focused ? Color.black : Color.white)
                .background(focused ? Color.white : TVStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                .scaleEffect(configuration.isPressed ? 0.99 : 1)
                .animation(.easeOut(duration: 0.12), value: focused)
        }
    }
}

private struct TVGuideCategoryStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View { Category(configuration: configuration, selected: selected) }
    private struct Category: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @Environment(\.isFocused) private var focused
        var body: some View {
            configuration.label.font(.system(size: 23, weight: .semibold))
                .padding(.horizontal, 24).padding(.vertical, 13)
                .foregroundStyle(selected ? Brand.onAccent : Color.white)
                .background(selected ? Brand.accent : TVStyle.raised, in: Capsule())
                .overlay { Capsule().strokeBorder(focused ? Color.white : .clear, lineWidth: 3).padding(-5) }
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
        }
    }
}
#endif

struct FavoritesView: View {
    @Environment(Store.self) private var store
    var body: some View {
        Group {
            if store.favorites.items.isEmpty {
                EmptyPage(symbol: AppSection.favorites.icon, title: L10n.text("No Favorites Yet"),
                          message: L10n.text("Save a live channel, a video, an episode, a song, or a cloud file with the heart."),
                          action: AppSection.live.title, actionSymbol: AppSection.live.icon, perform: { store.section = .live })
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                        if let error = store.favorites.persistenceError {
                            StatusNotice(text: L10n.text("Unable to save favorites: %@", error))
                        }
                        if !store.favorites.items(.live).isEmpty { liveSection }
                        if !store.favorites.items(.video).isEmpty { filmSection }
                        if !store.favorites.items(.episode).isEmpty { episodeSection }
                        if !store.favorites.items(.music).isEmpty { musicSection }
                        if !store.favorites.items(.cloud).isEmpty { cloudSection }
                    }
                    .pageContainer()
                }
            }
        }
        .screenBackdrop()
        .tabTitle(L10n.text("Favorites"))
    }

    private var liveSection: some View {
        VStack(alignment: .leading, spacing: Layout.headerSpacing) {
            SectionHeader(title: L10n.text("Live TV"))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Layout.cardMin), spacing: 12)], spacing: 12) {
                ForEach(store.favorites.liveChannels) { ChannelCard(channel: $0) }
            }
        }
        .tvFocusSection()
    }

    private var filmSection: some View {
        VStack(alignment: .leading, spacing: Layout.headerSpacing) {
            SectionHeader(title: L10n.text("Films"))
            LazyVGrid(columns: Layout.posterColumns, spacing: Layout.gridRowSpacing) {
                ForEach(store.favorites.items(.video)) { item in
                    if case .video(let video) = item { FavoriteFilmCard(video: video) }
                }
            }
        }
        .tvFocusSection()
    }

    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: Layout.headerSpacing) {
            SectionHeader(title: L10n.text("Saved Episodes"))
            LazyVGrid(columns: Layout.posterColumns, spacing: Layout.gridRowSpacing) {
                ForEach(store.favorites.items(.episode)) { item in
                    if case .episode(let episode) = item { FavoriteEpisodeCard(episode: episode) }
                }
            }
        }
        .tvFocusSection()
    }

    private var musicSection: some View {
        VStack(alignment: .leading, spacing: Layout.headerSpacing) {
            SectionHeader(title: L10n.text("Music"))
            LazyVStack(alignment: .leading, spacing: MusicLayout.rowSpacing) {
                ForEach(store.favorites.items(.music)) { item in
                    if case .music(let track) = item {
                        HStack(spacing: 10) {
                            MusicTrackRow(track: track, showsFavoriteMark: false) { store.music.play(track) }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            // The row's own menu has Unlike, which is how the remote removes it.
                            #if !os(tvOS)
                            FavoriteHeartButton(item: .music(track), name: track.title)
                                .fixedSize()
                            #endif
                        }
                    }
                }
            }
        }
        .tvFocusSection()
    }

    private var cloudSection: some View {
        VStack(alignment: .leading, spacing: Layout.headerSpacing) {
            SectionHeader(title: L10n.text("Cloud Files"))
            LazyVStack(alignment: .leading, spacing: Layout.cardSpacing) {
                ForEach(store.favorites.items(.cloud)) { item in
                    if case .cloud(let file) = item { FavoriteCloudRow(file: file) }
                }
            }
        }
        .tvFocusSection()
    }
}

/// Opens a saved film on its detail page, or reports that the source is gone.
struct FavoriteVideoOpener<Label: View>: View {
    @Environment(Store.self) private var store
    @Environment(\.stripDrag) private var drag
    private let video: FavoriteVideo
    private let label: Label

    init(video: FavoriteVideo, @ViewBuilder label: () -> Label) {
        self.video = video
        self.label = label()
    }

    var body: some View {
        if let listing = video.listingVideo(), let client = store.catalogClient(for: video) {
            RouteLink { VideoDetailView(video: listing, client: client) } label: { label }
                .buttonStyle(IgnoreStripDragCardStyle(drag: drag))
        } else {
            Button {
                if drag?.active != true { store.reportMissingFavoriteSource() }
            } label: { label }
            .cardButton()
        }
    }
}

/// NavigationLink activates on mouse-up; ignore that click while the home strip is dragging.
private struct IgnoreStripDragCardStyle: PrimitiveButtonStyle {
    var drag: StripDrag?
    func makeBody(configuration: Configuration) -> some View {
        Button {
            if drag?.active != true { configuration.trigger() }
        } label: {
            configuration.label
        }
        .cardButton()
    }
}

/// A saved film. The heart is a sibling of the poster button, so it does not open the title.
private struct FavoriteFilmCard: View {
    let video: FavoriteVideo
    @State private var hovering = false
    private var heartRevealed: Bool {
        #if os(macOS)
        hovering
        #else
        true
        #endif
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            FavoriteVideoOpener(video: video) {
                if let listing = video.listingVideo() {
                    PosterCard(video: listing)
                } else {
                    Text(video.videoName).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                }
            }
            .favoriteMenu(.video(video), name: video.videoName)
            #if !os(tvOS)
            FavoriteHeartButton(item: .video(video), name: video.videoName, onArtwork: true, revealed: heartRevealed)
                .fixedSize()
                .padding(8)
            #endif
        }
        #if os(macOS)
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.15), value: hovering)
        #endif
    }
}

/// A saved episode. Playing it does not remove the film favorite, and the heart removes only this episode.
private struct FavoriteEpisodeCard: View {
    @Environment(Store.self) private var store
    let episode: FavoriteEpisode
    @State private var hovering = false
    private var heartRevealed: Bool {
        #if os(macOS)
        hovering
        #else
        true
        #endif
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Button { store.play(episode) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    if let listing = episode.video.listingVideo() {
                        PosterCard(video: listing)
                    } else {
                        Text(episode.video.videoName).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                    }
                    Text(episode.episodeName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .cardButton()
            .favoriteMenu(.episode(episode), name: episode.video.videoName)
            #if !os(tvOS)
            FavoriteHeartButton(item: .episode(episode), name: episode.video.videoName, onArtwork: true, revealed: heartRevealed)
                .fixedSize()
                .padding(8)
            #endif
        }
        .overlay(alignment: .topTrailing) { if hovering { detailsLink.padding(8).transition(.opacity) } }
        #if !os(tvOS)
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.15), value: hovering)
        #endif
    }

    /// The title's page, where a click on the card only plays the episode. A pointer shows it, as on history cards.
    @ViewBuilder private var detailsLink: some View {
        if let listing = episode.video.listingVideo(), let client = store.catalogClient(for: episode.video) {
            RouteLink { VideoDetailView(video: listing, client: client) } label: {
                Image(systemName: "info").font(.system(size: 11, weight: .bold)).foregroundStyle(.white).artworkBadge()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("Show Details")).help(L10n.text("Show Details"))
        }
    }
}

/// A saved cloud file, using the same panel as a channel card and the file row's label.
private struct FavoriteCloudRow: View {
    @Environment(Store.self) private var store
    let file: FavoriteCloudFile

    var body: some View {
        let cloud = CloudFile(id: file.fileID, name: file.fileName, isFolder: false, size: file.size)
        let driveName = CloudFiles.drive(key: file.driveKey)?.name ?? file.driveKey
        HStack(spacing: 10) {
            Button { store.play(file) } label: {
                FileRowLabel(symbol: cloud.symbol, tint: cloud.tint, title: file.fileName, subtitle: driveName)
            }
            .glassRow()
            .favoriteMenu(.cloud(file), name: file.fileName)
            #if !os(tvOS)
            FavoriteHeartButton(item: .cloud(file), name: file.fileName)
                .fixedSize()
            #endif
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentPanel()
    }
}

struct ChannelLogo: View {
    let channel: Channel
    var size: CGFloat = 50
    private static let palette: [[Color]] = [
        [Brand.cyan, Color(red: 0.05, green: 0.36, blue: 0.75)], [Brand.indigo, Color(red: 0.20, green: 0.22, blue: 0.62)],
        [Brand.teal, Color(red: 0.04, green: 0.42, blue: 0.55)], [Color(red: 0.62, green: 0.50, blue: 1.0), Color(red: 0.32, green: 0.18, blue: 0.62)],
        [Color(red: 0.45, green: 0.66, blue: 0.95), Color(red: 0.16, green: 0.30, blue: 0.55)],
    ]
    private var colors: [Color] {
        Self.palette[channel.name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } % Self.palette.count]
    }
    var body: some View {
        #if os(tvOS)
        let size: CGFloat = 72
        #endif
        ZStack {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(String(channel.name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                .font(.system(size: size * 0.4, weight: .bold, design: .rounded)).foregroundStyle(.white)
            if let logo = channel.logo {
                AsyncImage(url: logo) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit().padding(size * 0.12)
                            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.white.opacity(0.95))
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

struct ChannelCard: View {
    @Environment(Store.self) private var store
    @Environment(\.stripDrag) private var drag
    let channel: Channel
    var body: some View {
        let favorite = store.isFavorite(channel)
        HStack(spacing: 10) {
            Button { if drag?.active != true { store.playing = channel } } label: {
                HStack(spacing: 14) {
                    ChannelLogo(channel: channel)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(channel.name).font(.headline).foregroundStyle(.primary).lineLimit(1)
                        Text(channel.displayGroup).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.cardButton()
            Button { if drag?.active != true { store.toggleFavorite(channel) } } label: {
                Image(systemName: favorite ? "heart.fill" : "heart")
                    .font(.title3).foregroundStyle(favorite ? Brand.rose : .secondary)
                    .frame(width: 44, height: 44).contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(favorite ? L10n.text("Remove %@ from favorites", channel.name) : L10n.text("Add %@ to favorites", channel.name))
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .contentPanel()
    }
}

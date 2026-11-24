import SwiftUI
import TVCore

/// Music: search songs, albums or playlists by name (and artist), and play from the best channel
/// found. With no search, the page offers to continue where listening stopped, then shelves of
/// charts, playlists and new albums as Discover has for video, then what played recently.
struct MusicView: View {
    @Environment(Store.self) private var store
    @State private var query = ""
    /// The query Return was pressed for: its direct hit plays once the search knows it. Typing
    /// something else clears it.
    @State private var autoPlayQuery: String?
    @State private var showsSettings = false
    #if DEBUG
    /// `-qaMusicOpen 1` opens the first album or playlist found, for screenshots.
    @State private var qaOpened: MusicCollection?
    /// `-qaMusicDownload <n>` downloads the first n songs found, once; `-qaMusicDownloads 1` opens
    /// Downloaded Songs.
    @State private var qaDownloaded = false
    @State private var qaDownloads = UserDefaults.standard.bool(forKey: "qaMusicDownloads")
    #endif

    var body: some View {
        let search = store.musicSearch
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MusicLayout.rowSpacing) {
                #if os(tvOS)
                let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                if !typed.isEmpty, typed != search.query {
                    SearchQueryButton(query: typed) { search.search(typed, immediately: true) }
                        .padding(.bottom, 12)
                } else if typed.isEmpty {
                    MusicNowPlayingButton()
                }
                #endif
                #if !os(macOS)
                if !search.query.isEmpty { kinds(search) }
                #endif
                if !search.query.isEmpty { filters(search) }
                content(search)
            }
            .glassRowInsets()
            .pageContainer()
        }
        .screenBackdrop()
        .catalogSearchable(text: $query, prompt: L10n.text("Song, artist, album or playlist"))
        .onChange(of: query) { _, text in
            if text.trimmingCharacters(in: .whitespacesAndNewlines) != autoPlayQuery { autoPlayQuery = nil }
            #if os(tvOS)
            // As in Global Search: typing only edits the query, and results change when it is
            // submitted. Results replaced under the keyboard took focus away from the letters.
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { search.clear() }
            #else
            search.search(text, kind: Self.searchKind)
            #endif
        }
        .onSubmit(of: .search) {
            autoPlayQuery = search.kind == .songs || search.kind == .top ? query.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            search.search(query, kind: Self.searchKind, immediately: true); playDirectHitIfReady()
        }
        .onChange(of: search.busy) {
            playDirectHitIfReady()
            #if DEBUG
            if !search.busy, UserDefaults.standard.bool(forKey: "qaMusicOpen"), qaOpened == nil { qaOpened = search.collections.first }
            let count = UserDefaults.standard.integer(forKey: "qaMusicDownload")
            if !search.busy, count > 0, !qaDownloaded, !search.results.isEmpty {
                qaDownloaded = true
                MusicDownloadLibrary.shared.download(Array(search.results.prefix(count)))
            }
            #endif
        }
        #if DEBUG && os(tvOS)
        // `-qaNowPlayingTab 1` (with `-qaMusicPlay 1 -qaMusicStayOnPage 1`) moves to the sidebar's
        // Now Playing once the song is loaded, for screenshots.
        .onChange(of: store.music.track != nil) { _, loaded in
            if loaded, UserDefaults.standard.bool(forKey: "qaNowPlayingTab") { store.section = .nowPlaying }
        }
        #endif
        #if DEBUG
        .navigationDestination(isPresented: $qaDownloads) {
            #if os(macOS)
            MusicDownloadsView().musicBar()
            #else
            MusicDownloadsView()
            #endif
        }
        #endif
        #if DEBUG
        .navigationDestination(item: $qaOpened) {
            #if os(macOS)
            MusicCollectionView(collection: $0).musicBar()
            #else
            MusicCollectionView(collection: $0)
            #endif
        }
        #endif
        .musicPlayerInset()
        #if os(tvOS)
        .onPlayPauseCommand { store.music.toggle() }
        #endif
        // The shelves load the first time the page shows with nothing searched, not at launch.
        .task(id: search.query.isEmpty) { if search.query.isEmpty { await store.musicBrowse.load() } }
        .tabTitle(L10n.text("Music"))
        #if !os(tvOS)
        .toolbar {
            Button { showsSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                .accessibilityLabel(L10n.text("Music Settings"))
        }
        #endif
        #if os(tvOS)
        .fullScreenCover(isPresented: $showsSettings) { MusicSettingsView() }
        #else
        .sheet(isPresented: $showsSettings) { MusicSettingsView() }
        #endif
        .task {
            if query.isEmpty, !search.query.isEmpty { query = search.query }
            if let kind = Self.searchKind, search.kind != kind { search.search(search.query, kind: kind) }
            #if DEBUG
            // `-qaMusicDecade 2000 -qaMusicGenre pop -qaMusicLanguage mandarin` turns search filters on first.
            let qaFilter = MusicSearchFilter(
                decade: UserDefaults.standard.string(forKey: "qaMusicDecade").flatMap { Int($0) }.flatMap(MusicDecade.init(rawValue:)),
                genre: UserDefaults.standard.string(forKey: "qaMusicGenre").flatMap(MusicGenre.init(rawValue:)),
                language: UserDefaults.standard.string(forKey: "qaMusicLanguage").flatMap(MusicLanguage.init(rawValue:)))
            if !qaFilter.isEmpty { search.setFilter(qaFilter) }
            // `-qaSection music -qaQuery <text> [-qaMusicKind albums] [-qaMusicPlay 1]` searches, and plays the direct hit.
            if query.isEmpty, let text = UserDefaults.standard.string(forKey: "qaQuery") {
                if UserDefaults.standard.bool(forKey: "qaMusicPlay") { autoPlayQuery = text }
                query = text
                search.search(text, kind: UserDefaults.standard.string(forKey: "qaMusicKind").flatMap(MusicSearchKind.init(rawValue:)), immediately: true)
            }
            // `-qaMusicSettings 1` opens Music Settings.
            if UserDefaults.standard.bool(forKey: "qaMusicSettings") { showsSettings = true }
            #endif
        }
    }

    /// Apple TV leads with All, its results in rows; a phone or iPad has only the kinds.
    private static var chips: [MusicSearchKind] {
        #if os(tvOS)
        [.top] + MusicSearchKind.filters
        #else
        MusicSearchKind.filters
        #endif
    }

    /// The Mac shows every kind at once, in rows, with no chips; elsewhere the chips choose one.
    private static var searchKind: MusicSearchKind? {
        #if os(macOS)
        .top
        #else
        nil
        #endif
    }

    private func playDirectHitIfReady() {
        let search = store.musicSearch
        guard let wanted = autoPlayQuery, wanted == search.query, !search.busy else { return }
        autoPlayQuery = nil
        var hit = search.directHit
        #if DEBUG
        // `-qaMusicPlay 1` plays the first result when no single one is clearly meant.
        if hit == nil, UserDefaults.standard.bool(forKey: "qaMusicPlay") { hit = search.results.first }
        #endif
        if let hit, store.music.track?.id != hit.id { playResults(from: hit) }
    }

    private func kinds(_ search: MusicSearchModel) -> some View {
        ChipRow {
            GlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(Self.chips, id: \.self) { kind in
                        Chip(title: kind.name, selected: search.kind == kind) { search.search(query, kind: kind, immediately: true) }
                    }
                }
            }.padding(.vertical, 4)
        }
        .padding(.bottom, 8)
        .tvFocusSection()
    }

    /// The filters get a row of their own, so one that is on stays in sight.
    @ViewBuilder private func filters(_ search: MusicSearchModel) -> some View {
        if !MusicSearchFilter.facets(for: search.kind).isEmpty {
            ChipRow { HStack(spacing: 8) { MusicFilterMenus(search: search) }.padding(.vertical, 4) }
                .padding(.bottom, 8)
                .tvFocusSection()
        }
    }

    @ViewBuilder private func content(_ search: MusicSearchModel) -> some View {
        if search.query.isEmpty {
            MusicHome { showsSettings = true }
        } else if search.results.isEmpty && search.collections.isEmpty && search.busy {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 80)
        } else if search.failed {
            ErrorState(title: L10n.text("Unable to Search Music"), message: L10n.text("Check your network connection and try again."),
                           details: failureDetails(search), retry: { search.search(query, immediately: true) }, busy: search.busy)
                .padding(.vertical, 24).tvFocusSection()
        } else if search.filteredOut {
            EmptyResults(symbol: "line.3.horizontal.decrease", title: L10n.text("No Matches"),
                         message: L10n.text("No results match these filters. Only songs QQ Music lists have a year, genre and language."),
                         action: L10n.text("Reset Filters"), actionSymbol: "arrow.counterclockwise") { search.setFilter(MusicSearchFilter()) }
        } else if search.empty {
            EmptyResults(symbol: "music.note", title: L10n.text("No Matching Songs"), message: L10n.text("Try the song's full name, or add the artist."))
        } else {
            ForEach(search.failures.keys.sorted { $0.rawValue < $1.rawValue }, id: \.self) { platform in
                StatusNotice(text: L10n.text("%@ didn't answer, so these results are from the other catalog.", platform.name))
                    .padding(.bottom, 10)
            }
            if search.kind == .top {
                #if os(macOS) || os(tvOS)
                MusicTopResults(search: search) { playResults(from: $0) }
                #endif
            } else if search.kind == .songs || search.kind == .artists {
                ForEach(search.results) { track in MusicTrackRow(track: track) { playResults(from: track) } }
            } else {
                ForEach(search.collections) { collection in MusicCollectionRow(collection: collection) }
            }
        }
    }

    /// A song from the results plays with the results after it queued, so the next one follows.
    private func playResults(from track: MusicTrack) {
        let results = store.musicSearch.results
        guard let index = results.firstIndex(of: track) else { store.music.play(track); return }
        store.music.play(MusicQueue(tracks: results, start: index))
    }

    private func failureDetails(_ search: MusicSearchModel) -> String {
        search.failures.map { "\($0.key.name): \($0.value.localizedDescription) (\($0.value.detail))" }.sorted().joined(separator: "\n")
    }
}

/// Year, genre and language menus after the kind chips (#649), as many as the kind's results can be narrowed by.
/// A menu names its choice once one is made; the cross clears them all.
private struct MusicFilterMenus: View {
    let search: MusicSearchModel

    var body: some View {
        let filter = search.filter
        ForEach(MusicSearchFilter.facets(for: search.kind), id: \.self) { facet in
            switch facet {
            case .decade: menu("decade", L10n.text("Year"), filter.decade, MusicDecade.allCases, \.name) { $0.decade = $1 }
            case .genre: menu("genre", L10n.text("Genre"), filter.genre, MusicGenre.allCases, \.name) { $0.genre = $1 }
            case .language: menu("language", L10n.text("Language"), filter.language, MusicLanguage.allCases, \.name) { $0.language = $1 }
            }
        }
        if !filter.isEmpty, !MusicSearchFilter.facets(for: search.kind).isEmpty {
            Button { search.setFilter(MusicSearchFilter()) } label: {
                #if os(tvOS)
                Label(L10n.text("Reset Filters"), systemImage: "xmark")
                #elseif os(macOS)
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 30, height: 30)
                    .background(.primary.opacity(0.07), in: Circle()).contentShape(Circle())
                #else
                Image(systemName: "xmark").frame(width: 38, height: 38).glassSurface(.regular, in: Circle())
                #endif
            }
            #if os(tvOS)
            .buttonStyle(DiscoverTVChipStyle(active: false))
            #else
            .buttonStyle(.plain)
            #endif
            .accessibilityLabel(L10n.text("Reset Filters")).accessibilityIdentifier("music.filter.reset")
        }
    }

    private func menu<Value: Hashable>(_ id: String, _ title: String, _ current: Value?, _ values: [Value], _ name: @escaping (Value) -> String,
                                       set: @escaping (inout MusicSearchFilter, Value?) -> Void) -> some View {
        let choose = { (value: Value?) in var next = search.filter; set(&next, value); search.setFilter(next) }
        return Menu {
            Button { choose(nil) } label: { checked(L10n.text("Any"), current == nil) }
            ForEach(values, id: \.self) { value in Button { choose(value) } label: { checked(name(value), current == value) } }
        } label: {
            #if os(tvOS)
            Text(current.map(name) ?? title)
            #else
            FilterChipLabel(title: current.map(name) ?? title, open: current != nil)
            #endif
        }
        #if os(tvOS)
        .menuStyle(.button).buttonStyle(DiscoverTVChipStyle(active: current != nil))
        #else
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        #endif
        .accessibilityIdentifier("music.filter." + id)
    }

    @ViewBuilder private func checked(_ text: String, _ on: Bool) -> some View {
        if on { Label(text, systemImage: "checkmark") } else { Text(text) }
    }
}

enum MusicLayout {
    #if os(tvOS)
    static let rowSpacing: CGFloat = 8, art: CGFloat = 76, gap: CGFloat = 22, header: CGFloat = 260
    #else
    static let rowSpacing: CGFloat = 2, art: CGFloat = 48, gap: CGFloat = 14, header: CGFloat = 150
    #endif
}

/// The Music page with nothing searched: continue listening, shelves to browse, and what played recently.
private struct MusicHome: View {
    @Environment(Store.self) private var store
    let openSettings: () -> Void

    var body: some View {
        let library = store.music.library
        let browse = store.musicBrowse
        let resumable = store.music.track == nil ? library.resumePoint : nil
        let downloads = !MusicDownloadLibrary.shared.items.isEmpty
        let empty = library.history.isEmpty && resumable == nil && !downloads && browse.sections.isEmpty && !browse.loading
        #if os(tvOS)
        // Apple TV has no toolbar button for Music Settings (where music sources are added), so the page offers it
        // here once there is something to show; the empty page below has its own (#1024).
        if !empty {
            Button(action: openSettings) { Label(L10n.text("Music Settings"), systemImage: "slider.horizontal.3") }
                .glassPill()
                .accessibilityIdentifier("music.settings")
                .padding(.bottom, 20)
        }
        #endif
        if let point = resumable, let track = point.queue.current {
            MusicContinueCard(point: point, track: track).padding(.bottom, 20)
        }
        let liked = store.favorites.musicTracks.count
        if liked > 0 { MusicLikedLink(count: liked).padding(.bottom, 20) }
        let likedCollections = store.favorites.musicCollections.count
        if likedCollections > 0 { MusicLikedCollectionsLink(count: likedCollections).padding(.bottom, 20) }
        if downloads { MusicDownloadsLink().padding(.bottom, 20) }
        if !browse.sections.isEmpty {
            MusicBrowseShelves(sections: browse.sections).padding(.bottom, 28)
        } else if browse.loading {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 60)
        }
        if browse.incomplete && !browse.loading {
            Button { Task { await browse.load() } } label: {
                Label(L10n.text("Some lists couldn't load. Try again."), systemImage: "arrow.clockwise")
                    #if !os(tvOS)
                    .font(.subheadline).frame(maxWidth: .infinity).padding(.vertical, 8)
                    #endif
            }
            #if os(tvOS)
            .controlButton().frame(maxWidth: .infinity)
            #else
            .buttonStyle(.plain)
            #endif
            .padding(.bottom, 20)
        }
        if !library.history.isEmpty {
            HStack {
                SectionHeader(title: L10n.text("Recently Played"))
                Spacer()
                Button(L10n.text("Clear")) { library.clearHistory() }.controlButton()
            }
            .padding(.bottom, 8)
            .tvFocusSection()
            ForEach(library.history.prefix(100)) { entry in
                // One entry can go on its own, from its menu, besides Clear for all of them (#1742).
                if let collection = entry.collection {
                    MusicCollectionRow(collection: collection) { library.remove(entry) }
                } else if let track = entry.track {
                    MusicTrackRow(track: track, removeFromHistory: { library.remove(entry) }) { store.music.play(track) }
                }
            }
        } else if empty {
            EmptyPage(symbol: "music.note", title: L10n.text("Search for a Song"),
                      message: L10n.text("Type a song's name, or its name and the artist. Yingxia finds the recording and plays it from the best channel available, lossless first."),
                      action: L10n.text("Music Settings"), actionSymbol: "slider.horizontal.3", perform: openSettings)
                .frame(minHeight: 420)
        }
    }
}

private struct MusicContinueCard: View {
    @Environment(Store.self) private var store
    let point: MusicResumePoint
    let track: MusicTrack

    var body: some View {
        Button { store.music.resume() } label: {
            HStack(spacing: MusicLayout.gap) {
                MusicArtwork(url: track.artwork, size: MusicLayout.art * 1.4)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("Continue Playing")).font(.caption.weight(.semibold)).foregroundStyle(Brand.accent)
                    Text(track.title).font(.headline).lineLimit(1)
                    Text([track.artistLine, point.queue.source, L10n.text("Stopped at %@", MusicTime.text(point.position))]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "play.circle.fill").font(.system(size: MusicLayout.art * 0.6)).foregroundStyle(Brand.accent)
            }
            .padding(14)
            .contentPanel(cornerRadius: 20)
            .contentShape(Rectangle())
        }
        .panelCardButton(cornerRadius: 20)
    }
}

struct MusicTrackRow: View {
    @Environment(Store.self) private var store
    let track: MusicTrack
    /// Its place in an album or playlist, shown instead of the cover.
    var number: Int?
    /// Off when a heart beside the row removes the favorite, so the row does not show a second heart.
    var showsFavoriteMark = true
    /// In Recently Played: takes this song out of it, from the row's menu.
    var removeFromHistory: (() -> Void)?
    let action: () -> Void

    var body: some View {
        let current = store.music.track?.id == track.id
        Button(action: action) {
            HStack(spacing: MusicLayout.gap) {
                if let number {
                    Text("\(number)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: MusicLayout.art * 0.6, alignment: .trailing)
                } else {
                    MusicArtwork(url: track.artwork, size: MusicLayout.art)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title).font(.headline).lineLimit(1)
                        .foregroundStyle(current ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(.primary))
                    Text([track.artistLine, number == nil ? track.album : nil].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                ForEach(track.tags.sorted(), id: \.self) { tag in Pill(text: tag.name) }
                if current { MusicActivityMark() }
                // A slot for the download state on every row, saved or not, and lengths at least as wide
                // as "00:00", trailing: the marks and the lengths each stay in a column.
                Group {
                    if let saved = MusicDownloadLibrary.shared.item(for: track) { DownloadState(status: saved.status, fraction: saved.fraction) }
                }
                .frame(width: DownloadState.size * 1.2)
                if showsFavoriteMark, store.favorites.contains(.music(track)) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: DownloadState.size, weight: .semibold))
                        .foregroundStyle(Brand.rose)
                        .accessibilityHidden(true)
                }
                if let duration = track.duration {
                    ZStack(alignment: .trailing) {
                        Text(verbatim: "00:00").hidden()
                        Text(MusicTime.text(duration))
                    }
                    .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, number == nil ? 6 : 10)
            .contentShape(Rectangle())
        }
        .glassRow()
        // On Apple TV, a long press.
        .contextMenu {
            FavoriteMenuButton(item: .music(track), name: track.title)
            Button { store.music.playNext([track]) } label: { Label(L10n.text("Play Next"), systemImage: "text.line.first.and.arrowtriangle.forward") }
            Button { store.music.addToUpNext([track]) } label: { Label(L10n.text("Add to Up Next"), systemImage: "text.line.last.and.arrowtriangle.forward") }
            MusicArtistMenu(track: track)
            Divider()
            MusicDownloadMenuItems(tracks: [track])
            if let removeFromHistory { MusicRemoveFromHistoryButton(action: removeFromHistory) }
        }
        .accessibilityLabel(Text([track.title, track.artistLine].joined(separator: ", ")))
    }
}

private struct MusicRemoveFromHistoryButton: View {
    let action: () -> Void
    var body: some View {
        Divider()
        Button(role: .destructive, action: action) { Label(L10n.text("Remove from Recently Played"), systemImage: "minus.circle") }
    }
}

/// "Go to Artist" in a song's menu (#1755): the artist's songs on a page of their own, one item for each artist
/// when several sing it. Left out where no stack can take the page.
struct MusicArtistMenu: View {
    @Environment(\.openRoute) private var openRoute
    let track: MusicTrack

    var body: some View {
        let artists = track.artists.filter { !$0.isEmpty }
        if let openRoute, let first = artists.first {
            if artists.count == 1 {
                button(first, label: L10n.text("Go to Artist"), openRoute)
            } else {
                Menu {
                    ForEach(artists, id: \.self) { button($0, label: $0, openRoute) }
                } label: {
                    Label(L10n.text("Go to Artist"), systemImage: "music.mic")
                }
            }
        }
    }

    private func button(_ artist: String, label: String, _ openRoute: RouteOpener) -> some View {
        Button { openRoute(Route { AnyView(MusicArtistView(name: artist)) }) } label: { Label(label, systemImage: "music.mic") }
    }
}

/// Likes an album or playlist, or unlikes it: Liked Albums & Playlists on the Music page keeps them (#720).
struct MusicCollectionLikeButton: View {
    @Environment(Store.self) private var store
    let collection: MusicCollection
    /// Only the heart, for a row of round buttons, in a square this wide when given.
    var iconOnly = false
    var side: CGFloat?

    var body: some View {
        let on = store.favorites.contains(collection)
        Button { store.favorites.toggle(collection) } label: {
            let label = Label(L10n.text(on ? "Unlike" : "Like"), systemImage: on ? (iconOnly ? "heart.fill" : "heart.slash") : "heart")
            if iconOnly { label.labelStyle(.iconOnly).frame(width: side, height: side) } else { label }
        }
        .accessibilityLabel(on ? L10n.text("Remove %@ from favorites", collection.title) : L10n.text("Add %@ to favorites", collection.title))
    }
}

private struct MusicCollectionRow: View {
    let collection: MusicCollection
    /// In Recently Played: takes this album or playlist out of it, from the row's menu.
    var removeFromHistory: (() -> Void)?

    var body: some View {
        RouteLink {
            MusicCollectionView(collection: collection)
        } label: {
            HStack(spacing: MusicLayout.gap) {
                MusicArtwork(url: collection.artwork, size: MusicLayout.art, symbol: collection.kind == .album ? "square.stack" : "music.note.list")
                VStack(alignment: .leading, spacing: 3) {
                    Text(collection.title).font(.headline).lineLimit(1).foregroundStyle(.primary)
                    Text(MusicCollectionView.details(collection)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .glassRow()
        // On Apple TV, a long press.
        .contextMenu {
            MusicCollectionLikeButton(collection: collection)
            if let removeFromHistory { MusicRemoveFromHistoryButton(action: removeFromHistory) }
        }
    }
}

/// The way to liked albums and playlists, under Liked Songs on the Music page.
private struct MusicLikedCollectionsLink: View {
    let count: Int

    var body: some View {
        RouteLink { MusicLikedCollectionsView() } label: {
            HStack(spacing: MusicLayout.gap) {
                Image(systemName: "square.stack.fill")
                    .font(.system(size: MusicLayout.art * 0.42, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: MusicLayout.art, height: MusicLayout.art)
                    .background(Brand.rose.gradient, in: RoundedRectangle(cornerRadius: MusicLayout.art * 0.3, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(MusicLikedCollectionsView.title).font(.headline).lineLimit(1).foregroundStyle(.primary)
                    Text(L10n.text("%lld albums and playlists", count)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .glassRow()
    }
}

/// Albums and playlists liked from their pages, newest first (#720). Unlike one from its menu, or on its page.
struct MusicLikedCollectionsView: View {
    @Environment(Store.self) private var store

    static var title: String { L10n.text("Liked Albums & Playlists") }

    var body: some View {
        let collections = store.favorites.musicCollections
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MusicLayout.rowSpacing) {
                #if os(tvOS)
                MusicNowPlayingButton()
                #endif
                #if os(macOS)
                Text(Self.title).font(.largeTitle.weight(.bold)).padding(.bottom, 20)
                #endif
                if collections.isEmpty {
                    EmptyResults(symbol: "heart", title: L10n.text("No Liked Albums or Playlists"),
                                 message: L10n.text("Like an album or playlist on its page, and it waits here."))
                }
                ForEach(collections) { MusicCollectionRow(collection: $0) }
            }
            .glassRowInsets()
            .pageContainer()
        }
        .screenBackdrop()
        .screenTitle(Self.title)
        #if os(macOS)
        .toolbar(removing: .title)
        #endif
        .musicPlayerInset()
        #if os(tvOS)
        .onPlayPauseCommand { store.music.toggle() }
        #endif
    }
}

/// An artist's songs (#1755): what searching the catalogs by the artist's name finds, the best known first.
struct MusicArtistView: View {
    let name: String
    @Environment(Store.self) private var store
    /// Its own search, so the Music page keeps what was searched there. Made when the page first shows.
    @State private var search: MusicSearchModel?
    /// The artist in Apple Music's catalog: picture, notes, and which songs are their best known.
    @State private var apple: AppleMusicCatalog.Artist?

    var body: some View {
        let tracks = AppleMusicCatalog.ranked(search?.results ?? [], top: apple?.topSongs ?? [])
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MusicLayout.rowSpacing) {
                #if os(tvOS)
                MusicNowPlayingButton()
                #endif
                header(tracks).padding(.bottom, 20)
                if let search {
                    if tracks.isEmpty && (search.busy || search.query.isEmpty) {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 60)
                    } else if search.failed {
                        ErrorState(title: L10n.text("Unable to Search Music"), message: L10n.text("Check your network connection and try again."),
                                   details: search.failures.map { "\($0.key.name): \($0.value.localizedDescription) (\($0.value.detail))" }.sorted().joined(separator: "\n"),
                                   retry: { search.search(name, kind: .artists, immediately: true) }, busy: search.busy)
                            .padding(.vertical, 24).tvFocusSection()
                    } else if search.empty {
                        EmptyResults(symbol: "music.mic", title: L10n.text("No Matching Songs"))
                    }
                }
                #if os(macOS)
                MusicSongTable(tracks: tracks) { store.music.play(MusicQueue(tracks: tracks, start: $0, source: name)) }
                #else
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    MusicTrackRow(track: track) { store.music.play(MusicQueue(tracks: tracks, start: index, source: name)) }
                }
                #endif
            }
            .glassRowInsets()
            .pageContainer()
        }
        .screenBackdrop()
        .screenTitle(name)
        #if os(macOS)
        .toolbar(removing: .title)
        #endif
        .musicPlayerInset()
        #if os(tvOS)
        .onPlayPauseCommand { store.music.toggle() }
        #endif
        .task {
            guard search == nil else { return }
            let model = MusicSearchModel(catalogs: MusicSearchModel.defaultCatalogs() + [MusicExtensionCatalog()], kind: .artists)
            search = model
            model.search(name, kind: .artists, immediately: true)
            apple = await AppleMusicCatalog.shared.artist(named: name)
        }
    }

    private func header(_ tracks: [MusicTrack]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("Artist")).font(.caption.weight(.semibold)).foregroundStyle(Brand.accent)
            #if os(macOS)
            Text(name).font(.largeTitle.weight(.bold))
            #endif
            if let apple { MusicAppleArtistSummary(artist: apple) }
            HStack(spacing: 10) {
                Group {
                    Button { store.music.play(MusicQueue(tracks: tracks, start: 0, source: name)) } label: {
                        Label(L10n.text("Play"), systemImage: "play.fill")
                    }
                    .controlButton(prominent: true)
                    Button { store.music.play(MusicQueue.shuffled(tracks, source: name)) } label: {
                        Label(L10n.text("Shuffle"), systemImage: "shuffle")
                    }
                    .controlButton()
                }
                .disabled(tracks.isEmpty)
            }
            .fixedSize()
            .tvFocusSection()
        }
    }
}

/// An album or playlist: its tracks, Play and Shuffle. Playing a track queues the whole list from it.
struct MusicCollectionView: View {
    let collection: MusicCollection
    @Environment(Store.self) private var store
    @State private var tracks: [MusicTrack] = []
    @State private var loading = false
    @State private var error: String?
    /// The album in Apple Music's catalog, for its notes, release date and label.
    @State private var apple: AppleMusicCatalog.Album?

    static func details(_ collection: MusicCollection) -> String {
        [collection.subtitle, collection.trackCount.map { L10n.text("%lld songs", $0) }, collection.year, collection.platform.name]
            .compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MusicLayout.rowSpacing) {
                #if os(tvOS)
                MusicNowPlayingButton()
                #endif
                #if os(macOS)
                MusicCollectionHeader(collection: collection, tracks: tracks).padding(.bottom, 28)
                #else
                header.padding(.bottom, 24)
                #endif
                if loading && tracks.isEmpty { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 60) }
                if let error {
                    ErrorState(title: L10n.text("Unable to Load Songs"), message: L10n.text("Check your network connection and try again."),
                                   details: error, retry: { Task { await load() } }, busy: loading)
                        .padding(.vertical, 24).tvFocusSection()
                }
                #if os(macOS)
                MusicSongTable(tracks: tracks, numbered: collection.kind == .album) {
                    store.music.play(MusicQueue(tracks: tracks, start: $0, collection: collection))
                }
                #else
                ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                    MusicTrackRow(track: track, number: index + 1) {
                        store.music.play(MusicQueue(tracks: tracks, start: index, collection: collection))
                    }
                }
                #endif
                if let apple, MusicAppleAlbumAbout.shows(apple) { MusicAppleAlbumAbout(album: apple) }
            }
            .glassRowInsets()
            .pageContainer()
        }
        .screenBackdrop()
        .screenTitle(collection.title)
        #if os(macOS)
        // The header already names it in large type.
        .toolbar(removing: .title)
        #endif
        .musicPlayerInset()
        #if os(tvOS)
        .onPlayPauseCommand { store.music.toggle() }
        #endif
        .task {
            if tracks.isEmpty { await load() }
            if collection.kind == .album, apple == nil {
                apple = await AppleMusicCatalog.shared.album(title: collection.title, artist: collection.subtitle)
            }
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "qaMusicPlay"), store.music.track == nil, !tracks.isEmpty {
                store.music.play(MusicQueue(tracks: tracks, collection: collection))
            }
            // `-qaMusicSaveCollection 1` downloads the album or playlist, for its shelf in Downloaded Songs.
            if UserDefaults.standard.bool(forKey: "qaMusicSaveCollection"), !tracks.isEmpty {
                MusicDownloadLibrary.shared.download(tracks, from: collection)
            }
            #endif
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: MusicLayout.gap * 1.4) {
                MusicArtwork(url: collection.artwork, size: MusicLayout.header, symbol: collection.kind == .album ? "square.stack" : "music.note.list")
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text(collection.kind == .album ? "Album" : "Playlist")).font(.caption.weight(.semibold)).foregroundStyle(Brand.accent)
                    Text(collection.title).font(.title2.weight(.bold)).lineLimit(2)
                    Text(Self.details(collection)).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            HStack(spacing: 10) {
                    Button { store.music.play(MusicQueue(tracks: tracks, collection: collection)) } label: {
                        Label(L10n.text("Play"), systemImage: "play.fill")
                    }
                    .controlButton(prominent: true)
                    Button { store.music.play(MusicQueue.shuffled(tracks, collection: collection)) } label: {
                        Label(L10n.text("Shuffle"), systemImage: "shuffle")
                    }
                    .controlButton()
                    MusicDownloadButton(tracks: tracks, collection: collection).controlButton()
                    MusicCollectionLikeButton(collection: collection, iconOnly: true).controlButton()
            }
            .fixedSize()
            .disabled(tracks.isEmpty)
        }
        .tvFocusSection()
    }

    private func load() async {
        guard let source = store.musicSearch.source(for: collection.platform) else { return }
        loading = true; error = nil
        defer { loading = false }
        do { tracks = try await source.tracks(of: collection) }
        catch { self.error = MusicProviderError(error).localizedDescription + " (" + MusicProviderError(error).detail + ")" }
    }
}

/// The way to liked songs, at the top of the Music page: every song saved with Like, played as one list.
struct MusicLikedLink: View {
    let count: Int

    var body: some View {
        RouteLink { MusicLikedView() } label: {
            HStack(spacing: MusicLayout.gap) {
                #if os(iOS)
                SectionGlyph(section: .favorites, size: MusicLayout.art)
                #else
                Image(systemName: AppSection.favorites.icon)
                    .font(.system(size: MusicLayout.art * 0.46, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: MusicLayout.art, height: MusicLayout.art)
                    .background(Brand.rose.gradient, in: RoundedRectangle(cornerRadius: MusicLayout.art * 0.3, style: .continuous))
                    .accessibilityHidden(true)
                #endif
                VStack(alignment: .leading, spacing: 3) {
                    Text(MusicLikedView.title).font(.headline).lineLimit(1).foregroundStyle(.primary)
                    Text(L10n.text("%lld songs", count)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .glassRow()
    }
}

/// The songs saved with Like, newest first. Play, Shuffle and Add to Up Next treat them as one list,
/// so liking songs is all it takes to build a playlist.
struct MusicLikedView: View {
    @Environment(Store.self) private var store

    static var title: String { L10n.text("Liked Songs") }
    /// Narrows the list by title, artist or album (#1854); Play and Shuffle then take what shows.
    @State private var filter = ""

    var body: some View {
        let liked = store.favorites.musicTracks
        let tracks = filter.isEmpty ? liked : liked.filter { $0.matches(filter) }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MusicLayout.rowSpacing) {
                header(tracks).padding(.bottom, 20)
                if liked.isEmpty {
                    EmptyResults(symbol: "heart", title: L10n.text("No Liked Songs"),
                                 message: L10n.text("Like a song from its menu, and it waits here, ready to play as one list."))
                } else if tracks.isEmpty {
                    EmptyResults(symbol: "magnifyingglass", title: L10n.text("No Matching Songs"))
                }
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    HStack(spacing: 10) {
                        MusicTrackRow(track: track, showsFavoriteMark: false) {
                            store.music.play(MusicQueue(tracks: tracks, start: index, source: Self.title))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // The row's own menu has Unlike, which is how the remote removes it.
                        #if !os(tvOS)
                        FavoriteHeartButton(item: .music(track), name: track.title)
                            .fixedSize()
                        #endif
                    }
                }
            }
            .glassRowInsets()
            .pageContainer()
        }
        // Not on Apple TV: the system search there takes the top of the page for its keyboard row.
        #if !os(tvOS)
        .catalogSearchable(text: $filter, prompt: L10n.text("Search Liked Songs"), endsWhenIdle: true)
        #endif
        .screenBackdrop()
        .screenTitle(Self.title)
        #if os(macOS)
        // The header names it in large type, as on the other Music pages.
        .toolbar(removing: .title)
        #endif
        .musicPlayerInset()
        #if os(tvOS)
        .onPlayPauseCommand { store.music.toggle() }
        #endif
    }

    private func header(_ tracks: [MusicTrack]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            #if os(macOS)
            Text(Self.title).font(.largeTitle.weight(.bold))
            #endif
            Text(L10n.text("%lld songs", tracks.count))
                .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Group {
                    Button { store.music.play(MusicQueue(tracks: tracks, start: 0, source: Self.title)) } label: {
                        Label(L10n.text("Play"), systemImage: "play.fill")
                    }
                    .controlButton(prominent: true)
                    Button { store.music.play(MusicQueue.shuffled(tracks, source: Self.title)) } label: {
                        Label(L10n.text("Shuffle"), systemImage: "shuffle")
                    }
                    .controlButton()
                    Button { store.music.addToUpNext(tracks) } label: {
                        Label(L10n.text("Add to Up Next"), systemImage: "text.line.last.and.arrowtriangle.forward")
                    }
                    .controlButton()
                }
                .disabled(tracks.isEmpty)
            }
            .fixedSize()
            .tvFocusSection()
        }
    }
}

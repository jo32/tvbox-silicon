import SwiftUI
import TVCore

/// Music: search songs, albums or playlists by name (and artist), and play from the best channel
/// found. With no search, the page offers to continue where listening stopped and lists what
/// played recently.
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
                content(search)
            }
            .glassRowInsets()
            .pageContainer()
        }
        .screenBackdrop()
        .catalogSearchable(text: $query, prompt: L10n.text("Song, album or playlist"))
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

    @ViewBuilder private func content(_ search: MusicSearchModel) -> some View {
        if search.query.isEmpty {
            MusicHome { showsSettings = true }
        } else if search.results.isEmpty && search.collections.isEmpty && search.busy {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 80)
        } else if search.failed {
            ErrorStateCard(title: L10n.text("Unable to Search Music"), message: L10n.text("Check your network connection and try again."),
                           details: failureDetails(search), retry: { search.search(query, immediately: true) }, busy: search.busy)
                .padding(.vertical, 24).tvFocusSection()
        } else if search.empty {
            ContentUnavailableView(L10n.text("No Matching Songs"), systemImage: "music.note",
                                   description: Text(L10n.text("Try the song's full name, or add the artist.")))
                .frame(maxWidth: .infinity).padding(.vertical, 60)
        } else {
            ForEach(search.failures.keys.sorted { $0.rawValue < $1.rawValue }, id: \.self) { platform in
                StatusNotice(text: L10n.text("%@ didn't answer, so these results are from the other catalog.", platform.name))
                    .padding(.bottom, 10)
            }
            if search.kind == .top {
                #if os(macOS) || os(tvOS)
                MusicTopResults(search: search) { playResults(from: $0) }
                #endif
            } else if search.kind == .songs {
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

enum MusicLayout {
    #if os(tvOS)
    static let rowSpacing: CGFloat = 8, art: CGFloat = 76, gap: CGFloat = 22, header: CGFloat = 260
    #else
    static let rowSpacing: CGFloat = 2, art: CGFloat = 48, gap: CGFloat = 14, header: CGFloat = 150
    #endif
}

/// The Music page with nothing searched: continue listening, and what played recently.
private struct MusicHome: View {
    @Environment(Store.self) private var store
    let openSettings: () -> Void

    var body: some View {
        let library = store.music.library
        let resumable = store.music.track == nil ? library.resumePoint : nil
        if let point = resumable, let track = point.queue.current {
            MusicContinueCard(point: point, track: track).padding(.bottom, 20)
        }
        let downloads = !MusicDownloadLibrary.shared.items.isEmpty
        if downloads { MusicDownloadsLink().padding(.bottom, 20) }
        if !library.history.isEmpty {
            HStack {
                SectionHeader(title: L10n.text("Recently Played"))
                Spacer()
                Button(L10n.text("Clear")) { library.clearHistory() }.controlButton()
            }
            .padding(.bottom, 8)
            .tvFocusSection()
            ForEach(library.history.prefix(100)) { entry in
                if let collection = entry.collection {
                    MusicCollectionRow(collection: collection)
                } else if let track = entry.track {
                    MusicTrackRow(track: track) { store.music.play(track) }
                }
            }
        } else if resumable == nil && !downloads {
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
            Divider()
            MusicDownloadMenuItems(tracks: [track])
        }
        .accessibilityLabel(Text([track.title, track.artistLine].joined(separator: ", ")))
    }
}

private struct MusicCollectionRow: View {
    let collection: MusicCollection

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
    }
}

/// An album or playlist: its tracks, Play and Shuffle. Playing a track queues the whole list from it.
struct MusicCollectionView: View {
    let collection: MusicCollection
    @Environment(Store.self) private var store
    @State private var tracks: [MusicTrack] = []
    @State private var loading = false
    @State private var error: String?

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
                    ErrorStateCard(title: L10n.text("Unable to Load Songs"), message: L10n.text("Check your network connection and try again."),
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

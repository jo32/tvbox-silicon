import SwiftUI
import TVCore

/// Songs saved for listening without a connection, and those still on their way. Apple TV keeps them
/// in Caches, as it does episodes, and tvOS may clear them when it runs low on space.
struct MusicDownloadsView: View {
    @Environment(Store.self) private var store
    /// Inside the Downloads page, which has its own title.
    var embedded = false
    @State private var confirmsDeleteAll = false
    private var library: MusicDownloadLibrary { .shared }

    /// Most recently saved first.
    private var saved: [MusicDownload] { library.completed.sorted { ($0.finished ?? $0.created) > ($1.finished ?? $1.created) } }

    var body: some View {
        let tracks = saved.map(\.track)
        let page = list(tracks)
            .screenBackdrop()
            .musicPlayerInset()
            #if os(tvOS)
            .onPlayPauseCommand { store.music.toggle() }
            #endif
            .task { library.forgetMissing() }
            #if os(macOS)
            // Files may have been deleted or moved in Finder while the app was in the background.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in library.forgetMissing() }
            #endif
            .confirmationDialog(L10n.text("Delete all downloaded songs?"), isPresented: $confirmsDeleteAll, titleVisibility: .visible) {
                Button(L10n.text("Delete Downloads"), role: .destructive) { library.remove(library.items.map(\.id)) }
            }
            #if DEBUG
            // `-qaPlayDownloaded 1` plays the newest saved song as soon as there is one.
            .task(id: tracks.first?.id) {
                if UserDefaults.standard.bool(forKey: "qaPlayDownloaded"), store.music.track == nil, !tracks.isEmpty {
                    store.music.play(MusicQueue(tracks: tracks, start: 0, source: Self.title))
                }
            }
            #endif
        if embedded {
            page
        } else {
            page.screenTitle(Self.title)
                #if os(macOS)
                .toolbar(removing: .title)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { NSWorkspace.shared.open(library.root) } label: { Label(L10n.text("Show in Finder"), systemImage: "folder") }
                            .help(L10n.text("Show in Finder"))
                    }
                }
                #endif
        }
    }

    private func list(_ tracks: [MusicTrack]) -> some View {
        let pending = library.pending
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: MusicLayout.rowSpacing) {
                header(tracks).padding(.bottom, 20)
                if library.items.isEmpty {
                    ContentUnavailableView(L10n.text("No Downloaded Songs"), systemImage: "arrow.down.circle",
                                           description: Text(L10n.text("Download a song, album or playlist from its menu to listen without a connection.")))
                        .frame(maxWidth: .infinity).padding(.vertical, 60)
                }
                if !pending.isEmpty {
                    // Its own stack: a song that finishes moves to the list below under the same ID,
                    // and in one lazy stack its old row stayed on screen in place of the new one.
                    VStack(alignment: .leading, spacing: MusicLayout.rowSpacing) {
                        // The buttons go under the title when a phone has no room beside it.
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .center, spacing: 8) {
                                SectionHeader(title: L10n.text("Downloading"))
                                Spacer(minLength: 8)
                                MusicPendingActions(pending: pending)
                            }
                            VStack(alignment: .leading, spacing: 10) {
                                SectionHeader(title: L10n.text("Downloading"))
                                MusicPendingActions(pending: pending)
                            }
                        }
                        .padding(.bottom, 8)
                        .tvFocusSection()
                        ForEach(pending) { MusicPendingRow(item: $0) }
                    }
                }
                shelf(L10n.text("Playlists"), library.collections.filter { $0.collection.kind == .playlist })
                shelf(L10n.text("Albums"), library.collections.filter { $0.collection.kind == .album })
                if !saved.isEmpty {
                    if !pending.isEmpty || !library.collections.isEmpty {
                        SectionHeader(title: L10n.text(library.collections.isEmpty ? "Downloaded" : "Songs")).padding(.top, 24).padding(.bottom, 8)
                    }
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        MusicTrackRow(track: track) { store.music.play(MusicQueue(tracks: tracks, start: index, source: Self.title)) }
                    }
                }
            }
            .pageContainer()
        }
    }

    static var title: String { L10n.text("Downloaded Songs") }
    #if os(macOS)
    static let tile: CGFloat = 150, tileSpacing: CGFloat = 16
    #elseif os(tvOS)
    static let tile = MusicBrowseMetrics.cover, tileSpacing = MusicBrowseMetrics.tileSpacing
    #else
    static let tile: CGFloat = 132, tileSpacing: CGFloat = 16
    #endif

    /// Albums or playlists downloaded from their pages, as covers in a row; each opens its saved songs.
    @ViewBuilder private func shelf(_ title: String, _ collections: [MusicDownloadedCollection]) -> some View {
        if !collections.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: title)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: Self.tileSpacing) {
                        ForEach(collections) { MusicDownloadedTile(entry: $0, size: Self.tile) }
                    }
                }
                .scrollClipDisabled()
            }
            .padding(.top, 24)
            .tvFocusSection()
        }
    }

    private func header(_ tracks: [MusicTrack]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            #if os(macOS)
            if !embedded { Text(Self.title).font(.largeTitle.weight(.bold)) }
            #endif
            Text([L10n.text("%lld songs", tracks.count), DownloadFormat.size(library.size)].joined(separator: " · "))
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
                }
                .disabled(tracks.isEmpty)
                // In plain sight rather than in the toolbar: it also clears songs still on their way.
                if !library.items.isEmpty {
                    Button { confirmsDeleteAll = true } label: { Label(L10n.text("Delete Downloads"), systemImage: "trash").labelStyle(.iconOnly) }
                        .controlButton()
                        .help(L10n.text("Delete Downloads"))
                }
            }
            .fixedSize()
            .tvFocusSection()
        }
    }
}

/// An album or playlist downloaded from its page: its saved songs in its order with Play and Shuffle,
/// the songs still on their way, and Remove Download for all of it.
struct MusicDownloadedCollectionView: View {
    let id: String
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsRemove = false
    private var library: MusicDownloadLibrary { .shared }

    var body: some View {
        if let entry = library.collection(id: id) {
            let collection = entry.collection
            let items = library.items(in: entry)
            let tracks = items.filter { $0.status == .completed }.map(\.track)
            let pending = items.filter(\.isPending)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: MusicLayout.rowSpacing) {
                    #if os(macOS)
                    MusicCollectionHeader(collection: collection, tracks: tracks).padding(.bottom, 28)
                    #else
                    header(collection, tracks).padding(.bottom, 24)
                    #endif
                    if !pending.isEmpty {
                        VStack(alignment: .leading, spacing: MusicLayout.rowSpacing) {
                            ForEach(pending) { MusicPendingRow(item: $0) }
                        }
                        .padding(.bottom, 12)
                    }
                    #if os(macOS)
                    MusicSongTable(tracks: tracks, numbered: collection.kind == .album) {
                        store.music.play(MusicQueue(tracks: tracks, start: $0, collection: collection))
                    }
                    #else
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        MusicTrackRow(track: track, number: collection.kind == .album ? index + 1 : nil) {
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
            .toolbar(removing: .title)
            #endif
            .musicPlayerInset()
            #if os(tvOS)
            .onPlayPauseCommand { store.music.toggle() }
            #else
            .toolbar {
                Button { confirmsRemove = true } label: { Image(systemName: "trash") }
                    .help(L10n.text("Remove Download")).accessibilityLabel(L10n.text("Remove Download"))
            }
            #endif
            .confirmationDialog(collection.title, isPresented: $confirmsRemove, titleVisibility: .visible) {
                Button(L10n.text("Remove Download"), role: .destructive) { library.remove(collection: id); dismiss() }
            }
        } else {
            ContentUnavailableView(L10n.text("No Downloaded Songs"), systemImage: "arrow.down.circle").screenBackdrop()
        }
    }

    private func header(_ collection: MusicCollection, _ tracks: [MusicTrack]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: MusicLayout.gap * 1.4) {
                MusicArtwork(url: collection.artwork, size: MusicLayout.header, symbol: collection.kind == .album ? "square.stack" : "music.note.list")
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text(collection.kind == .album ? "Album" : "Playlist")).font(.caption.weight(.semibold)).foregroundStyle(Brand.accent)
                    Text(collection.title).font(.title2.weight(.bold)).lineLimit(2)
                    Text([collection.subtitle, L10n.text("%lld songs", tracks.count)].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            HStack(spacing: 10) {
                Group {
                    Button { store.music.play(MusicQueue(tracks: tracks, collection: collection)) } label: {
                        Label(L10n.text("Play"), systemImage: "play.fill")
                    }
                    .controlButton(prominent: true)
                    Button { store.music.play(MusicQueue.shuffled(tracks, collection: collection)) } label: {
                        Label(L10n.text("Shuffle"), systemImage: "shuffle")
                    }
                    .controlButton()
                }
                .disabled(tracks.isEmpty)
                #if os(tvOS)
                // Apple TV hides the navigation bar, and the toolbar's trash with it.
                Button(role: .destructive) { confirmsRemove = true } label: {
                    Label(L10n.text("Remove Download"), systemImage: "trash")
                }
                .controlButton()
                #endif
            }
            .fixedSize()
            .tvFocusSection()
        }
    }
}

/// A saved album or playlist as its cover, title and song count; it opens the songs saved from it.
private struct MusicDownloadedTile: View {
    let entry: MusicDownloadedCollection
    let size: CGFloat
    @State private var hovering = false

    var body: some View {
        let collection = entry.collection
        let saved = MusicDownloadLibrary.shared.items(in: entry).filter { $0.status == .completed }.count
        let link = RouteLink { MusicDownloadedCollectionView(id: entry.id) } label: {
            VStack(alignment: .leading, spacing: 7) {
                MusicArtwork(url: collection.artwork, size: size, symbol: collection.kind == .album ? "square.stack" : "music.note.list")
                    .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(hovering ? 0.12 : 0)) }
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(collection.title).font(Self.titleFont).foregroundStyle(.primary).lineLimit(1)
                    Text(L10n.text("%lld songs", saved)).font(Self.subtitleFont).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                }
                .cardCaption()
            }
            .frame(width: size, alignment: .leading)
            .contentShape(.rect)
        }
        #if os(tvOS)
        link.cardButton()
        #else
        link.buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
        #endif
    }

    #if os(tvOS)
    private static let titleFont = Font.system(size: 24, weight: .semibold), subtitleFont = Font.system(size: 20)
    #else
    private static let titleFont = Font.subheadline.weight(.medium), subtitleFont = Font.caption
    #endif
}

/// One Pause All (Resume All once paused) for every song on its way, and Cancel All.
private struct MusicPendingActions: View {
    let pending: [MusicDownload]

    var body: some View {
        let library = MusicDownloadLibrary.shared
        let paused = library.isPaused
        HStack(spacing: 8) {
            // Failed songs wait for Retry: with only those left there is nothing to pause.
            if pending.contains(where: { $0.status != .failed }) {
                Button { paused ? library.resumeAll() : library.pauseAll() } label: {
                    Label(L10n.text(paused ? "Resume All" : "Pause All"), systemImage: paused ? "play.fill" : "pause.fill")
                }
            }
            // Busy channels fail a run of songs at once; one press tries them all again.
            if pending.filter({ $0.status == .failed }).count > 1 {
                Button { library.retryFailed() } label: { Label(L10n.text("Retry All"), systemImage: "arrow.clockwise") }
            }
            Button(role: .destructive) { library.remove(pending.map(\.id)) } label: {
                Label(L10n.text("Cancel All"), systemImage: "xmark")
            }
        }
        .labelStyle(.titleAndIcon)
        #if os(tvOS)
        .controlButton()
        #else
        .font(.subheadline.weight(.semibold))
        .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
        #endif
        .fixedSize()
    }
}

/// A song on its way: how far it got, or why it stopped, with Retry and Cancel. On Apple TV the row
/// is one button that offers them: small buttons beside each other are hard to reach with a remote.
private struct MusicPendingRow: View {
    let item: MusicDownload
    @State private var choosing = false

    var body: some View {
        #if os(tvOS)
        Button { choosing = true } label: { row.contentShape(.rect) }
            .glassRow()
            .confirmationDialog(item.track.title, isPresented: $choosing, titleVisibility: .visible) {
                if item.status == .failed { Button(L10n.text("Retry")) { MusicDownloadLibrary.shared.retry(item.id) } }
                Button(L10n.text("Cancel Download"), role: .destructive) { MusicDownloadLibrary.shared.remove([item.id]) }
            }
        #else
        row
        #endif
    }

    private var row: some View {
        HStack(spacing: MusicLayout.gap) {
            MusicArtwork(url: item.track.artwork, size: MusicLayout.art)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.track.title).font(.headline).lineLimit(1)
                Text(status).font(.subheadline).monospacedDigit().lineLimit(2)
                    .foregroundStyle(item.status == .failed ? AnyShapeStyle(Brand.rose) : AnyShapeStyle(.secondary))
            }
            Spacer(minLength: 8)
            #if os(tvOS)
            DownloadState(status: item.status, fraction: item.fraction)
            #else
            if item.status == .failed {
                Button { MusicDownloadLibrary.shared.retry(item.id) } label: {
                    Image(systemName: "arrow.clockwise").font(.body.weight(.semibold)).frame(width: 30, height: 30).contentShape(.rect)
                }
                .buttonStyle(.borderless).help(L10n.text("Retry")).accessibilityLabel(L10n.text("Retry"))
            } else {
                DownloadState(status: item.status, fraction: item.fraction)
            }
            Button { MusicDownloadLibrary.shared.remove([item.id]) } label: {
                Image(systemName: "xmark").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 30, height: 30).contentShape(.rect)
            }
            .buttonStyle(.borderless).help(L10n.text("Cancel Download")).accessibilityLabel(L10n.text("Cancel Download"))
            #endif
        }
        .padding(.vertical, 6)
    }

    private var status: String {
        switch item.status {
        case .queued: L10n.text("Waiting")
        case .paused: L10n.text("Paused")
        case .downloading:
            if let expected = item.expected, expected > 0 {
                L10n.text("%@ of %@", DownloadFormat.size(item.received), DownloadFormat.size(expected))
            } else {
                L10n.text("Downloading")
            }
        case .finishing: L10n.text("Finishing…")
        case .failed: item.failure ?? L10n.text("Download failed")
        case .completed: L10n.text("Downloaded")
        }
    }
}

/// The way to saved songs, at the top of the Music page and on the Downloads page.
struct MusicDownloadsLink: View {
    /// On the Downloads page it sits among cards, so it is one too.
    var card = false

    var body: some View {
        let library = MusicDownloadLibrary.shared
        RouteLink { MusicDownloadsView() } label: {
            HStack(spacing: MusicLayout.gap) {
                #if os(iOS)
                SectionGlyph(section: .downloads, size: MusicLayout.art)
                #else
                Image(systemName: AppSection.downloads.icon)
                    .font(.system(size: MusicLayout.art * 0.46, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: MusicLayout.art, height: MusicLayout.art)
                    .background(Brand.cyan.gradient, in: RoundedRectangle(cornerRadius: MusicLayout.art * 0.3, style: .continuous))
                    .accessibilityHidden(true)
                #endif
                VStack(alignment: .leading, spacing: 3) {
                    Text(MusicDownloadsView.title).font(.headline).lineLimit(1).foregroundStyle(.primary)
                    Text(details(library)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, card ? 12 : 6)
            .padding(.horizontal, card ? 14 : 0)
            .background { if card { Color.clear.contentPanel(cornerRadius: 18) } }
            .contentShape(Rectangle())
        }
        .glassRow()
    }

    private func details(_ library: MusicDownloadLibrary) -> String {
        var parts = [L10n.text("%lld songs", library.completed.count)]
        // Failed songs wait for Retry on the page; only those on their way count here.
        let running = library.pending.filter { $0.status != .failed }.count
        if running > 0 { parts.append(L10n.text("%lld downloading", running)) }
        if library.size > 0 { parts.append(DownloadFormat.size(library.size)) }
        return parts.joined(separator: " · ")
    }
}

/// Download, or Remove Download once every song is saved or on its way, for songs' menus.
struct MusicDownloadMenuItems: View {
    let tracks: [MusicTrack]

    var body: some View {
        let library = MusicDownloadLibrary.shared
        let saved = tracks.compactMap { library.item(for: $0) }
        if !tracks.isEmpty, saved.count == tracks.count {
            Button(role: .destructive) { library.remove(saved.map(\.id)) } label: {
                Label(L10n.text(saved.allSatisfy { $0.status == .completed } ? "Remove Download" : "Cancel Download"), systemImage: "trash")
            }
        } else {
            Button { library.download(tracks) } label: { Label(L10n.text("Download"), systemImage: "arrow.down.circle") }
        }
    }
}

/// Downloads an album's or playlist's songs; a check once they are all saved.
struct MusicDownloadButton: View {
    let tracks: [MusicTrack]
    /// The album or playlist they belong to, kept with them for Downloaded Songs.
    var collection: MusicCollection?
    /// The Mac header's buttons have a fixed size.
    var side: CGFloat?

    var body: some View {
        let library = MusicDownloadLibrary.shared
        let items = tracks.compactMap { library.item(for: $0) }
        // Songs saved one by one before still leave the button on until the album or playlist is kept too.
        let kept = collection.map { library.collection(id: $0.id) != nil } ?? true
        let queued = kept && !tracks.isEmpty && items.count == tracks.count && !items.contains { $0.status == .failed }
        let done = queued && items.allSatisfy { $0.status == .completed }
        let label = L10n.text(done ? "Downloaded" : queued ? "Downloading" : "Download")
        Button { library.download(tracks, from: collection) } label: {
            Label(label, systemImage: done ? "checkmark.circle" : queued ? "arrow.down.circle.dotted" : "arrow.down.circle")
                #if !os(tvOS)
                .labelStyle(.iconOnly)
                #endif
                .frame(width: side, height: side)
        }
        .disabled(tracks.isEmpty || queued)
        .help(label).accessibilityLabel(label)
    }
}

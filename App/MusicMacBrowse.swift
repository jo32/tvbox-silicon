import SwiftUI
import TVCore

#if os(macOS) || os(tvOS)

/// Search results in rows, as Music on the Mac and Spotify on Apple TV lay them out: albums and
/// playlists as rows of covers, songs as columns of a few rows, each scrolling sideways. On the
/// Mac a row's title opens all of it; on Apple TV the filter chips above do.
struct MusicTopResults: View {
    let search: MusicSearchModel
    /// Plays the results from this song.
    let play: (MusicTrack) -> Void

    var body: some View {
        let albums = search.collections.filter { $0.kind == .album }
        let playlists = search.collections.filter { $0.kind == .playlist }
        VStack(alignment: .leading, spacing: MusicBrowseMetrics.sectionSpacing) {
            if !albums.isEmpty { collections(L10n.text("Albums"), albums) }
            if !search.results.isEmpty {
                VStack(alignment: .leading, spacing: MusicBrowseMetrics.headerSpacing) {
                    #if os(macOS)
                    MusicSectionLink(title: L10n.text("Songs")) { MusicSongsPage(title: L10n.text("Songs"), tracks: search.results) }
                    #else
                    SectionHeader(title: L10n.text("Songs"))
                    #endif
                    MusicSongGrid(tracks: Array(search.results.prefix(36)), play: play)
                }
            }
            if !playlists.isEmpty { collections(L10n.text("Playlists"), playlists) }
            if search.busy { ProgressView().frame(maxWidth: .infinity) }
        }
        .padding(.top, 4)
    }

    private func collections(_ title: String, _ items: [MusicCollection]) -> some View {
        VStack(alignment: .leading, spacing: MusicBrowseMetrics.headerSpacing) {
            #if os(macOS)
            MusicSectionLink(title: title) { MusicCollectionsPage(title: title, collections: items) }
            ScrollStrip(overlayArrows: true, arrowCenter: MusicBrowseMetrics.cover / 2) { tiles(items) }
                // The strip keeps its place by item: results ranked again as catalogs answer left it
                // scrolled to where the old first item went. A new first item starts it over.
                .id(items.first?.id)
            #else
            SectionHeader(title: title)
            ChipRow { tiles(items) }.tvFocusSection()
            #endif
        }
    }

    private func tiles(_ items: [MusicCollection]) -> some View {
        HStack(alignment: .top, spacing: MusicBrowseMetrics.tileSpacing) {
            ForEach(items.prefix(24)) { MusicCollectionTile(collection: $0, size: MusicBrowseMetrics.cover) }
        }
    }
}

#endif

enum MusicBrowseMetrics {
    #if os(tvOS)
    static let cover: CGFloat = 230, tileSpacing: CGFloat = 40, sectionSpacing: CGFloat = 50, headerSpacing: CGFloat = 18
    static let songArt: CGFloat = 72, songColumn: CGFloat = 560, songRows = 3
    #elseif os(iOS)
    static let cover: CGFloat = 148, tileSpacing: CGFloat = 14, sectionSpacing: CGFloat = 28, headerSpacing: CGFloat = 8
    #else
    static let cover: CGFloat = 164, tileSpacing: CGFloat = 18, sectionSpacing: CGFloat = 34, headerSpacing: CGFloat = 10
    static let songArt: CGFloat = 40, songRows = 3
    #endif
}

#if !os(tvOS)
/// A section's title with a chevron; it opens the whole section.
private struct MusicSectionLink<Destination: View>: View {
    let title: String
    @ViewBuilder let destination: () -> Destination
    var body: some View {
        RouteLink(destination: destination) {
            HStack(spacing: 5) {
                Text(title).font(.title3.weight(.bold)).foregroundStyle(.primary)
                Image(systemName: "chevron.right").font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isHeader)
    }
}
#endif

/// An album or playlist as a cover with its title and artist under it; it opens the list.
struct MusicCollectionTile: View {
    let collection: MusicCollection
    var size: CGFloat?
    @State private var hovering = false

    var body: some View {
        let link = RouteLink { MusicCollectionView(collection: collection) } label: {
            VStack(alignment: .leading, spacing: 7) {
                MusicArtwork(url: collection.artwork, size: size, symbol: collection.kind == .album ? "square.stack" : "music.note.list")
                    .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(hovering ? 0.12 : 0)) }
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(collection.title).font(Self.titleFont).foregroundStyle(.primary).lineLimit(1)
                    Text(collection.subtitle ?? collection.platform.name).font(Self.subtitleFont).foregroundStyle(.secondary).lineLimit(1)
                }
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
    #elseif os(iOS)
    private static let titleFont = Font.subheadline.weight(.medium), subtitleFont = Font.caption
    #else
    private static let titleFont = Font.system(size: 12, weight: .medium), subtitleFont = Font.system(size: 11)
    #endif
}

/// The Music page with nothing searched, laid out as Discover is for video: a row of covers for each
/// shelf (charts, playlists, new albums), scrolling sideways. On the Mac and iPhone a shelf's title
/// opens all of it as a grid. The shelves come from `MusicBrowseModel`, whatever catalog filled them.
struct MusicBrowseShelves: View {
    let sections: [MusicBrowseSection]

    var body: some View {
        VStack(alignment: .leading, spacing: MusicBrowseMetrics.sectionSpacing) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: MusicBrowseMetrics.headerSpacing) {
                    #if os(tvOS)
                    SectionHeader(title: section.title)
                    ChipRow { tiles(section.collections) }.tvFocusSection()
                    #else
                    MusicSectionLink(title: section.title) { MusicCollectionsPage(title: section.title, collections: section.collections) }
                    ScrollStrip(overlayArrows: true, arrowCenter: MusicBrowseMetrics.cover / 2) { tiles(section.collections) }
                    #endif
                }
            }
        }
    }

    private func tiles(_ items: [MusicCollection]) -> some View {
        LazyHStack(alignment: .top, spacing: MusicBrowseMetrics.tileSpacing) {
            ForEach(items) { MusicCollectionTile(collection: $0, size: MusicBrowseMetrics.cover) }
        }
    }
}

#if !os(tvOS)
/// Every album or playlist a search found, or a whole shelf of the Music page, as a grid of covers.
struct MusicCollectionsPage: View {
    let title: String
    let collections: [MusicCollection]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                #if os(macOS)
                Text(title).font(.largeTitle.weight(.bold))
                #endif
                LazyVGrid(columns: [GridItem(.adaptive(minimum: MusicBrowseMetrics.cover, maximum: MusicBrowseMetrics.cover * 1.35), spacing: 20, alignment: .top)],
                          alignment: .leading, spacing: 24) {
                    ForEach(collections) { MusicCollectionTile(collection: $0) }
                }
            }
            .pageContainer()
        }
        .screenBackdrop()
        #if os(macOS)
        .navigationTitle(title)
        .toolbar(removing: .title)
        #else
        .screenTitle(title)
        .musicPlayerInset()
        #endif
    }
}
#endif

#if os(macOS) || os(tvOS)
/// Songs a few to a column, scrolling sideways: three columns to the width on the Mac.
private struct MusicSongGrid: View {
    let tracks: [MusicTrack]
    let play: (MusicTrack) -> Void

    var body: some View {
        let rows = MusicBrowseMetrics.songRows
        let columns = stride(from: 0, to: tracks.count, by: rows).map { Array(tracks[$0..<min($0 + rows, tracks.count)]) }
        #if os(macOS)
        ScrollStrip(overlayArrows: true) {
            HStack(alignment: .top, spacing: 26) {
                ForEach(columns.indices, id: \.self) { column in
                    self.column(columns[column]).containerRelativeFrame(.horizontal, count: 3, spacing: 26)
                }
            }
        }
        #else
        ChipRow {
            HStack(alignment: .top, spacing: 40) {
                ForEach(columns.indices, id: \.self) { column in
                    self.column(columns[column]).frame(width: MusicBrowseMetrics.songColumn)
                }
            }
        }
        .tvFocusSection()
        #endif
    }

    private func column(_ tracks: [MusicTrack]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.offset) { row, track in
                MusicSongCell(track: track, divider: row < tracks.count - 1) { play(track) }
            }
        }
    }
}

/// A song in the grid: cover, title and artist; on the Mac its menu too, on Apple TV a long press.
private struct MusicSongCell: View {
    @Environment(Store.self) private var store
    let track: MusicTrack
    var divider = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let current = store.music.track?.id == track.id
        #if os(tvOS)
        Button(action: action) {
            HStack(spacing: 18) {
                MusicArtwork(url: track.artwork, size: MusicBrowseMetrics.songArt)
                    .overlay { if current { MusicPlayingBadge(current: true) } }
                labels(current: current, title: 26, artist: 21)
            }
            .padding(.vertical, 6)
        }
        .glassRow()
        .contextMenu {
            Button { store.music.playNext([track]) } label: { Label(L10n.text("Play Next"), systemImage: "text.line.first.and.arrowtriangle.forward") }
            Button { store.music.addToUpNext([track]) } label: { Label(L10n.text("Add to Up Next"), systemImage: "text.line.last.and.arrowtriangle.forward") }
            Divider()
            MusicDownloadMenuItems(tracks: [track])
        }
        #else
        HStack(spacing: 10) {
            MusicArtwork(url: track.artwork, size: MusicBrowseMetrics.songArt)
                .overlay { if current || hovering { MusicPlayingBadge(current: current) } }
            labels(current: current, title: 12.5, artist: 11.5)
            MusicTrackMenu(tracks: [track])
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { if divider { Divider().padding(.leading, 50) } }
        .contentShape(.rect)
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, action)
        #endif
    }

    private func labels(current: Bool, title: CGFloat, artist: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(track.title).font(.system(size: title, weight: .medium)).lineLimit(1)
                .foregroundStyle(current ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(.primary))
            Text(track.artistLine).font(.system(size: artist)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Over a cover: bars while its song plays, a play symbol on hover.
private struct MusicPlayingBadge: View {
    let current: Bool
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.black.opacity(0.42))
            Image(systemName: current ? "waveform" : "play.fill")
                .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                .symbolEffect(.variableColor.iterative, isActive: current)
        }
        .accessibilityHidden(true)
    }
}

#if os(macOS)
/// A song's "…": play it next, or after everything queued.
struct MusicTrackMenu: View {
    @Environment(Store.self) private var store
    let tracks: [MusicTrack]
    var body: some View {
        Menu {
            Button { store.music.playNext(tracks) } label: { Label(L10n.text("Play Next"), systemImage: "text.line.first.and.arrowtriangle.forward") }
            Button { store.music.addToUpNext(tracks) } label: { Label(L10n.text("Add to Up Next"), systemImage: "text.line.last.and.arrowtriangle.forward") }
            Divider()
            MusicDownloadMenuItems(tracks: tracks)
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 26, height: 26).contentShape(.rect)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(L10n.text("More"))
    }
}

/// Songs as a table: cover and title, artist, album and length, as Music lists them. An album's
/// own list numbers the songs instead and leaves out what every row would repeat.
struct MusicSongTable: View {
    let tracks: [MusicTrack]
    var numbered = false
    let play: (Int) -> Void
    @State private var width: CGFloat = 800

    var body: some View {
        let artist = max(110, width * 0.2), album = max(120, width * 0.24)
        LazyVStack(spacing: 0) {
            if !numbered {
                HStack(spacing: 12) {
                    Text(L10n.text("Song")).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 48)
                    Text(L10n.text("Artist")).frame(width: artist, alignment: .leading)
                    Text(L10n.text("Album")).frame(width: album, alignment: .leading)
                    Text(L10n.text("Time")).frame(width: 44, alignment: .trailing)
                    Color.clear.frame(width: 26, height: 1)
                }
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.bottom, 6)
                .overlay(alignment: .bottom) { Divider() }
            }
            ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                MusicSongTableRow(index: index, track: track, numbered: numbered, artist: artist, album: album) { play(index) }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

private struct MusicSongTableRow: View {
    @Environment(Store.self) private var store
    let index: Int
    let track: MusicTrack
    let numbered: Bool
    let artist: CGFloat
    let album: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let current = store.music.track?.id == track.id
        HStack(spacing: 12) {
            if numbered {
                Group {
                    if current { MusicActivityMark() }
                    else if hovering { Image(systemName: "play.fill").font(.system(size: 11)) }
                    else { Text("\(index + 1)").monospacedDigit() }
                }
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
            } else {
                MusicArtwork(url: track.artwork, size: 36)
                    .overlay { if current || hovering { MusicPlayingBadge(current: current) } }
            }
            HStack(spacing: 6) {
                Text(track.title).lineLimit(1)
                    .fontWeight(current ? .semibold : .regular)
                    .foregroundStyle(current ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(.primary))
                ForEach(track.tags.sorted(), id: \.self) { Pill(text: $0.name) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !numbered {
                Text(track.artistLine).lineLimit(1).foregroundStyle(.secondary).frame(width: artist, alignment: .leading)
                Text(track.album ?? "").lineLimit(1).foregroundStyle(.secondary).frame(width: album, alignment: .leading)
            }
            Text(track.duration.map(MusicTime.text) ?? "").monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
            MusicTrackMenu(tracks: [track])
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10).padding(.vertical, numbered ? 9 : 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hovering ? 0.05 : 0)))
        .overlay(alignment: .bottom) { Divider().padding(.leading, numbered ? 46 : 58) }
        .contentShape(.rect)
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(current ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, action)
    }
}

/// Every song a search found, as a table.
struct MusicSongsPage: View {
    @Environment(Store.self) private var store
    let title: String
    let tracks: [MusicTrack]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(title).font(.largeTitle.weight(.bold))
                MusicSongTable(tracks: tracks) { store.music.play(MusicQueue(tracks: tracks, start: $0)) }
            }
            .pageContainer()
        }
        .screenBackdrop()
        .navigationTitle(title)
        .toolbar(removing: .title)
    }
}

/// An album's or playlist's head: the cover large, the title, who made it, what it is, then Shuffle,
/// Play and Add to Up Next.
struct MusicCollectionHeader: View {
    @Environment(Store.self) private var store
    let collection: MusicCollection
    let tracks: [MusicTrack]

    var body: some View {
        HStack(alignment: .bottom, spacing: 28) {
            MusicArtwork(url: collection.artwork, size: 236, symbol: collection.kind == .album ? "square.stack" : "music.note.list")
                .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
            VStack(alignment: .leading, spacing: 4) {
                Text(collection.title).font(.system(size: 26, weight: .bold)).lineLimit(2)
                if let subtitle = collection.subtitle {
                    Text(subtitle).font(.system(size: 22)).lineLimit(1)
                        .foregroundStyle(collection.kind == .album ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(.secondary))
                }
                Text(details).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 2)
                Spacer(minLength: 18)
                HStack(spacing: 10) {
                    Button { store.music.play(MusicQueue.shuffled(tracks, collection: collection)) } label: {
                        Image(systemName: "shuffle").frame(width: 34, height: 34)
                    }
                    .buttonStyle(MusicHeaderButtonStyle()).help(L10n.text("Shuffle")).accessibilityLabel(L10n.text("Shuffle"))
                    Button { store.music.play(MusicQueue(tracks: tracks, collection: collection)) } label: {
                        Label(L10n.text("Play"), systemImage: "play.fill").frame(width: 92, height: 34)
                    }
                    .buttonStyle(MusicHeaderButtonStyle())
                    Button { store.music.addToUpNext(tracks) } label: {
                        Image(systemName: "plus").frame(width: 34, height: 34)
                    }
                    .buttonStyle(MusicHeaderButtonStyle()).help(L10n.text("Add to Up Next")).accessibilityLabel(L10n.text("Add to Up Next"))
                    MusicDownloadButton(tracks: tracks, collection: collection, side: 34).buttonStyle(MusicHeaderButtonStyle())
                }
                .disabled(tracks.isEmpty)
            }
            .frame(height: 236, alignment: .topLeading)
            .padding(.vertical, 6)
        }
    }

    private var details: String {
        [L10n.text(collection.kind == .album ? "Album" : "Playlist"), collection.year,
         collection.trackCount.map { L10n.text("%lld songs", $0) }, collection.platform.name]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

private struct MusicHeaderButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Brand.accent)
            .background(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07), in: Capsule())
            .contentShape(Capsule())
            .opacity(enabled ? 1 : 0.45)
    }
}
#endif
#endif

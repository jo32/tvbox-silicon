import SwiftUI
import TVCore

// The listener's own playlists (#1568). A song's menu adds it to one, or to a new one; My Playlists on the Music
// page lists them. Names are asked for on these pages only, so no song row carries an alert.

/// "Add to Playlist" in a song's menu: New Playlist, which makes one holding the songs, then the playlists.
struct MusicPlaylistMenu: View {
    @EnvironmentObject private var store: Store
    let tracks: [MusicTrack]

    var body: some View {
        Menu {
            Button { store.playlists.create(name: "", fallback: L10n.text("Untitled Playlist"), tracks: tracks) } label: {
                Label(L10n.text("New Playlist"), systemImage: "plus")
            }
            ForEach(store.playlists.playlists) { playlist in
                Button { store.playlists.add(tracks, to: playlist.id) } label: { Label(playlist.name, systemImage: "music.note.list") }
            }
        } label: {
            Label(L10n.text("Add to Playlist"), systemImage: "text.badge.plus")
        }
    }
}

extension View {
    /// Asks for a playlist's name: `confirm` is the button that takes it (Create or Rename).
    func musicPlaylistNamePrompt(_ title: String, isPresented: Binding<Bool>, name: Binding<String>, confirm: String, action: @escaping () -> Void) -> some View {
        alert(title, isPresented: isPresented) {
            TextField(L10n.text("Playlist Name"), text: name)
            Button(confirm, action: action)
            Button(L10n.text("Cancel"), role: .cancel) {}
        }
    }
}

/// The way to the listener's playlists, under the liked songs and albums on the Music page.
struct MusicPlaylistsLink: View {
    let count: Int

    var body: some View {
        RouteLink { MusicPlaylistsView() } label: {
            HStack(spacing: MusicLayout.gap) {
                Image(systemName: "music.note.list")
                    .font(.system(size: MusicLayout.art * 0.42, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: MusicLayout.art, height: MusicLayout.art)
                    .background(Brand.accent.gradient, in: RoundedRectangle(cornerRadius: MusicLayout.art * 0.3, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(MusicPlaylistsView.title).font(.headline).lineLimit(1).foregroundStyle(.primary)
                    Text(L10n.text("%lld playlists", count)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
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

/// The listener's playlists, newest first. Rename or delete one from its menu, or on its page.
struct MusicPlaylistsView: View {
    @EnvironmentObject private var store: Store
    @State private var creating = false
    @State private var renaming: MusicPlaylist?
    @State private var name = ""

    static var title: String { L10n.text("My Playlists") }

    var body: some View {
        let playlists = store.playlists.playlists
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MusicLayout.rowSpacing) {
                #if os(tvOS)
                MusicNowPlayingButton()
                #endif
                VStack(alignment: .leading, spacing: 14) {
                    #if os(macOS)
                    Text(Self.title).font(.largeTitle.weight(.bold))
                    #endif
                    Button { name = ""; creating = true } label: { Label(L10n.text("New Playlist"), systemImage: "plus") }
                        .controlButton()
                        .tvFocusSection()
                }
                .padding(.bottom, 20)
                if playlists.isEmpty {
                    EmptyResults(symbol: "music.note.list", title: L10n.text("No Playlists"),
                                 message: L10n.text("Make a playlist here, or from a song's menu with Add to Playlist."))
                }
                ForEach(playlists) { playlist in
                    RouteLink { MusicPlaylistView(id: playlist.id) } label: {
                        HStack(spacing: MusicLayout.gap) {
                            MusicArtwork(url: playlist.tracks.first?.artwork, size: MusicLayout.art, symbol: "music.note.list")
                            VStack(alignment: .leading, spacing: 3) {
                                Text(playlist.name).font(.headline).lineLimit(1).foregroundStyle(.primary)
                                Text(L10n.text("%lld songs", playlist.tracks.count)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
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
                        Button { store.music.play(MusicQueue(tracks: playlist.tracks, start: 0, source: playlist.name)) } label: {
                            Label(L10n.text("Play"), systemImage: "play.fill")
                        }
                        .disabled(playlist.tracks.isEmpty)
                        Button { name = playlist.name; renaming = playlist } label: { Label(L10n.text("Rename"), systemImage: "pencil") }
                        Divider()
                        Button(role: .destructive) { store.playlists.delete(playlist.id) } label: { Label(L10n.text("Delete Playlist"), systemImage: "trash") }
                    }
                }
            }
            .glassRowInsets()
            .pageContainer()
        }
        .screenBackdrop()
        .screenTitle(Self.title)
        #if os(macOS)
        .compatToolbarRemovingTitle()
        #endif
        .musicPlayerInset()
        #if os(tvOS)
        .onPlayPauseCommand { store.music.toggle() }
        #endif
        .musicPlaylistNamePrompt(L10n.text("New Playlist"), isPresented: $creating, name: $name, confirm: L10n.text("Create")) {
            store.playlists.create(name: name, fallback: L10n.text("Untitled Playlist"))
        }
        .musicPlaylistNamePrompt(L10n.text("Rename"), isPresented: Binding { renaming != nil } set: { if !$0 { renaming = nil } },
                                 name: $name, confirm: L10n.text("Rename")) {
            if let renaming { store.playlists.rename(renaming.id, to: name) }
        }
    }
}

/// One playlist: its songs in the order they were added, played as one list. A song leaves from its menu.
struct MusicPlaylistView: View {
    let id: String
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var renaming = false
    @State private var deleting = false
    @State private var name = ""

    var body: some View {
        let playlist = store.playlists.playlist(id)
        let tracks = playlist?.tracks ?? []
        let title = playlist?.name ?? ""
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MusicLayout.rowSpacing) {
                header(tracks, title: title).padding(.bottom, 20)
                if tracks.isEmpty {
                    EmptyResults(symbol: "music.note.list", title: L10n.text("No Songs Yet"),
                                 message: L10n.text("Add a song from its menu with Add to Playlist."))
                }
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    MusicTrackRow(track: track, removeFromPlaylist: { store.playlists.remove(track, from: id) }) {
                        store.music.play(MusicQueue(tracks: tracks, start: index, source: title))
                    }
                }
            }
            .glassRowInsets()
            .pageContainer()
        }
        .screenBackdrop()
        .screenTitle(title)
        #if os(macOS)
        .compatToolbarRemovingTitle()
        #endif
        .musicPlayerInset()
        #if os(tvOS)
        .onPlayPauseCommand { store.music.toggle() }
        #endif
        .musicPlaylistNamePrompt(L10n.text("Rename"), isPresented: $renaming, name: $name, confirm: L10n.text("Rename")) {
            store.playlists.rename(id, to: name)
        }
        .confirmationDialog(L10n.text("Delete the playlist “%@”?", title), isPresented: $deleting, titleVisibility: .visible) {
            Button(L10n.text("Delete Playlist"), role: .destructive) {
                store.playlists.delete(id)
                dismiss()
            }
            Button(L10n.text("Cancel"), role: .cancel) {}
        }
    }

    private func header(_ tracks: [MusicTrack], title: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            #if os(tvOS)
            MusicNowPlayingButton()
            #endif
            #if os(macOS)
            Text(title).font(.largeTitle.weight(.bold))
            #endif
            Text(L10n.text("%lld songs", tracks.count))
                .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Group {
                    Button { store.music.play(MusicQueue(tracks: tracks, start: 0, source: title)) } label: {
                        Label(L10n.text("Play"), systemImage: "play.fill")
                    }
                    .controlButton(prominent: true)
                    Button { store.music.play(MusicQueue.shuffled(tracks, source: title)) } label: {
                        Label(L10n.text("Shuffle"), systemImage: "shuffle")
                    }
                    .controlButton()
                }
                .disabled(tracks.isEmpty)
                Menu {
                    Button { store.music.addToUpNext(tracks) } label: {
                        Label(L10n.text("Add to Up Next"), systemImage: "text.line.last.and.arrowtriangle.forward")
                    }
                    .disabled(tracks.isEmpty)
                    Button { name = title; renaming = true } label: { Label(L10n.text("Rename"), systemImage: "pencil") }
                    Divider()
                    Button(role: .destructive) { deleting = true } label: { Label(L10n.text("Delete Playlist"), systemImage: "trash") }
                } label: {
                    Label(L10n.text("More"), systemImage: "ellipsis").labelStyle(.iconOnly)
                }
                .controlButton()
            }
            .fixedSize()
            .tvFocusSection()
        }
    }
}

#if !os(tvOS)
import SwiftUI
import TVCore

/// Catalog-only actions alongside the existing native transport controls.
struct CatalogPlaybackActions: View {
    let channel: Channel
    let session: PlaybackSession
    @Environment(Store.self) private var store
    @State private var showsSkip = false
    @State private var showsDanmaku = false

    var body: some View {
        if channel.historyContext != nil {
            Menu {
                if let catalog = store.catalog(for: channel) {
                    Toggle(L10n.text("Auto-play next episode"), isOn: Binding(
                        get: { store.autoPlayNext }, set: { store.autoPlayNext = $0 }))
                    Menu(L10n.text("Episodes")) {
                        ForEach(catalog.playlist.flags, id: \.self) { flag in
                            Menu(flag) {
                                ForEach(catalog.playlist.episodes(for: flag)) { episode in
                                    Button(catalog.labels[episode.id] ?? episode.name) { store.selectEpisode(episode, from: channel) }
                                }
                            }
                        }
                    }
                    .disabled(store.resolvingEpisode != nil)
                }
                Toggle(L10n.text("Automatically skip intro and outro"), isOn: Binding(
                    get: { session.skipSettings.enabled },
                    set: { value in
                        var settings = session.skipSettings
                        settings.enabled = value
                        session.applySkipSettings(settings)
                    }))
                Button(L10n.text("Skip intro / outro")) { showsSkip = true }
                    .accessibilityIdentifier("player.skip")
                if channel.historyContext?.sourceKey != Bilibili.siteKey {
                    Button(L10n.text("Danmaku")) { showsDanmaku = true }
                        .accessibilityIdentifier("player.danmaku")
                }
                if let error = store.episodeError { Text(error) }
            } label: {
                #if os(macOS)
                Image(systemName: "ellipsis").font(.system(size: 14, weight: .medium))
                    .frame(width: 34, height: 34).contentShape(Circle())
                #else
                Image(systemName: "ellipsis.circle").font(.headline).frame(width: 22, height: 22)
                #endif
            }
            #if os(macOS)
            // The same 34 pt glass circle as the window's other buttons; a bordered menu drew a wider capsule, and a
            // borderless one drew its icon at the leading edge of the circle instead of the centre.
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .fixedSize()
            .glassSurface(.regular.interactive(), in: Circle())
            .help(L10n.text("Episodes"))
            #else
            .chromeButton()
            #endif
            .accessibilityLabel(L10n.text("Playback Options"))
            .accessibilityIdentifier("player.catalogOptions")
            .sheet(isPresented: $showsSkip) { EpisodeSkipSettingsView(session: session).playerSheet() }
            .sheet(isPresented: $showsDanmaku) {
                CatalogDanmakuSettingsView(model: session.catalogDanmaku, channelName: channel.name).playerSheet()
            }
        }
    }
}

extension View {
    /// A settings sheet over the player, dark like the player. A player at the top of a page makes only its own views
    /// dark (`PlayerScheme`); before iOS 26 a sheet it opens inherits that for its text but keeps the phone's light
    /// background, so on a phone in light mode the sheet showed white text on a white form (#533).
    /// The Mac's sheets keep the window's appearance, as before.
    @ViewBuilder func playerSheet() -> some View {
        #if os(iOS)
        preferredColorScheme(.dark)
        #else
        self
        #endif
    }
}
#endif

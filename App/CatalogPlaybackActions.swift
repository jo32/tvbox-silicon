#if !os(tvOS)
import SwiftUI
import TVCore

/// Catalog-only actions alongside the existing native transport controls.
///
/// This menu does not present the episode sheet itself. It asks its host to, via
/// `openEpisodes`, because the sheet's presentation depends on which of the
/// iPhone Duo's three player shapes is on screen — a sheet over a full-screen
/// player, a panel inside the picture at the top of a watch page. That decision
/// belongs to `PlayerSurface` in the player, not to this menu, and having the
/// menu present its own sheet as well meant two different episode experiences
/// depending on where the viewer tapped.
struct CatalogPlaybackActions: View {
    let channel: Channel
    let session: PlaybackSession
    /// Ask the player to open its episode sheet or panel.
    var openEpisodes: () -> Void = {}
    @Environment(Store.self) private var store
    @State private var showsSkip = false
    @State private var showsDanmaku = false

    var body: some View {
        if channel.historyContext != nil {
            Menu {
                if store.catalog(for: channel) != nil {
                    Toggle(L10n.text("Auto-play next episode"), isOn: Binding(
                        get: { store.autoPlayNext }, set: { store.autoPlayNext = $0 }))
                    // One tap into the episode sheet: lines, their health and the
                    // whole grid, instead of a two-level menu.
                    Button(action: openEpisodes) {
                        Label(L10n.text("Episodes"), systemImage: "list.bullet.rectangle")
                    }
                    .disabled(store.resolvingEpisode != nil)
                    .accessibilityIdentifier("player.episodes")
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
            .sheet(isPresented: $showsSkip) { EpisodeSkipSettingsView(session: session) }
            .sheet(isPresented: $showsDanmaku) {
                CatalogDanmakuSettingsView(model: session.catalogDanmaku, channelName: channel.name)
            }
        }
    }
}
#endif

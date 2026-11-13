#if !os(tvOS)
import SwiftUI
import TVCore

/// Catalog-only actions alongside the existing native transport controls. The episodes have their own button
/// (`PlayerEpisodesButton`, #524).
struct CatalogPlaybackActions: View {
    let channel: Channel
    let session: PlaybackSession
    @Environment(Store.self) private var store
    @State private var showsSkip = false
    @State private var showsDanmaku = false

    var body: some View {
        if channel.historyContext != nil {
            Menu {
                if store.catalog(for: channel) != nil {
                    Toggle(L10n.text("Auto-play next episode"), isOn: Binding(
                        get: { store.autoPlayNext }, set: { store.autoPlayNext = $0 }))
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
                if !session.chapters.isEmpty {
                    Menu {
                        ForEach(Array(session.chapters.enumerated()), id: \.offset) { _, chapter in
                            Button { session.jump(to: chapter.start) } label: {
                                Text(EpisodeSkipSettings.formatTime(chapter.start) + "  " + chapter.title)
                            }
                        }
                    } label: { Label(L10n.text("Chapters"), systemImage: "list.bullet") }
                    .accessibilityIdentifier("player.chapters")
                }
                Toggle(L10n.text("Show Danmaku"), isOn: Binding(
                    get: { session.catalogDanmaku.enabled }, set: { session.catalogDanmaku.enabled = $0 }))
                Button(L10n.text("Danmaku Settings…")) { showsDanmaku = true }
                    .accessibilityIdentifier("player.danmaku")
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
            .help(L10n.text("Playback Options"))
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

/// The source's opening or ending credits playing now (#256): one tap skips them, as Bilibili's own player offers.
struct SourceSkipButton: View {
    let session: PlaybackSession
    var body: some View {
        if let skip = session.skipOffer {
            Button { session.skipSourceSegment() } label: {
                Label(skip.kind == .intro ? L10n.text("Skip Intro") : L10n.text("Skip Outro"), systemImage: "forward.fill")
                    .font(.subheadline.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 9)
                    .glassSurface(.regular.interactive(), in: Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .padding(.trailing, 20).padding(.bottom, 96)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .transition(.opacity)
            .accessibilityIdentifier("player.skipSource")
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

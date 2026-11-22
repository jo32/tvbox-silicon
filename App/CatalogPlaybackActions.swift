#if !os(tvOS)
import SwiftUI
import TVCore

/// Catalog-only actions alongside the existing native transport controls. The episodes have their own button
/// (`PlayerEpisodesButton`, #524).
struct CatalogPlaybackActions: View {
    let channel: Channel
    let session: PlaybackSession
    /// Skip Intro / Outro here, for the player without a settings menu (the Mac's in-window one).
    var offersSkip = false
    @Environment(Store.self) private var store
    @State private var showsSkip = false

    var body: some View {
        // Nothing to offer (a drive's file has no next episode to play on, and no chapters): no empty menu.
        if channel.historyContext != nil,
           offersSkip || store.catalog(for: channel) != nil || !session.chapters.isEmpty || store.episodeError != nil {
            Menu {
                if store.catalog(for: channel) != nil {
                    Toggle(L10n.text("Auto-play next episode"), isOn: Binding(
                        get: { store.autoPlayNext }, set: { store.autoPlayNext = $0 }))
                }
                // The players with a settings menu have Skip Intro / Outro there (#1488); a lone switch here, on with no
                // times set, skipped nothing and looked broken (#1405).
                if offersSkip { SkipTimesMenuButton(session: session) { showsSkip = true } }
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
            // A 34 pt button in the window's glass button group; a bordered menu drew a wider capsule, and a
            // borderless one drew its icon at the leading edge of the circle instead of the centre.
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .fixedSize()
            .playerBarButton()
            .help(L10n.text("Playback Options"))
            #else
            .chromeButton()
            #endif
            .accessibilityLabel(L10n.text("Playback Options"))
            .accessibilityIdentifier("player.catalogOptions")
            // Store handed in, as for every sheet over the player (`PlayerSheetPresentation`).
            .sheet(isPresented: $showsSkip) { EpisodeSkipSettingsView(session: session).playerSheet().environment(store) }
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

/// The viewer's own intro and outro times at work (#1003): the intro just skipped, with Undo, and a countdown before
/// the outro is skipped, with Cancel, so a wrong time can be put right on the spot.
struct SkipNoticeView: View {
    let session: PlaybackSession
    var body: some View {
        if let notice = session.skipNotice {
            HStack(spacing: 12) {
                switch notice {
                case .introSkipped:
                    Text(L10n.text("Intro skipped"))
                    Button(L10n.text("Undo")) { session.undoIntroSkip() }
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("player.skipNotice.undo")
                case .outroIn(let seconds):
                    Text(L10n.text("Skipping the outro in %@ s", String(seconds)))
                        .contentTransition(.numericText(countsDown: true))
                        .monospacedDigit()
                    Button(L10n.text("Cancel")) { session.keepOutro() }
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("player.skipNotice.keep")
                }
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.plain)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .glassSurface(.regular.interactive(), in: Capsule())
            .foregroundStyle(.white)
            .animation(.smooth(duration: 0.25), value: notice)
            .padding(.leading, 20).padding(.bottom, 96)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .transition(.opacity)
            .accessibilityIdentifier("player.skipNotice")
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

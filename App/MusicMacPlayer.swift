#if os(macOS)
import AVKit
import SwiftUI
import TVCore

/// The player while a song is loaded, as Music has it on the Mac: one glass bar floating over the
/// bottom of the window, on every page. The transport is on the left, the song in the middle (a
/// click opens Now Playing), and the menu, lyrics, Up Next, AirPlay and volume on the right.
struct MusicMacBar: View {
    @Environment(Store.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var showsVolume = false
    @State private var showsChannels = false
    #if DEBUG
    private static var qaOpened = false
    #endif

    var body: some View {
        let music = store.music
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                MusicMacButton(symbol: "shuffle", label: "Shuffle", size: 11, on: music.shuffled) { music.toggleShuffle() }
                MusicMacButton(symbol: "backward.fill", label: "Previous", size: 14, prominent: true) { music.previous() }
                MusicMacPlayButton(size: 19, frame: 34)
                MusicMacButton(symbol: "forward.fill", label: "Next", size: 14, prominent: true) { music.next() }.disabled(!music.canAdvance)
                MusicMacButton(symbol: music.repeatMode.symbol, label: music.repeatMode.label, size: 11, on: music.repeatMode != .off) { music.cycleRepeat() }
            }
            song(music)
            HStack(spacing: 0) {
                MusicMacMenu(showsChannels: $showsChannels)
                MusicMacButton(symbol: "quote.bubble", label: "Lyrics", size: 13) { open(.lyrics) }
                MusicMacButton(symbol: "list.bullet", label: "Up Next", size: 13) { open(.queue) }
                MusicMacRoutePicker(player: music.player).frame(width: 30, height: 30).help(L10n.text("AirPlay"))
                MusicMacButton(symbol: MusicMacVolume.symbol(music.volume), label: "Volume", size: 13) { showsVolume.toggle() }
                    .popover(isPresented: $showsVolume, arrowEdge: .top) { MusicMacVolume().frame(width: 200).padding(14) }
                MusicMacButton(symbol: "pip.enter", label: "Mini Player", size: 13) { openWindow(id: MusicMacMiniPlayer.windowID) }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 54)
        .glassSurface(.regular, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
        .frame(maxWidth: 720)
        .padding(.horizontal, Layout.gutter).padding(.bottom, 12)
        .sheet(isPresented: $showsChannels) { MusicChannelsView() }
        #if DEBUG
        // `-qaNowPlaying lyrics|queue` opens Now Playing on that panel once, for screenshots. Once:
        // every page has its own bar.
        .task {
            guard !Self.qaOpened, let panel = UserDefaults.standard.string(forKey: "qaNowPlaying") else { return }
            Self.qaOpened = true
            open(panel == "queue" ? .queue : .lyrics)
        }
        #endif
    }

    /// Now Playing on `panel`; the same button again closes it.
    private func open(_ panel: MusicNowPlayingPanel) {
        let music = store.music
        if music.presentsPlayer && music.nowPlayingPanel == panel { music.presentsPlayer = false; return }
        music.nowPlayingPanel = panel
        music.presentsPlayer = true
    }

    /// Cover, title and artist over a hairline of progress; the whole of it opens Now Playing.
    private func song(_ music: MusicPlaybackSession) -> some View {
        Button { open(music.nowPlayingPanel) } label: {
            HStack(spacing: 10) {
                MusicArtwork(url: music.track?.artwork, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(music.track?.title ?? "").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Group {
                        if let failure = music.failure {
                            Text(failure).foregroundStyle(Brand.amber)
                        } else if music.phase == .resolving {
                            Text(L10n.text("Finding the best channel…"))
                        } else {
                            Text(MusicMacNowPlaying.byline(music.track))
                        }
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) { MusicMacProgressLine().padding(.horizontal, 6) }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .frame(minWidth: 160, maxWidth: 360)
        .help(MusicMacNowPlaying.credit(music) ?? L10n.text("Now Playing"))
        .accessibilityLabel(L10n.text("Now Playing"))
    }
}

extension View {
    /// The music bar floating over the bottom of a page, while a song is loaded. Each page carries
    /// its own: a page pushed in the Mac's detail column takes neither the stack's safe-area
    /// insets nor its overlays.
    func musicBar() -> some View { modifier(MusicBarInset()) }
}

private struct MusicBarInset: ViewModifier {
    @Environment(Store.self) private var store
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) { if store.music.track != nil { MusicMacBar() } }
    }
}

/// While Now Playing covers the window: the pages' toolbar items and the title are hidden, and
/// AirPlay, volume and Close are one title-bar accessory at the trailing end. Controls drawn under
/// the title bar lost their clicks and drags to it (dragging the volume moved the window);
/// replacing the window's toolbar made SwiftUI throw; hiding its items one by one lasted only
/// until SwiftUI next refreshed them. So the toolbar's own view is hidden instead: the toolbar
/// still holds its height, and the window's buttons keep the room they have on the pages.
/// Before macOS 26 the title bar also draws the toolbar's background over the player, a light
/// strip across the top, so it is made transparent while covered.
struct NowPlayingWindowChrome: NSViewRepresentable {
    let active: Bool
    let store: Store
    func makeNSView(context: Context) -> NSView { NSView() }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func updateNSView(_ view: NSView, context: Context) {
        let active = active, coordinator = context.coordinator, store = store
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            if active { coordinator.cover(window, store: store) } else { coordinator.uncover(window) }
        }
    }

    @MainActor final class Coordinator {
        private var accessories: [NSTitlebarAccessoryViewController] = []
        private weak var toolbarView: NSView?
        private var titlebarWasTransparent = false

        func cover(_ window: NSWindow, store: Store) {
            guard accessories.isEmpty else { return }
            toolbarView = window.contentView?.superview.flatMap(Self.toolbarView)
            toolbarView?.isHidden = true
            if #unavailable(macOS 26) {
                titlebarWasTransparent = window.titlebarAppearsTransparent
                window.titlebarAppearsTransparent = true
            }
            window.titleVisibility = .hidden
            let host = NSHostingView(rootView: MusicMacWindowControls().environment(store).environment(\.colorScheme, .dark))
            host.frame.size = host.fittingSize
            let accessory = NSTitlebarAccessoryViewController()
            accessory.layoutAttribute = .trailing
            accessory.view = host
            window.addTitlebarAccessoryViewController(accessory)
            accessories = [accessory]
        }

        func uncover(_ window: NSWindow) {
            guard !accessories.isEmpty else { return }
            accessories.forEach { $0.removeFromParent() }
            accessories = []
            toolbarView?.isHidden = false
            if #unavailable(macOS 26) { window.titlebarAppearsTransparent = titlebarWasTransparent }
            window.titleVisibility = .visible
        }

        /// AppKit's view drawing the toolbar's items, inside the window's frame view.
        private static func toolbarView(in view: NSView) -> NSView? {
            if NSStringFromClass(type(of: view)) == "NSToolbarView" { return view }
            for subview in view.subviews { if let found = toolbarView(in: subview) { return found } }
            return nil
        }
    }
}

/// AirPlay, volume and Close, in one glass capsule at the top right of Now Playing.
private struct MusicMacWindowControls: View {
    @Environment(Store.self) private var store
    var body: some View {
        HStack(spacing: 10) {
            MusicMacRoutePicker(player: store.music.player, color: .white).frame(width: 20, height: 20).help(L10n.text("AirPlay"))
            MusicMacVolume().frame(width: 140)
            Divider().frame(height: 16)
            Button { store.music.presentsPlayer = false } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 22, height: 22).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(L10n.text("Close"))
            .accessibilityLabel(L10n.text("Close"))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .glassSurface(.regular, in: Capsule())
        .padding(.trailing, 14).padding(.vertical, 10)
    }
}

/// The song's progress as a hairline along the bottom of the bar's middle.
struct MusicMacProgressLine: View {
    @Environment(Store.self) private var store
    var body: some View {
        let music = store.music
        let total = music.duration ?? 0
        let fraction = total > 0 ? min(1, max(0, (music.seekingTo ?? music.position) / total)) : 0
        Capsule().fill(Color.primary.opacity(0.12))
            .overlay(alignment: .leading) {
                GeometryReader { proxy in Capsule().fill(Color.primary.opacity(0.55)).frame(width: proxy.size.width * fraction) }
            }
            .frame(height: 2)
            .accessibilityHidden(true)
    }
}

/// A borderless round control: secondary at rest, filled behind when switched on.
struct MusicMacButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 13
    var on = false
    /// Drawn in the primary colour without being on, like the play button.
    var prominent = false
    var frame: CGFloat = 30
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(on || prominent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .opacity(enabled ? 1 : 0.4)
                .frame(width: frame, height: frame)
                .background(Color.primary.opacity(on ? 0.14 : hovering && enabled ? 0.07 : 0), in: Circle())
                .contentShape(Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L10n.text(label))
        .accessibilityLabel(L10n.text(label))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Play or pause; a spinner while a channel is found, Retry after a failure.
struct MusicMacPlayButton: View {
    @Environment(Store.self) private var store
    var size: CGFloat
    var frame: CGFloat
    var body: some View {
        let music = store.music
        if music.failure != nil {
            MusicMacButton(symbol: "arrow.clockwise", label: "Retry", size: size * 0.8, prominent: true, frame: frame) { music.retry() }
        } else if music.busy && !music.isPlaying {
            ProgressView().controlSize(frame > 40 ? .regular : .small).frame(width: frame, height: frame)
        } else {
            MusicMacButton(symbol: music.isPlaying ? "pause.fill" : "play.fill", label: music.isPlaying ? "Pause" : "Play",
                           size: size, prominent: true, frame: frame) { music.toggle() }
        }
    }
}

/// The song's menu: what is playing and from where, Channels, lyrics timing, and Stop.
private struct MusicMacMenu: View {
    @Environment(Store.self) private var store
    @Binding var showsChannels: Bool
    var body: some View {
        let music = store.music
        Menu {
            if let quality = MusicMacNowPlaying.quality(music) { Text(quality) }
            if let credit = MusicMacNowPlaying.credit(music) { Text(credit) }
            if music.sourceStream != nil {
                Button { music.openInVideoPlayer() } label: { Label(L10n.text("Open in Video Player"), systemImage: "play.rectangle") }
            } else {
                Button { showsChannels = true } label: { Label(L10n.text("Channels"), systemImage: "antenna.radiowaves.left.and.right") }
            }
            if let track = music.track { MusicDownloadMenuItems(tracks: [track]) }
            if music.lyrics?.synced == true {
                Divider()
                Button(L10n.text("Lyrics Earlier")) { music.adjustLyrics(by: 0.5) }
                Button(L10n.text("Lyrics Later")) { music.adjustLyrics(by: -0.5) }
                if music.lyricsOffset != 0 { Button(L10n.text("Reset")) { music.resetLyricsOffset() } }
            }
            Divider()
            Button(role: .destructive) { music.stop() } label: { Label(L10n.text("Stop"), systemImage: "xmark") }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 30, height: 30).contentShape(Circle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.text("More"))
        .accessibilityLabel(L10n.text("More"))
    }
}

/// The player's volume between a quiet and a loud speaker.
struct MusicMacVolume: View {
    @Environment(Store.self) private var store
    static func symbol(_ volume: Double) -> String {
        volume <= 0 ? "speaker.slash.fill" : volume < 0.34 ? "speaker.wave.1.fill" : volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }
    var body: some View {
        @Bindable var music = store.music
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
            Slider(value: $music.volume, in: 0...1).controlSize(.small)
            Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("Volume"))
    }
}

/// The system's AirPlay button, sending this player's sound.
struct MusicMacRoutePicker: NSViewRepresentable {
    let player: AVPlayer
    var color: NSColor = .secondaryLabelColor
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.player = player
        view.isRoutePickerButtonBordered = false
        view.setRoutePickerButtonColor(color, for: .normal)
        return view
    }
    func updateNSView(_ view: AVRoutePickerView, context: Context) {}
}

/// Now Playing over the whole window: the cover, the song and its controls on the left on a
/// backdrop blurred from the cover, and the lyrics or Up Next filling the right. Escape, the close
/// button or the bar's song closes it.
struct MusicMacNowPlaying: View {
    @Environment(Store.self) private var store
    @State private var tint = Color(white: 0.22)
    @State private var showsChannels = false
    @AppStorage("musicShowsTranslation") private var showsTranslation = true

    var body: some View {
        let music = store.music
        GeometryReader { proxy in
            let art = max(180, min(proxy.size.width * 0.28, proxy.size.height - 340, 400))
            HStack(spacing: max(48, proxy.size.width * 0.07)) {
                VStack(alignment: .leading, spacing: 0) {
                    MusicArtwork(url: music.track?.artwork, size: art)
                        .shadow(color: .black.opacity(0.4), radius: 26, y: 14)
                        // As in Music, the cover steps back while paused.
                        .scaleEffect(music.isPlaying || music.busy ? 1 : 0.9)
                        .animation(.spring(response: 0.5, dampingFraction: 0.75), value: music.isPlaying)
                    header(music).padding(.top, 22)
                    MusicScrubber().padding(.top, 10)
                    transport.padding(.top, 4)
                    status(music).padding(.top, 8)
                }
                .frame(width: art)
                Group {
                    switch music.nowPlayingPanel {
                    case .lyrics: MusicNowPlayingLyrics(showsTranslation: showsTranslation)
                    case .queue: MusicUpNext()
                    }
                }
                .frame(maxWidth: 580, maxHeight: .infinity, alignment: .leading)
            }
            .padding(.horizontal, max(56, proxy.size.width * 0.08)).padding(.top, 64).padding(.bottom, 72)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background {
            // Escape closes; Close itself is in the window's toolbar (NowPlayingWindowChrome).
            Button(L10n.text("Close")) { music.presentsPlayer = false }.keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true)
        }
        .overlay(alignment: .bottomTrailing) { panelSwitch(music).padding(.trailing, 22).padding(.bottom, 20) }
        .foregroundStyle(.white)
        .tint(.white)
        .background { backdrop(music) }
        .environment(\.colorScheme, .dark)
        .task(id: music.track?.artwork) {
            guard let url = music.track?.artwork, let color = await PosterPalette.average(url) else { return }
            withAnimation(.easeInOut(duration: 0.6)) { tint = color }
        }
        .onChange(of: music.track == nil) { _, gone in if gone { music.presentsPlayer = false } }
        .sheet(isPresented: $showsChannels) { MusicChannelsView() }
    }

    /// The cover's colour, then the cover itself blurred to a wash over it.
    private func backdrop(_ music: MusicPlaybackSession) -> some View {
        ZStack {
            LinearGradient(colors: [tint.mix(with: .black, by: 0.12), tint.mix(with: .black, by: 0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let artwork = music.track?.artwork {
                // Blurred small and drawn once, then scaled up: a full-window blur redrawn every
                // frame made opening the player and scrolling the lyrics stutter.
                GeometryReader { proxy in
                    PosterImage(url: artwork, symbol: "music.note")
                        .frame(width: 48, height: 48)
                        .blur(radius: 7, opaque: true)
                        .saturation(1.25)
                        .drawingGroup()
                        .scaleEffect(max(proxy.size.width, proxy.size.height) / 48 * 1.25)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
                .opacity(0.8)
                .id(artwork)
                .transition(.opacity)
            }
            Color.black.opacity(0.18)
        }
        .clipped()
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private func header(_ music: MusicPlaybackSession) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(music.track?.title ?? "").font(.system(size: 15, weight: .bold)).lineLimit(1)
                Text(Self.byline(music.track)).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MusicMacMenu(showsChannels: $showsChannels)
                .background(.white.opacity(0.14), in: Circle())
        }
    }

    private var transport: some View {
        let music = store.music
        return HStack {
            MusicMacButton(symbol: "shuffle", label: "Shuffle", size: 14, on: music.shuffled, frame: 36) { music.toggleShuffle() }
            Spacer(minLength: 0)
            MusicMacButton(symbol: "backward.fill", label: "Previous", size: 20, prominent: true, frame: 44) { music.previous() }
            Spacer(minLength: 0)
            MusicMacPlayButton(size: 28, frame: 52)
            Spacer(minLength: 0)
            MusicMacButton(symbol: "forward.fill", label: "Next", size: 20, prominent: true, frame: 44) { music.next() }.disabled(!music.canAdvance)
            Spacer(minLength: 0)
            MusicMacButton(symbol: music.repeatMode.symbol, label: music.repeatMode.label, size: 14, on: music.repeatMode != .off, frame: 36) { music.cycleRepeat() }
        }
    }

    /// The format actually read, and the channel's credit where it asks for one.
    private func status(_ music: MusicPlaybackSession) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let failure = music.failure {
                Text(failure).foregroundStyle(Brand.amber)
            } else if music.phase == .resolving {
                Text(L10n.text("Finding the best channel…"))
            } else if let quality = Self.quality(music) {
                Button { showsChannels = true } label: { Text(quality) }.buttonStyle(.plain)
            }
            if let credit = Self.credit(music) { Text(credit).foregroundStyle(.tertiary) }
        }
        .font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
    }

    private func panelSwitch(_ music: MusicPlaybackSession) -> some View {
        HStack(spacing: 10) {
            if music.nowPlayingPanel == .lyrics, music.lyrics?.lines.contains(where: { $0.translation != nil }) == true {
                MusicMacButton(symbol: "character.bubble", label: showsTranslation ? "Hide Translation" : "Show Translation",
                               size: 14, on: showsTranslation, frame: 34) { showsTranslation.toggle() }
                    .glassSurface(.regular, in: Circle())
            }
            HStack(spacing: 2) {
                ForEach([MusicNowPlayingPanel.lyrics, .queue], id: \.self) { panel in
                    MusicMacButton(symbol: panel == .lyrics ? "quote.bubble" : "list.bullet", label: panel == .lyrics ? "Lyrics" : "Up Next",
                                   size: 13, on: music.nowPlayingPanel == panel, frame: 30) {
                        withAnimation(.smooth(duration: 0.3)) { music.nowPlayingPanel = panel }
                    }
                }
            }
            .padding(2)
            .glassSurface(.regular, in: Capsule())
        }
    }

    static func byline(_ track: MusicTrack?) -> String {
        [track?.artistLine, track?.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
    }

    static func quality(_ music: MusicPlaybackSession) -> String? {
        guard music.failure == nil, let selection = music.selection else { return nil }
        let format = selection.probe.format.codec == .unknown ? L10n.text("Quality to be confirmed") : selection.probe.format.label
        return selection.degraded ? format + " · " + L10n.text("Lossy quality") : format
    }

    /// Both services ask to be named while their audio plays.
    static func credit(_ music: MusicPlaybackSession) -> String? {
        guard music.failure == nil else { return nil }
        switch music.selection?.candidate.provider {
        case .gdstudio: return L10n.text("Source: GD Music (music.gdstudio.xyz)")
        case .xinghai: return L10n.text("Source: Xinghai (yy.zddyr.top)")
        default: return nil
        }
    }
}
#endif

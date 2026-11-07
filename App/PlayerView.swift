import SwiftUI
import AVKit
import VideoToolbox
import TVCore

struct PlaybackView: View {
    let channel: Channel
    #if os(iOS)
    /// Set when the player is the top of an iPhone watch page rather than a screen of its own.
    var watch: WatchPlayback? = nil
    #endif
    @Environment(\.dismiss) private var dismiss
    @Environment(Store.self) private var store
    @State private var session = PlaybackSession()
    @State private var showsChrome = true
    @State private var hideTask: Task<Void, Never>?
    #if os(iOS)
    /// A watch page starts playing by itself, so its controls wait for a tap (`-qaPlayerControls` keeps them up).
    @State private var quietStart = !UserDefaults.standard.bool(forKey: "qaPlayerControls")
    #endif
    @AppStorage(DanmakuPreference.key) private var showsDanmaku = true
    @AppStorage(DanmakuArea.key) private var danmakuArea = DanmakuArea.standard
    @State private var showsDanmakuList = false
    @State private var showsEpisodes = false
    @AppStorage(VideoEnhancement.upscaleKey) private var upscalesVideo = false
    @AppStorage(VideoEnhancement.smoothKey) private var smoothsVideo = false
    #if os(tvOS)
    @AppStorage(PlaybackInfo.key) private var showsPlaybackInfo = false
    @State private var playbackSpeed: Float = 1
    @State private var fillsScreen = false
    #endif
    #if os(macOS)
    @State private var importsSubtitleFile = false
    @State private var asksSubtitleAddress = false
    @State private var searchesSubtitles = false
    #endif
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    private var chromeVisible: Bool {
        #if os(iOS)
        if playerLayout == .inline, quietStart { return session.error != nil }
        #endif
        return showsChrome || session.error != nil || session.loading
    }

    var body: some View {
        ZStack {
            #if os(iOS)
            Color.black.playerBleed(playerLayout != .inline)
            #else
            Color.black.ignoresSafeArea()
            #endif
            #if os(tvOS)
            // Remove the native focus environment while recovery controls are shown.
            if session.error == nil {
                NativePlayerView(player: session.player, comments: session.danmaku, showsDanmaku: $showsDanmaku, opacity: session.danmakuOpacity, revision: session.danmakuRevision,
                                 subtitles: session.subtitles, qualities: session.qualities, quality: session.quality, choose: { session.choose(quality: $0) },
                                 audio: session.audioChoices, audioChoice: session.audioChoice, chooseAudio: { session.chooseAudio($0) },
                                 live: session.isLive, previous: episodeAction(store.step(back: true, from: channel, session: session)),
                                 next: episodeAction(store.step(back: false, from: channel, session: session)), waiting: waitContent,
                                 enhancer: session.enhancer, upscale: $upscalesVideo, smooth: $smoothsVideo, info: $showsPlaybackInfo,
                                 speed: playbackSpeed, setSpeed: { playbackSpeed = $0; session.setSpeed($0) }, fills: $fillsScreen, danmakuArea: $danmakuArea,
                                 external: session.externalSubtitles,
                                 exitWhileWaiting: session.showsPicture ? nil : { dismiss() }).ignoresSafeArea()
                    .onAppear { playbackSpeed = session.player.defaultRate }
            }
            // Until the picture starts, AVKit's player keeps the Back press to itself, so a stream that never
            // loads (a dead live channel) left no way out but quitting the app. This takes focus and closes instead.
            if session.error == nil && !session.showsPicture {
                Color.clear.loadingFocus(takeFocus: true) { dismiss() }
                    .accessibilityIdentifier("player.waiting")
            }
            // In the title-safe corner, over the picture and clear of the transport bar.
            if showsPlaybackInfo && session.error == nil && session.showsPicture {
                PlaybackInfoPanel(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(.opacity)
            }
            #elseif os(iOS)
            MobilePlayerView(channel: channel, session: session, showsDanmaku: $showsDanmaku, upscalesVideo: $upscalesVideo, smoothsVideo: $smoothsVideo,
                             waiting: waitContent, chromeVisible: chromeVisible, toggleChrome: toggleChrome, poke: poke, hold: holdChrome,
                             close: exit, layout: playerLayout, toggleFullScreen: watch.map { _ in toggleFullScreen })
            #else
            NativePlayerView(player: session.player, comments: session.danmaku, showsDanmaku: $showsDanmaku, opacity: session.danmakuOpacity, revision: session.danmakuRevision,
                             subtitles: session.subtitles).ignoresSafeArea()
            chrome.opacity(chromeVisible ? 1 : 0).allowsHitTesting(chromeVisible)
            #endif
            status
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "qaPlaybackProbe") {
                VStack {
                    Text(session.catalogDanmaku.automaticState)
                        .accessibilityIdentifier("player.qa.danmaku")
                        .accessibilityValue("\(session.danmaku.count)")
                    Text("Playback position").accessibilityIdentifier("player.qa.position")
                        .accessibilityValue("\(session.position)")
                }
                .font(.caption2).foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .allowsHitTesting(false)
            }
            // `-qaEnhanceHUD 1`: what the enhancer is doing, the frame rate it draws, and the screen's own rate.
            if UserDefaults.standard.bool(forKey: "qaEnhanceHUD") {
                Text(enhanceHUD)
                    .font(.system(size: 22, weight: .medium, design: .monospaced)).foregroundStyle(.white)
                    .padding(12).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                    .padding(60)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
            }
            #endif
        }
        #if os(iOS)
        // Registers the external-display accessory while the player is on screen (iOS 27): the system only
        // offers the display to apps that ask for it, and takes it back when the player closes.
        .background(ExternalDisplaySceneRegistrar().allowsHitTesting(false))
        // On a watch page the rest of the page keeps its own appearance.
        .modifier(PlayerScheme(ownsScreen: watch == nil))
        // The home indicator fades with the controls while the picture fills the screen (#650); a swipe up
        // brings it back first, as in other video apps. A watch page's player leaves it to the page.
        .persistentSystemOverlays(playerLayout != .inline && !chromeVisible ? .hidden : .automatic)
        #else
        .preferredColorScheme(.dark)
        #endif
        // Translated subtitles are translated here, where Translation can ask to download a language.
        .subtitleTranslation()
        #if os(macOS)
        .frame(minWidth: 880, minHeight: 540)
        #endif
        #if !os(tvOS)
        .onContinuousHover { _ in poke() }
        #if os(iOS)
        // The controls stay up while paused and start their countdown again on play.
        .onChange(of: session.paused) { _, paused in if paused { hideTask?.cancel() } else if showsChrome { scheduleHide() } }
        #else
        .simultaneousGesture(TapGesture().onEnded { poke() })
        #endif
        #endif
        .onAppear {
            startCatalogPlayback(session, channel: channel, store: store); showOnStart()
            #if os(iOS)
            ExternalDisplay.shared.attach(session.player)
            #endif
        }
        #if DEBUG && os(iOS)
        // `-qaWatchFullScreen <seconds>`: a watch page's player goes full screen after that long, for screenshots.
        .task(id: watch != nil) {
            let delay = UserDefaults.standard.double(forKey: "qaWatchFullScreen")
            guard watch?.fullScreen == false, delay > 0 else { return }
            try? await Task.sleep(for: .seconds(delay))
            if !Task.isCancelled { toggleFullScreen() }
        }
        #endif
        .onChange(of: channel) { _, channel in startCatalogPlayback(session, channel: channel, store: store); showOnStart() }
        #if os(iOS)
        .onChange(of: session.showsPicture || session.error != nil, initial: true) { _, started in watch?.started(started) }
        .onAppear { watch?.opened(session) }
        #endif
        .onChange(of: showsDanmaku) { _, value in session.catalogDanmaku.enabled = value }
        .onChange(of: session.catalogDanmaku.enabled) { _, value in showsDanmaku = value }
        .onDisappear {
            hideTask?.cancel(); store.cancelEpisodeSelection(); session.stop()
            #if os(iOS)
            ExternalDisplay.shared.detach(session.player)
            PlayerOrientation.release()
            #endif
        }
        #if os(iOS)
        // Opening iPhone Duo moves the app to the inner display, which ignores orientations: drop a
        // landscape lock so the outer display isn't left in landscape when it closes again.
        .onChange(of: horizontalSizeClass == .regular && verticalSizeClass == .regular) { _, large in
            if large { PlayerOrientation.release() }
        }
        #endif
    }

    #if DEBUG
    private var enhanceHUD: String {
        var lines = ["Sharper \(UserDefaults.standard.bool(forKey: VideoEnhancement.upscaleKey) ? "on" : "off") · Smooth \(UserDefaults.standard.bool(forKey: VideoEnhancement.smoothKey) ? "on" : "off")"
                     + " · drawing: \(session.enhancer.status.upscaling ? "upscaled " : "")\(session.enhancer.status.smoothing ? "smoothed" : session.enhancer.status.active ? "" : "AVKit picture")",
                     session.enhancer.summary]
        #if !os(macOS)
        if let screen = UIApplication.shared.appWindowScene?.screen {
            lines.append("screen \(screen.maximumFramesPerSecond) Hz \(Int(screen.nativeBounds.width))×\(Int(screen.nativeBounds.height))")
        }
        #endif
        return lines.joined(separator: "\n")
    }
    #endif

    #if os(tvOS)
    private func episodeAction(_ step: PlayerStep?) -> EpisodeAction? {
        step.map { EpisodeAction(name: $0.name, busy: $0.busy, play: $0.go) }
    }
    #endif

    #if !os(tvOS)
    #if os(macOS)
    private var chrome: some View {
        // One row when it fits: a long title truncates, and only when the buttons leave no room for any do they get
        // a row of their own. (One copy of each view: ViewThatFits with a candidate per title width built every glass
        // button many times over and stalled the main thread past the watchdog.) The iPhone and iPad player draws its
        // own (MobilePlayerView).
        ChromeRow { chromeTitle; chromeButtons; chromeClose }
            .padding(16)
            .frame(maxHeight: .infinity, alignment: .top)
        .subtitleImport(files: $importsSubtitleFile, address: $asksSubtitleAddress, search: $searchesSubtitles, subtitles: session.externalSubtitles)
        .playerEpisodesSheet(isPresented: $showsEpisodes, channel: channel)
        .sheet(isPresented: $showsDanmakuList) {
            DanmakuListView(player: session.player, comments: session.danmaku) { showsDanmakuList = false }
                .danmakuListPresentation()
        }
    }

    private var chromeTitle: some View {
        Text(channel.name).font(.headline).lineLimit(1)
            .padding(.horizontal, 18).padding(.vertical, 11)
            .glassSurface(.regular, in: Capsule())
    }

    private var chromeButtons: some View {
        HStack(spacing: 10) {
            if let previous = store.step(back: true, from: channel, session: session) {
                Button { previous.go() } label: {
                    Image(systemName: "backward.end.fill").font(.headline).frame(width: 22, height: 22)
                }
                .chromeButton()
                .disabled(previous.busy)
                .accessibilityLabel(L10n.text("Previous Episode")).help(previous.name)
            }
            if let next = store.step(back: false, from: channel, session: session) {
                Button { next.go() } label: {
                    Image(systemName: "forward.end.fill").font(.headline).frame(width: 22, height: 22)
                }
                .chromeButton()
                .disabled(next.busy)
                .accessibilityLabel(L10n.text("Next Episode")).help(next.name)
            }
            PlayerEpisodesButton(channel: channel, isPresented: $showsEpisodes) {
                Image(systemName: PlayerEpisodesSheet.symbol).font(.headline).frame(width: 22, height: 22)
            }
            .chromeButton()
            CatalogPlaybackActions(channel: channel, session: session)
            if session.qualities.count > 1 {
                Menu {
                    QualityPicker(session: session)
                } label: {
                    Image(systemName: "sparkles.tv").font(.headline).frame(width: 22, height: 22)
                }
                .chromeButton()
                .accessibilityLabel(L10n.text("Quality"))
            }
            // A file whose sound tracks AVKit's own menu can't offer (#428).
            if session.audioChoices.count > 1 {
                Menu {
                    Picker(L10n.text("Audio"), selection: Binding(get: { session.audioChoice }, set: { if let id = $0 { session.chooseAudio(id) } })) {
                        ForEach(session.audioChoices) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "speaker.wave.2").font(.headline).frame(width: 22, height: 22)
                }
                .chromeButton()
                .accessibilityLabel(L10n.text("Audio"))
            }
            // Subtitle files beside the video, or added now (#576); the item's own are in AVKit's menu.
            Menu {
                MacSubtitleFiles(subtitles: session.externalSubtitles, addFile: { importsSubtitleFile = true }, addAddress: { asksSubtitleAddress = true },
                                 searchOnline: { searchesSubtitles = true })
            } label: {
                Image(systemName: session.externalSubtitles.selected == nil ? "captions.bubble" : "captions.bubble.fill").font(.headline).frame(width: 22, height: 22)
            }
            .chromeButton()
            .accessibilityLabel(L10n.text("Subtitle Files"))
            // One button for danmaku: show or hide them, or open the list.
            if !session.danmaku.isEmpty {
                Menu {
                    Toggle(isOn: $showsDanmaku) { Label(L10n.text("Show Danmaku"), systemImage: "text.bubble") }
                    Picker(selection: $danmakuArea) {
                        ForEach(DanmakuArea.allCases, id: \.self) { Text($0.title).tag($0) }
                    } label: { Label(L10n.text("Danmaku Area"), systemImage: "rectangle.tophalf.inset.filled") }
                    .pickerStyle(.menu)
                    DanmakuStylePickers(model: session.catalogDanmaku)
                    Button { showsDanmakuList = true } label: { Label(L10n.text("Danmaku List"), systemImage: "list.bullet.rectangle") }
                } label: {
                    Image(systemName: showsDanmaku ? "text.bubble.fill" : "text.bubble").font(.headline).frame(width: 22, height: 22)
                }
                .chromeButton()
                .accessibilityLabel(L10n.text("Danmaku"))
            }
        }
    }

    private var chromeClose: some View {
        Button { dismiss() } label: { Image(systemName: "xmark").font(.headline).frame(width: 22, height: 22) }
            .chromeButton()
            .accessibilityLabel(L10n.text("Close"))
            .accessibilityIdentifier("player.close")
            .keyboardShortcut(.cancelAction)
    }
    #endif

    private func poke() {
        #if os(iOS)
        quietStart = false
        #endif
        showsChrome = true
        scheduleHide()
    }

    /// A channel starting shows the controls for a moment, except at the top of a watch page, which plays by itself.
    private func showOnStart() {
        #if os(iOS)
        if playerLayout == .inline, !UserDefaults.standard.bool(forKey: "qaPlayerControls") {
            hideTask?.cancel(); quietStart = true; showsChrome = false
            return
        }
        #endif
        poke()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        #if DEBUG
        // Keep screenshot/interaction QA stable while XCTest waits for AVKit to idle.
        if UserDefaults.standard.bool(forKey: "qaPlayerControls") { return }
        #endif
        #if os(iOS)
        // The controls stay while paused, and while VoiceOver runs, which can't reach controls that have faded out;
        // otherwise they leave about three seconds into playback.
        guard !session.paused, !UIAccessibility.isVoiceOverRunning else { return }
        let delay = 3.0
        #else
        let delay = 3.5
        #endif
        hideTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            if !Task.isCancelled { withAnimation(.smooth(duration: 0.3)) { showsChrome = false } }
        }
    }

    #if os(iOS)
    private var playerLayout: MobilePlayerLayout {
        guard let watch else { return .screen }
        return watch.fullScreen ? .pageFullScreen : .inline
    }

    /// Back: closes the player; on a watch page, leaves Full Screen, or the page.
    private func exit() {
        guard let watch else { return dismiss() }
        if watch.fullScreen { toggleFullScreen() } else { watch.leave() }
    }

    /// Full Screen turns the phone for a picture wider than tall; a portrait video fills the screen upright.
    private func toggleFullScreen() {
        let size = session.player.currentItem?.presentationSize ?? .zero
        watch?.toggleFullScreen(size.height == 0 || size.width >= size.height)
        poke()
    }

    /// A tap on the picture shows the controls, or hides them at once.
    private func toggleChrome() {
        #if DEBUG
        // UI tests tap the picture to reach the controls, which `-qaPlayerControls` keeps up.
        if UserDefaults.standard.bool(forKey: "qaPlayerControls") { return poke() }
        #endif
        guard showsChrome, !quietStart else { return poke() }
        hideTask?.cancel()
        withAnimation(.smooth(duration: 0.25)) { showsChrome = false }
    }

    /// The seek bar is held: the controls stay until it is let go, then count down again.
    private func holdChrome(_ holding: Bool) {
        if holding { showsChrome = true; hideTask?.cancel() } else { scheduleHide() }
    }
    #endif
    #else
    private func poke() {}
    private func showOnStart() {}
    #endif

    @ViewBuilder private var status: some View {
        if let error = session.error {
            #if os(tvOS)
            TVPlaybackFailureView(channelName: channel.name, details: error, symbol: session.errorSymbol, backdrop: waitContent,
                                  retry: { startCatalogPlayback(session, channel: channel, store: store) }, goBack: { dismiss() })
            #elseif os(iOS)
            if playerLayout == .inline {
                // At the top of a watch page: the same words, small, and Try Again; the page has Back.
                VStack(spacing: 8) {
                    Label(L10n.text("Can't play this right now"), systemImage: session.errorSymbol).font(.headline)
                    Text(error).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
                        .multilineTextAlignment(.center)
                    Button { startCatalogPlayback(session, channel: channel, store: store) } label: {
                        Label(L10n.text("Try Again"), systemImage: "arrow.clockwise")
                    }
                    .controlButton(prominent: true).tint(Brand.accent).appControlSize(.small).padding(.top, 2)
                }
                .foregroundStyle(.white).padding(.horizontal, 24).padding(.top, 36)
                .environment(\.colorScheme, .dark)
            } else {
                // A pause, not an alarm: the artwork stays behind (see waitContent), the words are kind, and the next step is clear.
                VStack(spacing: 0) {
                    Image(systemName: session.errorSymbol)
                        .font(.system(size: 58, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white)
                        .breathingSymbol()
                        .shadow(color: .white.opacity(0.22), radius: 26)
                        .frame(height: 70)
                        .accessibilityHidden(true)
                    Text(L10n.text("Can't play this right now")).font(.title2.weight(.semibold)).padding(.top, 24)
                    Text(error).font(.callout).foregroundStyle(.white.opacity(0.7)).lineSpacing(2)
                        .multilineTextAlignment(.center).frame(maxWidth: 330).padding(.top, 10)
                    GlassGroup(spacing: 12) {
                        HStack(spacing: 12) {
                            Button { startCatalogPlayback(session, channel: channel, store: store) } label: {
                                Label(L10n.text("Try Again"), systemImage: "arrow.clockwise")
                            }
                            .controlButton(prominent: true).tint(Brand.accent)
                            Button { exit() } label: { Label(L10n.text("Close"), systemImage: "xmark") }.controlButton()
                        }
                    }
                    .appControlSize(.large).padding(.top, 30)
                }
                .foregroundStyle(.white)
                .padding(32)
                .environment(\.colorScheme, .dark)
            }
            #else
            VStack(spacing: 18) {
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(Brand.amber)
                Text(error).multilineTextAlignment(.center).frame(maxWidth: 420)
                GlassGroup(spacing: 10) {
                    HStack(spacing: 10) {
                        Button(L10n.text("Retry")) { startCatalogPlayback(session, channel: channel, store: store) }.controlButton(prominent: true).tint(Brand.accent)
                        Button(L10n.text("Close")) { dismiss() }.controlButton()
                    }
                }.appControlSize(.large)
            }
            .padding(30).glassPanel(cornerRadius: 30).padding(30)
            #endif
        } else if session.loading || session.buffering {
            #if os(macOS)
            // Top of the frame, clear of the transport bar. Seeks stall briefly; only longer waits show.
            LoadingCard(appearAfter: session.loading ? 0 : 1.5, maxWidth: LoadingCard.compact) { session.loadingProgress }
                .padding(.horizontal, 24).padding(.top, 48)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
            #endif
        }
    }

    private var waitContent: PlaybackWaitContent? {
        #if os(tvOS)
        .make(session, channel: channel, store: store, linesHint: false)
        #else
        .make(session, channel: channel, store: store, linesHint: true)
        #endif
    }
}


extension PlaybackWaitContent {
    /// The wait drawn under a player's controls: the artwork while the episode first loads (and behind
    /// an error), the words alone when playback stalls. `linesHint` where the player has the ⋯ menu.
    static func make(_ session: PlaybackSession, channel: Channel, store: Store, linesHint: Bool) -> PlaybackWaitContent? {
        let starting = session.loading || session.error != nil || !session.showsPicture
        guard starting || session.buffering else { return nil }
        let catalog = store.catalog(for: channel)
        let artwork = PlaybackArtwork(poster: catalog?.video.poster ?? channel.historyContext?.poster,
                                      headers: catalog?.video.posterHeaders ?? channel.historyContext?.posterHeaders ?? [:])
        let resume = channel.resumePosition, hint = linesHint && catalog != nil
        return PlaybackWaitContent(artwork: artwork, starting: starting, showsWords: session.error == nil, appearAfter: starting ? 0.6 : 1.5) { [session] elapsed in
            session.wait(elapsed: elapsed, resume: resume, linesHint: hint)
        }
    }
}

#if !os(tvOS)
/// The player's title bar: the title, the buttons and Close share one row, the title truncating to leave the others
/// their width; when that would leave the title less than `minimumTitle`, the buttons and Close take a row of their
/// own, right-aligned.
private struct ChromeRow: SwiftUI.Layout {
    var spacing: CGFloat = 12
    var rowSpacing: CGFloat = 10
    /// Between the buttons and Close, as between the buttons themselves.
    var buttonSpacing: CGFloat = 10
    var minimumTitle: CGFloat = 110

    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) -> CGSize {
        guard subviews.count == 3 else { return .zero }
        let buttons = subviews[1].sizeThatFits(.unspecified), close = subviews[2].sizeThatFits(.unspecified)
        let tail = tailSize(buttons, close)
        let width = proposal.width ?? subviews[0].sizeThatFits(.unspecified).width + spacing + tail.width
        if let room = titleRoom(width, tail: tail) {
            let title = subviews[0].sizeThatFits(ProposedViewSize(width: room, height: nil))
            return CGSize(width: width, height: max(title.height, tail.height))
        }
        let title = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: title.height + rowSpacing + tail.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let buttons = subviews[1].sizeThatFits(.unspecified), close = subviews[2].sizeThatFits(.unspecified)
        let tail = tailSize(buttons, close)
        if let room = titleRoom(bounds.width, tail: tail) {
            let title = subviews[0].sizeThatFits(ProposedViewSize(width: room, height: nil))
            let row = max(title.height, tail.height)
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + (row - title.height) / 2), proposal: ProposedViewSize(width: room, height: title.height))
            placeTail(buttons, close, right: bounds.maxX, middle: bounds.minY + row / 2, subviews)
            return
        }
        let title = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: title.height))
        placeTail(buttons, close, right: bounds.maxX, middle: bounds.minY + title.height + rowSpacing + tail.height / 2, subviews)
    }

    /// The buttons and Close side by side.
    private func tailSize(_ buttons: CGSize, _ close: CGSize) -> CGSize {
        CGSize(width: buttons.width + (buttons.width > 0 ? buttonSpacing : 0) + close.width, height: max(buttons.height, close.height))
    }

    private func placeTail(_ buttons: CGSize, _ close: CGSize, right: CGFloat, middle: CGFloat, _ subviews: LayoutSubviews) {
        subviews[2].place(at: CGPoint(x: right - close.width, y: middle - close.height / 2), proposal: .unspecified)
        subviews[1].place(at: CGPoint(x: right - close.width - buttonSpacing - buttons.width, y: middle - buttons.height / 2), proposal: .unspecified)
    }

    private func titleRoom(_ width: CGFloat, tail: CGSize) -> CGFloat? {
        let room = width - tail.width - spacing
        return room >= minimumTitle ? room : nil
    }
}
#endif

#if os(tvOS)
private struct TVPlaybackFailureView: View {
    let channelName: String
    let details: String
    var symbol = "play.slash.fill"
    /// The episode's colours behind the message, as on iPhone; the plain background when there is no artwork.
    var backdrop: PlaybackWaitContent? = nil
    let retry: () -> Void
    let goBack: () -> Void
    @State private var showsDetails = false
    @FocusState private var retryFocused: Bool

    var body: some View {
        ZStack {
            if let backdrop { backdrop.view } else { TVStyle.background.ignoresSafeArea() }
            VStack(spacing: 0) {
                Image(systemName: symbol)
                    .font(.system(size: 96, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
                    .breathingSymbol()
                    .shadow(color: .white.opacity(0.2), radius: 40)
                    .frame(height: 120)
                    .accessibilityHidden(true)
                    .padding(.bottom, 40)
                Text(L10n.text("Can't play this right now"))
                    .font(.system(size: 56, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 18)
                Text(channelName)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Color(white: 0.85)).lineLimit(2)
                    .padding(.bottom, 16)
                Text(L10n.text("Try again, or go back and choose another video."))
                    .font(.system(size: 27)).foregroundStyle(Color(white: 0.65))
                    .fixedSize(horizontal: false, vertical: true)
                // Liquid Glass, as every other control on Apple TV: clear at rest, white on focus.
                GlassGroup(spacing: 20) {
                    HStack(spacing: 20) {
                        Button(action: retry) { Label(L10n.text("Try Again"), systemImage: "arrow.clockwise") }.focused($retryFocused)
                        Button(action: goBack) { Label(L10n.text("Go back"), systemImage: "chevron.backward") }
                        Button { showsDetails.toggle() } label: { Label(L10n.text(showsDetails ? "Hide details" : "Show details"), systemImage: "info.circle") }
                    }
                    .controlButton()
                }
                .padding(.top, 48)
                if showsDetails {
                    ScrollView {
                        Text(details)
                            .font(.system(size: 23))
                            .foregroundStyle(Color(white: 0.65))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity)
                    }
                    .frame(maxHeight: 150)
                    .padding(.top, 32)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 1120)
            .padding(64)
        }
        .onAppear { retryFocused = true }
        .onExitCommand(perform: goBack)
    }
}
#endif

#if os(macOS)
private struct NativePlayerView: View {
    let player: AVPlayer
    let comments: [Danmaku]
    @Binding var showsDanmaku: Bool
    var opacity = 0.9
    var revision = ""
    var subtitles: SubtitleCues? = nil
    var body: some View {
        ZStack {
            PlayerSurface(player: player)
            if showsDanmaku && !comments.isEmpty { DanmakuOverlay(player: player, comments: comments, opacity: opacity, revision: revision).ignoresSafeArea() }
            if let subtitles { SubtitleOverlay(cues: subtitles).ignoresSafeArea() }
        }
    }
}
private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}
#elseif os(iOS)
/// The iPhone player's rotate button. While it holds landscape the app allows landscape only, so the phone
/// held upright (or Portrait Orientation Lock) doesn't turn it back; the button or closing the player does.
@MainActor enum PlayerOrientation {
    static private(set) var mask: UIInterfaceOrientationMask = .allButUpsideDown
    static var available: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    /// An iPhone watch page is on screen: it stays upright, and only its Full Screen turns the phone.
    static private var holdsPortrait = false

    static func set(landscape: Bool) {
        guard let scene = UIApplication.shared.appWindowScene else { return }
        mask = landscape ? .landscape : holdsPortrait ? .portrait : .allButUpsideDown
        var controller = scene.keyWindow?.rootViewController
        while let next = controller?.presentedViewController { controller = next }
        controller?.setNeedsUpdateOfSupportedInterfaceOrientations()
        // UIKit calls the error handler on a background queue. @Sendable keeps it off the main actor;
        // without it Swift 6 checks the closure's main-actor isolation at entry and traps (issue #247).
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscape : .portrait)) { @Sendable error in
            Diagnostics.shared.record(.warning, "player", "Rotation refused: \(error.localizedDescription)")
        }
    }

    /// Back to portrait when the player closes, if the button turned it.
    static func release() {
        if mask == .landscape { set(landscape: false) }
    }

    /// While a watch page shows, the app stays upright (the page turns to landscape for Full Screen only).
    static func holdPortrait(_ hold: Bool) {
        guard holdsPortrait != hold else { return }
        holdsPortrait = hold
        if mask != .landscape { set(landscape: false) }
    }
}
#else
/// Full screen inside a SwiftUI view that ignores the safe area, the controller is told it has none,
/// and AVKit then lays its bottom controls into the TV's overscan margin, where focus effects are cut
/// off. This restores the title-safe area for the controls; the video and its overlays still fill the screen.
private final class TitleSafePlayerController: AVPlayerViewController {
    private static let titleSafe = UIEdgeInsets(top: 60, left: 80, bottom: 60, right: 80)
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let given = view.safeAreaInsets, extra = additionalSafeAreaInsets
        let wanted = UIEdgeInsets(top: max(0, Self.titleSafe.top - (given.top - extra.top)), left: max(0, Self.titleSafe.left - (given.left - extra.left)),
                                  bottom: max(0, Self.titleSafe.bottom - (given.bottom - extra.bottom)), right: max(0, Self.titleSafe.right - (given.right - extra.right)))
        if wanted != extra { additionalSafeAreaInsets = wanted }
    }
}

struct EpisodeAction {
    let name: String
    let busy: Bool
    let play: @MainActor () -> Void
}

/// AVPlayerViewController itself, for its transport-bar menu: the Danmaku switch lives there, next to
/// subtitles and audio, where a remote can reach it. Comments draw in the content overlay, under the controls.
private struct NativePlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    let comments: [Danmaku]
    @Binding var showsDanmaku: Bool
    var opacity = 0.9
    var revision = ""
    var subtitles: SubtitleCues? = nil
    var qualities: [StreamQuality] = []
    var quality: Int? = nil
    var choose: @MainActor (Int?) -> Void = { _ in }
    /// The sound tracks AVKit's own Audio menu can't offer (`PlaybackSession.audioChoices`), and the one playing.
    var audio: [UngroupedAudio.Choice] = []
    var audioChoice: CMPersistentTrackID? = nil
    var chooseAudio: @MainActor (CMPersistentTrackID) -> Void = { _ in }
    var live = false
    /// The neighbouring episodes of a catalog video, as transport-bar buttons beside the menus.
    var previous: EpisodeAction? = nil
    var next: EpisodeAction? = nil
    var waiting: PlaybackWaitContent? = nil
    var enhancer: VideoEnhancer? = nil
    var upscale: Binding<Bool> = .constant(false)
    var smooth: Binding<Bool> = .constant(false)
    var info: Binding<Bool> = .constant(false)
    /// The speed picked in the Playback Speed menu, which `setSpeed` makes the player's default rate.
    var speed: Float = 1
    var setSpeed: @MainActor (Float) -> Void = { _ in }
    /// Fill Screen: the picture is cropped to the whole screen rather than fitted inside it, as on iPhone.
    var fills: Binding<Bool> = .constant(false)
    var danmakuArea: Binding<DanmakuArea> = .constant(.standard)
    /// Subtitle files beside the video (#576); the item's own are in AVKit's Subtitles menu.
    var external: ExternalSubtitles? = nil
    private static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4]
    private static func speedLabel(_ speed: Float) -> String {
        Double(speed).formatted(.number.precision(.fractionLength(0...2))) + "×"
    }
    /// Closes the player on Back until the picture starts. The overlay that takes focus for that loses it
    /// once the transport bar shows (an episode button takes it), and AVKit then keeps the press to itself.
    var exitWhileWaiting: (() -> Void)? = nil
    final class Coordinator: NSObject, UIGestureRecognizerDelegate, @preconcurrency AVPlayerViewControllerDelegate {
        var host: UIHostingController<AnyView>?; var listed = ""; var criteria: DisplayCriteriaKeeper?
        var exit: (() -> Void)?
        var subtitles: SubtitleCues?
        // Picture in Picture shows only the player's own picture, so AVPlayer draws the subtitles there.
        func playerViewControllerWillStartPictureInPicture(_ controller: AVPlayerViewController) { subtitles?.native = true }
        func playerViewControllerDidStopPictureInPicture(_ controller: AVPlayerViewController) { subtitles?.native = false }
        let back = UITapGestureRecognizer()
        override init() {
            super.init()
            back.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
            back.delegate = self
            back.addTarget(self, action: #selector(pressedBack))
        }
        @objc private func pressedBack() { exit?() }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = TitleSafePlayerController()
        // Decided before the controller is presented: AVKit refuses the change during playback.
        if VideoEnhancement.canSmooth, let enhancer { context.coordinator.criteria = DisplayCriteriaKeeper(controller: controller, player: player, enhancer: enhancer) }
        controller.player = player
        controller.delegate = context.coordinator
        context.coordinator.subtitles = subtitles
        let host = UIHostingController(rootView: overlay)
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        // Comments use the whole picture, not the TV's title-safe area.
        host.safeAreaRegions = []
        // The content overlay exists only once the controller's view has loaded.
        controller.loadViewIfNeeded()
        if let container = controller.contentOverlayView {
            controller.addChild(host)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(host.view)
            NSLayoutConstraint.activate([host.view.leadingAnchor.constraint(equalTo: container.leadingAnchor), host.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                                         host.view.topAnchor.constraint(equalTo: container.topAnchor), host.view.bottomAnchor.constraint(equalTo: container.bottomAnchor)])
            host.didMove(toParent: controller)
        }
        context.coordinator.host = host
        controller.view.addGestureRecognizer(context.coordinator.back)
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
        // Live has no timeline worth scrubbing: keep it at the live edge.
        if controller.requiresLinearPlayback != live { controller.requiresLinearPlayback = live }
        let gravity: AVLayerVideoGravity = fills.wrappedValue ? .resizeAspectFill : .resizeAspect
        if controller.videoGravity != gravity { controller.videoGravity = gravity }
        context.coordinator.host?.rootView = overlay
        context.coordinator.exit = exitWhileWaiting
        context.coordinator.back.isEnabled = exitWhileWaiting != nil
        // The comment list is a tab in the info panel (swipe down), beside the video's own info.
        if context.coordinator.listed != "\(revision):\(comments.count)" {
            context.coordinator.listed = "\(revision):\(comments.count)"
            if comments.isEmpty { controller.customInfoViewControllers = [] }
            else {
                let list = UIHostingController(rootView: DanmakuListView(player: player, comments: comments))
                list.title = L10n.text("Danmaku")
                list.preferredContentSize = CGSize(width: 0, height: 480)
                controller.customInfoViewControllers = [list]
            }
        }
        let binding = $showsDanmaku
        var items: [UIMenuElement] = []
        if !comments.isEmpty {
            let area = danmakuArea
            let areas = DanmakuArea.allCases.map { option in
                UIAction(title: option.title, state: area.wrappedValue == option ? .on : .off) { _ in area.wrappedValue = option }
            }
            items.append(UIMenu(title: L10n.text("Danmaku"), image: UIImage(systemName: showsDanmaku ? "text.bubble.fill" : "text.bubble"), children: [
                UIAction(title: L10n.text("Show Danmaku"), state: showsDanmaku ? .on : .off) { _ in binding.wrappedValue.toggle() },
                UIMenu(title: L10n.text("Danmaku Area"), image: UIImage(systemName: "rectangle.tophalf.inset.filled"), children: areas),
            ]))
        }
        if qualities.count > 1 {
            let choose = choose
            let current = qualities.first { $0.id == quality }?.label ?? L10n.text("Auto")
            let options = [UIAction(title: L10n.text("Auto"), state: quality == nil ? .on : .off) { _ in choose(nil) }]
                + qualities.map { option in UIAction(title: option.label, state: quality == option.id ? .on : .off) { _ in choose(option.id) } }
            items.append(UIMenu(title: L10n.text("Quality") + " · " + current, image: UIImage(systemName: "sparkles.tv"), children: options))
        }
        if audio.count > 1 {
            let chooseAudio = chooseAudio
            let options = audio.map { option in UIAction(title: option.name, state: option.id == audioChoice ? .on : .off) { _ in chooseAudio(option.id) } }
            items.append(UIMenu(title: L10n.text("Audio"), image: UIImage(systemName: "speaker.wave.2"), children: options))
        }
        if let external, !external.entries.isEmpty || external.hasSources { items.append(Self.subtitleFilesMenu(external)) }
        if !live {
            let setSpeed = setSpeed, speed = speed
            let options = Self.speeds.map { rate in UIAction(title: Self.speedLabel(rate), state: rate == speed ? .on : .off) { _ in setSpeed(rate) } }
            items.append(UIMenu(title: L10n.text("Playback Speed") + " · " + Self.speedLabel(speed), image: UIImage(systemName: "gauge.with.dots.needle.67percent"), children: options))
        }
        if let previous {
            items.insert(UIAction(title: L10n.text("Previous Episode"), subtitle: previous.name, image: UIImage(systemName: "backward.end.fill"),
                                  attributes: previous.busy ? [.disabled] : []) { _ in previous.play() }, at: 0)
        }
        if let next {
            items.insert(UIAction(title: L10n.text("Next Episode"), subtitle: next.name, image: UIImage(systemName: "forward.end.fill"),
                                  attributes: next.busy ? [.disabled] : []) { _ in next.play() }, at: previous == nil ? 0 : 1)
        }
        do {
            let upscale = upscale, smooth = smooth, fills = fills
            var options: [UIMenuElement] = [
                UIAction(title: L10n.text("Fill Screen"), image: UIImage(systemName: "arrow.up.left.and.arrow.down.right"),
                         state: fills.wrappedValue ? .on : .off) { _ in fills.wrappedValue.toggle() },
            ]
            if VideoEnhancement.canUpscale {
                options.append(UIAction(title: L10n.text("Sharper Picture"), state: upscale.wrappedValue ? .on : .off) { _ in upscale.wrappedValue.toggle() })
            }
            if VideoEnhancement.canSmooth {
                options.append(UIAction(title: L10n.text("Smooth Motion (60 fps)"), state: smooth.wrappedValue ? .on : .off) { _ in smooth.wrappedValue.toggle() })
            }
            let enhances = VideoEnhancement.canUpscale || VideoEnhancement.canSmooth
            items.append(UIMenu(title: L10n.text("Picture"), image: UIImage(systemName: enhances ? "wand.and.sparkles" : "aspectratio"), children: options))
        }
        let info = info
        items.append(UIAction(title: L10n.text("Show Video Info"), image: UIImage(systemName: "info.circle"),
                              state: info.wrappedValue ? .on : .off) { _ in info.wrappedValue.toggle() })
        controller.transportBarCustomMenuItems = items
    }
    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) { coordinator.criteria?.reset() }

    /// Off and the files, then the chosen one's timing, frame rate and encoding. A file is added on the TV by the
    /// source (a drive's folder); there is no file panel here.
    private static func subtitleFilesMenu(_ external: ExternalSubtitles) -> UIMenu {
        var files: [UIMenuElement] = [UIAction(title: L10n.text("Off"), state: external.selected == nil ? .on : .off) { _ in external.select(nil) }]
        for entry in external.entries {
            switch entry.state {
            case .ready:
                files.append(UIAction(title: entry.title, state: external.selected == entry.id ? .on : .off) { _ in external.select(entry.id) })
            case .loading:
                files.append(UIAction(title: L10n.text("%@ (loading)", entry.title), attributes: [.disabled]) { _ in })
            case .failed(let reason):
                files.append(UIAction(title: L10n.text("%@: Try Again", entry.title), subtitle: reason) { _ in external.retry(entry.id) })
            }
        }
        var children: [UIMenuElement] = [UIMenu(options: .displayInline, children: files)]
        if external.hasSources || external.onlineState != .idle { children.append(onlineMenu(external)) }
        if let document = external.document {
            let timing = external.timing
            let shift = { (seconds: Double) in external.setTiming(SubtitleTiming(delay: timing.delay + seconds, scale: timing.scale)) }
            var delay: [UIMenuElement] = [
                UIAction(title: String(format: "%+.1f s", -SubtitleTiming.step), attributes: timing.delay <= SubtitleTiming.delays.lowerBound ? [.disabled] : []) { _ in shift(-SubtitleTiming.step) },
                UIAction(title: String(format: "%+.1f s", SubtitleTiming.step), attributes: timing.delay >= SubtitleTiming.delays.upperBound ? [.disabled] : []) { _ in shift(SubtitleTiming.step) },
            ]
            if !timing.isIdentity { delay.append(UIAction(title: L10n.text("Reset")) { _ in external.setTiming(SubtitleTiming()) }) }
            children.append(UIMenu(title: L10n.text("Subtitle Delay") + " · " + timing.title, image: UIImage(systemName: "clock.arrow.2.circlepath"), children: delay))
            let rates = [UIAction(title: L10n.text("As Made"), state: timing.rate == nil ? .on : .off) { _ in external.setTiming(SubtitleTiming(delay: timing.delay)) }]
                + SubtitleTiming.rates.map { rate in
                    UIAction(title: L10n.text("%@ fps", rate.title), state: timing.rate == rate ? .on : .off) { _ in external.setTiming(SubtitleTiming(delay: timing.delay, scale: rate.scale)) }
                }
            children.append(UIMenu(title: L10n.text("Frame Rate"), image: UIImage(systemName: "film"), children: rates))
            let encodings = SubtitleEncoding.allCases.map { encoding in
                UIAction(title: encoding.title, state: document.encoding == encoding ? .on : .off) { _ in external.read(as: encoding) }
            }
            children.append(UIMenu(title: L10n.text("Text Encoding"), image: UIImage(systemName: "textformat"), children: encodings))
            if document.format.isStyled {
                children.append(UIAction(title: L10n.text("ASS styling and effects show as plain text."), attributes: [.disabled]) { _ in })
            }
        }
        return UIMenu(title: L10n.text("Subtitle Files"), image: UIImage(systemName: external.selected == nil ? "captions.bubble" : "captions.bubble.fill"), children: children)
    }

    /// Subtitle sources (#576 M2): Search Online, then the results best first as they come in. The search uses the
    /// video's names as the catalog gives them; there is no editing them with the remote.
    private static func onlineMenu(_ external: ExternalSubtitles) -> UIMenu {
        var items: [UIMenuElement] = []
        switch external.onlineState {
        case .idle:
            items.append(UIAction(title: L10n.text("Search Online"), image: UIImage(systemName: "magnifyingglass")) { _ in external.search() })
        case .noSources:
            items.append(UIAction(title: L10n.text("No subtitle sources are on."), subtitle: L10n.text("Settings › Subtitle Sources"), attributes: [.disabled]) { _ in })
        case .searching, .done:
            for candidate in external.online.candidates.prefix(12) {
                let subtitle = ([candidate.detail] + candidate.tags).joined(separator: " · ")
                items.append(UIAction(title: candidate.title, subtitle: subtitle, state: external.selected == candidate.id ? .on : .off) { _ in external.download(candidate) })
            }
            if external.onlineState == .searching {
                items.append(UIAction(title: L10n.text("Searching…"), attributes: [.disabled]) { _ in })
            } else {
                if external.online.candidates.isEmpty { items.append(UIAction(title: L10n.text("No subtitles found."), attributes: [.disabled]) { _ in }) }
                for source in external.sourceNames {
                    if case .failed(let error)? = external.online.statuses[source.id] {
                        items.append(UIAction(title: source.name, subtitle: error.localizedDescription, attributes: [.disabled]) { _ in })
                    }
                }
                items.append(UIAction(title: L10n.text("Search Again"), image: UIImage(systemName: "arrow.clockwise")) { _ in external.search() })
            }
        }
        return UIMenu(title: L10n.text("Online"), options: .displayInline, children: items)
    }
    private var overlay: AnyView {
        AnyView(ZStack {
            if let enhancer { EnhancedVideoSurface(enhancer: enhancer, fills: fills.wrappedValue) }
            if showsDanmaku && !comments.isEmpty { DanmakuOverlay(player: player, comments: comments, opacity: opacity, revision: revision).ignoresSafeArea() }
            if let subtitles { SubtitleOverlay(cues: subtitles, fills: fills.wrappedValue) }
            if let waiting { waiting.view.transition(.opacity) }
        }
        .animation(.easeInOut(duration: 0.7), value: waiting == nil))
    }
}
#endif

#if os(macOS)
/// A real document-style window: playback remains independent of library navigation.
@MainActor final class PlayerWindowController: NSObject, NSWindowDelegate {
    private var window: PlaybackWindow?
    private let session = PlaybackSession()
    private var onClose: (() -> Void)?

    func present(_ channel: Channel, store: Store, onClose: @escaping () -> Void) {
        self.onClose = onClose
        let target: PlaybackWindow
        if let window { target = window }
        else {
            target = PlaybackWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                                    styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                    backing: .buffered, defer: false)
            target.isReleasedWhenClosed = false
            target.delegate = self
            target.contentMinSize = NSSize(width: 480, height: 320)
            target.collectionBehavior = [.fullScreenPrimary]
            target.backgroundColor = .black
            target.titlebarAppearsTransparent = true
            target.titleVisibility = .hidden
            target.isMovableByWindowBackground = true
            target.center()
            target.setFrameAutosaveName("PlaybackWindow")
            target.session = session
            window = target
        }
        target.title = channel.name
        // The next episode updates the view in place: a new one would rebuild the player view, a flash between episodes.
        let root = DesktopPlaybackRoot(channel: channel, session: session, window: target, store: store)
        if let host = target.contentView as? NSHostingView<DesktopPlaybackRoot> { host.rootView = root }
        else { target.contentView = NSHostingView(rootView: root) }
        startCatalogPlayback(session, channel: channel, store: store)
        target.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        session.stop()
        window?.contentView = nil
        window = nil
        let callback = onClose
        onClose = nil
        callback?()
    }
}

@MainActor final class PlaybackWindow: NSWindow {
    weak var session: PlaybackSession?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Preserve system commands and text/slider editing inside native controls.
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              !(firstResponder is NSTextView), !(firstResponder is NSSlider) else { return super.performKeyEquivalent(with: event) }
        switch event.keyCode {
        case 49: session?.togglePlayback()
        case 123: session?.skip(event.modifierFlags.contains(.shift) ? -60 : -10)
        case 124: session?.skip(event.modifierFlags.contains(.shift) ? 60 : 10)
        case 126: if let player = session?.player { player.volume = min(1, player.volume + 0.05) }
        case 125: if let player = session?.player { player.volume = max(0, player.volume - 0.05) }
        case 53:
            if styleMask.contains(.fullScreen) { toggleFullScreen(nil) }
            else { return super.performKeyEquivalent(with: event) }
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "f": toggleFullScreen(nil)
            case "m": session?.player.isMuted.toggle()
            default: return super.performKeyEquivalent(with: event)
            }
        }
        return true
    }
}

/// Auto-hiding chrome driven by real pointer movement and key presses (not hover
/// phases, which AVPlayerView's own overlay and layout passes keep re-firing).
@MainActor @Observable private final class ChromeIdle {
    var visible = true
    private var task: Task<Void, Never>?
    private var monitor: Any?
    private weak var window: NSWindow?

    func attach(_ window: NSWindow) {
        detach()
        self.window = window
        window.acceptsMouseMovedEvents = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .scrollWheel, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self.window else { return }
                // Ignore synthetic mouse events that carry no movement.
                if event.type == .mouseMoved, abs(event.deltaX) + abs(event.deltaY) < 1 { return }
                self.poke()
            }
            return event
        }
        poke()
    }

    func detach() {
        task?.cancel(); task = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    func poke() {
        if !visible { withAnimation(.smooth(duration: 0.25)) { visible = true } }
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, let self else { return }
            withAnimation(.smooth(duration: 0.4)) { self.visible = false }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }
}

private struct DesktopPlaybackRoot: View {
    let channel: Channel
    let session: PlaybackSession
    let window: PlaybackWindow
    let store: Store
    var body: some View { DesktopPlaybackView(channel: channel, session: session, window: window).environment(store) }
}

private struct DesktopPlaybackView: View {
    @Environment(Store.self) private var store
    let channel: Channel
    @Bindable var session: PlaybackSession
    let window: PlaybackWindow
    @State private var fillsFrame = false
    @State private var floats = false
    @State private var idle = ChromeIdle()
    @AppStorage(DanmakuPreference.key) private var showsDanmaku = true
    @AppStorage(DanmakuArea.key) private var danmakuArea = DanmakuArea.standard
    @State private var showsDanmakuList = false
    @State private var showsEpisodes = false
    @AppStorage(VideoEnhancement.upscaleKey) private var upscalesVideo = false
    @AppStorage(VideoEnhancement.smoothKey) private var smoothsVideo = false
    @AppStorage(PlaybackInfo.key) private var showsPlaybackInfo = false
    /// Devices with Yingxia open, for the Play On button; and the one the video was sent to.
    @State private var tvBrowser = PlayOnBrowser()
    @State private var playingOn: String?
    @State private var importsSubtitleFile = false
    @State private var asksSubtitleAddress = false
    @State private var searchesSubtitles = false

    private var showsChrome: Bool { idle.visible || session.error != nil }
    private var waitContent: PlaybackWaitContent? { .make(session, channel: channel, store: store, linesHint: true) }

    var body: some View {
        ZStack(alignment: .top) {
            ZStack {
                Color.black
                let bare = session.isLive || !session.hasTimeline
                // A new player view whenever the controls come or go (see DesktopNativePlayer).
                DesktopNativePlayer(player: session.player, fillsFrame: fillsFrame, live: bare, waiting: waitContent, enhancer: session.enhancer,
                                    subtitles: session.subtitles)
                    .id(bare)
                if showsDanmaku && !session.danmaku.isEmpty { DanmakuOverlay(player: session.player, comments: session.danmaku, opacity: session.danmakuOpacity, revision: session.danmakuRevision).ignoresSafeArea() }
                SubtitleOverlay(cues: session.subtitles, fills: fillsFrame).ignoresSafeArea()
                // Under the title bar's buttons, so it stays put while they come and go.
                if showsPlaybackInfo && session.error == nil && session.showsPicture && playingOn == nil {
                    PlaybackInfoPanel(session: session)
                        .padding(.leading, 16).padding(.top, 56)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .transition(.opacity)
                }
                if let error = session.error {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                        Text(error).multilineTextAlignment(.center).textSelection(.enabled)
                        Button(L10n.text("Retry")) { startCatalogPlayback(session, channel: channel, store: store) }.buttonStyle(.borderedProminent)
                    }
                    .padding(24).frame(maxWidth: 440)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18)).padding()
                }
                if let playingOn {
                    Color.black
                    PlayOnPlaceholder(receiver: playingOn) {
                        self.playingOn = nil
                        if session.paused { session.togglePlayback() }
                    }
                }
            }
            topBar
                .opacity(showsChrome ? 1 : 0)
                .allowsHitTesting(showsChrome)
        }
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
        .onChange(of: showsDanmaku) { _, value in session.catalogDanmaku.enabled = value }
        .onChange(of: session.catalogDanmaku.enabled) { _, value in showsDanmaku = value }
        .onChange(of: floats) { _, value in window.level = value ? .floating : .normal }
        .onChange(of: showsChrome) { _, value in setTrafficLights(visible: value) }
        .onAppear { floats = window.level == .floating; idle.attach(window); tvBrowser.start() }
        // Played here again (Space, say): the other device no longer has it to itself.
        .onChange(of: session.paused) { _, paused in if !paused { playingOn = nil } }
        .playerEpisodesSheet(isPresented: $showsEpisodes, channel: channel)
        .sheet(isPresented: $showsDanmakuList) {
            DanmakuListView(player: session.player, comments: session.danmaku) { showsDanmakuList = false }
                .danmakuListPresentation()
        }
        .onDisappear { idle.detach(); tvBrowser.stop() }
        .subtitleImport(files: $importsSubtitleFile, address: $asksSubtitleAddress, search: $searchesSubtitles, subtitles: session.externalSubtitles)
        // A subtitle file dropped on the video shows on it (#576).
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(ExternalSubtitles.handles)
            files.forEach { session.externalSubtitles.add(file: $0) }
            return !files.isEmpty
        }
    }

    /// Title on the left (beside the traffic lights), actions on the right, over a soft scrim.
    private var topBar: some View {
        HStack(spacing: 10) {
            Text(channel.name).font(.headline).lineLimit(1)
                .shadow(color: .black.opacity(0.6), radius: 4)
                .padding(.leading, 86)
            Spacer(minLength: 12)
            GlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    if session.isLive || !session.hasTimeline {
                        // AVKit's controls are hidden without a timeline (see DesktopNativePlayer), so play and mute live here.
                        barButton(session.paused ? "play.fill" : "pause.fill", L10n.text("Play / Pause (Space)")) { session.togglePlayback() }
                        barButton(session.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", L10n.text("Mute (M)")) { session.player.isMuted.toggle() }
                    } else {
                        barButton("gobackward.10", L10n.text("Back 10 seconds (←)")) { session.skip(-10) }
                        barButton("goforward.10", L10n.text("Forward 10 seconds (→)")) { session.skip(10) }
                    }
                    if let previous = store.step(back: true, from: channel, session: session) {
                        barButton("backward.end.fill", L10n.text("Previous Episode"), help: previous.name) { previous.go() }
                            .disabled(previous.busy)
                    }
                    if let next = store.step(back: false, from: channel, session: session) {
                        barButton("forward.end.fill", L10n.text("Next Episode"), help: next.name) { next.go() }
                            .disabled(next.busy)
                    }
                    PlayerEpisodesButton(channel: channel, isPresented: $showsEpisodes) {
                        Image(systemName: PlayerEpisodesSheet.symbol).font(.system(size: 14, weight: .medium))
                            .frame(width: 34, height: 34)
                            .glassSurface(.regular.interactive(), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    if !tvBrowser.receivers.isEmpty {
                        PlayOnButton(channel: channel, session: session, browser: tvBrowser) { receiver in
                            session.player.pause()
                            playingOn = receiver
                        }
                    }
                    CatalogPlaybackActions(channel: channel, session: session)
                    optionsMenu
                    barButton("arrow.up.left.and.arrow.down.right", L10n.text("Enter / Exit Full Screen")) { window.toggleFullScreen(nil) }
                }
            }
        }
        .padding(.top, 10).padding(.trailing, 16).padding(.bottom, 36)
        .background(alignment: .top) {
            LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        }
    }

    private func barButton(_ symbol: String, _ label: String, help: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 14, weight: .medium)) }
            .buttonStyle(.plain)
            .frame(width: 34, height: 34)
            .glassSurface(.regular.interactive(), in: Circle())
            .help(help ?? label)
            .accessibilityLabel(label)
    }

    private var optionsMenu: some View {
        Menu {
            Toggle(L10n.text("Loop Playback"), isOn: $session.looping)
            Toggle(L10n.text("Fill Window"), isOn: $fillsFrame)
            Toggle(L10n.text("Float on Top"), isOn: $floats)
            Toggle(L10n.text("Show Video Info"), isOn: $showsPlaybackInfo)
            if VideoEnhancement.canUpscale { Toggle(L10n.text("Sharper Picture"), isOn: $upscalesVideo) }
            if VideoEnhancement.canSmooth { Toggle(L10n.text("Smooth Motion (60 fps)"), isOn: $smoothsVideo) }
            if session.qualities.count > 1 {
                Menu(L10n.text("Quality")) { QualityPicker(session: session) }
            }
            Menu(L10n.text("Subtitle Files")) {
                MacSubtitleFiles(subtitles: session.externalSubtitles, addFile: { importsSubtitleFile = true }, addAddress: { asksSubtitleAddress = true },
                                 searchOnline: { searchesSubtitles = true })
            }
            if !session.danmaku.isEmpty {
                Toggle(L10n.text("Show Danmaku"), isOn: $showsDanmaku)
                Picker(L10n.text("Danmaku Area"), selection: $danmakuArea) {
                    ForEach(DanmakuArea.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                DanmakuStylePickers(model: session.catalogDanmaku)
                Button(L10n.text("Danmaku List…")) { showsDanmakuList = true }
            }
            Divider()
            Button(L10n.text("Enter / Exit Full Screen")) { window.toggleFullScreen(nil) }
            Button(L10n.text("Retry")) { startCatalogPlayback(session, channel: channel, store: store) }
            Divider()
            Text(L10n.text("Space: Play / Pause"))
            Text(L10n.text("← / →: Seek 10s · Shift: 60s"))
            Text(L10n.text("↑ / ↓: Volume · M: Mute · F: Full Screen"))
        } label: {
            Image(systemName: "slider.horizontal.3").font(.system(size: 14, weight: .medium))
                .frame(width: 34, height: 34).contentShape(Circle())
        }
            // A borderless menu drew its icon at the leading edge of the circle; a plain one keeps it centred.
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .fixedSize()
            .glassSurface(.regular.interactive(), in: Circle())
            .help(L10n.text("Playback Options"))
            .accessibilityLabel(L10n.text("Playback Options"))
    }

    private func setTrafficLights(visible: Bool) {
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.animator().alphaValue = visible ? 1 : 0
        }
    }
}

/// The Mac's subtitle-file menu: AVKit's own menu has the item's subtitles, so this one has Off and the files.
private struct MacSubtitleFiles: View {
    let subtitles: ExternalSubtitles
    let addFile: () -> Void
    let addAddress: () -> Void
    let searchOnline: () -> Void
    var body: some View {
        if subtitles.selected != nil { Button(L10n.text("Off")) { subtitles.select(nil) } }
        ExternalSubtitleMenu(subtitles: subtitles, addFile: addFile, addAddress: addAddress, searchOnline: searchOnline)
    }
}

/// AVPlayerView without its controls for live streams. Its floating controls build a scrubber from the
/// item's duration and seekable range; a live item has an indefinite duration and, at first, no
/// seekable range, and AVKit traps on that range (macOS 27). An IPTV channel is a plain address, so it
/// is only known to be live once its item is ready: the controls wait for a ready item with a finite
/// duration. tvOS avoids it with linear playback.
/// `live` is fixed for a view's life: set to `.none` on a view that has shown its floating controls,
/// AVKit takes the buttons away but leaves their empty glass platter, which still fades in under the
/// mouse (macOS 27). A view made without controls has no platter.
private struct DesktopNativePlayer: NSViewRepresentable {
    let player: AVPlayer
    let fillsFrame: Bool
    var live = false
    var waiting: PlaybackWaitContent? = nil
    var enhancer: VideoEnhancer? = nil
    var subtitles: SubtitleCues? = nil
    @MainActor final class Coordinator: NSObject, @preconcurrency AVPlayerViewPictureInPictureDelegate {
        var host: PassthroughHostingView<AnyView>?
        var subtitles: SubtitleCues?
        // Picture in Picture shows only the player's own picture, so AVPlayer draws the subtitles there.
        func playerViewWillStartPicture(inPicture playerView: AVPlayerView) { subtitles?.native = true }
        func playerViewDidStopPicture(inPicture playerView: AVPlayerView) { subtitles?.native = false }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        // The wait lives in the content overlay, under the floating controls, and lets the mouse through to them.
        // It follows the overlay's frame and sets no size of its own: with NSHostingView's default sizing
        // constraints, its SwiftUI content's size pushed back through the overlay and the whole player was laid
        // out at that size (16 × 130 pt once loading ended, the video a 16 × 9 box).
        if let container = view.contentOverlayView {
            let host = PassthroughHostingView(rootView: overlay)
            host.sizingOptions = []
            host.frame = container.bounds
            host.autoresizingMask = [.width, .height]
            container.addSubview(host)
            context.coordinator.host = host
        }
        view.controlsStyle = live ? .none : .floating
        view.player = player
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        context.coordinator.subtitles = subtitles
        view.pictureInPictureDelegate = context.coordinator
        view.showsSharingServiceButton = false
        view.speeds = [0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4].map { AVPlaybackSpeed(rate: Float($0), localizedName: "\($0)×") }
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
        view.videoGravity = fillsFrame ? .resizeAspectFill : .resizeAspect
        context.coordinator.host?.rootView = overlay
    }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) { view.player = nil }
    private var overlay: AnyView {
        AnyView(ZStack {
            if let enhancer { EnhancedVideoSurface(enhancer: enhancer, fills: fillsFrame) }
            if let waiting { waiting.view.transition(.opacity) }
        }.animation(.easeInOut(duration: 0.7), value: waiting == nil))
    }
}

/// A hosting view that draws but never takes the mouse, so AVPlayerView's controls above it keep working.
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#endif

#if !os(tvOS)
/// Automatic, or one of the stream's qualities, best first.
struct QualityPicker: View {
    let session: PlaybackSession
    var body: some View {
        Picker(L10n.text("Quality"), selection: Binding(get: { session.quality ?? 0 }, set: { session.choose(quality: $0 == 0 ? nil : $0) })) {
            Text(L10n.text("Auto")).tag(0)
            ForEach(session.qualities) { Text($0.label).tag($0.id) }
        }
        .pickerStyle(.inline)
    }
}
#endif

/// What the player's Previous and Next buttons do: an episode of the video playing, or the file
/// beside the playing one in its Cloud Files folder. Next plays from the queue once it waits there.
struct PlayerStep {
    let name: String
    let busy: Bool
    let go: @MainActor () -> Void
}

extension Store {
    func step(back: Bool, from channel: Channel, session: PlaybackSession) -> PlayerStep? {
        if let episode = back ? previousEpisode(before: channel) : nextEpisode(after: channel) {
            return PlayerStep(name: episode.name, busy: resolvingEpisode != nil) { [weak self] in
                if back || !session.playUpcoming() { self?.selectEpisode(episode, from: channel) }
            }
        }
        if let file = back ? previousFile(before: channel) : nextFile(after: channel) {
            return PlayerStep(name: file.name, busy: false) { [weak self] in
                if back || !session.playUpcoming() { self?.playing = file }
            }
        }
        return nil
    }
}

/// Shared setup leaves the native AVKit controls and Bilibili resolution intact.
@MainActor private func startCatalogPlayback(_ session: PlaybackSession, channel: Channel, store: Store) {
    session.history = store.playbackHistory
    session.skipDefaults = store.playbackDefaults
    session.catalogDanmaku.enabled = UserDefaults.standard.object(forKey: DanmakuPreference.key) == nil
        || UserDefaults.standard.bool(forKey: DanmakuPreference.key)
    session.start(channel)
    session.onPlaybackEnded = { [weak store] in
        guard let store, store.autoPlayNext else { return }
        if let file = store.nextFile(after: channel) { store.playing = file }
        else if let next = store.nextEpisode(after: channel) { store.selectEpisode(next, from: channel) }
    }
    // Near the end the next episode is resolved and queued, so it plays on without stopping to load.
    session.playsOn = { [weak store] in store?.autoPlayNext == true }
    session.upcomingEpisode = { [weak store] in await store?.upcomingEpisode(after: channel) }
    session.onAdvance = { [weak store] next in store?.advance(to: next, from: channel) }
    session.onUnplayableFile = { [weak store, weak session] in
        guard let store, let other = store.transcodedLine(for: channel) else { return nil }
        store.selectEpisode(other, from: channel) { session?.lineSwitchFailed($0) }
        return other.flag
    }
    if let context = channel.historyContext, let next = store.nextEpisode(after: channel),
       let catalog = store.catalog(for: channel), context.sourceKey != Bilibili.siteKey {
        session.catalogDanmaku.prefetch(PlaybackHistoryContext(origin: context.origin, site: catalog.client.site,
            video: catalog.video, episode: next))
    }
}

/// The info panel in a corner of the picture (Settings → Show Video Info, off by default): the video and audio
/// format, the picture's size and frame rate, and the stream's bitrate beside what arrives. It exists only while
/// the switch is on, and reads the playing item once a second, as the session's own sampling does.
struct PlaybackInfoPanel: View {
    let session: PlaybackSession
    @State private var info = PlaybackInfo()
    @State private var sampler = PlaybackInfoSampler()

    private struct Row: Identifiable { let id: String; let text: String }

    var body: some View {
        let rows = [Row(id: "film", text: info.video ?? ""), Row(id: "waveform", text: info.audio ?? ""),
                    Row(id: "speedometer", text: info.network() ?? "")].filter { !$0.text.isEmpty }
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            ForEach(rows) { row in
                HStack(spacing: Metrics.spacing * 2.5) {
                    Image(systemName: row.id).foregroundStyle(.white.opacity(0.55)).frame(width: Metrics.icon)
                    Text(row.text).lineLimit(1)
                }
            }
        }
        .font(.system(size: Metrics.font, weight: .medium)).monospacedDigit()
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, Metrics.padding * 1.3).padding(.vertical, Metrics.padding)
        // A plain tint, not a material: it sits over moving video, where a blur would redraw every frame.
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1) }
        .opacity(rows.isEmpty ? 0 : 1)
        .animation(.smooth(duration: 0.25), value: rows.map(\.id))
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("player.info")
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func refresh() async {
        guard let next = await sampler.sample(session) else { return }
        if next != info { info = next }
    }

    private enum Metrics {
        #if os(tvOS)
        static let font: CGFloat = 21, spacing: CGFloat = 6, padding: CGFloat = 14, corner: CGFloat = 18, icon: CGFloat = 28
        #else
        static let font: CGFloat = 11.5, spacing: CGFloat = 3, padding: CGFloat = 8, corner: CGFloat = 10, icon: CGFloat = 15
        #endif
    }
}

/// Reads what `PlaybackInfo` holds from the playing item: the info panel and the tags over the seek bar each keep one
/// and ask it once a second while they show.
@MainActor final class PlaybackInfoSampler {
    private let formats = PlaybackFormats()

    /// Nil while the item changes under the read; an empty info without an item.
    func sample(_ session: PlaybackSession) async -> PlaybackInfo? {
        guard let item = session.player.currentItem else { return PlaybackInfo() }
        let tracks = item.tracks.filter(\.isEnabled)
        let video = tracks.first { $0.assetTrack?.mediaType == .video }
        let audio = tracks.first { $0.assetTrack?.mediaType == .audio }
        let picture = await formats.describe(video?.assetTrack)
        let sound = await formats.describe(audio?.assetTrack)
        guard !Task.isCancelled, session.player.currentItem === item else { return nil }
        var next = PlaybackInfo()
        let size = item.presentationSize
        next.width = Int(size.width.rounded()); next.height = Int(size.height.rounded())
        if next.width == 0 || next.height == 0 { next.width = picture?.width ?? 0; next.height = picture?.height ?? 0 }
        next.videoCodec = picture?.codec
        next.transferFunction = picture?.transferFunction
        next.hardwareDecoding = picture?.codec.map(Self.decodesInHardware)
        next.dolbyVisionProfile = picture?.dolbyVisionProfile
        if let asset = item.asset as? AVURLAsset { next.droppedDolbyVisionProfile = Remux.droppedDolbyVision(asset.url) }
        // The track's own rate; the measured one (a stream that declares none) wanders around it. A streamed MP4 can
        // declare about 1 fps (a 4K drama showed "1FPS"): no video plays that slowly, so then the measured one.
        let measured = Double(video?.currentVideoFrameRate ?? 0)
        let declaredRate = picture?.frameRate.flatMap { $0 >= 5 ? $0 : nil }
        next.frameRate = declaredRate ?? (measured > 0 ? measured : nil)
        // Smooth Motion's in-between frames reach the screen at its grid's rate (#519).
        let enhancement = session.enhancer.status
        if enhancement.smoothing {
            let source = enhancement.sourceRate > 0 ? enhancement.sourceRate : next.frameRate ?? 0
            next.smoothedFrameRate = VideoEnhancer.outputRate(source: source, matching: false)
        }
        next.audioCodec = sound?.codec
        next.sampleRate = sound?.sampleRate
        next.channels = sound?.channels
        // The session's measured rate (the variant's, or the decoded media's), else what the file's tracks declare.
        let declared = (picture?.dataRate ?? 0) + (sound?.dataRate ?? 0)
        next.bitrate = session.transfer.required.map { $0 * 8 } ?? (declared > 0 ? declared : nil)
        next.download = session.transfer.bytesPerSecond
        return next
    }

    private static var hardware: [UInt32: Bool] = [:]

    /// Whether VideoToolbox has a hardware decoder for the format here: HEVC and H.264 on every device, AV1 from the
    /// A17 Pro and M3 on. Dolby Vision asks for its base layer's codec.
    static func decodesInHardware(_ code: UInt32) -> Bool {
        if let known = hardware[code] { return known }
        let base: CMVideoCodecType = switch code {
        case 0x6476_6831, 0x6476_6865, 0x6865_7631: kCMVideoCodecType_HEVC   // dvh1, dvhe, hev1
        case 0x6476_6131, 0x6476_6176, 0x6176_6333: kCMVideoCodecType_H264   // dva1, dvav, avc3
        case 0x6461_7631: 0x6176_3031                                        // dav1: AV1 (av01)
        default: code
        }
        let supported = VTIsHardwareDecodeSupported(base)
        hardware[code] = supported
        return supported
    }
}

/// The formats of the tracks playing, loaded once per track: a stream's tracks change only when its variant does.
@MainActor private final class PlaybackFormats {
    struct Format {
        var codec: UInt32?
        var transferFunction: String?
        /// From the sample description's dvcC/dvvC/dvwC box: profile 8 rides on an hvc1 entry.
        var dolbyVisionProfile: Int?
        var width = 0, height = 0
        var frameRate: Double?
        var sampleRate: Double?
        var channels: Int?
        /// Bits per second the track declares.
        var dataRate: Double?
    }
    private var known: [(track: AVAssetTrack, format: Format)] = []

    func describe(_ track: AVAssetTrack?) async -> Format? {
        guard let track else { return nil }
        if let hit = known.first(where: { $0.track === track }) { return hit.format }
        guard let (descriptions, frameRate, dataRate) = try? await track.load(.formatDescriptions, .nominalFrameRate, .estimatedDataRate) else { return nil }
        var format = Format()
        if let description = descriptions.first {
            format.codec = CMFormatDescriptionGetMediaSubType(description)
            format.transferFunction = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
            if let atoms = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any] {
                let box = ["dvcC", "dvvC", "dvwC"].lazy.compactMap { atoms[$0] }.first
                let config = box as? Data ?? (box as? [Data])?.first
                format.dolbyVisionProfile = config.flatMap(PlaybackInfo.dolbyVisionProfile(config:))
            }
            if CMFormatDescriptionGetMediaType(description) == kCMMediaType_Video {
                let dimensions = CMVideoFormatDescriptionGetDimensions(description)
                format.width = Int(dimensions.width); format.height = Int(dimensions.height)
            }
            if let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                format.sampleRate = stream.mSampleRate > 0 ? stream.mSampleRate : nil
                format.channels = stream.mChannelsPerFrame > 0 ? Int(stream.mChannelsPerFrame) : nil
            }
        }
        format.frameRate = frameRate > 0 ? Double(frameRate) : nil
        format.dataRate = dataRate > 0 ? Double(dataRate) : nil
        // The video and audio tracks playing now, and the ones before a variant switch.
        known = Array(([(track, format)] + known).prefix(4))
        return format
    }
}

import SwiftUI
import AVKit
import TVCore

struct PlaybackView: View {
    let channel: Channel
    @Environment(\.dismiss) private var dismiss
    @Environment(Store.self) private var store
    @State private var session = PlaybackSession()
    @State private var showsChrome = true
    @State private var hideTask: Task<Void, Never>?
    @AppStorage(DanmakuPreference.key) private var showsDanmaku = true
    @State private var showsDanmakuList = false
    @AppStorage(VideoEnhancement.upscaleKey) private var upscalesVideo = false
    @AppStorage(VideoEnhancement.smoothKey) private var smoothsVideo = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    private var chromeVisible: Bool { showsChrome || session.error != nil || session.loading }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            #if os(tvOS)
            // Remove the native focus environment while recovery controls are shown.
            if session.error == nil {
                NativePlayerView(player: session.player, comments: session.danmaku, showsDanmaku: $showsDanmaku, opacity: session.danmakuOpacity, revision: session.danmakuRevision,
                                 qualities: session.qualities, quality: session.quality, choose: { session.choose(quality: $0) },
                                 live: session.isLive, previous: episodeAction(store.step(back: true, from: channel, session: session)),
                                 next: episodeAction(store.step(back: false, from: channel, session: session)), waiting: waitContent,
                                 enhancer: session.enhancer, upscale: $upscalesVideo, smooth: $smoothsVideo).ignoresSafeArea()
            }
            // Until the picture starts, AVKit's player keeps the Back press to itself, so a stream that never
            // loads (a dead live channel) left no way out but quitting the app. This takes focus and closes instead.
            if session.error == nil && !session.showsPicture {
                Color.clear.loadingFocus(takeFocus: true) { dismiss() }
                    .accessibilityIdentifier("player.waiting")
            }
            #elseif os(iOS)
            MobilePlayerView(channel: channel, session: session, showsDanmaku: $showsDanmaku, upscalesVideo: $upscalesVideo, smoothsVideo: $smoothsVideo,
                             waiting: waitContent, chromeVisible: chromeVisible, toggleChrome: toggleChrome, poke: poke, hold: holdChrome,
                             close: { dismiss() })
            #else
            NativePlayerView(player: session.player, comments: session.danmaku, showsDanmaku: $showsDanmaku, opacity: session.danmakuOpacity, revision: session.danmakuRevision).ignoresSafeArea()
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
        .preferredColorScheme(.dark)
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
        .onAppear { startCatalogPlayback(session, channel: channel, store: store); poke() }
        .onChange(of: channel) { _, channel in startCatalogPlayback(session, channel: channel, store: store); poke() }
        .onChange(of: showsDanmaku) { _, value in session.catalogDanmaku.enabled = value }
        .onChange(of: session.catalogDanmaku.enabled) { _, value in showsDanmaku = value }
        .onDisappear {
            hideTask?.cancel(); store.cancelEpisodeSelection(); session.stop()
            #if os(iOS)
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
        if let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen {
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
            // One button for danmaku: show or hide them, or open the list.
            if !session.danmaku.isEmpty {
                Menu {
                    Toggle(isOn: $showsDanmaku) { Label(L10n.text("Show Danmaku"), systemImage: "text.bubble") }
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
        showsChrome = true
        scheduleHide()
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
    /// A tap on the picture shows the controls, or hides them at once.
    private func toggleChrome() {
        #if DEBUG
        // UI tests tap the picture to reach the controls, which `-qaPlayerControls` keeps up.
        if UserDefaults.standard.bool(forKey: "qaPlayerControls") { return poke() }
        #endif
        guard showsChrome else { return poke() }
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
    #endif

    @ViewBuilder private var status: some View {
        if let error = session.error {
            #if os(tvOS)
            TVPlaybackFailureView(channelName: channel.name, details: error, symbol: session.errorSymbol, backdrop: waitContent,
                                  retry: { startCatalogPlayback(session, channel: channel, store: store) }, goBack: { dismiss() })
            #elseif os(iOS)
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
                        Button { dismiss() } label: { Label(L10n.text("Close"), systemImage: "xmark") }.controlButton()
                    }
                }
                .controlSize(.large).padding(.top, 30)
            }
            .foregroundStyle(.white)
            .padding(32)
            .environment(\.colorScheme, .dark)
            #else
            VStack(spacing: 18) {
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(Brand.amber)
                Text(error).multilineTextAlignment(.center).frame(maxWidth: 420)
                GlassGroup(spacing: 10) {
                    HStack(spacing: 10) {
                        Button(L10n.text("Retry")) { startCatalogPlayback(session, channel: channel, store: store) }.controlButton(prominent: true).tint(Brand.accent)
                        Button(L10n.text("Close")) { dismiss() }.controlButton()
                    }
                }.controlSize(.large)
            }
            .padding(30).glassPanel(cornerRadius: 30).padding(30)
            #endif
        } else if session.loading || session.buffering {
            #if os(macOS)
            // Top of the frame, clear of the transport bar. Seeks stall briefly; only longer waits show.
            LoadingCard(appearAfter: session.loading ? 0 : 1.5) { session.loadingProgress }
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
                    .symbolEffect(.breathe, options: .repeat(.periodic(delay: 2.5)))
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
                HStack(spacing: 20) {
                    Button(action: retry) { Label(L10n.text("Try Again"), systemImage: "arrow.clockwise") }.focused($retryFocused)
                    Button(action: goBack) { Label(L10n.text("Go back"), systemImage: "chevron.backward") }
                    Button { showsDetails.toggle() } label: { Label(L10n.text(showsDetails ? "Hide details" : "Show details"), systemImage: "info.circle") }
                }
                .buttonStyle(TVPlaybackRecoveryStyle())
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

private struct TVPlaybackRecoveryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { RecoveryButton(configuration: configuration) }
    private struct RecoveryButton: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var focused
        var body: some View {
            configuration.label
                .font(.system(size: 26, weight: .semibold))
                .padding(.horizontal, 32).padding(.vertical, 20)
                .frame(minWidth: 220)
                .foregroundStyle(focused ? Color.black : Color.white)
                .background(focused ? Color.white : TVStyle.raised, in: Capsule())
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.12), value: focused)
        }
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
    var body: some View {
        ZStack {
            PlayerSurface(player: player)
            if showsDanmaku && !comments.isEmpty { DanmakuOverlay(player: player, comments: comments, opacity: opacity, revision: revision) }
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

    static func set(landscape: Bool) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        mask = landscape ? .landscape : .allButUpsideDown
        var controller = scene.keyWindow?.rootViewController
        while let next = controller?.presentedViewController { controller = next }
        controller?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscape : .portrait)) { error in
            Diagnostics.shared.record(.warning, "player", "Rotation refused: \(error.localizedDescription)")
        }
    }

    /// Back to portrait when the player closes, if the button turned it.
    static func release() {
        if mask == .landscape { set(landscape: false) }
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
    var qualities: [StreamQuality] = []
    var quality: Int? = nil
    var choose: @MainActor (Int?) -> Void = { _ in }
    var live = false
    /// The neighbouring episodes of a catalog video, as transport-bar buttons beside the menus.
    var previous: EpisodeAction? = nil
    var next: EpisodeAction? = nil
    var waiting: PlaybackWaitContent? = nil
    var enhancer: VideoEnhancer? = nil
    var upscale: Binding<Bool> = .constant(false)
    var smooth: Binding<Bool> = .constant(false)
    final class Coordinator { var host: UIHostingController<AnyView>?; var listed = ""; var criteria: DisplayCriteriaKeeper? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = TitleSafePlayerController()
        // Decided before the controller is presented: AVKit refuses the change during playback.
        if VideoEnhancement.canSmooth, let enhancer { context.coordinator.criteria = DisplayCriteriaKeeper(controller: controller, player: player, enhancer: enhancer) }
        controller.player = player
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
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
        // Live has no timeline worth scrubbing: keep it at the live edge.
        if controller.requiresLinearPlayback != live { controller.requiresLinearPlayback = live }
        context.coordinator.host?.rootView = overlay
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
            items.append(UIAction(title: L10n.text("Danmaku"), image: UIImage(systemName: showsDanmaku ? "text.bubble.fill" : "text.bubble"),
                                  state: showsDanmaku ? .on : .off) { _ in binding.wrappedValue.toggle() })
        }
        if qualities.count > 1 {
            let choose = choose
            let current = qualities.first { $0.id == quality }?.label ?? L10n.text("Auto")
            let options = [UIAction(title: L10n.text("Auto"), state: quality == nil ? .on : .off) { _ in choose(nil) }]
                + qualities.map { option in UIAction(title: option.label, state: quality == option.id ? .on : .off) { _ in choose(option.id) } }
            items.append(UIMenu(title: L10n.text("Quality") + " · " + current, image: UIImage(systemName: "sparkles.tv"), children: options))
        }
        if let previous {
            items.insert(UIAction(title: L10n.text("Previous Episode"), subtitle: previous.name, image: UIImage(systemName: "backward.end.fill"),
                                  attributes: previous.busy ? [.disabled] : []) { _ in previous.play() }, at: 0)
        }
        if let next {
            items.insert(UIAction(title: L10n.text("Next Episode"), subtitle: next.name, image: UIImage(systemName: "forward.end.fill"),
                                  attributes: next.busy ? [.disabled] : []) { _ in next.play() }, at: previous == nil ? 0 : 1)
        }
        if VideoEnhancement.canUpscale || VideoEnhancement.canSmooth {
            let upscale = upscale, smooth = smooth
            var options: [UIMenuElement] = []
            if VideoEnhancement.canUpscale {
                options.append(UIAction(title: L10n.text("Sharper Picture"), state: upscale.wrappedValue ? .on : .off) { _ in upscale.wrappedValue.toggle() })
            }
            if VideoEnhancement.canSmooth {
                options.append(UIAction(title: L10n.text("Smooth Motion (60 fps)"), state: smooth.wrappedValue ? .on : .off) { _ in smooth.wrappedValue.toggle() })
            }
            items.append(UIMenu(title: L10n.text("Picture"), image: UIImage(systemName: "wand.and.sparkles"), children: options))
        }
        controller.transportBarCustomMenuItems = items
    }
    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) { coordinator.criteria?.reset() }
    private var overlay: AnyView {
        AnyView(ZStack {
            if let enhancer { EnhancedVideoSurface(enhancer: enhancer) }
            if showsDanmaku && !comments.isEmpty { DanmakuOverlay(player: player, comments: comments, opacity: opacity, revision: revision) }
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
    @State private var showsDanmakuList = false
    @AppStorage(VideoEnhancement.upscaleKey) private var upscalesVideo = false
    @AppStorage(VideoEnhancement.smoothKey) private var smoothsVideo = false

    private var showsChrome: Bool { idle.visible || session.error != nil }
    private var waitContent: PlaybackWaitContent? { .make(session, channel: channel, store: store, linesHint: true) }

    var body: some View {
        ZStack(alignment: .top) {
            ZStack {
                Color.black
                let bare = session.isLive || !session.hasTimeline
                // A new player view whenever the controls come or go (see DesktopNativePlayer).
                DesktopNativePlayer(player: session.player, fillsFrame: fillsFrame, live: bare, waiting: waitContent, enhancer: session.enhancer)
                    .id(bare)
                if showsDanmaku && !session.danmaku.isEmpty { DanmakuOverlay(player: session.player, comments: session.danmaku, opacity: session.danmakuOpacity, revision: session.danmakuRevision) }
                if let error = session.error {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                        Text(error).multilineTextAlignment(.center).textSelection(.enabled)
                        Button(L10n.text("Retry")) { startCatalogPlayback(session, channel: channel, store: store) }.buttonStyle(.borderedProminent)
                    }
                    .padding(24).frame(maxWidth: 440)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18)).padding()
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
        .onAppear { floats = window.level == .floating; idle.attach(window) }
        .sheet(isPresented: $showsDanmakuList) {
            DanmakuListView(player: session.player, comments: session.danmaku) { showsDanmakuList = false }
                .danmakuListPresentation()
        }
        .onDisappear { idle.detach() }
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
            if VideoEnhancement.canUpscale { Toggle(L10n.text("Sharper Picture"), isOn: $upscalesVideo) }
            if VideoEnhancement.canSmooth { Toggle(L10n.text("Smooth Motion (60 fps)"), isOn: $smoothsVideo) }
            if session.qualities.count > 1 {
                Menu(L10n.text("Quality")) { QualityPicker(session: session) }
            }
            if !session.danmaku.isEmpty {
                Toggle(L10n.text("Show Danmaku"), isOn: $showsDanmaku)
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
    final class Coordinator { var host: PassthroughHostingView<AnyView>? }
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
        view.showsSharingServiceButton = false
        view.speeds = [0.5, 0.75, 1, 1.25, 1.5, 2].map { AVPlaybackSpeed(rate: Float($0), localizedName: "\($0)×") }
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

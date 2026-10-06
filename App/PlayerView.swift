import SwiftUI
import AVKit
import TVCore

struct PlaybackView: View {
    let channel: Channel
    @Environment(\.dismiss) private var dismiss
    @State private var session = PlaybackSession()
    @State private var showsChrome = true
    @State private var hideTask: Task<Void, Never>?

    private var chromeVisible: Bool { showsChrome || session.error != nil || session.loading }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            #if os(tvOS)
            // Remove the native focus environment while recovery controls are shown.
            if session.error == nil {
                NativePlayerView(player: session.player).ignoresSafeArea()
            }
            #else
            NativePlayerView(player: session.player).ignoresSafeArea()
            #endif
            #if !os(tvOS)
            chrome.opacity(chromeVisible ? 1 : 0).allowsHitTesting(chromeVisible)
            #endif
            status
        }
        .preferredColorScheme(.dark)
        #if os(macOS)
        .frame(minWidth: 880, minHeight: 540)
        #endif
        #if !os(tvOS)
        .onContinuousHover { _ in poke() }
        .simultaneousGesture(TapGesture().onEnded { poke() })
        #endif
        .onAppear { session.start(channel); poke() }
        .onDisappear { hideTask?.cancel(); session.stop() }
    }

    #if !os(tvOS)
    private var chrome: some View {
        VStack {
            HStack(spacing: 12) {
                Text(channel.name).font(.headline).lineLimit(1)
                    .padding(.horizontal, 18).padding(.vertical, 11)
                    .glassEffect(.regular, in: Capsule())
                Spacer(minLength: 0)
                Button { dismiss() } label: { Image(systemName: "xmark").font(.headline).frame(width: 22, height: 22) }
                    .controlButton().buttonBorderShape(.circle).controlSize(.large)
                    .accessibilityLabel(L10n.text("Close"))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Spacer()
        }
    }

    private func poke() {
        showsChrome = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            if !Task.isCancelled { withAnimation(.smooth(duration: 0.35)) { showsChrome = false } }
        }
    }
    #else
    private func poke() {}
    #endif

    @ViewBuilder private var status: some View {
        if let error = session.error {
            #if os(tvOS)
            TVPlaybackFailureView(channelName: channel.name, details: error,
                                  retry: { session.start(channel) }, goBack: { dismiss() })
            #else
            VStack(spacing: 18) {
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(Brand.amber)
                Text(error).multilineTextAlignment(.center).frame(maxWidth: 420)
                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        Button(L10n.text("Retry")) { session.start(channel) }.controlButton(prominent: true).tint(Brand.accent)
                        Button(L10n.text("Close")) { dismiss() }.controlButton()
                    }
                }.controlSize(.large)
            }
            .padding(30).glassPanel(cornerRadius: 30).padding(30)
            #endif
        } else if session.loading || session.buffering {
            // Top of the frame, clear of the transport bar. Seeks stall briefly; only longer waits show.
            LoadingCard(appearAfter: session.loading ? 0 : 1.5) { session.loadingProgress }
                .padding(.horizontal, 24).padding(.top, 48)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
        }
    }
}

#if os(tvOS)
private struct TVPlaybackFailureView: View {
    let channelName: String
    let details: String
    let retry: () -> Void
    let goBack: () -> Void
    @State private var showsDetails = false
    @FocusState private var retryFocused: Bool

    var body: some View {
        ZStack {
            TVStyle.background.ignoresSafeArea()
            VStack(spacing: 0) {
                Image(systemName: "video.slash")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(Color(white: 0.65))
                    .accessibilityHidden(true)
                    .padding(.bottom, 32)
                Text(L10n.text("Playback error"))
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
                    Button(L10n.text("Retry"), action: retry).focused($retryFocused)
                    Button(L10n.text("Go back"), action: goBack)
                    Button(L10n.text(showsDetails ? "Hide details" : "Show details")) { showsDetails.toggle() }
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
private struct NativePlayerView: NSViewRepresentable {
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
#else
private struct NativePlayerView: View {
    let player: AVPlayer
    var body: some View { VideoPlayer(player: player) }
}
#endif

#if os(macOS)
/// A real document-style window: playback remains independent of library navigation.
@MainActor final class PlayerWindowController: NSObject, NSWindowDelegate {
    private var window: PlaybackWindow?
    private let session = PlaybackSession()
    private var onClose: (() -> Void)?

    func present(_ channel: Channel, onClose: @escaping () -> Void) {
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
        target.contentView = NSHostingView(rootView: DesktopPlaybackView(channel: channel, session: session, window: target))
        session.start(channel)
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

private struct DesktopPlaybackView: View {
    let channel: Channel
    @Bindable var session: PlaybackSession
    let window: PlaybackWindow
    @State private var fillsFrame = false
    @State private var floats = false
    @State private var idle = ChromeIdle()

    private var showsChrome: Bool { idle.visible || session.error != nil }

    var body: some View {
        ZStack(alignment: .top) {
            ZStack {
                Color.black
                DesktopNativePlayer(player: session.player, fillsFrame: fillsFrame)
                if let error = session.error {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                        Text(error).multilineTextAlignment(.center).textSelection(.enabled)
                        Button(L10n.text("Retry")) { session.start(channel) }.buttonStyle(.borderedProminent)
                    }
                    .padding(24).frame(maxWidth: 440)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18)).padding()
                } else if session.loading || session.buffering {
                    LoadingCard(appearAfter: session.loading ? 0 : 1.5) { session.loadingProgress }
                        .padding(.horizontal, 24).padding(.top, 56)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .allowsHitTesting(false)
                }
            }
            topBar
                .opacity(showsChrome ? 1 : 0)
                .allowsHitTesting(showsChrome)
        }
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
        .onChange(of: floats) { _, value in window.level = value ? .floating : .normal }
        .onChange(of: showsChrome) { _, value in setTrafficLights(visible: value) }
        .onAppear { floats = window.level == .floating; idle.attach(window) }
        .onDisappear { idle.detach() }
    }

    /// Title on the left (beside the traffic lights), actions on the right, over a soft scrim.
    private var topBar: some View {
        HStack(spacing: 10) {
            Text(channel.name).font(.headline).lineLimit(1)
                .shadow(color: .black.opacity(0.6), radius: 4)
                .padding(.leading, 86)
            Spacer(minLength: 12)
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    barButton("gobackward.10", L10n.text("Back 10 seconds (←)")) { session.skip(-10) }
                    barButton("goforward.10", L10n.text("Forward 10 seconds (→)")) { session.skip(10) }
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

    private func barButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 14, weight: .medium)) }
            .buttonStyle(.plain)
            .frame(width: 34, height: 34)
            .glassEffect(.regular.interactive(), in: Circle())
            .help(label)
            .accessibilityLabel(label)
    }

    private var optionsMenu: some View {
        Menu {
            Toggle(L10n.text("Loop Playback"), isOn: $session.looping)
            Toggle(L10n.text("Fill Window"), isOn: $fillsFrame)
            Toggle(L10n.text("Float on Top"), isOn: $floats)
            Divider()
            Button(L10n.text("Enter / Exit Full Screen")) { window.toggleFullScreen(nil) }
            Button(L10n.text("Retry")) { session.start(channel) }
            Divider()
            Text(L10n.text("Space: Play / Pause"))
            Text(L10n.text("← / →: Seek 10s · Shift: 60s"))
            Text(L10n.text("↑ / ↓: Volume · M: Mute · F: Full Screen"))
        } label: { Image(systemName: "slider.horizontal.3").font(.system(size: 14, weight: .medium)) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .frame(width: 34, height: 34)
            .glassEffect(.regular.interactive(), in: Circle())
            .help(L10n.text("Playback Options"))
            .accessibilityLabel(L10n.text("Playback Options"))
    }

    private func setTrafficLights(visible: Bool) {
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.animator().alphaValue = visible ? 1 : 0
        }
    }
}

private struct DesktopNativePlayer: NSViewRepresentable {
    let player: AVPlayer
    let fillsFrame: Bool
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        view.showsSharingServiceButton = false
        view.speeds = [0.5, 0.75, 1, 1.25, 1.5, 2].map { AVPlaybackSpeed(rate: Float($0), localizedName: "\($0)×") }
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
        view.videoGravity = fillsFrame ? .resizeAspectFill : .resizeAspect
    }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player = nil }
}
#endif

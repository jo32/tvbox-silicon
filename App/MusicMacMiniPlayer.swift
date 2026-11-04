#if os(macOS)
import AppKit
import SwiftUI
import TVCore

/// The mini player, as Spotify and Music have it on the Mac: the song and its transport in a small
/// window that floats over other apps, for when the main window is out of the way. Minimizing the
/// main window while a song is loaded opens it, and bringing the window back closes it again; the
/// bar's button and Window ▸ Mini Player open it at any time, and those stay until closed.
struct MusicMacMiniPlayer: View {
    static let windowID = "music-mini"
    @Environment(Store.self) private var store
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var hovering = false

    var body: some View {
        let music = store.music
        HStack(spacing: 12) {
            cover(music)
            VStack(alignment: .leading, spacing: 2) {
                Text(music.track?.title ?? L10n.text("Not Playing")).font(.system(size: 13, weight: .semibold)).lineLimit(1)
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
                MusicMacProgressLine().padding(.top, 7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 0) {
                MusicMacButton(symbol: "backward.fill", label: "Previous", size: 13, prominent: true) { music.previous() }
                MusicMacPlayButton(size: 17, frame: 34)
                MusicMacButton(symbol: "forward.fill", label: "Next", size: 13, prominent: true) { music.next() }.disabled(!music.canAdvance)
            }
            .disabled(music.track == nil)
        }
        .padding(10).padding(.trailing, 2)
        .frame(width: 340, height: 76)
        .contentShape(.rect)
        .gesture(WindowDragGesture())
        .glassSurface(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .topLeading) { if hovering { close } }
        .onHover { hovering = $0 }
        .onAppear { MusicMiniWindow.isOpen = true }
        .onDisappear { MusicMiniWindow.isOpen = false; MusicMiniWindow.openedForMinimize = false }
        // One opened for a minimized window goes with the song.
        .onChange(of: music.track == nil) { _, gone in
            if gone && MusicMiniWindow.openedForMinimize { dismissWindow(id: Self.windowID) }
        }
    }

    /// The cover; a click brings the main window back on Now Playing.
    private func cover(_ music: MusicPlaybackSession) -> some View {
        Button {
            MusicMiniWindow.showMain()
            if music.track != nil { music.presentsPlayer = true }
        } label: {
            MusicArtwork(url: music.track?.artwork, size: 56)
                .overlay {
                    if hovering {
                        RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.black.opacity(0.35))
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(L10n.text("Now Playing"))
        .accessibilityLabel(L10n.text("Now Playing"))
    }

    private var close: some View {
        Button { dismissWindow(id: Self.windowID) } label: {
            Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(.black.opacity(0.55), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(5)
        .help(L10n.text("Close"))
        .accessibilityLabel(L10n.text("Close"))
    }
}

/// What the mini player and the main windows share.
@MainActor enum MusicMiniWindow {
    static var isOpen = false
    /// Opened because the main window was minimized, so it closes when the window comes back.
    static var openedForMinimize = false
    /// The window with the app's pages, last seen.
    fileprivate(set) static weak var main: NSWindow?

    static func showMain() {
        NSApp.activate()
        guard let main else { return }
        if main.isMiniaturized { main.deminiaturize(nil) }
        main.makeKeyAndOrderFront(nil)
    }
}

/// Behind the pages: minimizing their window while a song is loaded opens the mini player, and
/// restoring it closes a mini player opened that way.
struct MusicMiniPlayerTrigger: View {
    @Environment(Store.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    #if DEBUG
    @State private var qaWindow: NSWindow?
    #endif

    var body: some View {
        MainWindowObserver { window, minimized in
            #if DEBUG
            qaWindow = window
            #endif
            guard let minimized else { return }
            if minimized, store.music.track != nil, !MusicMiniWindow.isOpen {
                MusicMiniWindow.openedForMinimize = true
                openWindow(id: MusicMacMiniPlayer.windowID)
            } else if !minimized, MusicMiniWindow.openedForMinimize {
                dismissWindow(id: MusicMacMiniPlayer.windowID)
            }
        }
        #if DEBUG
        // `-qaMiniPlayer open|minimize` (with `-qaMusicPlay 1`) opens the mini player, or minimizes
        // the main window, once a song is loaded, for screenshots.
        .task(id: store.music.track != nil && qaWindow != nil) {
            guard store.music.track != nil, let window = qaWindow else { return }
            switch UserDefaults.standard.string(forKey: "qaMiniPlayer") {
            case "open": openWindow(id: MusicMacMiniPlayer.windowID)
            case "minimize":
                // A window restored minimized from the last run has to come back first.
                if window.isMiniaturized { window.deminiaturize(nil) }
                try? await Task.sleep(for: .seconds(1.5))
                window.miniaturize(nil)
            default: break
            }
        }
        #endif
    }
}

/// Reports the window it is in, and each time that window is minimized (true) or restored (false).
private struct MainWindowObserver: NSViewRepresentable {
    let changed: @MainActor (NSWindow, Bool?) -> Void
    func makeNSView(context: Context) -> ObservingView { ObservingView() }
    func updateNSView(_ view: ObservingView, context: Context) { view.changed = changed }

    final class ObservingView: NSView {
        var changed: (@MainActor (NSWindow, Bool?) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            MusicMiniWindow.main = window
            // After this update: the window is reported into SwiftUI state.
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.changed?(window, nil) } }
            for (name, minimized) in [(NSWindow.didMiniaturizeNotification, true), (NSWindow.didDeminiaturizeNotification, false)] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        if minimized { MusicMiniWindow.main = window }
                        self?.changed?(window, minimized)
                    }
                })
            }
        }
    }
}
#endif

import AVKit
import SwiftUI
import TVCore

#if os(tvOS)
/// Now Playing on Apple TV through AVKit's own player, as the video player does: the remote
/// behaves as everywhere on Apple TV (click left or right for 10 seconds, swipe to scrub, hold to
/// fast-forward, Play/Pause), and the transport bar carries previous and next, lyrics, channels,
/// the queue and lyric timing. The song itself, its cover and its lyrics, fill the content overlay.
struct MusicPlayerScreen: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// Lyrics show by themselves when the song has them; the transport bar turns them off.
    @State private var showsLyrics = true

    var body: some View {
        let music = store.music
        // Read here so the transport bar is rebuilt whenever what it lists changes.
        let revision = [String(music.queue?.index ?? -1), String(music.queue?.tracks.count ?? 0), String(music.attempts.count),
                        music.selection?.candidate.id ?? "", String(music.lyrics != nil), String(music.lyricsOffset), String(showsLyrics)]
            .joined(separator: "|")
        MusicNativePlayer(store: store, showsLyrics: $showsLyrics, revision: revision)
            .ignoresSafeArea()
            .onChange(of: music.track == nil) { _, gone in if gone { dismiss() } }
    }
}

/// AVKit lays its bottom controls into the TV's overscan margin when told there is no safe area;
/// this keeps them title-safe while the overlay still fills the screen, as for videos.
private final class MusicPlayerController: AVPlayerViewController {
    private static let titleSafe = UIEdgeInsets(top: 60, left: 80, bottom: 60, right: 80)
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let given = view.safeAreaInsets, extra = additionalSafeAreaInsets
        let wanted = UIEdgeInsets(top: max(0, Self.titleSafe.top - (given.top - extra.top)), left: max(0, Self.titleSafe.left - (given.left - extra.left)),
                                  bottom: max(0, Self.titleSafe.bottom - (given.bottom - extra.bottom)), right: max(0, Self.titleSafe.right - (given.right - extra.right)))
        if wanted != extra { additionalSafeAreaInsets = wanted }
    }
}

private struct MusicNativePlayer: UIViewControllerRepresentable {
    let store: Store
    @Binding var showsLyrics: Bool
    let revision: String
    final class Coordinator { var host: UIHostingController<AnyView>? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = MusicPlayerController()
        controller.player = store.music.player
        let host = UIHostingController(rootView: overlay)
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        host.safeAreaRegions = []
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
        let music = store.music
        if controller.player !== music.player { controller.player = music.player }
        context.coordinator.host?.rootView = overlay
        var items: [UIMenuElement] = []
        if let queue = music.queue, queue.tracks.count > 1 {
            let previous = queue.hasPrevious ? queue.tracks[queue.index - 1].title : nil
            // With the whole queue repeating, the last song is followed by the first.
            let next = queue.hasNext ? queue.tracks[queue.index + 1].title : music.canAdvance ? queue.tracks.first?.title : nil
            items.append(UIAction(title: L10n.text("Previous"), subtitle: previous, image: UIImage(systemName: "backward.end.fill")) { _ in music.previous() })
            items.append(UIAction(title: L10n.text("Next"), subtitle: next, image: UIImage(systemName: "forward.end.fill"),
                                  attributes: next == nil ? [.disabled] : []) { _ in music.next() })
        }
        if let queue = music.queue, !queue.tracks.isEmpty {
            let repeats = MusicRepeatMode.allCases.map { mode in
                UIAction(title: mode.label, state: music.repeatMode == mode ? .on : .off) { _ in music.setRepeat(mode) } as UIMenuElement
            }
            items.append(UIMenu(title: music.repeatMode.label, image: UIImage(systemName: music.repeatMode.symbol), children: repeats))
            if queue.tracks.count > 1 {
                items.append(UIAction(title: L10n.text("Shuffle"), image: UIImage(systemName: "shuffle"), state: music.shuffled ? .on : .off) { _ in music.toggleShuffle() })
            }
        }
        if let lyrics = music.lyrics, !lyrics.lines.isEmpty {
            let binding = $showsLyrics
            items.append(UIAction(title: L10n.text("Lyrics"), image: UIImage(systemName: showsLyrics ? "quote.bubble.fill" : "quote.bubble"),
                                  state: showsLyrics ? .on : .off) { _ in binding.wrappedValue.toggle() })
        }
        let channels = MusicChannelsView.rows(music).map { row in
            let current = row.candidate == music.selection?.candidate && music.failure == nil
            return UIAction(title: row.candidate.name, subtitle: row.detail, state: current ? .on : .off) { _ in
                if !current { music.choose(row.candidate) }
            } as UIMenuElement
        }
        if !channels.isEmpty {
            items.append(UIMenu(title: L10n.text("Channels"), image: UIImage(systemName: "antenna.radiowaves.left.and.right"), children: channels))
        }
        if let queue = music.queue, queue.tracks.count > 1 {
            let tracks = queue.tracks.enumerated().map { index, track in
                UIAction(title: track.title, subtitle: track.artistLine, state: index == queue.index ? .on : .off) { _ in
                    if index != queue.index { music.jump(to: index) }
                } as UIMenuElement
            }
            items.append(UIMenu(title: L10n.text("Up Next"), image: UIImage(systemName: "list.bullet"), children: tracks))
        }
        if music.lyrics?.synced == true {
            var timing: [UIMenuElement] = [
                UIAction(title: L10n.text("Lyrics Earlier"), image: UIImage(systemName: "plus")) { _ in music.adjustLyrics(by: 0.5) },
                UIAction(title: L10n.text("Lyrics Later"), image: UIImage(systemName: "minus")) { _ in music.adjustLyrics(by: -0.5) },
            ]
            if music.lyricsOffset != 0 { timing.append(UIAction(title: L10n.text("Reset")) { _ in music.resetLyricsOffset() }) }
            let state = music.lyricsOffset == 0 ? L10n.text("Lyrics in sync") : String(format: "%+.1f s", music.lyricsOffset)
            items.append(UIMenu(title: state, image: UIImage(systemName: "timer"), children: timing))
        }
        // A book's intro and outro, for all its chapters (#1486); never a song's.
        if music.canSkip {
            items.append(SkipTimesMenu.make(music.skipSettings, set: { music.applySkipSettings($0) }, mark: { music.markSkip(intro: $0) }))
        }
        items.append(SleepTimer.shared.uiMenu(item: music.sleepItem))
        controller.transportBarCustomMenuItems = items
    }

    private var overlay: AnyView {
        AnyView(MusicTVContent(showsLyrics: showsLyrics).environment(store))
    }
}

/// What fills the screen behind AVKit's controls: the cover's colours, the source at the top, and
/// the cover with the song, or beside its lyrics.
private struct MusicTVContent: View {
    @Environment(Store.self) private var store
    let showsLyrics: Bool

    var body: some View {
        let music = store.music
        ZStack {
            MusicTVBackdrop(artwork: music.track?.artwork)
            VStack(spacing: 0) {
                Text(music.queue?.source ?? music.track?.album ?? L10n.text("Music"))
                    .font(.system(size: 24, weight: .semibold)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                    .padding(.top, 70)
                Spacer(minLength: 30)
                if showsLyrics, let lyrics = music.lyrics, !lyrics.lines.isEmpty {
                    HStack(alignment: .center, spacing: 100) {
                        MusicTVSong(music: music, art: 400, alignment: .leading)
                        MusicLyricLines(lyrics: lyrics, current: music.currentLyric, size: 44, translationSize: 26)
                            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                                                         .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                                                 startPoint: .top, endPoint: .bottom))
                            .frame(maxWidth: .infinity, maxHeight: 620)
                    }
                    .padding(.horizontal, 120)
                } else {
                    MusicTVSong(music: music, art: 500, alignment: .center)
                }
                Spacer(minLength: 170)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: showsLyrics)
    }
}

/// The cover with the song under it. It sinks a little while paused, as in Music.
private struct MusicTVSong: View {
    let music: MusicPlaybackSession
    let art: CGFloat
    let alignment: HorizontalAlignment

    var body: some View {
        VStack(alignment: alignment, spacing: 0) {
            PosterImage(url: music.track?.artwork, symbol: "music.note")
                .frame(width: art, height: art)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 36, y: 20)
                .scaleEffect(music.phase == .paused ? 0.92 : 1)
                .animation(.spring(duration: 0.5), value: music.phase == .paused)
            VStack(alignment: alignment, spacing: 4) {
                Text(music.track?.title ?? "").font(.system(size: 29, weight: .semibold)).lineLimit(1)
                Text(music.track?.artistLine ?? "").font(.system(size: 27)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                if let notice = music.notice ?? music.failure {
                    Text(notice).font(.system(size: 22)).foregroundStyle(Brand.amber).lineLimit(2).padding(.top, 6)
                } else if music.phase == .resolving {
                    Text(L10n.text("Finding the best channel…")).font(.system(size: 22)).foregroundStyle(.white.opacity(0.6)).padding(.top, 6)
                }
            }
            .multilineTextAlignment(alignment == .center ? .center : .leading)
            .frame(width: art + 200, alignment: alignment == .center ? .center : .leading)
            .padding(.top, 26)
        }
        .foregroundStyle(.white)
    }
}

/// The cover's colours across the screen: the cover blurred far past recognition, still vivid.
private struct MusicTVBackdrop: View {
    let artwork: URL?
    var body: some View {
        ZStack {
            Color.black
            PosterImage(url: artwork, symbol: "music.note")
                .scaleEffect(1.8)
                .blur(radius: 140)
                .saturation(1.6)
            LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }
}
#endif

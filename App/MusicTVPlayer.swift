import SwiftUI
import TVCore

#if os(tvOS)
/// Now Playing at the top of a music page, as a small pill like the filter chips beside it: the
/// remote reaches it in a move from the results, and it opens the full-screen player.
struct MusicNowPlayingButton: View {
    @EnvironmentObject private var store: Store
    var body: some View {
        let music = store.music
        if let track = music.track {
            Button { music.presentsPlayer = true } label: {
                HStack(spacing: 14) {
                    PosterImage(url: track.artwork, symbol: "music.note")
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    // Bars in the label's own colour, so they stay visible on the focused white plate.
                    Image(systemName: "waveform")
                    Text([track.title, track.artistLine].joined(separator: " · ")).lineLimit(1)
                }
            }
            .glassPill()
            .accessibilityLabel(Text(L10n.text("Now Playing") + ", " + track.title))
            .padding(.bottom, 16)
        }
    }
}

/// The sidebar's Now Playing item: the song's title, and bars that move while it plays. The sidebar
/// draws every icon in one colour (a cover came out as a black disc), so the bars are the motion.
struct MusicTabLabel: View {
    @EnvironmentObject private var store: Store
    @StateObject private var bars = MusicTabBars()
    var body: some View {
        let music = store.music
        Label { Text(music.track?.title ?? L10n.text("Now Playing")) } icon: { Image(uiImage: bars.image) }
            .compatOnChange(of: music.phase == .playing, initial: true) { _, playing in bars.animates = playing }
    }
}

/// Three bars drawn at a few heights, cycled while the song plays; low and still while it is paused.
@MainActor final class MusicTabBars: ObservableObject {
    @Published private(set) var image = MusicTabBars.frames[0]
    @Published var animates = false { didSet { if animates != oldValue { restart() } } }
    private var frame = 0
    private var timer: Timer?
    private static let still = render([0.35, 0.35, 0.35])
    private static let frames = [[0.45, 0.9, 0.6], [0.8, 0.5, 1.0], [0.6, 1.0, 0.4], [1.0, 0.65, 0.8]].map { render($0) }

    private func restart() {
        timer?.invalidate(); timer = nil
        guard animates else { image = Self.still; return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.frame += 1
                self.image = Self.frames[self.frame % Self.frames.count]
            }
        }
    }

    /// A template, so the sidebar tints it like its other icons, dark on the focused plate.
    private nonisolated static func render(_ heights: [CGFloat]) -> UIImage {
        let size = CGSize(width: 30, height: 30), width: CGFloat = 5, gap: CGFloat = 3.5, tallest: CGFloat = 24
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor.black.setFill()
            let start = (size.width - width * 3 - gap * 2) / 2
            for (index, height) in heights.enumerated() {
                let barHeight = tallest * height
                let bar = CGRect(x: start + CGFloat(index) * (width + gap), y: (size.height + tallest) / 2 - barHeight, width: width, height: barHeight)
                UIBezierPath(roundedRect: bar, cornerRadius: width / 2).fill()
            }
        }.withRenderingMode(.alwaysTemplate)
    }
}

/// The top of the sidebar while a song is loaded, where Music keeps the profile card: the cover,
/// with bars over it while it plays, the title and the artist. Clicking it opens the player.
/// tvOS 27 and later; before that the sidebar leads with a plain Now Playing item instead.
struct MusicSidebarNowPlaying: View {
    @EnvironmentObject private var store: Store

    static var inSidebarHeader: Bool {
        if #available(tvOS 27, *) { true } else { false }
    }

    var body: some View {
        let music = store.music
        if let track = music.track {
            Button { music.presentsPlayer = true } label: { MusicSidebarCard(track: track) }
                .buttonStyle(MusicSidebarCardStyle())
                .accessibilityLabel(Text(L10n.text("Now Playing") + ", " + track.title))
                // Close to the sections under it, as the profile card sits in Music.
                .padding(.bottom, -36)
        }
    }
}

/// The card itself. In focus only the cover is outlined and lifts, like a poster; the words stay put.
private struct MusicSidebarCard: View {
    @EnvironmentObject private var store: Store
    @Environment(\.isFocused) private var focused
    let track: MusicTrack
    private let art: CGFloat = 60

    var body: some View {
        HStack(spacing: 16) {
            MusicArtwork(url: track.artwork, size: art)
                .overlay { activity(store.music) }
                .overlay {
                    RoundedRectangle(cornerRadius: art * 0.12 + 5, style: .continuous)
                        .strokeBorder(.white, lineWidth: 3).padding(-5)
                        .opacity(focused ? 1 : 0)
                }
                .scaleEffect(focused ? 1.08 : 1)
                .shadow(color: .black.opacity(focused ? 0.45 : 0), radius: 12, y: 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title).font(.system(size: 25, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(track.artistLine).font(.system(size: 20)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        // The cover lines up with the section icons, with room above for its outline.
        .padding(.leading, 22).padding(.trailing, 12).padding(.top, 14).padding(.bottom, 6)
        .animation(.easeOut(duration: 0.15), value: focused)
    }

    /// Bars while sound plays, a spinner while a channel is found; the cover alone while paused.
    @ViewBuilder private func activity(_ music: MusicPlaybackSession) -> some View {
        if music.phase == .playing || music.busy {
            ZStack {
                RoundedRectangle(cornerRadius: art * 0.12, style: .continuous).fill(.black.opacity(0.4))
                if music.busy && !music.isPlaying {
                    ProgressView().tint(.white).scaleEffect(0.7)
                } else {
                    Image(systemName: "waveform").font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
                        
                }
            }
        }
    }
}

/// No plate: the card draws its own focus on the cover.
private struct MusicSidebarCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.8 : 1)
    }
}

extension View {
    /// The Now Playing card at the top of the sidebar, where tvOS has a place for one.
    @ViewBuilder func musicSidebarHeader() -> some View {
        if #available(tvOS 27, *) { tabViewSidebarHeader { MusicSidebarNowPlaying() } } else { self }
    }
}
#endif

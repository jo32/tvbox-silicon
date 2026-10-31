import SwiftUI
import TVCore

/// A cover, always square with the same rounding for its size, however the image is shaped:
/// rows, the mini player and the Now Playing screen all draw covers through this.
struct MusicArtwork: View {
    let url: URL?
    var size: CGFloat?
    var symbol = "music.note"
    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { PosterImage(url: url, symbol: symbol) }
            .frame(width: size, height: size)
            .posterClip(RoundedRectangle(cornerRadius: size.map { max(4, $0 * 0.12) } ?? 12, style: .continuous))
    }
}

#if os(iOS)
/// The player as a strip above the tab bar, as in Music: cover, title and artist, play and next.
/// It is always the same height; the lyrics and everything else are on the Now Playing screen,
/// which a tap opens. `inline` is the narrower form beside a minimized tab bar.
struct MusicMiniPlayer: View {
    @Environment(Store.self) private var store
    var inline = false

    var body: some View {
        let music = store.music
        HStack(spacing: inline ? 10 : 12) {
            MusicArtwork(url: music.track?.artwork, size: inline ? 28 : 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(music.track?.title ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
                if let failure = music.failure {
                    Text(failure).font(.caption).foregroundStyle(Brand.amber).lineLimit(1)
                } else if !inline {
                    Text(music.track?.artistLine ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if music.failure != nil {
                    button("arrow.clockwise", label: "Retry") { music.retry() }
                } else if music.busy && !music.isPlaying {
                    ProgressView().frame(width: 36, height: 36)
                } else {
                    button(music.isPlaying ? "pause.fill" : "play.fill", label: music.isPlaying ? "Pause" : "Play") { music.toggle() }
                        .contentTransition(.symbolEffect(.replace))
                }
                if !inline {
                    button("forward.fill", label: "Next") { music.next() }.disabled(music.queue?.hasNext != true)
                }
            }
            .font(.title3)
        }
        .padding(.leading, inline ? 6 : 10).padding(.trailing, inline ? 4 : 8)
        .frame(maxHeight: .infinity)
        .contentShape(.rect)
        .onTapGesture { music.presentsPlayer = true }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: L10n.text("Now Playing")) { music.presentsPlayer = true }
        #if DEBUG
        // `-qaNowPlaying artwork|lyrics|queue` opens Now Playing on that panel, for screenshots.
        .task { if UserDefaults.standard.string(forKey: "qaNowPlaying") != nil { music.presentsPlayer = true } }
        #endif
    }

    private func button(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 36, height: 36).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text(label))
    }
}

/// The tab bar's accessory slot (iOS 26.1): the system floats the mini player above the bar and
/// tucks it in beside the bar when scrolling minimizes it, with its own animation. Before 26.1
/// there is no way to hide the slot, so pages show the strip themselves (`musicPlayerInset`).
extension View {
    @ViewBuilder func musicAccessory(enabled: Bool) -> some View {
        if #available(iOS 26.1, *) {
            tabViewBottomAccessory(isEnabled: enabled) { MusicAccessoryContent() }
        } else {
            self
        }
    }
}

enum MusicAccessory {
    /// The system's accessory holds the mini player: iOS 26.1 on a phone.
    static func used(compact: Bool) -> Bool {
        if #available(iOS 26.1, *) { return compact }
        return false
    }
}

@available(iOS 26.1, *)
private struct MusicAccessoryContent: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    var body: some View { MusicMiniPlayer(inline: placement == .inline) }
}
#endif

#if !os(tvOS)
import SwiftUI
import TVCore

/// Lyrics on the Now Playing screen, as Music shows them: large and bold, the line being sung
/// bright and held a third of the way down, the rest faded. Tapping a line plays from it. Without
/// lyrics the panel says so in the same space, so nothing around it moves.
struct MusicNowPlayingLyrics: View {
    @Environment(Store.self) private var store
    @State private var scrolled: Int?
    var showsTranslation = true
    #if os(macOS)
    // A window's worth of room: larger lines.
    private let size: CGFloat = 32, translationSize: CGFloat = 18, spacing: CGFloat = 30
    #else
    private let size: CGFloat = 28, translationSize: CGFloat = 17, spacing: CGFloat = 24
    #endif

    var body: some View {
        let music = store.music
        if let lyrics = music.lyrics {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: spacing) {
                    ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                        let faded = lyrics.synced && index != music.currentLyric
                        VStack(alignment: .leading, spacing: 4) {
                            Text(line.text.isEmpty ? "♪" : line.text).font(.system(size: size, weight: .bold))
                            if showsTranslation, let translation = line.translation {
                                Text(translation).font(.system(size: translationSize, weight: .semibold))
                            }
                        }
                        .foregroundStyle(.white.opacity(faded ? 0.32 : 1))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .animation(.easeOut(duration: 0.3), value: faded)
                        .contentShape(.rect)
                        .onTapGesture { if lyrics.synced { music.seek(toLyric: line) } }
                        .id(index)
                    }
                    Text(L10n.text("Lyrics from %@", lyrics.platform.name)).font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                }
                .scrollTargetLayout()
                .padding(.vertical, 28)
            }
            .scrollPosition(id: $scrolled, anchor: UnitPoint(x: 0.5, y: 0.3))
            // The lines fade in and out at the panel's edges instead of being cut.
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.07),
                                         .init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            // Once the lines are laid out: set as the panel appeared, the position was dropped, and
            // reopening the player left the lyrics at the top until the next line.
            .task { try? await Task.sleep(for: .milliseconds(60)); scrolled = music.currentLyric }
            .onChange(of: music.currentLyric) { _, index in
                guard let index else { return }
                withAnimation(.smooth(duration: 0.5)) { scrolled = index }
            }
        } else if music.lyricsLoading || music.busy {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyResults(symbol: "quote.bubble", title: L10n.text("No Lyrics"), message: L10n.text("None of the catalogs has lyrics for this song."), fills: true)
        }
    }
}

/// The songs after this one in what is playing; tapping one plays it.
struct MusicUpNext: View {
    @Environment(Store.self) private var store

    var body: some View {
        let music = store.music
        let queue = music.queue
        let upcoming = queue.map { queue in Array(queue.tracks.enumerated()).filter { $0.offset > queue.index } } ?? []
        if upcoming.isEmpty {
            EmptyResults(symbol: "list.bullet", title: L10n.text("Nothing Up Next"),
                         message: L10n.text("Play a song from search results, an album or a playlist, and the songs after it play next."), fills: true)
        } else {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("Up Next")).font(.headline).padding(.bottom, 6)
                    ForEach(upcoming, id: \.offset) { index, track in
                        Button { music.jump(to: index) } label: {
                            HStack(spacing: 12) {
                                MusicArtwork(url: track.artwork, size: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(track.title).font(.body.weight(.medium)).lineLimit(1)
                                    Text(track.artistLine).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                if let duration = track.duration {
                                    Text(MusicTime.text(duration)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 6)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 12)
            }
        }
    }
}
#endif

#if os(tvOS)
import SwiftUI
import TVCore

/// The Apple TV player's 选集: a tab of the info panel (swipe down), as in the TV app. The lines (线路) in a row, and
/// under them the chosen line's episodes, the one playing marked and focused first. Choosing one plays it in the same
/// player. Drawn like the Danmaku tab beside it: white plates on a dark panel, no glass over the moving picture.
struct TVPlayerEpisodesPanel: View {
    let channel: Channel
    @Environment(Store.self) private var store
    @State private var selectedFlag: String?
    @FocusState private var focus: Focus?

    private enum Focus: Hashable { case line(String), episode(Episode.ID) }

    /// The episode playing now: the next one may have started by itself while the panel was open.
    private var playing: Channel {
        store.playing.flatMap { store.catalog(for: $0) != nil ? $0 : nil } ?? channel
    }

    var body: some View {
        Group {
            if let catalog = store.catalog(for: playing) { content(catalog) } else { Color.clear }
        }
        .background(.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
    }

    private func content(_ catalog: PlaybackCatalog) -> some View {
        let episodes = catalog.video.episodes
        var seen = Set<String>()
        let flags = episodes.map(\.flag).filter { seen.insert($0).inserted }
        let current = playing.historyContext?.episode(in: episodes)
        let flag = selectedFlag.flatMap { flags.contains($0) ? $0 : nil } ?? current?.flag ?? flags.first ?? ""
        let items = episodes.filter { $0.flag == flag }
        let titles = Dictionary(items.map { ($0.id, catalog.labels[$0.id] ?? EpisodeRow.title($0.name)) }, uniquingKeysWith: { first, _ in first })
        // 第1集, 01: small tiles. File names and long titles: wide two-line cards.
        let short = (titles.values.map(\.count).max() ?? 0) <= 6
        return VStack(alignment: .leading, spacing: 18) {
            if flags.count > 1 {
                Text(L10n.text("Lines")).font(.headline).foregroundStyle(.secondary).padding(.horizontal, 48)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 14) {
                            ForEach(flags, id: \.self) { line in
                                Button { selectedFlag = line } label: {
                                    HStack(spacing: 8) {
                                        if line == current?.flag { Image(systemName: "speaker.wave.2.fill").font(.caption) }
                                        Text(line.isEmpty ? L10n.text("Play") : line).lineLimit(1)
                                    }
                                }
                                .buttonStyle(TVEpisodePlateStyle(selected: line == flag, capsule: true))
                                .focused($focus, equals: .line(line))
                                .id(line)
                            }
                        }
                        .padding(.horizontal, 48).padding(.vertical, 8)
                    }
                    .scrollClipDisabled()
                    // Up and Down move between the rows from anywhere, not only to a button straight above or below.
                    .focusSection()
                    .onAppear { proxy.scrollTo(flag, anchor: .center) }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(catalog.video.name).font(.headline).lineLimit(1)
                Text("\(items.count)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                if let error = store.episodeError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 48)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 14) {
                        ForEach(items) { episode in
                            let isCurrent = episode.id == current?.id
                            Button {
                                guard !isCurrent else { return }
                                store.selectEpisode(episode, from: playing)
                            } label: {
                                tile(titles[episode.id] ?? episode.name, current: isCurrent,
                                     loading: store.resolvingEpisode?.id == episode.id, short: short)
                            }
                            .buttonStyle(TVEpisodePlateStyle(selected: isCurrent, capsule: false))
                            .focused($focus, equals: .episode(episode.id))
                            .id(episode.id)
                            .accessibilityLabel(episode.name)
                            .accessibilityAddTraits(isCurrent ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal, 48).padding(.vertical, 8)
                }
                .scrollClipDisabled()
                .focusSection()
                .onAppear { if let id = current?.id, items.contains(where: { $0.id == id }) { proxy.scrollTo(id, anchor: .center) } }
                .onChange(of: flag) { _, _ in
                    if let first = items.first(where: { $0.id == current?.id }) ?? items.first { proxy.scrollTo(first.id, anchor: .leading) }
                }
            }
        }
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .defaultFocus($focus, current.map { .episode($0.id) })
        .accessibilityIdentifier("player.episodes.panel")
    }

    private func tile(_ title: String, current: Bool, loading: Bool, short: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if loading { ProgressView().controlSize(.small) }
                else if current { Image(systemName: "speaker.wave.2.fill").font(.caption) }
                Text(title).lineLimit(short ? 1 : 2).multilineTextAlignment(.leading)
            }
            if current && !short {
                Text(L10n.text("Now Playing")).font(.caption).opacity(0.7)
            }
        }
        .font(.system(size: 26, weight: current ? .semibold : .medium))
        .frame(width: short ? 150 : 360, height: short ? 76 : 108, alignment: short ? .center : .leading)
    }
}

/// A line or an episode: a quiet plate, the chosen one brighter, the focused one white with black text.
private struct TVEpisodePlateStyle: ButtonStyle {
    let selected: Bool
    let capsule: Bool
    func makeBody(configuration: Configuration) -> some View { Plate(configuration: configuration, selected: selected, capsule: capsule) }
    private struct Plate: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        let capsule: Bool
        @Environment(\.isFocused) private var focused
        var body: some View {
            let shape = RoundedRectangle(cornerRadius: capsule ? 40 : 16, style: .continuous)
            configuration.label
                .font(capsule ? .system(size: 26, weight: .medium) : nil)
                .foregroundStyle(focused ? Color.black : Color.white)
                .tint(focused ? .black : .white)
                .padding(.horizontal, capsule ? 30 : 20).padding(.vertical, capsule ? 12 : 0)
                .background {
                    shape.fill(focused ? Color.white : Color.white.opacity(selected ? 0.32 : 0.12))
                }
                .scaleEffect(focused ? (configuration.isPressed ? 1.02 : 1.08) : 1)
                .shadow(color: .black.opacity(focused ? 0.35 : 0), radius: 14, y: 8)
                .animation(.easeOut(duration: 0.18), value: focused)
        }
    }
}
#endif

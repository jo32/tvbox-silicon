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
    /// The show's TMDB match, as the details page kept it: the episodes' stills.
    @State private var tmdb = TMDBLookup()

    private enum Focus: Hashable { case line(String), episode(Episode.ID) }

    /// The episode playing now: the next one may have started by itself while the panel was open.
    private var playing: Channel {
        store.playing.flatMap { store.catalog(for: $0) != nil ? $0 : nil } ?? channel
    }

    var body: some View {
        Group {
            if let catalog = store.catalog(for: playing) {
                content(catalog).task(id: catalog.video.id) {
                    guard TMDBLookup.applies(to: catalog.client.site) else { return }
                    _ = await tmdb.prepare(key: TMDBMatchStore.key(source: catalog.client.site.key, video: catalog.video.id))
                }
            } else { Color.clear }
        }
        // A Liquid Glass strip over the picture, as other players show their 选集.
        .glassSurface(.regular, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        // The row scrolls under the glass's edges, not past them.
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
        // Pictures, as on the details page: TMDB's stills, else the show's backdrops (or the cover) with the number.
        let stills = tmdb.episodes(items)
        let backdrops = tmdb.episodeBackdrops.isEmpty ? [catalog.video.poster].compactMap { $0 } : tmdb.episodeBackdrops
        return VStack(alignment: .leading, spacing: 14) {
            // The lines (线路), when there are several, beside the title: the tab is a compact strip, as in other players.
            if flags.count > 1 || store.episodeError != nil {
            HStack(alignment: .center, spacing: 28) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(catalog.video.name).font(.headline).lineLimit(1)
                    Text("\(items.count)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                    if let error = store.episodeError {
                        Label(error, systemImage: "exclamationmark.triangle.fill").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .fixedSize()
                if flags.count > 1 {
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
                            .padding(.trailing, 48).padding(.vertical, 8)
                        }
                        .scrollClipDisabled()
                        // Up and Down move between the rows from anywhere, not only to a button straight above or below.
                        .focusSection()
                        .onAppear { proxy.scrollTo(flag, anchor: .center) }
                    }
                }
            }
            .padding(.leading, 40)
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 30) {
                        ForEach(items) { episode in
                            let isCurrent = episode.id == current?.id
                            Button {
                                guard !isCurrent else { return }
                                store.selectEpisode(episode, from: playing)
                            } label: {
                                TMDBEpisodeTile(name: titles[episode.id] ?? episode.name, info: stills[episode.id], detail: catalog.details[episode.id],
                                                current: isCurrent, loading: store.resolvingEpisode?.id == episode.id, width: 250,
                                                backdrops: backdrops, oneLine: true)
                                    // Its whole 16:9 picture: the panel's height otherwise squeezed it to a stamp.
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .tmdbCardButton()
                            .focused($focus, equals: .episode(episode.id))
                            .id(episode.id)
                            .accessibilityLabel(episode.name)
                            .accessibilityAddTraits(isCurrent ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal, 40).padding(.top, 10).padding(.bottom, 2)
                }
                .scrollClipDisabled()
                .focusSection()
                .onAppear { if let id = current?.id, items.contains(where: { $0.id == id }) { proxy.scrollTo(id, anchor: .center) } }
                .onChange(of: flag) { _, _ in
                    if let first = items.first(where: { $0.id == current?.id }) ?? items.first { proxy.scrollTo(first.id, anchor: .leading) }
                }
            }
        }
        .padding(.top, 16).padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .defaultFocus($focus, current.map { .episode($0.id) })
        .accessibilityIdentifier("player.episodes.panel")
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
/// The info panel's Channel List (#1010): the list the live channel was picked from, a group at a time, as a strip over
/// the picture like the Episodes tab.
struct TVPlayerChannelsPanel: View {
    let channel: Channel
    @Environment(Store.self) private var store
    @State private var selectedGroup: String?

    /// The channel playing now, which may have changed while the panel was open.
    private var playing: Channel { store.playing ?? channel }

    var body: some View {
        Group {
            if let lineup = store.lineup(for: playing) { content(lineup) } else { Color.clear }
        }
        .environment(store.guide(for: playing))
        .glassSurface(.regular, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
    }

    private func content(_ lineup: LiveLineup) -> some View {
        let playing = playing
        var seen = Set<String>()
        let groups = lineup.channels.map(\.group).filter { seen.insert($0).inserted }
        let group = selectedGroup.flatMap { groups.contains($0) ? $0 : nil } ?? playing.group
        let items = groups.count > 1 ? lineup.channels.filter { $0.group == group } : lineup.channels
        return VStack(alignment: .leading, spacing: 14) {
            if groups.count > 1 {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 14) {
                            ForEach(groups, id: \.self) { value in
                                Button { selectedGroup = value } label: {
                                    Text(value.isEmpty ? L10n.text("Ungrouped") : value).lineLimit(1)
                                }
                                .buttonStyle(TVEpisodePlateStyle(selected: value == group, capsule: true))
                                .id(value)
                            }
                        }
                        .padding(.horizontal, 40).padding(.vertical, 8)
                    }
                    .scrollClipDisabled()
                    .focusSection()
                    .onAppear { proxy.scrollTo(group, anchor: .center) }
                }
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 20) {
                        ForEach(items) { item in
                            let current = item.id == playing.id
                            Button { if !current { store.playing = item } } label: {
                                HStack(spacing: 16) {
                                    ChannelLogo(channel: item, size: 56)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name).font(.headline).lineLimit(1)
                                        NowOnText(channel: item).font(.caption).lineLimit(1).opacity(0.7)
                                    }
                                    if current { Image(systemName: "speaker.wave.2.fill").font(.caption) }
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                            }
                            .buttonStyle(TVEpisodePlateStyle(selected: current, capsule: false))
                            .id(item.id)
                            .accessibilityAddTraits(current ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal, 40).padding(.vertical, 10)
                }
                .scrollClipDisabled()
                .focusSection()
                .onAppear { proxy.scrollTo(playing.id, anchor: .center) }
                .onChange(of: group) { _, _ in if let first = items.first { proxy.scrollTo(first.id, anchor: .leading) } }
            }
        }
        .padding(.vertical, 20)
    }
}
#endif

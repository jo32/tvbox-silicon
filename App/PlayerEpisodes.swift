#if !os(tvOS)
import SwiftUI
import TVCore

/// The player's 选集 (#524): a button beside Previous and Next Episode that opens the video's episodes in a sheet
/// (`playerEpisodesSheet`). They were four menus deep in the player's ⋯ menu (⋯ › Episodes › line › episode), as a
/// list of bare names. `label` is the button's face in its row's style; nothing shows for a video of one episode.
struct PlayerEpisodesButton<Label: View>: View {
    let channel: Channel
    @Binding var isPresented: Bool
    @ViewBuilder let label: () -> Label
    @Environment(Store.self) private var store

    var body: some View {
        if PlayerEpisodesSheet.offered(for: channel, in: store) {
            Button(action: { isPresented = true }, label: label)
                .help(L10n.text("Episodes"))
                .accessibilityLabel(L10n.text("Episodes"))
                .accessibilityIdentifier("player.episodes")
        }
    }
}

extension View {
    /// The episodes sheet, on a view that stays while the player's controls come and go: on the button itself, the
    /// sheet closed whenever its row did.
    func playerEpisodesSheet(isPresented: Binding<Bool>, channel: Channel) -> some View {
        sheet(isPresented: isPresented) { PlayerEpisodesSheet(channel: channel).playerSheet() }
    }
}

/// The video's episodes as its page shows them: the lines to choose from, then TMDB's stills and episode titles when
/// the page found the title on TMDB (the answer this device kept), else the page's tiles with the episodes' names.
/// Half the screen on a phone, so the picture stays in view; the episode playing is marked and scrolled to.
struct PlayerEpisodesSheet: View {
    let channel: Channel
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var tmdb = TMDBLookup()
    @State private var selectedFlag: String?
    /// The same 倒序 as the video's page.
    @AppStorage("episodesReversed") private var reversesEpisodes = false
    /// The viewer chose an episode here: the sheet closes once it plays.
    @State private var picked = false

    /// The Episodes button's symbol, which the player's wait also shows when another line may be faster.
    static let symbol = "rectangle.stack"

    /// A video of several episodes, or of several lines.
    @MainActor static func offered(for channel: Channel, in store: Store) -> Bool {
        (store.catalog(for: channel)?.video.episodes.count ?? 0) > 1
    }

    /// The episode playing now: the next one may have started by itself while the sheet was open.
    private var playing: Channel {
        store.playing.flatMap { store.catalog(for: $0) != nil ? $0 : nil } ?? channel
    }

    var body: some View {
        NavigationStack {
            Group {
                if let catalog = store.catalog(for: playing) {
                    content(catalog)
                } else {
                    // The video stopped playing behind the sheet.
                    Color.clear.onAppear { dismiss() }
                }
            }
            .navigationTitle(L10n.text("Episodes"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { dismiss() } }
            }
        }
        .environment(\.glassControls, true)
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #else
        .frame(minWidth: 620, idealWidth: 720, minHeight: 460, idealHeight: 560)
        #endif
        // The chosen episode is playing: the sheet has done its job.
        .onChange(of: store.playing) { _, _ in if picked { dismiss() } }
        .task(id: store.catalog(for: playing)?.video.id) { await lookUp() }
    }

    private func content(_ catalog: PlaybackCatalog) -> some View {
        let episodes = catalog.video.episodes
        var seen = Set<String>()
        let flags = episodes.map(\.flag).filter { seen.insert($0).inserted }
        let current = playing.historyContext?.episode(in: episodes)
        let flag = selectedFlag.flatMap { flags.contains($0) ? $0 : nil } ?? current?.flag ?? flags.first ?? ""
        let items = episodes.filter { $0.flag == flag }
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(catalog, count: items.count)
                    if flags.count > 1 {
                        SourceStrip(items: flags.map { .init(id: $0, name: $0.isEmpty ? L10n.text("Play") : $0) }, selection: flag) {
                            selectedFlag = $0
                        }
                        .contentMargins(.horizontal, 16, for: .scrollContent).scrollClipDisabled()
                        .padding(.horizontal, -16)
                    }
                    if let error = store.episodeError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    grid(items, labels: catalog.labels, current: current?.id)
                }
                .padding(16)
            }
            .onAppear { if let id = current?.id { proxy.scrollTo(id, anchor: .center) } }
        }
    }

    /// The title and how many episodes the line has, with 倒序 beside them as on the video's page.
    private func header(_ catalog: PlaybackCatalog, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(catalog.video.name).font(.headline).lineLimit(1)
            Text("\(count)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if tmdb.details != nil { TMDBBadge() }
            Button { reversesEpisodes.toggle() } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(reversesEpisodes ? Brand.accent : Color.secondary)
                    .frame(minWidth: 32, minHeight: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.text("Reverse Order"))
            .accessibilityLabel(L10n.text("Reverse Order"))
            .accessibilityAddTraits(reversesEpisodes ? .isSelected : [])
        }
    }

    private func grid(_ items: [Episode], labels: [Episode.ID: String], current: Episode.ID?) -> some View {
        // TMDB's stills when its season lines up with most of the episodes and has pictures for them, as on the page.
        let stills = tmdb.episodes(items)
        let showsStills = items.count > 1 && stills.values.filter { $0.still != nil }.count * 2 >= items.count
        let titles = Dictionary(items.map { ($0.id, labels[$0.id] ?? EpisodeRow.title($0.name)) }, uniquingKeysWith: { first, _ in first })
        // 第1集, 01, 4K国语: small tiles. File names and long titles: two-line cards.
        let short = (titles.values.map(\.count).max() ?? 0) <= 6
        let minimum: CGFloat = showsStills ? Self.stillTile : short ? Self.shortTile : Self.longTile
        let shown = reversesEpisodes ? items.reversed() : items
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: showsStills ? 12 : 8, alignment: .top)],
                         spacing: showsStills ? 14 : 8) {
            ForEach(shown) { episode in
                let title = titles[episode.id] ?? episode.name
                let isCurrent = episode.id == current
                let loading = store.resolvingEpisode?.id == episode.id
                Button {
                    // The episode playing keeps playing.
                    guard !isCurrent else { dismiss(); return }
                    picked = true
                    store.selectEpisode(episode, from: playing)
                } label: {
                    if showsStills {
                        TMDBEpisodeTile(name: title, info: stills[episode.id], current: isCurrent, loading: loading, width: nil)
                    } else {
                        EpisodeCell(title: title, current: isCurrent, loading: loading, compact: short)
                    }
                }
                .buttonStyle(.plain)
                .id(episode.id)
                .accessibilityLabel(episode.name)
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
                .contextMenu { if labels[episode.id] != nil { Text(episode.name) } }
            }
        }
        .animation(.smooth(duration: 0.4), value: showsStills)
    }

    #if os(macOS)
    private static let stillTile: CGFloat = 180, shortTile: CGFloat = 84, longTile: CGFloat = 220
    #else
    private static let stillTile: CGFloat = 160, shortTile: CGFloat = 76, longTile: CGFloat = 220
    #endif

    /// TMDB's details as the video's page has them: the answer this device kept, else the same lookup the page runs.
    private func lookUp() async {
        guard let catalog = store.catalog(for: playing) else { return }
        let site = catalog.client.site
        guard TMDBLookup.applies(to: site) else { return }
        let key = TMDBMatchStore.key(source: site.key, video: catalog.video.id)
        let request = TMDBMatch.Request(video: catalog.video, listVideo: catalog.video,
                                        source: TMDBMatch.SourceRef(key: site.key, name: site.name))
        guard !TMDBMatch.labeledNotOnTMDB(request) else { return }
        await tmdb.run(key: key, request: request)
    }
}

/// An episode without TMDB's still: the page's tile (iPhone watch page), the one playing filled with the accent.
private struct EpisodeCell: View {
    let title: String
    let current: Bool
    let loading: Bool
    let compact: Bool
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(spacing: 6) {
            if loading { ProgressView().controlSize(.small) }
            Text(title).lineLimit(compact ? 1 : 2).multilineTextAlignment(compact ? .center : .leading)
        }
        .font(.subheadline.weight(current ? .semibold : .regular))
        .foregroundStyle(current ? Brand.onAccent : Color.primary)
        .tint(current ? Brand.onAccent : nil)
        .padding(.horizontal, compact ? 8 : 12)
        .frame(maxWidth: .infinity, minHeight: compact ? 44 : 54, alignment: compact ? .center : .leading)
        .glassOrFill(current ? GlassStyle.regular.tint(Brand.accent).interactive() : .regular.interactive(),
                     current ? Brand.accent : Color.primary.opacity(0.06), in: shape)
        .contentShape(shape)
    }
}
#endif

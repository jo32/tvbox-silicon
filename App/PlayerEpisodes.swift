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
        // TMDB's stills when its season lines up with most of the episodes and it has pictures, as on the page. While
        // TMDB hasn't answered, tiles with the episodes' numbers, also as on the page, so its stills fade into the same
        // tiles: even the answer this device kept arrives a moment after the sheet opens, and rows turning into tiles
        // then drew every tile at a row's width, shrinking, over the others.
        let tiles = !tmdb.episodeTiles(items).isEmpty || (tmdbPending(catalog) && items.count <= 60)
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
                    grid(items, tiles: tiles, labels: catalog.labels, details: catalog.details, current: current?.id)
                }
                .padding(16)
            }
            .onAppear { if let id = current?.id { proxy.scrollTo(id, anchor: .center) } }
            // The layout changed under the episode playing (TMDB had nothing to show): back to it.
            .onChange(of: tiles) { _, _ in if let id = current?.id { proxy.scrollTo(id, anchor: .center) } }
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

    /// TMDB hasn't answered yet, or is still looking: the first moment of every sheet for a title it may know.
    private func tmdbPending(_ catalog: PlaybackCatalog) -> Bool {
        tmdb.phase == .looking || (tmdb.phase == .idle && TMDBLookup.applies(to: catalog.client.site))
    }

    private func grid(_ items: [Episode], tiles showsStills: Bool, labels: [Episode.ID: String], details: [Episode.ID: String],
                      current: Episode.ID?) -> some View {
        let stills = tmdb.episodes(items)
        let titles = Dictionary(items.map { ($0.id, labels[$0.id] ?? EpisodeRow.title($0.name)) }, uniquingKeysWith: { first, _ in first })
        // 第1集, 01, 4K国语: small tiles. Longer titles: two-line cards. File names a card would cut short: a row
        // each, the whole name, because what tells two files of a film apart (HDR, the audio, the subtitles) is at the
        // end of the name, where a card's … was (#897).
        let short = (titles.values.map(\.count).max() ?? 0) <= 6
        let rows = !showsStills && !short && titles.contains { Self.overflowsCard($0.value, withDetail: details[$0.key] != nil) }
        let minimum: CGFloat = showsStills ? Self.stillTile : short ? Self.shortTile : Self.longTile
        let shown = reversesEpisodes ? items.reversed() : items
        let columns = rows ? [GridItem(.flexible(), alignment: .top)]
            : [GridItem(.adaptive(minimum: minimum), spacing: showsStills ? 12 : 8, alignment: .top)]
        return LazyVGrid(columns: columns, spacing: showsStills ? 14 : 8) {
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
                        TMDBEpisodeTile(name: title, info: stills[episode.id], detail: details[episode.id], current: isCurrent, loading: loading, width: nil,
                                        backdrops: tmdb.episodeBackdrops)
                    } else {
                        EpisodeCell(title: title, detail: details[episode.id], current: isCurrent, loading: loading, compact: short, whole: rows)
                    }
                }
                .buttonStyle(.plain)
                .id(episode.id)
                .accessibilityLabel(episode.name)
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
                .contextMenu { if labels[episode.id] != nil { Text(episode.name) } }
            }
        }
        // Tiles that turn into rows or cards change at once: morphing, each tile shrank or grew across the others.
        .animation(nil, value: showsStills)
    }

    #if os(macOS)
    private static let stillTile: CGFloat = 180, shortTile: CGFloat = 84, longTile: CGFloat = 220
    #else
    private static let stillTile: CGFloat = 160, shortTile: CGFloat = 76, longTile: CGFloat = 220
    #endif

    /// Whether a card at its narrowest shows less than the whole title: one line above the file's detail, two without
    /// it. A card's line holds about 26 Latin letters or digits, or 13 Chinese characters.
    static func overflowsCard(_ title: String, withDetail: Bool) -> Bool {
        title.unicodeScalars.reduce(0) { $0 + ($1.isASCII ? 1 : 2) } > (withDetail ? 26 : 52)
    }

    /// TMDB's details as the video's page has them: the answer this device kept, else the same lookup the page runs.
    private func lookUp() async {
        guard let catalog = store.catalog(for: playing) else { return }
        let site = catalog.client.site
        guard TMDBLookup.applies(to: site) else { return }
        let key = TMDBMatchStore.key(source: site.key, video: catalog.video.id)
        let request = TMDBMatch.Request(video: catalog.video, listVideo: catalog.video,
                                        source: TMDBMatch.SourceRef(key: site.key, name: site.name))
        guard !TMDBMatch.labeledNotOnTMDB(request) else { tmdb.skip(); return }
        await tmdb.run(key: key, request: request)
    }
}

/// An episode without TMDB's still: the page's tile (iPhone watch page), the one playing filled with the accent.
private struct EpisodeCell: View {
    let title: String
    /// Resolution and size from the file name (4K · 5.2G), under the title.
    let detail: String?
    let current: Bool
    let loading: Bool
    let compact: Bool
    /// A row of its own with the whole name, however many lines that takes (within reason), for file names.
    var whole = false
    /// A file name that wraps where its parts end. Left alone, Movie.2025.2160p.WEB-DL.H265 is one word that breaks
    /// only at its hyphen, leaving most of a line empty: a line may end after a dot or an underscore, and not at a hyphen.
    static func breakable(_ name: String) -> String {
        name.replacingOccurrences(of: ".", with: ".\u{200B}").replacingOccurrences(of: "_", with: "_\u{200B}")
            .replacingOccurrences(of: "-", with: "\u{2011}")
    }
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(spacing: 6) {
            if loading { ProgressView().appControlSize(.small) }
            VStack(alignment: compact ? .center : .leading, spacing: whole ? 3 : 1) {
                Text(whole ? Self.breakable(title) : title).lineLimit(whole ? 4 : compact || detail != nil ? 1 : 2)
                    .multilineTextAlignment(compact ? .center : .leading)
                    .fixedSize(horizontal: false, vertical: whole)
                if let detail { EpisodeFileDetail(text: detail) }
            }
        }
        .font(.subheadline.weight(current ? .semibold : .regular))
        .foregroundStyle(current ? Brand.onAccent : Color.primary)
        .tint(current ? Brand.onAccent : nil)
        .padding(.horizontal, compact ? 8 : 12).padding(.vertical, whole ? 10 : 0)
        .frame(maxWidth: .infinity, minHeight: compact ? 44 : 54, alignment: compact ? .center : .leading)
        .glassOrFill(current ? GlassStyle.regular.tint(Brand.accent).interactive() : .regular.interactive(),
                     current ? Brand.accent : Color.primary.opacity(0.06), in: shape)
        .contentShape(shape)
    }
}
#endif

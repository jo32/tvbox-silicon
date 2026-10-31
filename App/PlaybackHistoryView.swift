import SwiftUI
import TVCore

/// Watched titles, newest first: resume where you left off, or select titles to remove.
struct PlaybackHistoryView: View {
    @Environment(Store.self) private var store
    @State private var query = ""
    @State private var managing = false
    @State private var selected = Set<String>()
    @State private var confirmsDelete = false
    @State private var deletionIDs = Set<String>()
    private var history: PlaybackHistory { store.playbackHistory }
    private var entries: [PlaybackHistoryEntry] {
        history.entries.filter { query.isEmpty || $0.context.videoName.localizedCaseInsensitiveContains(query) || $0.context.sourceName.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        Group {
            if history.entries.isEmpty {
                EmptyPage(symbol: AppSection.history.icon, title: L10n.text("No Playback History Yet"),
                          message: L10n.text("Videos you watch appear here, ready to pick up where you left off."),
                          action: L10n.text("Browse Sources"), actionSymbol: AppSection.sites.icon, perform: { store.section = .sites })
            } else {
                content.catalogSearchable(text: $query, prompt: L10n.text("Search history"))
            }
        }
        .screenBackdrop()
        .historyDetailsDestination()
        .tabTitle(L10n.text("Playback History"))
        .onChange(of: history.entries.isEmpty) { _, empty in if empty { managing = false; selected.removeAll() } }
        // Leaving the page gives up a title still being prepared.
        .onDisappear { if store.playing == nil { store.cancelResume() } }
        .confirmationDialog(L10n.text("Remove selected history and its cached content?"), isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button(L10n.text("Remove from history"), role: .destructive) {
                history.remove(deletionIDs); selected.subtract(deletionIDs); deletionIDs.removeAll()
            }
            .accessibilityIdentifier("history.confirmDelete")
        } message: {
            Text(L10n.text("Removing a title also clears its cached content and skip times."))
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.headerSpacing) {
                if let error = history.persistenceError {
                    StatusNotice(text: L10n.text("Unable to save playback history: %@", error))
                }
                header
                LazyVGrid(columns: Layout.posterColumns, spacing: Layout.gridRowSpacing) {
                    ForEach(entries) { entry in
                        HistoryCard(entry: entry, selection: managing ? selected.contains(entry.id) : nil, details: true,
                                    action: managing ? { tap(entry) } : nil)
                    }
                }
                .tvFocusSection()
            }
            .pageContainer()
        }
    }

    /// Count and actions on one line, or actions under the count when a phone is too narrow;
    /// managing swaps them for selection actions.
    private var header: some View {
        let title = SectionHeader(title: L10n.text("%lld titles", entries.count))
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                title
                Spacer(minLength: 12)
                actions
            }
            VStack(alignment: .leading, spacing: 12) {
                title
                HStack(spacing: 10) { actions }
            }
        }
        .tvFocusSection()
    }

    @ViewBuilder private var actions: some View {
            if managing {
                Button(L10n.text("Select all")) { selected = Set(entries.map(\.id)) }
                    .controlButton().accessibilityIdentifier("history.selectAll")
                Button { deletionIDs = selected; confirmsDelete = true } label: {
                    Label(L10n.text("Delete selected (%lld)", selected.count), systemImage: "trash").lineLimit(1).fixedSize()
                }
                .controlButton().disabled(selected.isEmpty).accessibilityIdentifier("history.deleteSelected")
                Button(L10n.text("Done")) { managing = false; selected.removeAll() }
                    .controlButton(prominent: true).accessibilityIdentifier("history.manage")
            } else {
                Button { managing = true } label: {
                    Label(L10n.text("Manage history"), systemImage: "checklist").lineLimit(1).fixedSize()
                }
                .controlButton().accessibilityIdentifier("history.manage")
                Button { deletionIDs = Set(history.entries.map(\.id)); confirmsDelete = true } label: {
                    Label(L10n.text("Clear history"), systemImage: "trash").lineLimit(1).fixedSize()
                }
                .controlButton()
            }
    }

    /// Selects or deselects while managing; otherwise the card resumes the title itself.
    private func tap(_ entry: PlaybackHistoryEntry) {
        if selected.contains(entry.id) { selected.remove(entry.id) } else { selected.insert(entry.id) }
    }
}

enum HistoryMetrics {
    /// Continue Watching card width on Watch Now; the History page lets the grid size its cards.
    #if os(tvOS)
    static let card: CGFloat = 240
    #elseif os(macOS)
    static let card: CGFloat = 150
    #else
    static let card: CGFloat = 120
    #endif
}

enum HistoryFormat {
    static func status(_ entry: PlaybackHistoryEntry) -> String {
        entry.completed ? L10n.text("Finished · Watch again") : L10n.text("Continue from %@", EpisodeSkipSettings.formatTime(entry.position))
    }
}

/// A watched title as a poster card, with progress along the poster's foot. Continue Watching shows
/// the episode; the History page (`details`) adds the source and where playback resumes.
struct HistoryCard: View {
    @Environment(Store.self) private var store
    @Environment(\.stripDrag) private var drag
    @Environment(\.openHistoryDetails) private var openDetails
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
    let entry: PlaybackHistoryEntry
    /// Whether the card is selected while managing history; nil outside managing.
    var selection: Bool? = nil
    var details = false
    /// Replaces resuming, for managing.
    var action: (() -> Void)? = nil
    @State private var hovering = false
    /// Touch has no hover, so the empty heart stays available there. The remote cannot press a heart on a card (the
    /// card's menu has Like), so Apple TV shows only a saved one.
    private var heartRevealed: Bool {
        #if os(macOS)
        hovering
        #elseif os(tvOS)
        false
        #else
        true
        #endif
    }
    var body: some View {
        // The heart is a sibling of the poster button, so a click does not resume or change the selection.
        ZStack(alignment: .topLeading) {
            posterButton
            FavoriteHeartButton(item: entry.favoriteItem(), name: entry.context.videoName, onArtwork: true, revealed: heartRevealed)
                .fixedSize()
                .padding(8)
                .allowsHitTesting(drag?.active != true)
        }
        #if !os(tvOS)
        // The menu lifts the whole card. Lifted from the poster alone, it left the heart drawn above
        // the poster behind: alone over the hole for a moment, then gone under the blur, a flicker.
        .contextMenu { menu }
        #endif
        .overlay(alignment: .topTrailing) {
            if selection == nil, hovering {
                HStack(spacing: 6) {
                    if let details = detailsRoute { detailsButton(details) }
                    historyRemove
                }
                    .padding(8)
                    .transition(.opacity)
            }
        }
        #if !os(tvOS)
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.15), value: hovering)
        #endif
    }

    /// Remove control, rose under the pointer. A pointer shows it; the context menu stays for touch and the remote.
    private var historyRemove: some View {
        ArtworkBadgeButton(symbol: "xmark", label: L10n.text("Remove from history"), destructive: true) {
            guard drag?.active != true else { return }
            store.playbackHistory.remove(entry.id)
        }
        .allowsHitTesting(drag?.active != true)
    }

    /// Opens the title's page, with its episodes, instead of resuming it. A pointer shows it; the context menu has it too.
    private func detailsButton(_ route: Route) -> some View {
        ArtworkBadgeButton(symbol: "info", label: L10n.text("Show Details")) {
            guard drag?.active != true else { return }
            openDetails?(route)
        }
        .allowsHitTesting(drag?.active != true)
    }

    /// The title's page, where a tap on the card only resumes it. None on an iPhone, where the tap opens that page.
    private var detailsRoute: Route? {
        guard action == nil, openDetails != nil, let client = store.historyClient(entry) else { return nil }
        #if os(iOS)
        if WatchPage.applies(horizontalSizeClass, verticalSizeClass) { return nil }
        #endif
        let video = entry.listVideo
        return Route { AnyView(VideoDetailView(video: video, client: client)) }
    }

    private var posterButton: some View {
        Group {
            #if os(iOS)
            // On an iPhone the title's watch page opens and resumes it at the top (`VideoDetailView`).
            if action == nil, WatchPage.applies(horizontalSizeClass, verticalSizeClass), let client = store.historyClient(entry) {
                NavigationLink(value: Route { AnyView(VideoDetailView(video: entry.listVideo, client: client, resume: entry)) }) { cardLabel }
                    .cardButton()
            } else {
                resumeButton
            }
            #else
            resumeButton
            #endif
        }
        .accessibilityAddTraits(selection == true ? [.isSelected] : [])
        .accessibilityIdentifier((selection != nil ? "history.select." : "history.resume.") + entry.context.videoID)
        #if os(tvOS)
        // The remote opens a menu on the focused button, so it stays here.
        .contextMenu { menu }
        #endif
    }

    private var resumeButton: some View {
        Button {
            guard drag?.active != true else { return }
            if let action { action() } else { store.resume(entry) }
        } label: { cardLabel }
        .cardButton()
    }

    private var cardLabel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear.aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay { PosterImage(url: entry.context.poster, headers: entry.context.posterHeaders ?? [:]) }
                .coverOverlay(alignment: .bottom) {
                    if entry.duration > 0 {
                        // White on the artwork, as in the TV app: the accent is near-black in light mode.
                        GeometryReader { proxy in
                            Capsule().fill(.white.opacity(0.25))
                                .overlay(alignment: .leading) { Capsule().fill(.white).frame(width: proxy.size.width * entry.progress) }
                        }
                        .frame(height: 5).padding(10)
                    }
                }
                .coverOverlay(alignment: .topTrailing) {
                    if let selection {
                        Image(systemName: selection ? "checkmark.circle.fill" : "circle")
                            .font(.title2).symbolRenderingMode(.palette)
                            .foregroundStyle(selection ? Brand.onAccent : .white, selection ? Brand.accent : .black.opacity(0.35))
                            .contentTransition(.symbolEffect(.replace))
                            .padding(8)
                    }
                }
                .coverOverlay(animated: true) {
                    // Preparing this title; choosing another card switches to that one.
                    if store.resumingHistoryID == entry.id {
                        ZStack {
                            Color.black.opacity(0.5)
                            ProgressView().controlSize(.large).tint(.white)
                        }
                    }
                }
                .posterClip(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .opacity(selection == false ? 0.6 : 1)
            Text(entry.context.videoName).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                .cardCaption()
            if details {
                Text("\(entry.context.episodeName) · \(SourceLabel(entry.context.sourceName).text)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).cardCaption()
                Text(HistoryFormat.status(entry)).font(.caption).monospacedDigit().foregroundStyle(.tertiary).lineLimit(1)
                    .cardCaption()
            } else {
                // The bar on the poster already says how far; the line names the episode.
                Text(entry.context.episodeName).font(.caption).foregroundStyle(.secondary).lineLimit(1).cardCaption()
            }
        }
        .frame(width: details ? nil : HistoryMetrics.card)
        .frame(maxWidth: details ? .infinity : nil, alignment: .leading)
    }

    @ViewBuilder private var menu: some View {
        if let details = detailsRoute {
            Button(L10n.text("Show Details"), systemImage: "info.circle") { openDetails?(details) }
        }
        FavoriteMenuButton(item: entry.favoriteItem(), name: entry.context.videoName)
        Button(L10n.text("Remove from history"), systemImage: "trash", role: .destructive) { store.playbackHistory.remove(entry.id) }
    }
}

extension EnvironmentValues { @Entry var openHistoryDetails: ((Route) -> Void)? = nil }

extension View {
    /// Lets the history cards under it open a title's page (`HistoryCard.detailsRoute`). Outside the cards' lazy grids:
    /// a navigation destination inside a lazy container is not supported.
    func historyDetailsDestination() -> some View { modifier(HistoryDetailsDestination()) }
}

private struct HistoryDetailsDestination: ViewModifier {
    @Environment(\.openRoute) private var openRoute
    @State private var route: Route?
    func body(content: Content) -> some View {
        content
            .environment(\.openHistoryDetails) { if let openRoute { openRoute($0) } else { route = $0 } }
            .navigationDestination(item: $route) { route in
                #if os(macOS)
                route.build().musicBar()
                #else
                route.build()
                #endif
            }
    }
}

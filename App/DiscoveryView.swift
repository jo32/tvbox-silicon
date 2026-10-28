import SwiftUI
import TVCore

private struct SearchSourceItem: Identifiable {
    let id: String
    let name: String
    var count: Int? = nil
    /// A source that is slow or failing lately; see `SourceHealth`.
    var dot: Color? = nil
}

private struct SearchPoster: Identifiable {
    let site: Site
    let video: Video
    var id: String { "\(site.id.utf8.count):\(site.id)\(video.id)" }
}

struct GlobalSearchView: View {
    @Environment(Store.self) private var store
    @FocusState private var inputFocused: Bool
    @State private var showFailures = false
    /// The sources being searched right now, under the summary; folded away unless asked for.
    @AppStorage("searchShowsActivity") private var showsActivity = false
    /// Whether the end of the results is on screen, so finished pages can ask for the next.
    @State private var endVisible = false
    @AppStorage("videoSearchHistory") private var historyData = Data()
    #if os(tvOS)
    /// Titles iQiyi suggests for the draft, and 360kan's chart for an empty field (`SearchSuggestions`).
    @State private var suggested: [String] = []
    @State private var trending: [String] = []
    #endif
    private var model: SearchModel { store.searchModel }
    private var history: [String] { (try? JSONDecoder().decode([String].self, from: historyData)) ?? [] }
    /// First pages in source order, then later pages as they arrive, so loading more only adds at the end.
    private var posters: [SearchPoster] {
        let shown = model.matches.filter { model.selectedSource == nil || $0.id == model.selectedSource }
        let sites = Dictionary(shown.map { ($0.id, $0.site) }) { first, _ in first }
        var seen = Set<String>()
        let first = shown.flatMap { result in (result.page?.videos ?? []).map { SearchPoster(site: result.site, video: $0) } }
        let later = model.batches.flatMap { batch in sites[batch.source].map { site in batch.videos.map { SearchPoster(site: site, video: $0) } } ?? [] }
        return (first + later).filter { seen.insert($0.id).inserted }
    }
    /// Built-in sources can be selected while their first search is still in flight. One the viewer
    /// hid, or one paused for failing, isn't asked and gets no chip.
    private var sourceItems: [SearchSourceItem] {
        let builtins = Site.builtInSites.filter { site in
            model.total > 0 && (model.results.contains { $0.site.key == site.key } ||
                (model.busy && model.asking.contains(site.key)))
        }.map { site in
            SearchSourceItem(id: site.key, name: site.name,
                             count: model.results.contains { $0.site.key == site.key } ? uniqueVideos(model.videos(for: site.key)).count : nil)
        }
        return [.init(id: "", name: L10n.text("All Sources"), count: model.videoCount)]
            + builtins
            + model.matches.filter { !$0.site.isBuiltIn }.map { .init(id: $0.id, name: $0.site.name, count: uniqueVideos(model.videos(for: $0.id)).count,
                                                                       dot: store.health(of: $0.site).warning) }
    }

    var body: some View {
        @Bindable var model = model
        #if os(tvOS)
        searchResults
            .searchable(text: $model.draft, prompt: Text(L10n.text("Search videos")))
            .searchSuggestions {
                // Past searches first, then titles for what is typed: a remote spells "xyj" and picks 西游记, as on
                // FongMi's TV search. A completion only fills the field; the Search button below still starts the search.
                let past = Array(history.filter { model.draft.isEmpty || $0.localizedCaseInsensitiveContains(model.draft) }.prefix(6))
                ForEach(past + (model.draft.isEmpty ? trending : suggested).filter { !past.contains($0) }, id: \.self) { query in
                    Text(query).searchCompletion(query)
                }
            }
            .task(id: model.draft) { await suggest(model.draft) }
            .onSubmit(of: .search) { if let config = store.subscription { submit(config) } }
            .screenBackdrop()
            .sheet(isPresented: $showFailures) { failureDetails }
            .onAppear { if let config = store.subscription { model.resumeSuspended(config: config) } }
            .onDisappear { endVisible = false; model.suspend() }
        #else
        searchResults
            .scrollPosition(id: $model.scrollID)
            // A hard edge: the summary, the activity and the source chips are a tall bar, and results showed through it.
            .topBar(hardEdge: true) { if let config = store.subscription, showsHeader { searchHeader(config) } }
            .screenBackdrop()
            .screenTitle(L10n.text("Global Search"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            // The system search field, as on Sources and Live TV: under the title on iPhone and iPad, in the toolbar on
            // the Mac. Only Return or the keyboard's Search key searches; clearing the field goes back to the recent searches.
            .catalogSearchable(text: $model.draft, prompt: L10n.text("Search videos"))
            .searchFieldFocused($inputFocused)
            .onSubmit(of: .search) { if let config = store.subscription { submit(config) } }
            .onChange(of: model.draft) { _, draft in if draft.isEmpty && !model.keyword.isEmpty { model.reset() } }
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .sheet(isPresented: $showFailures) { failureDetails }
            .onAppear {
                // Not on iPhone and iPad: the keyboard would cover the tab bar, and a tab's root page has no back
                // button, so there would be no way to leave without searching.
                #if os(macOS)
                if model.keyword.isEmpty { inputFocused = true }
                #endif
                if let config = store.subscription { model.resumeSuspended(config: config) }
            }
            .onDisappear { endVisible = false; model.suspend() }
            #if DEBUG
            // `-qaSection search -qaQuery <text>` searches once the subscription has loaded, for screenshots.
            .task(id: store.subscription?.origin) {
                guard QALaunch.section == .search, model.keyword.isEmpty, let config = store.subscription,
                      let text = UserDefaults.standard.string(forKey: "qaQuery") else { return }
                model.draft = text; submit(config)
            }
            #endif
        #endif
    }

    /// The search field is the system's, so the bar below it waits for a search.
    private var showsHeader: Bool { !model.keyword.isEmpty }

    private var searchResults: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                #if os(tvOS)
                // Editing, dictation and search completions only update the draft. The remote
                // needs an explicit, focusable submit action before starting expensive plugins.
                if let config = store.subscription {
                    let query = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !query.isEmpty, query != model.keyword {
                        SearchQueryButton(query: query) { submit(config) }.accessibilityIdentifier("search.submit")
                    }
                    if !model.keyword.isEmpty {
                        searchHeader(config).padding(.horizontal, -Layout.gutter)
                    }
                }
                #endif
                if let config = store.subscription {
                    if model.keyword.isEmpty { idle.frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity) }
                    else {
                        if model.total == 0 {
                            ContentUnavailableView(L10n.text("No searchable sources are available on this device."), systemImage: "magnifyingglass")
                        } else if posters.isEmpty {
                            if model.busy {
                                VStack(spacing: 18) {
                                    ProgressView()
                                    Text(L10n.text("Searching for “%@”…", model.keyword)).font(.title3.weight(.semibold))
                                    Text(L10n.text("Results appear as each source responds.")).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity).padding(.vertical, 70)
                            } else {
                                emptyResults(config)
                            }
                        } else {
                            LazyVGrid(columns: Layout.posterColumns, spacing: Layout.gridRowSpacing) {
                                resultLinks(config)
                            }.scrollTargetLayout()
                            // Scrolling the end into view asks for the next page; while it stays in view each new page asks again.
                            if model.canLoadMore(model.selectedSource) || model.loadingMore {
                                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
                                    .onScrolledIntoView(threshold: 0.2) { visible in
                                        endVisible = visible
                                        if visible { model.loadMore(model.selectedSource, config: config) }
                                    }
                                    .onChange(of: model.loadingMore) { _, loading in
                                        if !loading, endVisible { model.loadMore(model.selectedSource, config: config) }
                                    }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView(L10n.text("No Sources Yet"), systemImage: "magnifyingglass", description: Text(L10n.text("Add a TVBox subscription in Settings.")))
                }
            }.pageContainer()
        }
    }

    /// Separates "nothing matched" from "most sources never answered" so the empty state does not blame the keyword.
    private func emptyResults(_ config: Subscription) -> some View {
        let mostlyFailed = model.failures.count * 2 > model.completed
        return ContentUnavailableView {
            Label(L10n.text(mostlyFailed ? "Most Sources Unavailable" : "No Videos"),
                  systemImage: mostlyFailed ? "wifi.exclamationmark" : "magnifyingglass")
        } description: {
            Text(mostlyFailed
                 ? L10n.text("%lld of %lld sources didn't respond, so results may be incomplete.", model.failures.count, model.total)
                 : L10n.text("Try another keyword."))
        } actions: {
            if !model.failures.isEmpty || !model.paused.isEmpty {
                HStack(spacing: 16) {
                    Button(L10n.text("Retry failed sources")) { model.resume(config: config, retryFailures: true) }
                        .controlButton(prominent: true)
                    Button(L10n.text("Show Details")) { showFailures = true }.controlButton()
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 420)
    }

    private func searchHeader(_ config: Subscription) -> some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 14) {
            if !model.keyword.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 16) {
                        searchSummary
                        Spacer(minLength: 16)
                        searchActions(config)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        searchSummary
                        searchActions(config)
                    }
                }
                #if os(tvOS)
                // Stop and the unavailable sources sit at the row's far end, out of line with the suggestions above and
                // the source chips below, so the remote passed them by. As a section, moving onto the row lands on them.
                .focusSection()
                #endif
                if model.busy {
                    SearchActivityList(origin: config.origin, completed: model.completed, total: model.total, runStart: model.runStart,
                                       showsSources: showsActivity)
                        .transition(.opacity)
                }
                if sourceItems.count > 1 {
                    #if os(tvOS)
                    ChipRow {
                        HStack(spacing: 8) {
                            ForEach(sourceItems) { item in
                                Chip(title: item.count.map { "\(item.name) · \($0)" } ?? item.name, selected: (model.selectedSource ?? "") == item.id,
                                     mark: item.id == Bilibili.siteKey, dot: item.dot) {
                                    model.select(item.id.isEmpty ? nil : item.id)
                                }
                            }
                        }
                    }
                    #else
                    SourceStrip(items: sourceItems.map { .init(id: $0.id, name: $0.name, count: $0.count, dot: $0.dot) }, selection: model.selectedSource ?? "") { id in
                        model.select(id.isEmpty ? nil : id)
                    }
                    #endif
                }
            }
        }
        .frame(maxWidth: model.keyword.isEmpty ? 760 : Layout.maxWidth - Layout.gutter * 2)
        .frame(maxWidth: .infinity)
        #if os(iOS)
        // Right under the search bar, which has its own margin.
        .padding(.horizontal, Layout.gutter).padding(.top, 6).padding(.bottom, 12)
        #elseif os(macOS)
        .padding(.horizontal, Layout.gutter).padding(.vertical, 10)
        #else
        .padding(.horizontal, Layout.gutter).padding(.vertical, 16)
        #endif
    }

    private var searchSummary: some View {
        // A spinner has no text baseline, so it centers on the row; only the two labels share a baseline.
        HStack(alignment: .center, spacing: 12) {
            #if !os(iOS)
            if model.busy { ProgressView().controlSize(.small) }
            #endif
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(L10n.text("%lld results", model.videoCount)).font(.headline)
                Text(summaryDetail)
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .monospacedDigit()
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Failed sources count as "completed", so once the search ends report how many actually answered.
    private var summaryDetail: String {
        if model.stopped { return L10n.text("Search paused") }
        if model.busy || model.failures.isEmpty { return L10n.text("Searched %lld of %lld sources", model.completed, model.total) }
        return L10n.text("%lld of %lld sources responded", model.completed - model.failures.count, model.total)
    }

    /// Always one row. Stacking them here let the summary keep them beside it on a phone, as a lopsided
    /// column; too narrow a row now moves the whole row under the summary instead.
    private func searchActions(_ config: Subscription) -> some View {
        HStack(spacing: 8) { searchActionButtons(config) }.fixedSize()
    }

    /// tvOS pills lead with a symbol, as the search pill does; elsewhere the title stands alone.
    @ViewBuilder private func searchActionLabel(_ title: String, symbol: String) -> some View {
        #if os(tvOS)
        Label(title, systemImage: symbol)
        #else
        Text(title)
        #endif
    }

    @ViewBuilder private func searchActionButtons(_ config: Subscription) -> some View {
        if model.busy {
            Button { model.stop() } label: { searchActionLabel(L10n.text("Stop"), symbol: "stop.fill") }.searchAction()
            let title = L10n.text(showsActivity ? "Hide Details" : "Show Details")
            Button { withAnimation(.smooth(duration: 0.25)) { showsActivity.toggle() } } label: {
                Image(systemName: "chevron.down").font(.footnote.weight(.semibold))
                    .rotationEffect(.degrees(showsActivity ? 180 : 0))
            }
            .searchAction()
            .accessibilityLabel(title).help(title)
        } else if model.completed < model.total {
            Button { model.resume(config: config) } label: { searchActionLabel(L10n.text("Continue search"), symbol: "arrow.clockwise") }.searchAction()
        }
        if !model.failures.isEmpty || !model.paused.isEmpty {
            Button { showFailures = true } label: {
                Label {
                    Text(L10n.text("%lld unavailable", model.failures.count + model.paused.count))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Brand.amber)
                }
            }.searchAction()
        }
    }

    @ViewBuilder private func resultLinks(_ config: Subscription) -> some View {
        ForEach(posters) { item in
            RouteLink {
                VideoDetailView(video: item.video, client: CatalogClient(site: item.site, origin: config.origin, jarURL: config.spiderURL))
                    .onAppear { rememberQuery() }
            } label: { searchPoster(item) }
            .cardButton().id(item.id)
        }
    }

    private func searchPoster(_ item: SearchPoster) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            PosterCard(video: item.video)
            Text(SourceLabel(item.site.name).text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: idleSpacing) {
            #if os(tvOS)
            Text(L10n.text("Search all available sources in your subscription.")).font(.body).foregroundStyle(.secondary)
            if !history.isEmpty {
                HStack {
                    Text(L10n.text("Recent Searches")).font(.headline)
                    Spacer()
                    Button(L10n.text("Clear")) { historyData = Data() }.controlButton()
                }
            }
            #else
            if history.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "magnifyingglass").font(.system(size: 44, weight: .light)).foregroundStyle(.tertiary)
                    Text(L10n.text("Search all available sources in your subscription.")).font(.title3.weight(.medium)).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.top, 80)
            } else {
                HStack {
                    Text(L10n.text("Recent Searches")).font(.title3.weight(.bold))
                    Spacer()
                    Button(L10n.text("Clear")) { historyData = Data() }.buttonStyle(.plain).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).frame(minHeight: 44)
                }
                VStack(spacing: 0) {
                    ForEach(Array(history.enumerated()), id: \.element) { index, item in
                        HStack(spacing: 0) {
                            Button { useHistory(item) } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "clock.arrow.circlepath").font(.body).foregroundStyle(.secondary).frame(width: 24)
                                    Text(item).font(.body).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.leading, 18).frame(minHeight: 48).frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Button { removeSearch(item) } label: {
                                Image(systemName: "xmark").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                                    .frame(width: 36, height: 48)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L10n.text("Remove"))
                            Button { useHistory(item) } label: {
                                Image(systemName: "arrow.up.left").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                                    .padding(.trailing, 18).frame(height: 48)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                        if index < history.count - 1 { Divider().padding(.leading, 56) }
                    }
                }
                .glassSurface(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            #endif
        }
    }

    private var idleSpacing: CGFloat {
        #if os(tvOS)
        22
        #else
        8
        #endif
    }

    private func pauseNote(_ site: Site) -> String {
        guard let until = store.subscription.flatMap({ SourceHealth.shared.pausedUntil(site, origin: $0.origin) }) else {
            return L10n.text("Skipped after repeated failures")
        }
        return L10n.text("Skipped after repeated failures; back in search at %@", until.formatted(date: .omitted, time: .shortened))
    }

    private var failureDetails: some View {
        NavigationStack {
            List {
                ForEach(model.failures) { result in
                    VStack(alignment: .leading, spacing: 6) {
                        let health = store.health(of: result.site)
                        HStack(spacing: 6) { Text(result.site.name).font(.headline); SourceHealthDot(status: health) }
                        Text(result.error ?? "").font(.caption).foregroundStyle(.secondary)
                        if health == .failing { Text(health.summary).font(.caption).foregroundStyle(Brand.rose) }
                    }
                }
                // Sources this search left out for failing; the retry below asks them too.
                ForEach(model.paused) { site in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) { Text(site.name).font(.headline); SourceHealthDot(status: .failing) }
                        Text(pauseNote(site)).font(.caption).foregroundStyle(Brand.rose)
                    }
                }
            }
            .screenTitle(L10n.text("Unavailable Sources"))
            .screenBackdrop()
            #if os(tvOS)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button(L10n.text("Retry failed sources")) {
                        if let config = store.subscription { model.resume(config: config, retryFailures: true) }
                        showFailures = false
                    }.controlButton(prominent: true).disabled(model.busy || (model.failures.isEmpty && model.paused.isEmpty))
                    Spacer()
                    Button(L10n.text("Done")) { showFailures = false }.controlButton()
                }.padding(32).controlBackdrop()
            }
            #else
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { showFailures = false } }
                ToolbarItem(placement: .primaryAction) {
                    Button(L10n.text("Retry failed sources")) {
                        if let config = store.subscription { model.resume(config: config, retryFailures: true) }
                        showFailures = false
                    }.disabled(model.busy || (model.failures.isEmpty && model.paused.isEmpty))
                }
            }
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 380)
        #elseif os(tvOS)
        .frame(width: 1000, height: 650)
        #endif
    }

    private func useHistory(_ item: String) {
        model.draft = item
        if let config = store.subscription { submit(config) }
    }

    private func removeSearch(_ item: String) {
        historyData = (try? JSONEncoder().encode(history.filter { $0 != item })) ?? historyData
    }

    private func rememberQuery(_ query: String? = nil) {
        let keyword = query ?? model.keyword
        guard !keyword.isEmpty else { return }
        historyData = (try? JSONEncoder().encode(Array(([keyword] + history.filter { $0 != keyword }).prefix(20)))) ?? Data()
    }

    #if os(tvOS)
    /// A quarter second after typing stops, so a word spelled out key by key on the remote asks once; a newer draft
    /// cancels the wait and the answer.
    private func suggest(_ draft: String) async {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else {
            suggested = []
            if trending.isEmpty { trending = await SearchSuggestions.trending() }
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let titles = await SearchSuggestions.titles(for: typed)
        if !Task.isCancelled { suggested = titles }
    }
    #endif

    private func submit(_ config: Subscription) {
        let keyword = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        rememberQuery(keyword)
        inputFocused = false
        model.search(keyword, config: config) { [store] site in
            store.hiddenSources.contains(site, origin: config.origin)
        }
    }
}
/// What a running search is doing: overall progress, a time estimate, and one row per plugin
/// source in flight. A first search can spend minutes building plugin components, and the
/// summary count alone looks stuck.
private struct SearchActivityList: View {
    let origin: URL
    let completed: Int
    let total: Int
    let runStart: (date: Date, completed: Int)?
    /// The progress bar always shows; the sources being searched fold behind the chevron.
    let showsSources: Bool
    /// The on-device plugin worker runs at most this many searches at once.
    private let limit = 5
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
            let active = Array(PluginPreparation.active(origin: origin).prefix(limit))
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    ProgressView(value: Double(completed), total: Double(max(total, 1)))
                        .progressViewStyle(.linear).tint(Brand.accent)
                    if let remaining = remaining(at: timeline.date) {
                        Text(remaining).foregroundStyle(.secondary).monospacedDigit().fixedSize()
                    }
                    if let runStart {
                        Text(Duration.seconds(max(0, Int(timeline.date.timeIntervalSince(runStart.date))))
                                .formatted(.time(pattern: .minuteSecond)))
                            .foregroundStyle(.secondary).monospacedDigit().fixedSize()
                    }
                }
                if active.contains(where: { $0.snapshot.stage == .converting || $0.snapshot.converted > 0 }) {
                    Label(L10n.text("Preparing plugins for first use. Later searches are much faster."), systemImage: "hourglass")
                        .foregroundStyle(.secondary)
                }
                if showsSources {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        ForEach(active) { item in
                            GridRow {
                                Text(item.name).fontWeight(.semibold).lineLimit(1)
                                Text(status(item.snapshot)).foregroundStyle(.secondary).lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(Duration.seconds(max(0, Int(timeline.date.timeIntervalSince(item.snapshot.started))))
                                        .formatted(.time(pattern: .minuteSecond)))
                                    .monospacedDigit().foregroundStyle(.secondary)
                                    .gridColumnAlignment(.trailing)
                            }
                        }
                    }
                    .transition(.opacity)
                }
            }
            .font(.subheadline)
            .accessibilityElement(children: .combine)
            .animation(.smooth(duration: 0.25), value: active.map(\.id))
        }
    }
    /// While searching, the plugin's "loading" stage is the search itself.
    private func status(_ snapshot: PluginPreparation.Snapshot) -> String {
        let title = snapshot.stage == .loading ? L10n.text("Searching…") : snapshot.stage.title
        return snapshot.detail.map { "\(title) · \($0)" } ?? title
    }
    /// Extrapolates this run's finishing rate; hidden until a few sources have answered.
    private func remaining(at now: Date) -> String? {
        guard let runStart, total > completed else { return nil }
        let done = completed - runStart.completed
        let elapsed = now.timeIntervalSince(runStart.date)
        guard done >= 3, elapsed >= 20 else { return nil }
        let minutes = Int((elapsed / Double(done) * Double(total - completed) / 60).rounded(.up))
        return minutes <= 1 ? L10n.text("Less than a minute left") : L10n.text("About %lld min left", minutes)
    }
}

#if !os(tvOS)
private struct QuietPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12).frame(height: SourceStrip.controlSize - 2)
            .background(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07), in: Capsule())
            .contentShape(Capsule())
    }
}
#endif

private extension View {
    @ViewBuilder func searchAction() -> some View {
        #if os(tvOS)
        glassPill()
        #else
        buttonStyle(QuietPillStyle())
        #endif
    }
}

private func uniqueVideos(_ videos: [Video]) -> [Video] {
    var seen = Set<String>()
    return videos.filter { seen.insert($0.id).inserted }
}

struct RecommendationsView: View {
    @Environment(Store.self) private var store
    @Environment(\.openRoute) private var openRoute
    let config: Subscription
    var fixedSite: Site? = nil
    @AppStorage("recommendationSource") private var sourceKey = ""
    @State private var revision = 0
    @State private var forceRefresh = false
    @State private var choosingSource = false
    /// A source's page opened from its long-press menu, outside a stack that takes `openRoute`.
    @State private var openedSource: Route?
    #if os(tvOS)
    @FocusState private var focusedSource: String?
    /// The long-press action chosen in the source picker, run once its sheet has closed.
    @State private var afterPicker: (() -> Void)?
    #endif
    /// The source category shown instead of its recommendations; nil shows the recommendations.
    @State private var category: String?
    @State private var categoryPage = 1
    /// The source `category` belongs to. A source change clears it inside the load task, which is the last writer.
    @State private var categorySite: String?
    @State private var browser = CatalogBrowser()
    private var model: RecommendationModel { store.recommendationModel }
    private var sites: [Site] { fixedSite.map { [$0] } ?? store.recommendationSites(config) }
    /// Until the user picks a source, default to the first in strategy order, so opening the app
    /// does not start the JVM when a standard API or script source is available. A source paused for
    /// failing (`SourceHealth.paused`) is passed over unless it is the viewer's pick.
    private var site: Site? {
        sites.first(where: { $0.key == sourceKey })
            ?? sites.first(where: { !SourceHealth.shared.paused($0, origin: config.origin) }) ?? sites.first
    }
    private var requestID: String { "\(config.origin)|\(config.importedAt)|\(site?.key ?? "")|\(revision)" }

    private var recommendationControls: some View {
        HStack(spacing: 12) {
            if let site {
                if fixedSite == nil {
                #if os(tvOS)
                Button { choosingSource = true } label: {
                    Label(site.name, systemImage: "chevron.down")
                        .lineLimit(1)
                }
                .glassPill()
                .accessibilityLabel(L10n.text("Recommendation Source"))
                .contextMenu { sourceActions(site) }
                .sheet(isPresented: $choosingSource, onDismiss: { afterPicker?(); afterPicker = nil }) {
                    NavigationStack {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 4) {
                                    ForEach(sites) { candidate in
                                        Button {
                                            // Leaving this source drops its open category before the new home loads.
                                            category = nil
                                            categoryPage = 1
                                            sourceKey = candidate.key
                                            revision = 0
                                            forceRefresh = false
                                            choosingSource = false
                                        } label: {
                                            HStack {
                                                Text(candidate.name).lineLimit(1)
                                                Spacer()
                                                if candidate.key == site.key { Image(systemName: "checkmark").foregroundStyle(Brand.accent) }
                                            }
                                            .frame(maxWidth: .infinity)
                                        }
                                        .glassRow()
                                        .contextMenu { sourceActions(candidate) { afterPicker = $0; choosingSource = false } }
                                        .focused($focusedSource, equals: candidate.key)
                                        .id(candidate.key)
                                    }
                                }
                                .glassRowInsets()
                            }
                            // Open on the current source rather than the top of a long list.
                            .defaultFocus($focusedSource, site.key)
                            .onAppear { proxy.scrollTo(site.key, anchor: .center) }
                        }
                        .screenTitle(L10n.text("Recommendation Source"))
                        .screenBackdrop()
                    }
                    .frame(width: 1000, height: 700)
                    .onExitCommand { choosingSource = false }
                }
                #endif
                }
                Spacer(minLength: 0)
                #if os(tvOS)
                Button { forceRefresh = true; revision += 1 } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .glassPill()
                .disabled(model.busy).accessibilityLabel(L10n.text("Refresh"))
                #else
                Button { forceRefresh = true; revision += 1 } label: {
                    ZStack {
                        Circle().fill(Color.primary.opacity(0.06))
                        if model.busy {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: SourceStrip.controlSize, height: SourceStrip.controlSize)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(model.busy)
                .accessibilityLabel(L10n.text(model.busy ? "Loading…" : "Refresh"))
                .help(L10n.text("Refresh"))
                #endif
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            #if os(tvOS)
            recommendationControls.tvFocusSection()
            #else
            if fixedSite == nil, let site, sites.count > 1 {
                HStack(spacing: 10) {
                    SourceStrip(items: sites.map { .init(id: $0.key, name: $0.name) }, selection: site.key) { key in
                        // Clear before the key changes. The load task opens a category-only home after it returns;
                        // an onChange that also clears would run after a cached load and wipe that category.
                        if key != sourceKey { category = nil; categoryPage = 1 }
                        sourceKey = key; revision = 0; forceRefresh = false
                    } actions: { key in
                        AnyView(sites.first(where: { $0.key == key }).map { sourceActions($0) })
                    }
                    recommendationControls.fixedSize()
                }
            } else {
                HStack(spacing: 16) {
                    Text(L10n.text("Recommendations")).font(.title3.weight(.bold))
                    Spacer()
                    recommendationControls.fixedSize()
                }
            }
            #endif
            if model.busy, let site {
                LoadingCard { .source(site, origin: config.origin, title: L10n.text("Loading recommendations…")) }
            }
            if model.busy && model.items.isEmpty { PosterSkeletonGrid() }
            if let error = model.error {
                Text(error).foregroundStyle(.secondary)
                Button(L10n.text("Retry")) { forceRefresh = true; revision += 1 }
            }
            if let loadedSite = model.site, !model.categories.isEmpty {
                categoryChips(loadedSite).tvFocusSection()
            }
            if category != nil, let loadedSite = model.site {
                categoryContent(loadedSite)
            } else if !model.busy && model.error == nil && model.items.isEmpty {
                Text(L10n.text("This source has no recommendations. Choose another source or use Global Search."))
                    .foregroundStyle(.secondary)
            }
            if category == nil, !model.items.isEmpty, let loadedSite = model.site {
                if (loadedSite.raw["indexs"]?.int ?? 0) == 1 {
                    Text(L10n.text("Choose a title to find it across your sources.")).font(.subheadline).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: Layout.posterColumns, spacing: Layout.gridRowSpacing) {
                    ForEach(model.items) { item in
                        switch item.destination {
                        case .search(let keyword):
                            Button { store.searchVideos(keyword) } label: { PosterCard(recommendation: item) }.cardButton()
                        case .detail(let video):
                            RouteLink {
                                VideoDetailView(video: video, client: CatalogClient(site: loadedSite, origin: config.origin, jarURL: config.spiderURL))
                            } label: { PosterCard(recommendation: item) }.cardButton()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .tvFocusSection()
            }
        }
        .task(id: requestID) {
            #if DEBUG && os(tvOS)
            // `-qaSourcePicker 1` opens the recommendation source picker, for screenshots.
            if UserDefaults.standard.bool(forKey: "qaSourcePicker"), fixedSite == nil { choosingSource = true }
            #endif
            let requested = site?.key
            guard let site else { model.reset(); return }
            // Reset here, while this task is the last writer. A later onChange would clear the category
            // a cached home opens below: that home has no posters, so the page would say it has none.
            if categorySite != requested { category = nil; categoryPage = 1; categorySite = requested }
            let refresh = forceRefresh; forceRefresh = false
            await model.load(client: CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL), subscriptionDate: config.importedAt, force: refresh)
            guard !Task.isCancelled, site.key == requested else { return }
            // A source whose home names only categories (list sites) opens its first one.
            if category == nil, !model.busy, model.error == nil, model.items.isEmpty, let first = model.categories.first {
                category = first.id; categoryPage = 1
            }
        }
        .task(id: "\(requestID)|\(category ?? "")|\(categoryPage)") {
            guard let category, let loadedSite = model.site, loadedSite.key == site?.key else { return }
            await browser.load(.list(category: category, query: "", page: categoryPage),
                               client: CatalogClient(site: loadedSite, origin: config.origin, jarURL: config.spiderURL))
        }
        .onDisappear { browser.cancel() }
        .navigationDestination(item: $openedSource) { route in
            #if os(macOS)
            route.build().musicBar()
            #else
            route.build()
            #endif
        }
    }

    /// A long press on a source (a right click on Mac): hide it, open its page to search only that source, as the
    /// Sources page does, or go to the Sources page to manage them all. `leave` runs the two that leave Watch Now;
    /// the tvOS picker passes one that closes its sheet first.
    @ViewBuilder private func sourceActions(_ candidate: Site, leave: @escaping (@escaping () -> Void) -> Void = { $0() }) -> some View {
        HideSourceButton(site: candidate, origin: config.origin)
        Button {
            leave {
                let route = Route { AnyView(SiteView(site: candidate, origin: config.origin, jarURL: config.spiderURL)) }
                if let openRoute { openRoute(route) } else { openedSource = route }
            }
        } label: { Label(L10n.text("Search This Source"), systemImage: "magnifyingglass") }
            .accessibilityIdentifier("source.search." + candidate.key)
        Button { leave { store.section = .sites } } label: { Label(L10n.text("Manage Sources"), systemImage: AppSection.sites.icon) }
    }

    private func categoryChips(_ loadedSite: Site) -> some View {
        ChipRow {
            HStack(spacing: 8) {
                if !model.items.isEmpty {
                    Chip(title: L10n.text("Recommendations"), selected: category == nil) { category = nil; categoryPage = 1 }
                }
                ForEach(model.categories) { item in
                    Chip(title: item.name, selected: category == item.id) { category = item.id; categoryPage = 1 }
                }
            }.padding(.vertical, 4)
        }
    }

    @ViewBuilder private func categoryContent(_ loadedSite: Site) -> some View {
        let client = CatalogClient(site: loadedSite, origin: config.origin, jarURL: config.spiderURL)
        let isIndex = (loadedSite.raw["indexs"]?.int ?? 0) == 1
        if browser.busy && browser.videos.isEmpty { PosterSkeletonGrid() }
        if let error = browser.error {
            Text(error).foregroundStyle(.secondary)
            Button(L10n.text("Retry")) { Task { await browser.load(browser.request, client: client) } }
        }
        if !browser.videos.isEmpty {
            if isIndex {
                Text(L10n.text("Choose a title to find it across your sources.")).font(.subheadline).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: Layout.posterColumns, spacing: Layout.gridRowSpacing) {
                ForEach(browser.videos) { video in
                    if isIndex {
                        Button { store.searchVideos(video.name) } label: { PosterCard(video: video) }.cardButton()
                    } else {
                        RouteLink { VideoDetailView(video: video, client: client) } label: { PosterCard(video: video) }.cardButton()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(browser.busy ? 0.55 : 1)
            .tvFocusSection()
            if browser.pageCount > 1 {
                HStack(spacing: 12) {
                    Button { categoryPage -= 1 } label: { Image(systemName: "chevron.left").frame(width: 22) }
                        .controlButton().disabled(categoryPage <= 1 || browser.busy).accessibilityLabel(L10n.text("Previous"))
                    Text(L10n.text("Page %lld of %lld", browser.page, browser.pageCount)).font(.subheadline.weight(.medium).monospacedDigit())
                    Button { categoryPage += 1 } label: { Image(systemName: "chevron.right").frame(width: 22) }
                        .controlButton().disabled(categoryPage >= browser.pageCount || browser.busy).accessibilityLabel(L10n.text("Next"))
                }
                .frame(maxWidth: .infinity).tvFocusSection()
            }
        }
    }
}

#if !os(tvOS)
/// Recommendation source picker. It is its own view so scrolling and dragging
/// re-render only the strip, never the poster grid below it.
struct SourceStrip: View {
    #if os(macOS)
    static let controlSize: CGFloat = 30
    #else
    static let controlSize: CGFloat = 44
    #endif
    struct Item: Identifiable {
        let id: String
        let name: String
        var count: Int? = nil
        var dot: Color? = nil
    }
    let items: [Item]
    let selection: String
    let select: (String) -> Void
    /// A chip's long-press (right-click) menu, by item id.
    var actions: ((String) -> AnyView)? = nil

    var body: some View {
        ScrollStrip(scrollTo: selection, leftLabel: "Scroll sources left", rightLabel: "Scroll sources right") {
            HStack(spacing: 6) {
                ForEach(items) { item in
                    let chip = SourceChip(name: item.name, count: item.count, dot: item.dot, selected: item.id == selection) { select(item.id) }
                    Group {
                        if let actions { chip.contextMenu { actions(item.id) } } else { chip }
                    }
                    .id(item.id)
                }
            }
            .padding(.vertical, 4)
            .scrollTargetLayout()
        }
    }
}

/// Outside ScrollStrip so measuring it in a sendable closure does not capture the generic content type.
private struct ScrollStripMetrics: Equatable { var offset: CGFloat, viewport: CGFloat, maximum: CGFloat }

/// A horizontal row of chips or cards. A mouse wheel cannot scroll sideways, so on Mac the row can
/// also be dragged like a trackpad swipe and shows arrow buttons once it overflows. Elsewhere it is
/// a plain horizontal scroll view (touch on iOS; tvOS rows stay focus-driven and do not use it).
struct ScrollStrip<Content: View>: View {
    let scrollTo: String?
    let leftLabel: String
    let rightLabel: String
    /// Floats the arrows over the strip's ends instead of beside it, for strips that run edge to edge,
    /// centred this far from the strip's top (the middle of its artwork), or on the strip when nil.
    var overlayArrows = false
    var arrowCenter: CGFloat?
    let content: Content
    #if os(macOS)
    @State private var position = ScrollPosition(idType: String.self)
    #endif
    @State private var edges = Edges()
    /// Live geometry and drag state. A plain reference, so updating it never invalidates the view.
    @State private var tracking = Tracking()

    init(scrollTo: String? = nil, leftLabel: String = "Scroll left", rightLabel: String = "Scroll right",
         overlayArrows: Bool = false, arrowCenter: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.scrollTo = scrollTo
        self.leftLabel = leftLabel
        self.rightLabel = rightLabel
        self.overlayArrows = overlayArrows
        self.arrowCenter = arrowCenter
        self.content = content()
    }

    private struct Edges: Equatable { var leading = false, trailing = false }
    private typealias Metrics = ScrollStripMetrics
    @MainActor private final class Tracking {
        var metrics = Metrics(offset: 0, viewport: 0, maximum: 0)
        var dragOrigin: CGFloat?
        let drag = StripDrag()
        func clamp(_ x: CGFloat) -> CGFloat { min(metrics.maximum, max(0, x)) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 8) {
                measured(
                    ScrollView(.horizontal, showsIndicators: false) {
                        measuredContent
                    }
                    #if os(macOS)
                    .scrollPosition($position)
                    #endif
                )
                .mask {
                    HStack(spacing: 0) {
                        LinearGradient(colors: [edges.leading ? .clear : .black, .black], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 20)
                        Rectangle()
                        LinearGradient(colors: [.black, edges.trailing ? .clear : .black], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 28)
                    }
                }
                .environment(\.stripDrag, tracking.drag)
                #if os(macOS)
                .simultaneousGesture(dragToScroll)
                .overlay(alignment: arrowCenter == nil ? .center : .top) {
                    if overlayArrows {
                        HStack {
                            if edges.leading { arrow(forward: false) }
                            Spacer(minLength: 0)
                            if edges.trailing { arrow(forward: true) }
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, arrowCenter.map { max(0, $0 - 17) } ?? 0)
                    }
                }
                #endif
                #if os(macOS)
                if !overlayArrows, edges.leading || edges.trailing {
                    HStack(spacing: 4) { arrow(forward: false); arrow(forward: true) }
                }
                #endif
            }
            .onAppear {
                guard let scrollTo else { return }
                #if os(macOS)
                position.scrollTo(id: scrollTo, anchor: .center)
                #else
                proxy.scrollTo(scrollTo, anchor: .center)
                #endif
            }
        }
    }

    private func update(_ metrics: Metrics) {
        tracking.metrics = metrics
        let next = Edges(leading: metrics.offset > 1, trailing: metrics.offset < metrics.maximum - 1)
        if next != edges { edges = next }
    }

    @ViewBuilder private func measured(_ scrollView: some View) -> some View {
        if #available(iOS 18, *) {
            scrollView.onScrollGeometryChange(for: Metrics.self) { geometry in
                Metrics(offset: geometry.contentOffset.x + geometry.contentInsets.leading,
                        viewport: geometry.containerSize.width,
                        maximum: max(0, geometry.contentSize.width + geometry.contentInsets.leading
                            + geometry.contentInsets.trailing - geometry.containerSize.width))
            } action: { _, metrics in update(metrics) }
        } else {
            scrollView
        }
    }

    /// Before iOS 18 the scroll view cannot report its geometry, so the content measures the part of
    /// itself that is on screen.
    @ViewBuilder private var measuredContent: some View {
        if #available(iOS 18, *) {
            content
        } else {
            content.onGeometryChange(for: Metrics.self) { geometry in
                let visible = geometry.bounds(of: .scrollView(axis: .horizontal)) ?? .zero
                return Metrics(offset: visible.minX, viewport: visible.width, maximum: max(0, geometry.size.width - visible.width))
            } action: { update($0) }
        }
    }

    #if os(macOS)
    /// Mouse users can grab the strip like a trackpad swipe, with momentum on release.
    private var dragToScroll: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let origin = tracking.dragOrigin ?? tracking.metrics.offset
                tracking.dragOrigin = origin
                tracking.drag.active = true
                position.scrollTo(x: tracking.clamp(origin - value.translation.width))
            }
            .onEnded { value in
                let origin = tracking.dragOrigin ?? tracking.metrics.offset
                tracking.dragOrigin = nil
                withAnimation(.smooth(duration: 0.45)) {
                    position.scrollTo(x: tracking.clamp(origin - value.predictedEndTranslation.width))
                }
                let drag = tracking.drag
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(120))
                    drag.active = false
                }
            }
    }

    private func arrow(forward: Bool) -> some View {
        let enabled = forward ? edges.trailing : edges.leading
        let label = L10n.text(forward ? rightLabel : leftLabel)
        return Button {
            let step = max(1, tracking.metrics.viewport * 0.8)
            withAnimation(.smooth(duration: 0.3)) {
                position.scrollTo(x: tracking.clamp(tracking.metrics.offset + (forward ? step : -step)))
            }
        } label: {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .font(.system(size: overlayArrows ? 14 : 11, weight: .bold))
                .frame(width: overlayArrows ? 34 : 26, height: overlayArrows ? 34 : 26)
                .background(Color.primary.opacity(0.07), in: Circle())
                .glassSurface(overlayArrows ? .regular.interactive() : .identity, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .primary : .tertiary)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .help(label)
    }
    #endif
}

/// Flat capsule chip: cheap to draw in long rows, high contrast only for the selection.
private struct SourceChip: View {
    let name: String
    var count: Int? = nil
    var dot: Color? = nil
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.stripDrag) private var drag

    var body: some View {
        let label = SourceLabel(name)
        // The chip under the pointer receives the mouse-up that ends a drag.
        Button { if drag?.active != true { action() } } label: {
            HStack(spacing: 6) {
                if name == Site.bilibili.name { BilibiliGlyph(size: 15).foregroundStyle(selected ? Brand.onAccent : BilibiliMark.blue) } else if let symbol = label.symbol { Text(symbol) }
                Text(label.title).lineLimit(1)
                if let count { Text("\(count)").monospacedDigit().opacity(0.55) }
                if let dot { Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(dot) }
            }
            .font(.system(size: 13, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? Brand.onAccent : Color.primary.opacity(0.82))
            .padding(.horizontal, 12)
            .frame(height: SourceStrip.controlSize)
            .background(fill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.15), value: hovering)
        .animation(.smooth(duration: 0.2), value: selected)
        .accessibilityLabel(label.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .help(name)
    }

    private var fill: Color {
        if selected { return Brand.accent }
        return Color.primary.opacity(hovering ? 0.12 : 0.06)
    }
}

#endif

/// Source names often pack a leading emoji and box-drawing separators ("🌕┃片单┃精选").
/// Split them into a symbol and a readable title ("片单 · 精选").
struct SourceLabel {
    var symbol: String?
    var title: String
    /// The name's segments ("片单", "精选"); the first is the source's own name, the rest are taglines.
    var parts: [String]
    var text: String { [symbol, title].compactMap { $0 }.joined(separator: " ") }
    init(_ name: String) {
        var text = Substring(name.trimmingCharacters(in: .whitespaces))
        if let first = text.first, first.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }) {
            symbol = String(first)
            text = text.dropFirst()
        }
        let parts = text.split(whereSeparator: { character in
            "|｜丨¦·・".contains(character)
                || character.unicodeScalars.allSatisfy { (0x2500...0x257F).contains($0.value) } // box drawing
        })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        self.parts = parts.isEmpty ? [name] : parts
        title = self.parts.joined(separator: " · ")
    }
}

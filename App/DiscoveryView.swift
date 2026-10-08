import SwiftUI
import TVCore

private struct SearchPoster: Identifiable {
    let site: Site
    let video: Video
    var id: String { "\(site.id.utf8.count):\(site.id)\(video.id)" }
}

struct GlobalSearchView: View {
    @Environment(Store.self) private var store
    @FocusState private var inputFocused: Bool
    @State private var showFailures = false
    @AppStorage("videoSearchHistory") private var historyData = Data()
    private var model: SearchModel { store.searchModel }
    private var history: [String] { (try? JSONDecoder().decode([String].self, from: historyData)) ?? [] }
    private var posters: [SearchPoster] {
        model.matches.filter { model.selectedSource == nil || $0.id == model.selectedSource }.flatMap { result in
            uniqueVideos(result.page?.videos ?? []).map { SearchPoster(site: result.site, video: $0) }
        }
    }

    var body: some View {
        @Bindable var model = model
        #if os(tvOS)
        searchResults
            .searchable(text: $model.draft, prompt: Text(L10n.text("Search videos")))
            .searchSuggestions {
                ForEach(Array(history.filter { model.draft.isEmpty || $0.localizedCaseInsensitiveContains(model.draft) }.prefix(6)), id: \.self) { query in
                    Text(query).searchCompletion(query)
                }
            }
            .onSubmit(of: .search) { if let config = store.subscription { submit(config) } }
            .screenBackdrop()
            .sheet(isPresented: $showFailures) { failureDetails }
            .onAppear { if let config = store.subscription { model.resumeSuspended(config: config) } }
            .onDisappear { model.suspend() }
            .task(id: model.draft) {
                let query = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard query != model.keyword else { return }
                if query.isEmpty { model.reset(); return }
                // Wait for a pause in remote, dictation, or phone keyboard input.
                do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
                guard !Task.isCancelled, let config = store.subscription else { return }
                let draft = model.draft
                model.search(query, config: config)
                model.draft = draft
            }
        #else
        searchResults
            .scrollPosition(id: $model.scrollID)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .safeAreaBar(edge: .top, spacing: 0) { if let config = store.subscription { searchHeader(config) } }
            .screenBackdrop()
            .screenTitle(L10n.text("Global Search"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .sheet(isPresented: $showFailures) { failureDetails }
            .onAppear {
                if model.keyword.isEmpty { inputFocused = true }
                if let config = store.subscription { model.resumeSuspended(config: config) }
            }
            .onDisappear { model.suspend() }
        #endif
    }

    private var searchResults: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                #if os(tvOS)
                if let config = store.subscription, !model.keyword.isEmpty {
                    searchHeader(config).padding(.horizontal, -Layout.gutter)
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
                            if let selected = model.matches.first(where: { $0.id == model.selectedSource }) {
                                RouteLink {
                                    SiteView(site: selected.site, origin: config.origin, jarURL: config.spiderURL, initialQuery: model.keyword)
                                } label: { Label(L10n.text("More from %@", selected.site.name), systemImage: "arrow.right") }
                                .controlButton()
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
            if !model.failures.isEmpty {
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
            #if !os(tvOS)
            let trimmed = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 17, weight: .medium))
                    .foregroundStyle(inputFocused ? Color.primary : .secondary)
                TextField(L10n.text("Search videos"), text: $model.draft)
                    .textFieldStyle(.plain).font(.system(size: 17)).focused($inputFocused)
                    .submitLabel(.search).onSubmit { submit(config) }
                if !model.draft.isEmpty {
                    Button { model.reset(); inputFocused = true } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 15)).frame(width: 28, height: 40)
                    }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
                    .accessibilityLabel(L10n.text("Clear search"))
                }
                if !trimmed.isEmpty && trimmed != model.keyword {
                    Button(L10n.text("Search")) { submit(config) }
                        .buttonStyle(.plain).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Brand.onAccent)
                        .padding(.horizontal, 14).frame(height: 30)
                        .background(Brand.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
            .padding(.leading, 14).padding(.trailing, 7).frame(height: 44)
            .background(Color.primary.opacity(inputFocused ? 0.09 : 0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(inputFocused ? 0.30 : 0.08), lineWidth: 1) }
            .overlay(alignment: .bottom) {
                if model.busy && model.total > 0 {
                    GeometryReader { proxy in
                        Capsule().fill(Color.primary.opacity(0.55))
                            .frame(width: proxy.size.width * CGFloat(model.completed) / CGFloat(model.total))
                            .animation(.smooth(duration: 0.3), value: model.completed)
                    }
                    .frame(height: 2).padding(.horizontal, 12)
                    .transition(.opacity)
                    .accessibilityHidden(true)
                }
            }
            .animation(.smooth(duration: 0.18), value: inputFocused)
            .animation(.smooth(duration: 0.18), value: trimmed == model.keyword)
            .animation(.smooth(duration: 0.25), value: model.busy)
            .contentShape(Rectangle()).onTapGesture { inputFocused = true }
            #endif
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
                if model.busy {
                    SearchActivityList(origin: config.origin, completed: model.completed, total: model.total, runStart: model.runStart)
                }
                if !model.matches.isEmpty {
                    #if os(tvOS)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            Chip(title: L10n.text("All Sources"), selected: model.selectedSource == nil) { model.selectedSource = nil; model.scrollID = nil }
                            ForEach(model.matches) { result in
                                Chip(title: "\(result.site.name) · \(uniqueVideos(result.page?.videos ?? []).count)", selected: model.selectedSource == result.id) {
                                    model.selectedSource = result.id; model.scrollID = nil
                                }
                            }
                        }.padding(.vertical, 4)
                    }
                    #else
                    SourceStrip(items: [.init(id: "", name: L10n.text("All Sources"), count: model.videoCount)]
                                    + model.matches.map { .init(id: $0.id, name: $0.site.name, count: uniqueVideos($0.page?.videos ?? []).count) },
                                selection: model.selectedSource ?? "") { id in
                        model.selectedSource = id.isEmpty ? nil : id; model.scrollID = nil
                    }
                    #endif
                }
            }
        }
        .frame(maxWidth: model.keyword.isEmpty ? 760 : Layout.maxWidth - Layout.gutter * 2)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Layout.gutter).padding(.vertical, 16)
    }

    private var searchSummary: some View {
        // A spinner has no text baseline, so it centers on the row; only the two labels share a baseline.
        HStack(alignment: .center, spacing: 12) {
            #if os(tvOS)
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

    private func searchActions(_ config: Subscription) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { searchActionButtons(config) }
            VStack(alignment: .leading, spacing: 8) { searchActionButtons(config) }
        }
    }

    @ViewBuilder private func searchActionButtons(_ config: Subscription) -> some View {
        if model.busy {
            Button(L10n.text("Stop")) { model.stop() }.searchAction()
        } else if model.completed < model.total {
            Button(L10n.text("Continue search")) { model.resume(config: config) }.searchAction()
        }
        if !model.failures.isEmpty {
            Button { showFailures = true } label: {
                Label {
                    Text(L10n.text("%lld unavailable", model.failures.count))
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
        VStack(alignment: .leading, spacing: 22) {
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
                        Button { model.draft = item; if let config = store.subscription { submit(config) } } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "clock.arrow.circlepath").font(.body).foregroundStyle(.secondary).frame(width: 24)
                                Text(item).font(.body).lineLimit(1)
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.left").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 18).frame(minHeight: 52).frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        if index < history.count - 1 { Divider().padding(.leading, 56) }
                    }
                }
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            #endif
        }
    }

    private var failureDetails: some View {
        NavigationStack {
            List {
                ForEach(model.failures) { result in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(result.site.name).font(.headline)
                        Text(result.error ?? "").font(.caption).foregroundStyle(.secondary)
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
                    }.controlButton(prominent: true).disabled(model.busy || model.failures.isEmpty)
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
                    }.disabled(model.busy || model.failures.isEmpty)
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

    private func rememberQuery(_ query: String? = nil) {
        let keyword = query ?? model.keyword
        guard !keyword.isEmpty else { return }
        historyData = (try? JSONEncoder().encode(Array(([keyword] + history.filter { $0 != keyword }).prefix(20)))) ?? Data()
    }

    private func submit(_ config: Subscription) {
        let keyword = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        rememberQuery(keyword)
        inputFocused = false
        model.search(keyword, config: config)
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
        controlButton()
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
    let config: Subscription
    var fixedSite: Site? = nil
    @AppStorage("recommendationSource") private var sourceKey = ""
    @State private var revision = 0
    @State private var forceRefresh = false
    @State private var choosingSource = false
    /// The source category shown instead of its recommendations; nil shows the recommendations.
    @State private var category: String?
    @State private var categoryPage = 1
    @State private var browser = CatalogBrowser()
    private var model: RecommendationModel { store.recommendationModel }
    private var sites: [Site] { fixedSite.map { [$0] } ?? SourceStrategy.arrange(config.sites) { !$0.hidden && $0.canBrowse(jarURL: config.spiderURL) } }
    /// Until the user picks a source, default to the first in strategy order, so opening the app
    /// does not start the JVM when a standard API or script source is available.
    private var site: Site? { sites.first(where: { $0.key == sourceKey }) ?? sites.first }
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
                .controlButton()
                .accessibilityLabel(L10n.text("Recommendation Source"))
                .sheet(isPresented: $choosingSource) {
                    NavigationStack {
                        List(sites) { candidate in
                            Button {
                                sourceKey = candidate.key
                                revision = 0
                                forceRefresh = false
                                choosingSource = false
                            } label: {
                                HStack {
                                    Text(candidate.name)
                                    Spacer()
                                    if candidate.key == site.key { Image(systemName: "checkmark") }
                                }
                            }
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
                }.disabled(model.busy).accessibilityLabel(L10n.text("Refresh"))
                    .frame(minWidth: 44, minHeight: 44)
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
                        sourceKey = key; revision = 0; forceRefresh = false
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
            guard let site else { model.reset(); return }
            let refresh = forceRefresh; forceRefresh = false
            await model.load(client: CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL), subscriptionDate: config.importedAt, force: refresh)
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
        .onChange(of: site?.key) { category = nil; categoryPage = 1 }
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
    }
    let items: [Item]
    let selection: String
    let select: (String) -> Void

    var body: some View {
        ScrollStrip(scrollTo: selection, leftLabel: "Scroll sources left", rightLabel: "Scroll sources right") {
            HStack(spacing: 6) {
                ForEach(items) { item in
                    SourceChip(name: item.name, count: item.count, selected: item.id == selection) { select(item.id) }
                        .id(item.id)
                }
            }
            .padding(.vertical, 4)
            .scrollTargetLayout()
        }
    }
}

/// A horizontal row of chips or cards. A mouse wheel cannot scroll sideways, so on Mac the row can
/// also be dragged like a trackpad swipe and shows arrow buttons once it overflows. Elsewhere it is
/// a plain horizontal scroll view (touch on iOS; tvOS rows stay focus-driven and do not use it).
struct ScrollStrip<Content: View>: View {
    let scrollTo: String?
    let leftLabel: String
    let rightLabel: String
    let content: Content
    @State private var position = ScrollPosition(idType: String.self)
    @State private var edges = Edges()
    /// Live geometry and drag state. A plain reference, so updating it never invalidates the view.
    @State private var tracking = Tracking()

    init(scrollTo: String? = nil, leftLabel: String = "Scroll left", rightLabel: String = "Scroll right",
         @ViewBuilder content: () -> Content) {
        self.scrollTo = scrollTo
        self.leftLabel = leftLabel
        self.rightLabel = rightLabel
        self.content = content()
    }

    private struct Edges: Equatable { var leading = false, trailing = false }
    private struct Metrics: Equatable { var offset: CGFloat, viewport: CGFloat, maximum: CGFloat }
    @MainActor private final class Tracking {
        var metrics = Metrics(offset: 0, viewport: 0, maximum: 0)
        var dragOrigin: CGFloat?
        let drag = StripDrag()
        func clamp(_ x: CGFloat) -> CGFloat { min(metrics.maximum, max(0, x)) }
    }

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                content
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: Metrics.self) { geometry in
                Metrics(offset: geometry.contentOffset.x + geometry.contentInsets.leading,
                        viewport: geometry.containerSize.width,
                        maximum: max(0, geometry.contentSize.width + geometry.contentInsets.leading
                            + geometry.contentInsets.trailing - geometry.containerSize.width))
            } action: { _, metrics in
                tracking.metrics = metrics
                let next = Edges(leading: metrics.offset > 1, trailing: metrics.offset < metrics.maximum - 1)
                if next != edges { edges = next }
            }
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
            #endif
            #if os(macOS)
            if edges.leading || edges.trailing {
                HStack(spacing: 4) { arrow(forward: false); arrow(forward: true) }
            }
            #endif
        }
        .onAppear { if let scrollTo { position.scrollTo(id: scrollTo, anchor: .center) } }
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
                .font(.system(size: 11, weight: .bold))
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.07), in: Circle())
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
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.stripDrag) private var drag

    var body: some View {
        let label = SourceLabel(name)
        // The chip under the pointer receives the mouse-up that ends a drag.
        Button { if drag?.active != true { action() } } label: {
            HStack(spacing: 6) {
                if let symbol = label.symbol { Text(symbol) }
                Text(label.title).lineLimit(1)
                if let count { Text("\(count)").monospacedDigit().opacity(0.55) }
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
    var text: String { [symbol, title].compactMap { $0 }.joined(separator: " ") }
    init(_ name: String) {
        var text = Substring(name.trimmingCharacters(in: .whitespaces))
        if let first = text.first, first.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }) {
            symbol = String(first)
            text = text.dropFirst()
        }
        let parts = text.split(whereSeparator: { character in
            "|｜丨¦".contains(character)
                || character.unicodeScalars.allSatisfy { (0x2500...0x257F).contains($0.value) } // box drawing
        })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        title = parts.isEmpty ? name : parts.joined(separator: " · ")
    }
}

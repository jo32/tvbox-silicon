import SwiftUI
import TVCore

struct SitesView: View {
    @Environment(Store.self) private var store
    @State private var query = ""
    var body: some View {
        Group {
            if let config = store.subscription {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: Layout.cardMin), spacing: 14)], spacing: 14) {
                        ForEach(config.sites.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { site in
                            RouteLink { SiteView(site: site, origin: config.origin, jarURL: config.spiderURL) } label: { SiteCard(site: site) }.cardButton()
                        }
                    }.pageContainer()
                }
            } else { ContentUnavailableView(L10n.text("No Sources Yet"), systemImage: "square.grid.2x2", description: Text(L10n.text("Add a TVBox subscription in Settings."))) }
        }
        .screenBackdrop()
        .catalogSearchable(text: $query, prompt: L10n.text("Find a source")).screenTitle(L10n.text("Sources"))
    }
}

struct SiteCard: View {
    let site: Site
    var body: some View {
        HStack(spacing: 14) {
            IconTile(symbol: site.native ? "checkmark.seal.fill" : "puzzlepiece.extension.fill", tint: site.native ? Brand.accent : Brand.amber, size: 46)
            VStack(alignment: .leading, spacing: 6) {
                Text(site.name).font(.headline).foregroundStyle(.primary).lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
                Pill(text: site.compatibility, tint: site.native ? Brand.accent : Brand.amber)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .contentPanel()
    }
}

struct SiteView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let site: Site
    let origin: URL
    let jarURL: URL?
    var initialQuery: String = ""
    private var canLoad: Bool { site.canBrowse(jarURL: jarURL) }
    private var isIndex: Bool { (site.raw["indexs"]?.int ?? 0) == 1 }
    @State private var browser = CatalogBrowser()
    @State private var query = ""
    private var initialLoading: Bool { browser.videos.isEmpty && browser.error == nil && (browser.busy || !browser.loaded) }
    private var client: CatalogClient { CatalogClient(site: site, origin: origin, jarURL: jarURL) }
    var body: some View {
        Group {
            if !canLoad {
                ContentUnavailableView {
                    Label(site.compatibility, systemImage: "puzzlepiece.extension")
                } description: {
                    if site.type != 3 {
                        Text(L10n.text("This source format is not supported. Choose another source."))
                    } else {
                        Text(site.api.hasPrefix("csp_") ? L10n.text("This source uses a plugin that requires Android DEX and native libraries. This platform does not yet have the required compatibility layer.\n\n%@", site.api) : L10n.text("This source requires a JavaScript engine, which is not supported yet."))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                #if os(tvOS)
                .focusable()
                .onExitCommand { dismiss() }
                #endif
            } else if isIndex, let config = store.subscription {
                ScrollView { RecommendationsView(config: config, fixedSite: site).pageContainer() }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if !browser.categories.isEmpty { categoryBar } else if initialLoading { ChipSkeletonRow() }
                        if initialLoading { PosterSkeletonGrid() }
                        if let error = browser.error {
                            ErrorStateCard(
                                title: L10n.text("Unable to load this source"),
                                message: L10n.text("Try again, or choose another source to keep watching."),
                                details: error,
                                retry: { Task { await browser.load(browser.request, client: client) } },
                                goBack: { dismiss() },
                                busy: browser.busy
                            )
                            .padding(.vertical, browser.videos.isEmpty ? 24 : 8)
                        }
                        if browser.videos.isEmpty && browser.loaded && !browser.busy && browser.error == nil { ContentUnavailableView(L10n.text("No Videos"), systemImage: "film", description: Text(L10n.text("Try selecting a category or searching."))).frame(maxWidth: .infinity) }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: Layout.posterMin), spacing: 18, alignment: .top)], spacing: 22) {
                            ForEach(browser.videos) { video in
                                RouteLink { VideoDetailView(video: video, client: client) } label: { PosterCard(video: video) }.cardButton()
                            }
                        }
                        .opacity(browser.busy && !browser.videos.isEmpty ? 0.55 : 1).animation(.smooth, value: browser.busy)
                    }.pageContainer()
                }
                .safeAreaInset(edge: .bottom) { if browser.pageCount > 1 { pager } }
                .catalogSearchable(text: Binding(get: { query }, set: { value in
                    query = value
                    if value.isEmpty && !browser.query.isEmpty { Task { await home() } }
                }), prompt: L10n.text("Search videos"))
                .onSubmit(of: .search) { Task { await search() } }
            }
        }
        .screenBackdrop()
        .screenTitle(site.name).task {
            if canLoad && !isIndex && !browser.loaded {
                if initialQuery.isEmpty { await home() }
                else { query = initialQuery; await search() }
            }
        }
    }
    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                LazyHStack(spacing: 8) {
                    Chip(title: L10n.text("Recommendations"), selected: browser.query.isEmpty && browser.category.isEmpty) { query = ""; Task { await home() } }
                    ForEach(browser.categories) { item in
                        Chip(title: item.name, selected: browser.query.isEmpty && browser.category == item.id) {
                            query = ""
                            Task { await browser.load(.list(category: item.id, query: "", page: 1), client: client) }
                        }
                    }
                }
            }.padding(.vertical, 4)
        }
    }
    private var pager: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button { Task { await load(page: browser.page - 1) } } label: { Image(systemName: "chevron.left").frame(width: 22) }
                    .controlButton().disabled(browser.page <= 1 || browser.busy).accessibilityLabel(L10n.text("Previous"))
                Text(L10n.text("Page %lld of %lld", browser.page, browser.pageCount)).font(.subheadline.weight(.medium).monospacedDigit())
                    .padding(.horizontal, 16).padding(.vertical, 10)
                Button { Task { await load(page: browser.page + 1) } } label: { Image(systemName: "chevron.right").frame(width: 22) }
                    .controlButton().disabled(browser.page >= browser.pageCount || browser.busy).accessibilityLabel(L10n.text("Next"))
            }
        }.controlSize(.large)
        #if os(tvOS)
        .padding(.vertical, 20).frame(maxWidth: .infinity).background(TVStyle.background).focusSection()
        #else
        .padding(.vertical, 8).frame(maxWidth: .infinity).controlBackdrop()
        #endif
    }
    private func home() async { await browser.load(.home, client: client) }
    private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { await home() }
        else { await browser.load(.list(category: nil, query: text, page: 1), client: client) }
    }
    private func load(page next: Int) async {
        await browser.load(.list(category: browser.category.isEmpty ? nil : browser.category, query: browser.query, page: next), client: client)
    }
}

struct VideoDetailView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dismiss) private var dismiss
    @Environment(Store.self) private var store
    let video: Video
    let client: CatalogClient
    @State private var detail: Video?
    @State private var error: String?
    @State private var busy = false
    @State private var pendingPlan: PlaybackPlan?
    @State private var pendingEpisode: Episode?
    @State private var choosingQuality = false
    @State private var synopsisExpanded = false
    @State private var selectedFlag: String?
    @State private var containerWidth: CGFloat = 0
    /// The episode whose playback is being prepared; its row and the Play button show progress.
    @State private var loadingEpisode: Episode.ID?
    /// A failed or blocked playback attempt, shown as an inline banner beside the artwork.
    @State private var playbackIssue: PlaybackIssue?
    #if os(macOS)
    @State private var signingIn: CloudProvider?
    #endif
    private var flags: [String] {
        var seen = Set<String>()
        return (detail?.episodes ?? []).map(\.flag).filter { seen.insert($0).inserted }
    }
    private var activeFlag: String { flags.contains(selectedFlag ?? "\u{0}") ? selectedFlag! : (flags.first ?? "") }
    private var railWidth: CGFloat {
        #if os(tvOS)
        560
        #else
        348
        #endif
    }
    private var wideMinWidth: CGFloat {
        #if os(tvOS)
        1200
        #else
        760
        #endif
    }
    var body: some View {
        Group {
            if detail != nil && isWide {
                // Watch-page split: artwork, Play and synopsis on the left; the episode rail
                // scrolls on its own so the title and playback state stay in view.
                HStack(alignment: .top, spacing: Layout.gutter + 8) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) { header }
                        .padding(.vertical, Layout.gutter)
                    }
                    .scrollIndicators(.never)
                    episodePanel(scrolls: true).frame(width: railWidth).padding(.top, Layout.gutter)
                }
                .padding(.horizontal, Layout.gutter)
                .frame(maxWidth: Layout.maxWidth).frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        if detail != nil {
                            episodePanel(scrolls: false)
                        } else if let error {
                            errorCard(error).padding(.top, 12)
                        } else {
                            DetailSkeleton()
                        }
                    }
                    .pageContainer()
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
        .screenBackdrop()
        .screenTitle(video.name).task { if detail == nil { await loadDetail() } }
        .onChange(of: choosingQuality) { _, open in if !open && !busy { loadingEpisode = nil } }
        #if os(macOS)
        // Sign in where playback failed, then resume the episode that needed the account.
        .sheet(item: $signingIn) { provider in
            CloudLoginView(provider: provider) { cookie in
                Task {
                    do { try await provider.saveLogin(cookie) } catch { return }
                    if let episode = playbackIssue?.episode { await play(episode) }
                }
            }
        }
        #endif
        .confirmationDialog(L10n.text("Choose quality"), isPresented: $choosingQuality, titleVisibility: .visible) {
            if let plan = pendingPlan, let episode = pendingEpisode {
                ForEach(plan.choices) { choice in
                    Button(choice.name) { Task { await resolve(plan, choice: choice, episode: episode) } }
                }
            }
        }
    }
    @ViewBuilder private var playbackBanner: some View {
        if let issue = playbackIssue {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: issue.drive != nil ? "person.crop.circle.badge.exclamationmark.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(Brand.amber)
                    .frame(width: 36, height: 36)
                    .background(Brand.amber.opacity(0.15), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.text("Couldn't play %@", EpisodeRow.title(issue.episode.name)))
                            .font(.headline).lineLimit(2)
                        Text(issue.message).font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).selectable()
                    }
                    HStack(spacing: 8) {
                        #if os(macOS)
                        if let drive = issue.drive {
                            Button(drive.signInTitle) { signingIn = drive.provider }.settingsButton(prominent: true)
                        }
                        #endif
                        Button(L10n.text(issue.blockedBeforeRequest ? "Try Anyway" : "Retry")) {
                            Task { await play(issue.episode, skipAccountCheck: true) }
                        }
                        .settingsButton(prominent: issue.drive == nil)
                    }
                }
                Spacer(minLength: 0)
                Button { withAnimation(.smooth(duration: 0.2)) { playbackIssue = nil } } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.07), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).accessibilityLabel(L10n.text("Dismiss")).help(L10n.text("Dismiss"))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08)) }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
    private func errorCard(_ error: String) -> some View {
                    ErrorStateCard(
                        title: detail == nil ? L10n.text("Unable to load video details") : L10n.text("Unable to start playback"),
                        message: detail == nil
                            ? L10n.text("Try again, or go back and choose another video.")
                            : L10n.text("Try another episode or playback source."),
                        details: error,
                        retry: detail == nil ? { Task { await loadDetail() } } : nil,
                        goBack: { dismiss() },
                        busy: busy,
                        backTitle: L10n.text("Go back")
                    )
    }
    private func loadDetail() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do { detail = try await client.detail(video.id) } catch { self.error = error.localizedDescription }
    }
    private var headerLayout: AnyLayout {
        #if os(iOS)
        if sizeClass == .compact { return AnyLayout(HStackLayout(alignment: .top, spacing: 16)) }
        #endif
        return AnyLayout(HStackLayout(alignment: .top, spacing: 24))
    }
    private var compactDetail: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }
    @ViewBuilder private func synopsis(_ detail: Video) -> some View {
        if !detail.synopsis.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(detail.synopsis).foregroundStyle(.secondary)
                    .lineLimit(synopsisExpanded ? nil : synopsisLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                if detail.synopsis.count > 100 {
                    let toggle = Button(L10n.text(synopsisExpanded ? "Show Less" : "Show Full Synopsis")) { synopsisExpanded.toggle() }
                    #if os(tvOS)
                    toggle.controlButton()
                    #else
                    toggle.buttonStyle(.plain).font(.subheadline.weight(.semibold)).frame(minHeight: 44, alignment: .leading)
                    #endif
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var synopsisLineLimit: Int {
        #if os(tvOS)
        4
        #else
        3
        #endif
    }
    private var posterWidth: CGFloat {
        #if os(macOS)
        150
        #elseif os(iOS)
        compactDetail ? 104 : 150
        #else
        Layout.detailPoster
        #endif
    }
    private var isWide: Bool { containerWidth >= wideMinWidth }
    @ViewBuilder private var playControl: some View {
        if let detail {
            if let first = detail.episodes.first(where: { $0.flag == activeFlag }) ?? detail.episodes.first {
                Button { Task { await play(first) } } label: {
                    HStack(spacing: 8) {
                        if loadingEpisode == first.id { ProgressView().controlSize(.small) } else { Image(systemName: "play.fill") }
                        Text(L10n.text("Play"))
                    }
                    .font(.headline).padding(.horizontal, 8)
                }
                .controlButton(prominent: true).tint(Brand.accent).controlSize(.large)
            }
        } else if error == nil {
            SkeletonBlock(cornerRadius: 10).frame(width: 150, height: 40)
        }
    }
    /// Stands in for a watch-page player: a 16:9 stage with the artwork, title and the primary action.
    private var hero: some View {
        Color.clear.aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    ZStack {
                        PosterImage(url: video.poster, headers: video.posterHeaders)
                            .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                            .blur(radius: 40).scaleEffect(1.35)
                            .overlay(Color.black.opacity(0.5))
                        HStack(alignment: .center, spacing: 32) {
                            Color.clear.aspectRatio(2.0 / 3.0, contentMode: .fit)
                                .overlay { PosterImage(url: video.poster, headers: video.posterHeaders) }
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .shadow(color: .black.opacity(0.45), radius: 20, y: 10)
                                .frame(height: max(proxy.size.height - 56, 60))
                            VStack(alignment: .leading, spacing: 14) {
                                Text(video.name).font(.system(size: 34, weight: .bold)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                                if !video.remarks.isEmpty { Text(video.remarks).font(.title3).foregroundStyle(.white.opacity(0.75)) }
                                playControl.padding(.top, 6)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(28).frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
                    }
                }
            }
            .foregroundStyle(.white).environment(\.colorScheme, .dark)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            if isWide {
                hero
                playbackBanner
                if let detail, !detail.synopsis.isEmpty {
                    synopsis(detail).font(.body).padding(.horizontal, 18).padding(.vertical, 14)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            } else {
                HStack(alignment: .top, spacing: 14) {
                    Color.clear.aspectRatio(2.0 / 3.0, contentMode: .fit).frame(width: posterWidth)
                        .overlay { PosterImage(url: video.poster, headers: video.posterHeaders) }
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 12) {
                        Text(video.name).font(.title3.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                        if !video.remarks.isEmpty { Text(video.remarks).font(.subheadline).foregroundStyle(.secondary) }
                        playControl
                    }
                    Spacer(minLength: 0)
                }
                playbackBanner
                if let detail { synopsis(detail) }
            }
        }
    }
    @ViewBuilder private func episodePanel(scrolls: Bool) -> some View {
        if let detail {
            if detail.episodes.isEmpty {
                Text(L10n.text("No playable sources were found for this video.")).foregroundStyle(.secondary)
            } else {
                let items = detail.episodes.filter { $0.flag == activeFlag }
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(L10n.text("Episodes")).font(.headline)
                        Text("\(items.count)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        if flags.count == 1, !activeFlag.isEmpty {
                            Text(SourceLabel(activeFlag).text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    flagPicker
                    if scrolls {
                        ScrollView { episodeList(items).padding(.bottom, Layout.gutter) }
                            .scrollIndicators(.automatic)
                    } else {
                        episodeList(items)
                    }
                }
            }
        }
    }
    @ViewBuilder private var flagPicker: some View {
        if flags.count > 1 {
            #if os(tvOS)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(flags, id: \.self) { flag in
                        Chip(title: flag.isEmpty ? L10n.text("Play") : flag, selected: flag == activeFlag) { selectedFlag = flag }
                    }
                }.padding(.vertical, 2)
            }.tvFocusSection()
            #else
            SourceStrip(items: flags.map { .init(id: $0, name: $0.isEmpty ? L10n.text("Play") : $0) }, selection: activeFlag) { selectedFlag = $0 }
            #endif
        }
    }
    private func episodeList(_ items: [Episode]) -> some View {
        let longNames = isWide || (items.map { $0.name.count }.max() ?? 0) > 9
        return LazyVGrid(columns: longNames ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: episodeMin), spacing: 8)], spacing: longNames ? 4 : 8) {
            ForEach(items) { episode in
                if longNames {
                    EpisodeRow(name: episode.name, loading: loadingEpisode == episode.id) { Task { await play(episode) } }
                } else {
                    Chip(title: episode.name, selected: loadingEpisode == episode.id, fill: true) { Task { await play(episode) } }
                }
            }
        }.tvFocusSection()
    }
    private var episodeMin: CGFloat {
        #if os(tvOS)
        170
        #else
        74
        #endif
    }
    private func play(_ episode: Episode, skipAccountCheck: Bool = false) async {
        guard !busy else { return }
        // Cloud-drive plugins wait for an in-app login that cannot appear on this platform,
        // which surfaces only as a 60-second timeout. Ask for the account up front instead.
        if !skipAccountCheck, let drive = CloudDrive.missingLogin(forFlag: episode.flag) {
            withAnimation(.smooth(duration: 0.25)) {
                playbackIssue = PlaybackIssue(episode: episode, message: drive.loginHint, drive: drive, blockedBeforeRequest: true)
            }
            return
        }
        busy = true; loadingEpisode = episode.id
        withAnimation(.smooth(duration: 0.2)) { playbackIssue = nil }
        defer { busy = false; if !choosingQuality { loadingEpisode = nil } }
        do {
            let plan = try await client.preparePlayback(episode)
            if plan.choices.count > 1 {
                pendingPlan = plan; pendingEpisode = episode; choosingQuality = true
            } else {
                let resolved = try await client.resolvePlayback(plan, choice: plan.choices[0])
                store.playing = Channel(name: "\(video.name) · \(episode.name)", group: resolved.group, url: resolved.url, headers: resolved.headers)
            }
        } catch { fail(episode, error) }
    }
    private func resolve(_ plan: PlaybackPlan, choice: PlaybackChoice, episode: Episode) async {
        busy = true; loadingEpisode = episode.id
        defer { busy = false; pendingPlan = nil; pendingEpisode = nil; loadingEpisode = nil }
        do {
            let resolved = try await client.resolvePlayback(plan, choice: choice)
            store.playing = Channel(name: "\(video.name) · \(episode.name)", group: resolved.group, url: resolved.url, headers: resolved.headers)
        } catch { fail(episode, error) }
    }
    private func fail(_ episode: Episode, _ error: Error) {
        guard !(error is CancellationError) else { return }
        withAnimation(.smooth(duration: 0.25)) {
            playbackIssue = PlaybackIssue(episode: episode, message: error.localizedDescription,
                                          drive: CloudDrive.missingLogin(forFlag: episode.flag), blockedBeforeRequest: false)
        }
    }
}

private struct PlaybackIssue {
    let episode: Episode
    let message: String
    let drive: CloudDrive?
    /// True when playback was not attempted because a required account is missing.
    let blockedBeforeRequest: Bool
}

/// Cloud drives whose plugins need a saved login before they can return a stream.
private enum CloudDrive {
    case quark, uc
    init?(flag: String) {
        let text = flag.lowercased()
        if text.contains("夸克") || text.contains("quark") { self = .quark }
        else if text.hasPrefix("uc") || text.contains("uc网盘") { self = .uc }
        else { return nil }
    }
    var name: String { self == .quark ? L10n.text("Quark") : "UC" }
    var signInTitle: String { L10n.text(self == .quark ? "Sign In to Quark" : "Sign In to UC") }
    #if os(macOS)
    var provider: CloudProvider { self == .quark ? .quark : .uc }
    #endif
    var loginHint: String { L10n.text("This source plays from %@ and needs you to sign in first.", name) }
    static func missingLogin(forFlag flag: String) -> CloudDrive? {
        #if os(macOS)
        guard let drive = CloudDrive(flag: flag) else { return nil }
        let accounts = (try? CloudDriveAccounts.load()) ?? CloudDriveAccounts()
        let cookie = drive == .quark ? accounts.quarkCookie : accounts.ucCookie
        return cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? drive : nil
        #else
        return nil
        #endif
    }
}

/// Episode names often lead with a size tag ("[1.18GB] S01E41.mkv"); show it as trailing detail.
private struct EpisodeRow: View {
    let name: String
    let loading: Bool
    let action: () -> Void
    @State private var hovering = false
    static func split(_ name: String) -> (title: String, detail: String?) {
        if let match = name.firstMatch(of: /^\s*\[([^\]]+)\]\s*(.+)$/) { return (String(match.2), String(match.1)) }
        return (name, nil)
    }
    static func title(_ name: String) -> String { split(name).title }
    private var parts: (title: String, detail: String?) { Self.split(name) }
    var body: some View {
        let parts = parts
        let button = Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    if loading { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "play.fill").font(.system(size: 10)).foregroundStyle(hovering ? .primary : .tertiary) }
                }
                .frame(width: 16)
                Text(parts.title).font(.system(size: 13, weight: loading ? .semibold : .medium))
                    .lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                if let detail = parts.detail {
                    Text(detail).font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 12).frame(minHeight: 36)
            .frame(maxWidth: .infinity, alignment: .leading)
            #if !os(tvOS)
            .background(Color.primary.opacity(loading ? 0.12 : (hovering ? 0.08 : 0.04)),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            #endif
            .contentShape(Rectangle())
        }
        .accessibilityLabel(name)
        #if os(tvOS)
        button.controlButton().buttonBorderShape(.roundedRectangle(radius: 14))
        #else
        button.buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.smooth(duration: 0.15), value: hovering)
        #endif
    }
}

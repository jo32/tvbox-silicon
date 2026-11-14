import SwiftUI
import AVKit
import TVCore
import UniformTypeIdentifiers

@MainActor @Observable final class CatalogDanmakuModel: NSObject {
    private(set) var comments: [CatalogDanmakuComment] = []
    private(set) var track = ""
    private(set) var revision = UUID()
    var offset = 0.0
    var enabled = UserDefaults.standard.object(forKey: "danmakuEnabled") == nil ? true : UserDefaults.standard.bool(forKey: "danmakuEnabled") {
        didSet {
            guard enabled != oldValue, !synchronizingPreferences else { return }
            UserDefaults.standard.set(enabled, forKey: "danmakuEnabled")
            if !enabled { cancelAutomatic() }
            else if comments.isEmpty { resumeAutomatic() }
        }
    }
    var automatic = UserDefaults.standard.object(forKey: DanmakuService.automaticKey) == nil ? true : UserDefaults.standard.bool(forKey: DanmakuService.automaticKey) {
        didSet {
            guard automatic != oldValue, !synchronizingPreferences else { return }
            UserDefaults.standard.set(automatic, forKey: DanmakuService.automaticKey)
            if automatic { resumeAutomatic() } else { cancelAutomatic() }
        }
    }
    /// Applies to every track, Bilibili's own and live rooms included; the player's danmaku menu sets it too.
    var opacity = UserDefaults.standard.object(forKey: DanmakuStyle.opacityKey) as? Double ?? DanmakuStyle.standardOpacity {
        didSet { if opacity != oldValue { UserDefaults.standard.set(opacity, forKey: DanmakuStyle.opacityKey) } }
    }
    var fontSize = UserDefaults.standard.object(forKey: DanmakuStyle.fontSizeKey) as? Double ?? DanmakuStyle.standardFontSize {
        didSet { if fontSize != oldValue { UserDefaults.standard.set(fontSize, forKey: DanmakuStyle.fontSizeKey) } }
    }
    private var generation = UUID()
    private var automaticTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var automaticContext: PlaybackHistoryContext?
    private var usesSourceComments = false
    private var allowsAutomatic = true
    private var manuallySelected = false
    private var selectedOverridesSource = false
    @ObservationIgnored private var currentResolver: DanmakuResolver?
    @ObservationIgnored private var synchronizingPreferences = false
    @ObservationIgnored private var preferences = Preferences.load()
    @ObservationIgnored private var preferencesTask: Task<Void, Never>?
    @ObservationIgnored private var retriesSavedPreferences = false
    private(set) var automaticState = "idle"
    private(set) var source = ""
    private(set) var fromCache = false
    var context: PlaybackHistoryContext? { automaticContext }
    /// Native source comments remain the default; an explicit service/platform or manual track takes priority.
    var overridesSourceComments: Bool { !comments.isEmpty && (manuallySelected || selectedOverridesSource) }

    private struct Preferences: Equatable {
        let server: String
        let preferredSource: DanmakuProvider
        let automatic: Bool
        let dmkuServer: String
        let officialLookup: Bool
        var overridesSource: Bool { DanmakuService.isCustomServer(server) || preferredSource != .automatic }
        static func load() -> Self {
            let defaults = UserDefaults.standard
            return Self(server: DanmakuService.server(), preferredSource: DanmakuService.preferredSource(),
                        automatic: defaults.object(forKey: DanmakuService.automaticKey) == nil || defaults.bool(forKey: DanmakuService.automaticKey),
                        dmkuServer: defaults.string(forKey: "danmakuDmkuServer") ?? "https://dmku.hls.one/",
                        officialLookup: defaults.object(forKey: DanmakuService.officialLookupKey) == nil || defaults.bool(forKey: DanmakuService.officialLookupKey))
        }
        func resolver(server: String? = nil) -> DanmakuResolver {
            DanmakuResolver(dandanServer: server ?? self.server,
                            dmkuServer: URL(string: dmkuServer) ?? URL(string: "https://dmku.hls.one/")!,
                            officialLookup: officialLookup, preferredSource: preferredSource)
        }
    }

    override init() {
        super.init()
        // Selector observers are weak: Settings must not keep a closed playback session alive.
        NotificationCenter.default.addObserver(self, selector: #selector(serviceChanged), name: DanmakuService.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(defaultsChanged), name: UserDefaults.didChangeNotification, object: nil)
    }

    @objc nonisolated private func serviceChanged() {
        Task { @MainActor [weak self] in self?.schedulePreferencesRefresh(retry: true) }
    }
    @objc nonisolated private func defaultsChanged() {
        Task { @MainActor [weak self] in self?.schedulePreferencesRefresh() }
    }
    private func schedulePreferencesRefresh(retry: Bool = false) {
        retriesSavedPreferences = retriesSavedPreferences || retry
        preferencesTask?.cancel()
        // Saving updates several keys and posts a service notification. Treat that as one change.
        preferencesTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, let self else { return }
            let retry = self.retriesSavedPreferences
            self.retriesSavedPreferences = false; self.preferencesTask = nil
            self.refreshPreferences(retry: retry)
        }
    }
    private func refreshPreferences(retry: Bool = false) {
        let defaults = UserDefaults.standard
        let updated = Preferences.load(), previous = preferences
        preferences = updated
        let wasEnabled = enabled
        synchronizingPreferences = true
        enabled = defaults.object(forKey: "danmakuEnabled") == nil || defaults.bool(forKey: "danmakuEnabled")
        automatic = updated.automatic
        opacity = defaults.object(forKey: DanmakuStyle.opacityKey) as? Double ?? DanmakuStyle.standardOpacity
        fontSize = defaults.object(forKey: DanmakuStyle.fontSizeKey) as? Double ?? DanmakuStyle.standardFontSize
        synchronizingPreferences = false
        let serviceChanged = updated.server != previous.server || updated.preferredSource != previous.preferredSource
            || updated.dmkuServer != previous.dmkuServer || updated.officialLookup != previous.officialLookup
        if serviceChanged || (retry && automatic) {
            cancelAutomatic()
            if retry, let context = automaticContext {
                let resolver = updated.resolver()
                resolver.forget(context); resolver.forgetUnreachableServers()
            }
            resetComments(); resumeAutomatic()
        } else if (wasEnabled && !enabled) || (previous.automatic && !automatic) {
            // Only when one was just switched off: any other key changing (a display setting, a system write) must
            // not cancel an episode being loaded by hand while matching is off, or reset its state to idle.
            cancelAutomatic()
        } else if (!wasEnabled || !previous.automatic) && comments.isEmpty {
            resumeAutomatic()
        }
    }

    @ObservationIgnored private var renderedKey: String?
    @ObservationIgnored private var rendered: [Danmaku] = []
    var renderedRevision: String { "\(revision):\(offset)" }
    var renderedComments: [Danmaku] {
        let key = renderedRevision
        if renderedKey != key {
            renderedKey = key
            rendered = comments.map { comment in
                Danmaku(time: max(0, comment.time + offset),
                    position: comment.mode == .top ? .top : comment.mode == .bottom ? .bottom : .scroll,
                    color: comment.color, text: comment.text)
            }
        }
        return rendered
    }

    func startAutomatic(_ context: PlaybackHistoryContext?, usesSourceComments: Bool = false, allowsAutomatic: Bool = true) {
        cancelAutomatic()
        automaticContext = context
        self.usesSourceComments = usesSourceComments
        self.allowsAutomatic = allowsAutomatic
        // Resolve using preferences now, including when an episode starts after Settings was changed.
        let settings = Preferences.load()
        preferences = settings
        synchronizingPreferences = true; automatic = settings.automatic; synchronizingPreferences = false
        guard let context, automatic, enabled, allowsAutomatic, comments.isEmpty,
              !usesSourceComments || settings.overridesSource else { return }
        let resolver = settings.resolver()
        currentResolver = resolver
        let active = generation
        automaticState = "searching"
        automaticTask = Task { [weak self] in
            do {
                let result = try await resolver.resolve(context, first: settings.overridesSource ? nil : CatPawDanmaku.comments)
                try Task.checkCancellation()
                guard let self, self.generation == active, self.enabled, self.automatic, Preferences.load() == settings else { return }
                self.comments = result.comments
                self.track = result.track; self.source = result.source; self.fromCache = result.cached
                self.manuallySelected = false; self.selectedOverridesSource = settings.overridesSource
                self.offset = 0; self.revision = UUID(); self.automaticState = result.state
                self.automaticTask = nil
            } catch {
                guard let self, self.generation == active else { return }
                // Optional overlay failures never interrupt video playback or show alerts.
                self.automaticState = error is CancellationError ? "idle" : "unavailable"
                self.automaticTask = nil
            }
        }
    }

    private func resumeAutomatic() {
        startAutomatic(automaticContext, usesSourceComments: usesSourceComments, allowsAutomatic: allowsAutomatic)
    }
    private func cancelAutomatic() {
        generation = UUID(); automaticTask?.cancel(); automaticTask = nil; prefetchTask?.cancel(); prefetchTask = nil; automaticState = "idle"
    }

    func prefetch(_ context: PlaybackHistoryContext?) {
        prefetchTask?.cancel()
        let settings = Preferences.load()
        guard let context, settings.automatic, enabled, allowsAutomatic,
              !usesSourceComments || settings.overridesSource else { return }
        let active = generation, ticket = MediaCache.shared.ticket()
        let automaticTask = automaticTask, resolver = settings.resolver()
        prefetchTask = Task { [weak self] in
            await automaticTask?.value
            guard !Task.isCancelled, self?.generation == active, self?.comments.isEmpty == false else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, self?.generation == active, Preferences.load() == settings else { return }
            _ = try? await resolver.resolve(context, ticket: ticket, first: settings.overridesSource ? nil : CatPawDanmaku.comments)
        }
    }

    func retryAutomatic() {
        let settings = Preferences.load(), resolver = settings.resolver()
        if let context = automaticContext { resolver.forget(context) }
        resolver.forgetUnreachableServers()
        cancelAutomatic(); resetComments(); resumeAutomatic()
    }

    func load(_ episode: CatalogDanmakuEpisode, anime: CatalogDanmakuAnime, client: CatalogDanmakuClient, siblings: [CatalogDanmakuEpisode] = []) async throws {
        cancelAutomatic()
        let settings = Preferences.load(), resolver = settings.resolver(server: client.server.absoluteString)
        let active = generation
        let comments = try await client.comments(episode)
        try Task.checkCancellation()
        guard generation == active, Preferences.load() == settings else { throw CancellationError() }
        let ticket = automaticContext.map { resolver.invalidateEpisodes(for: $0) } ?? MediaCache.shared.ticket()
        self.comments = comments; track = anime.title + " · " + episode.title
        let platform = episode.source.isEmpty ? anime.source : episode.source
        source = platform.isEmpty ? L10n.text("Danmaku Service") : episode.source.isEmpty ? anime.sourceTitle : episode.sourceTitle
        fromCache = false; manuallySelected = true; selectedOverridesSource = true; currentResolver = resolver
        cacheCurrent(resolver: resolver, ticket: ticket)
        if let context = automaticContext, !siblings.isEmpty, !resolver.isCustomServer {
            // The official server: saved as Dandanplay's, which is where automatic matching looks for (and first asks)
            // a title already matched there. Saved under the platform instead, the next episode searched again.
            resolver.remember(DanmakuMapping(provider: "dandan", title: context.videoName, year: context.year,
                tracks: siblings.map { DanmakuTrack(number: CatalogDanmakuMatcher.episodeNumber($0.title), title: $0.title, id: $0.id) }),
                for: context, ticket: ticket)
        } else if let context = automaticContext, !siblings.isEmpty {
            let provider = DanmakuProvider(source: platform)
            let selectedTracks = siblings.filter { sibling in
                let siblingSource = sibling.source.isEmpty ? anime.source : sibling.source
                return provider == .automatic ? siblingSource == platform : DanmakuProvider(source: siblingSource) == provider
            }
            resolver.remember(DanmakuMapping(provider: provider == .automatic ? platform : provider.rawValue,
                title: context.videoName, year: context.year,
                tracks: selectedTracks.map { DanmakuTrack(number: $0.episodeNumber ?? CatalogDanmakuMatcher.episodeNumber($0.title),
                    title: $0.title, page: $0.url, id: $0.id, source: $0.source) }, animeID: anime.id, source: platform),
                for: context, ticket: ticket)
        }
        offset = 0; revision = UUID(); automaticState = comments.isEmpty ? "unmatched" : "loaded"; enabled = true
    }

    func clear(keepingContext: Bool = false) {
        cancelAutomatic()
        if keepingContext, let context = automaticContext { (currentResolver ?? Preferences.load().resolver()).forget(context) }
        if !keepingContext { automaticContext = nil; usesSourceComments = false; allowsAutomatic = true }
        resetComments()
    }
    private func resetComments() {
        comments = []; track = ""; source = ""; fromCache = false; offset = 0; revision = UUID()
        manuallySelected = false; selectedOverridesSource = false; currentResolver = nil
    }

    func importFile(_ url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= CatalogDanmakuParser.maximumBytes else { throw TVError.unsupported(L10n.text("The danmaku file is too large.")) }
        let parsed = try CatalogDanmakuParser.parse(Data(contentsOf: url, options: .mappedIfSafe))
        cancelAutomatic()
        comments = parsed; track = url.deletingPathExtension().lastPathComponent
        source = L10n.text("Imported file"); fromCache = false; manuallySelected = true; selectedOverridesSource = true
        let resolver = Preferences.load().resolver(); currentResolver = resolver; cacheCurrent(resolver: resolver)
        offset = 0; revision = UUID(); automaticState = parsed.isEmpty ? "unmatched" : "loaded"; enabled = true
    }
    private func cacheCurrent(resolver: DanmakuResolver, ticket: MediaCache.Ticket? = nil) {
        guard let context = automaticContext, !comments.isEmpty else { return }
        resolver.cache(AutomaticDanmakuResult(comments: comments, track: track, source: source, state: "loaded"),
                       for: context, ticket: ticket ?? MediaCache.shared.ticket())
    }
}

#if !os(tvOS)
struct CatalogDanmakuSettingsView: View {
    let model: CatalogDanmakuModel
    let channelName: String
    @Environment(\.dismiss) private var dismiss
    @AppStorage(DanmakuService.serverKey) private var server = CatalogDanmakuClient.defaultServer
    @AppStorage(DanmakuService.preferredSourceKey) private var preferredSource = ""
    @State private var keyword = ""
    @State private var animes: [CatalogDanmakuAnime] = []
    @State private var episodes: [CatalogDanmakuEpisode] = []
    @State private var selectedAnime: CatalogDanmakuAnime?
    @State private var busy = false
    @State private var searched = false
    @State private var error: String?
    @State private var work: Task<Void, Never>?
    @State private var workGeneration = UUID()
    @State private var showsImporter = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    DanmakuServiceSettings()
                    Section {
                        Text(status).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("danmaku.status")
                        Button(L10n.text("Retry automatic matching")) { cancelWork(); model.retryAutomatic() }.disabled(model.context == nil)
                        if !model.track.isEmpty {
                            Text(model.track).font(.subheadline)
                            Text(model.source + (model.fromCache ? " · " + L10n.text("From local cache") : "")).font(.caption).foregroundStyle(.secondary)
                            Text(L10n.text("Loaded %lld comments", model.comments.count)).foregroundStyle(.secondary)
                            Stepper(value: $model.offset, in: -300...300, step: 0.5) {
                                Text(L10n.text("Time Offset: %@ s", String(format: "%+.1f", model.offset)))
                            }
                            HStack {
                                Button(L10n.text("Advance 5 s")) { shift(by: -5) }
                                Button(L10n.text("Advance 0.5 s")) { shift(by: -0.5) }
                            }
                            HStack {
                                Button(L10n.text("Delay 0.5 s")) { shift(by: 0.5) }
                                Button(L10n.text("Delay 5 s")) { shift(by: 5) }
                                Button(L10n.text("Reset Timing")) { model.offset = 0 }.disabled(model.offset == 0)
                            }
                            Text(L10n.text("A positive offset shows comments later. Playback controls stay available."))
                                .font(.caption).foregroundStyle(.secondary)
                            Button(L10n.text("Clear Danmaku"), role: .destructive) { cancelWork(); model.clear(keepingContext: true) }
                        }
                    } header: { Text(L10n.text("Current Danmaku")) }
                    Section {
                        HStack {
                            TextField(L10n.text("Video title"), text: $keyword).onSubmit { search() }.accessibilityIdentifier("danmaku.keyword")
                            Button(L10n.text("Search")) { search() }.disabled(busy || keyword.trimmingCharacters(in: .whitespaces).isEmpty).accessibilityIdentifier("danmaku.search")
                        }
                        if busy { ProgressView(L10n.text("Loading…")) }
                        if let error { Text(error).foregroundStyle(.red).font(.callout) }
                        if let anime = selectedAnime {
                            Button(L10n.text("Back to search results")) { cancelWork(); selectedAnime = nil; episodes = []; error = nil }
                            Text(anime.title).font(.headline)
                            Text(animeDetails(anime)).font(.caption).foregroundStyle(.secondary)
                            ForEach(episodes, id: \.self) { episode in
                                Button { load(episode, anime: anime) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(episode.title)
                                        if !episode.source.isEmpty { Text(episode.sourceTitle).font(.caption).foregroundStyle(.secondary) }
                                    }
                                }
                                .disabled(busy).accessibilityIdentifier("danmaku.episode." + episode.id).id(episode.id)
                            }
                        } else {
                            ForEach(animes, id: \.self) { anime in
                                Button { select(anime) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(anime.title)
                                        Text(animeDetails(anime)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }.disabled(busy).accessibilityIdentifier("danmaku.anime." + anime.id)
                            }
                            if searched && animes.isEmpty && !busy && error == nil {
                                Text(L10n.text("No danmaku found. Try another title or server.")).foregroundStyle(.secondary)
                            }
                        }
                    } header: { Text(L10n.text("Find Danmaku")) }
                      footer: { Text(L10n.text("Search sends only the title to the selected danmaku service. Choose the correct season and episode; some videos have no comments.")) }
                    Section {
                        Button(L10n.text("Import Danmaku File")) { showsImporter = true }.disabled(busy)
                    } footer: { Text(L10n.text("Import Bilibili XML or Dandanplay JSON from Files. Imported comments do not require a network connection.")) }
                }
                // Grouped forms scroll on Mac, including a show with thousands of episodes.
                .formStyle(.grouped)
                .navigationTitle(L10n.text("Danmaku"))
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { dismiss() } } }
                #if DEBUG
                .task {
                    let pick = UserDefaults.standard.integer(forKey: "qaDanmakuSearch")
                    guard pick > 0 else { return }
                    try? await Task.sleep(for: .milliseconds(300))
                    search(); await work?.value
                    guard animes.indices.contains(pick - 1) else { return }
                    select(animes[pick - 1]); await work?.value
                    try? await Task.sleep(for: .seconds(1))
                    if let last = episodes.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                #endif
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 500, idealHeight: 640)
        #endif
        .onAppear { keyword = CatalogDanmakuMatcher.withoutReleaseNotes(channelName.components(separatedBy: " · ").first ?? channelName) }
        .onDisappear { cancelWork() }
        .onChange(of: server) { _, _ in resetSearch() }
        .onChange(of: preferredSource) { _, _ in resetSearch() }
        .onReceive(NotificationCenter.default.publisher(for: DanmakuService.changed)) { _ in resetSearch() }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.xml, .json]) { result in
            do { try model.importFile(result.get()); dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }

    private var status: String {
        switch model.automaticState {
        case "searching": L10n.text("Finding matching danmaku…")
        case "loaded": L10n.text("Loaded %lld comments", model.comments.count)
        case "unmatched": L10n.text("No matching episode has comments.")
        case "unavailable": L10n.text("Danmaku services are temporarily unavailable. Video playback is unaffected.")
        default: L10n.text("Automatic matching is idle.")
        }
    }
    private var source: DanmakuProvider { DanmakuProvider(rawValue: preferredSource) ?? .automatic }
    private func animeDetails(_ anime: CatalogDanmakuAnime) -> String {
        let platform = anime.source.isEmpty ? L10n.text("Unknown Source") : anime.sourceTitle
        return ([platform, anime.year ?? L10n.text("Unknown Year"), anime.type]).filter { !$0.isEmpty }.joined(separator: " · ")
    }
    private func shift(by seconds: Double) { model.offset = min(300, max(-300, model.offset + seconds)) }
    private func cancelWork() { workGeneration = UUID(); work?.cancel(); work = nil; busy = false }
    private func resetSearch() {
        cancelWork(); animes = []; episodes = []; selectedAnime = nil; searched = false; error = nil
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        cancelWork(); busy = true; error = nil
        let active = workGeneration
        work = Task { @MainActor in
            do { try await operation() }
            catch { if !Task.isCancelled, workGeneration == active { self.error = error.localizedDescription } }
            if !Task.isCancelled, workGeneration == active { busy = false; work = nil }
        }
    }
    private func search() {
        guard !busy else { return }
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        selectedAnime = nil; episodes = []; animes = []; searched = true
        let address = DanmakuService.server(), source = source
        perform {
            let results = try await CatalogDanmakuClient(address: address).search(query, source: source)
            try Task.checkCancellation(); animes = results
        }
    }
    private func select(_ anime: CatalogDanmakuAnime) {
        let address = DanmakuService.server()
        perform {
            let results = try await CatalogDanmakuClient(address: address).episodes(anime)
            try Task.checkCancellation(); episodes = results; selectedAnime = anime
            if results.isEmpty { error = L10n.text("No danmaku found. Try another title or server.") }
        }
    }
    private func load(_ episode: CatalogDanmakuEpisode, anime: CatalogDanmakuAnime) {
        let address = DanmakuService.server()
        perform { try await model.load(episode, anime: anime, client: CatalogDanmakuClient(address: address), siblings: episodes); dismiss() }
    }
}
#endif

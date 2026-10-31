import SwiftUI
import AVKit
import TVCore
import UniformTypeIdentifiers

@MainActor @Observable final class CatalogDanmakuModel {
    private(set) var comments: [CatalogDanmakuComment] = []
    private(set) var track = ""
    private(set) var revision = UUID()
    var offset = 0.0
    var enabled = UserDefaults.standard.object(forKey: "danmakuEnabled") == nil ? true : UserDefaults.standard.bool(forKey: "danmakuEnabled") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "danmakuEnabled")
            if !enabled { cancelAutomatic() }
            else if comments.isEmpty { startAutomatic(automaticContext) }
        }
    }
    var automatic = UserDefaults.standard.object(forKey: "danmakuAutoMatch") == nil ? true : UserDefaults.standard.bool(forKey: "danmakuAutoMatch") {
        didSet {
            UserDefaults.standard.set(automatic, forKey: "danmakuAutoMatch")
            if automatic { startAutomatic(automaticContext) } else { cancelAutomatic() }
        }
    }
    var opacity = UserDefaults.standard.object(forKey: "danmakuOpacity") as? Double ?? 0.85 {
        didSet { UserDefaults.standard.set(opacity, forKey: "danmakuOpacity") }
    }
    var fontSize = UserDefaults.standard.object(forKey: "danmakuFontSize") as? Double ?? 22 {
        didSet { UserDefaults.standard.set(fontSize, forKey: "danmakuFontSize") }
    }
    private var generation = UUID()
    private var automaticTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var automaticContext: PlaybackHistoryContext?
    private(set) var automaticState = "idle"
    private(set) var source = ""
    private(set) var fromCache = false
    var context: PlaybackHistoryContext? { automaticContext }

    @ObservationIgnored private var renderedKey: String?
    @ObservationIgnored private var rendered: [Danmaku] = []
    var renderedRevision: String { "\(revision):\(offset):\(fontSize)" }
    var renderedComments: [Danmaku] {
        let key = renderedRevision
        if renderedKey != key {
            renderedKey = key
            rendered = comments.map { comment in
                Danmaku(time: max(0, comment.time + offset),
                    position: comment.mode == .top ? .top : comment.mode == .bottom ? .bottom : .scroll,
                    color: comment.color, scale: fontSize / 22, text: comment.text)
            }
        }
        return rendered
    }

    func startAutomatic(_ context: PlaybackHistoryContext?) {
        cancelAutomatic()
        automaticContext = context
        guard let context, automatic, enabled, comments.isEmpty else { return }
        let active = generation
        automaticState = "searching"
        automaticTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == active { self.automaticTask = nil } }
            do {
                let defaults = UserDefaults.standard
                let resolver = DanmakuResolver(dandanServer: defaults.string(forKey: "danmakuServer") ?? CatalogDanmakuClient.defaultServer,
                    dmkuServer: URL(string: defaults.string(forKey: "danmakuDmkuServer") ?? "https://dmku.hls.one/") ?? URL(string: "https://dmku.hls.one/")!,
                    officialLookup: defaults.object(forKey: "danmakuOfficialLookup") == nil || defaults.bool(forKey: "danmakuOfficialLookup"))
                let result = try await resolver.resolve(context)
                try Task.checkCancellation()
                guard self.generation == active, self.enabled, self.automatic else { return }
                self.comments = result.comments
                self.track = result.track; self.source = result.source; self.fromCache = result.cached
                self.offset = 0; self.revision = UUID()
                self.automaticState = result.state
            } catch {
                guard self.generation == active else { return }
                // Optional overlay failures never interrupt video playback or show alerts.
                self.automaticState = error is CancellationError ? "idle" : "unavailable"
            }
        }
    }

    private func cancelAutomatic() {
        generation = UUID(); automaticTask?.cancel(); automaticTask = nil; prefetchTask?.cancel(); prefetchTask = nil; automaticState = "idle"
    }

    func prefetch(_ context: PlaybackHistoryContext?) {
        prefetchTask?.cancel()
        guard let context, automatic, enabled else { return }
        let active = generation
        let ticket = MediaCache.shared.ticket()
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            await self.automaticTask?.value
            guard !Task.isCancelled, self.generation == active, !self.comments.isEmpty else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, self.generation == active else { return }
            let defaults = UserDefaults.standard
            let resolver = DanmakuResolver(dandanServer: defaults.string(forKey: "danmakuServer") ?? CatalogDanmakuClient.defaultServer,
                dmkuServer: URL(string: defaults.string(forKey: "danmakuDmkuServer") ?? "https://dmku.hls.one/") ?? URL(string: "https://dmku.hls.one/")!,
                officialLookup: defaults.object(forKey: "danmakuOfficialLookup") == nil || defaults.bool(forKey: "danmakuOfficialLookup"))
            _ = try? await resolver.resolve(context, ticket: ticket)
        }
    }
    func retryAutomatic() {
        let context = automaticContext
        if let context { MediaCache.shared.remove(DanmakuResolver.episodeKey(context), kind: .danmaku, scope: context.id) }
        clear(); startAutomatic(context)
    }

    func load(_ episode: CatalogDanmakuEpisode, anime: CatalogDanmakuAnime, client: CatalogDanmakuClient, siblings: [CatalogDanmakuEpisode] = []) async throws {
        cancelAutomatic()
        let ticket = MediaCache.shared.ticket()
        let active = UUID(); generation = active
        let comments = try await client.comments(episode)
        try Task.checkCancellation()
        guard generation == active else { throw CancellationError() }
        self.comments = comments; track = anime.title + " · " + episode.title
        source = "Dandanplay"; fromCache = false; cacheCurrent(ticket: ticket)
        if let context = automaticContext, !siblings.isEmpty {
            DanmakuResolver(dandanServer: client.server.absoluteString).remember(
                DanmakuMapping(provider: "dandan", title: context.videoName, year: context.year,
                    tracks: siblings.map { DanmakuTrack(number: CatalogDanmakuMatcher.episodeNumber($0.title), title: $0.title, id: $0.id) }),
                for: context, ticket: ticket)
        }
        offset = 0; revision = UUID(); enabled = true
    }

    func clear(keepingContext: Bool = false) {
        cancelAutomatic()
        if !keepingContext { automaticContext = nil }
        else if let context = automaticContext { MediaCache.shared.remove(DanmakuResolver.episodeKey(context), kind: .danmaku, scope: context.id) }
        comments = []; track = ""; source = ""; fromCache = false; offset = 0; revision = UUID()
    }

    func importFile(_ url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= CatalogDanmakuParser.maximumBytes else { throw TVError.unsupported(L10n.text("The danmaku file is too large.")) }
        let parsed = try CatalogDanmakuParser.parse(Data(contentsOf: url, options: .mappedIfSafe))
        cancelAutomatic()
        comments = parsed; track = url.deletingPathExtension().lastPathComponent
        source = L10n.text("Imported file"); fromCache = false; cacheCurrent()
        offset = 0; revision = UUID(); enabled = true
    }
    private func cacheCurrent(ticket: MediaCache.Ticket? = nil) {
        guard let context = automaticContext, !comments.isEmpty,
              let data = try? JSONEncoder().encode(AutomaticDanmakuResult(comments: comments, track: track, source: source, state: "loaded")) else { return }
        MediaCache.shared.store(data, for: DanmakuResolver.episodeKey(context), kind: .danmaku, scope: context.id,
            ttl: 7 * 86400, ticket: ticket ?? MediaCache.shared.ticket())
    }
}

#if !os(tvOS)
struct CatalogDanmakuSettingsView: View {
    let model: CatalogDanmakuModel
    let channelName: String
    @Environment(\.dismiss) private var dismiss
    @AppStorage("danmakuServer") private var server = CatalogDanmakuClient.defaultServer
    @AppStorage("danmakuOfficialLookup") private var officialLookup = true
    @State private var keyword = ""
    @State private var animes: [CatalogDanmakuAnime] = []
    @State private var episodes: [CatalogDanmakuEpisode] = []
    @State private var selectedAnime: CatalogDanmakuAnime?
    @State private var busy = false
    @State private var searched = false
    @State private var error: String?
    @State private var work: Task<Void, Never>?
    @State private var showsImporter = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    Toggle(L10n.text("Show Danmaku"), isOn: $model.enabled).settingsSwitch().accessibilityIdentifier("danmaku.enabled")
                    Toggle(L10n.text("Automatically match the current episode"), isOn: $model.automatic)
                        .settingsSwitch()
                        .accessibilityIdentifier("danmaku.automatic")
                    Text(L10n.text("Matching comments appear automatically. If none match or the service is unavailable, the video stays clear."))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(status).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("danmaku.status")
                    Button(L10n.text("Retry automatic matching")) { model.retryAutomatic() }.disabled(model.context == nil)
                    if !model.track.isEmpty {
                        Text(model.track).font(.subheadline)
                        Text(model.source + (model.fromCache ? " · " + L10n.text("From local cache") : "")).font(.caption).foregroundStyle(.secondary)
                        Text(L10n.text("Loaded %lld comments", model.comments.count)).foregroundStyle(.secondary)
                        HStack {
                            Text(L10n.text("Opacity"))
                            Slider(value: $model.opacity, in: 0.2...1)
                        }
                        HStack {
                            Text(L10n.text("Text Size"))
                            Slider(value: $model.fontSize, in: 16...36, step: 2)
                        }
                        Stepper(value: $model.offset, in: -300...300, step: 0.5) {
                            Text(L10n.text("Time Offset: %@ s", String(format: "%+.1f", model.offset)))
                        }
                        Text(L10n.text("A positive offset shows comments later. Playback controls stay available."))
                            .font(.caption).foregroundStyle(.secondary)
                        Button(L10n.text("Clear Danmaku"), role: .destructive) { work?.cancel(); busy = false; model.clear(keepingContext: true) }
                    }
                }
                Section {
                    Toggle(L10n.text("Find official episodes for dmku"), isOn: $officialLookup).settingsSwitch()
                    Text(L10n.text("Uses Dandanplay first, then tries iQIYI and Tencent Video if no comments are found or the service is unavailable. Official public episode pages are sent to dmku, or to danmu.zxz.ee when dmku has none; stream URLs and playback headers are never sent."))
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField(L10n.text("Video title"), text: $keyword).onSubmit { search() }.accessibilityIdentifier("danmaku.keyword")
                        Button(L10n.text("Search")) { search() }.disabled(busy || keyword.trimmingCharacters(in: .whitespaces).isEmpty).accessibilityIdentifier("danmaku.search")
                    }
                    if busy { ProgressView(L10n.text("Loading…")) }
                    if let error { Text(error).foregroundStyle(.red).font(.callout) }
                    if let anime = selectedAnime {
                        Button(L10n.text("Back to search results")) { work?.cancel(); busy = false; selectedAnime = nil; episodes = []; error = nil }
                        Text(anime.title).font(.headline)
                        ForEach(episodes) { episode in
                            Button(episode.title) { load(episode, anime: anime) }.disabled(busy).accessibilityIdentifier("danmaku.episode." + episode.id)
                        }
                    } else {
                        ForEach(animes) { anime in
                            Button { select(anime) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(anime.title)
                                    if !anime.type.isEmpty { Text(anime.type).font(.caption).foregroundStyle(.secondary) }
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
                Section {
                    TextField(L10n.text("Danmaku server URL"), text: $server)
                        #if os(iOS)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        #endif
                        .onChange(of: server) { _, _ in
                            work?.cancel(); busy = false; animes = []; episodes = []; selectedAnime = nil; searched = false; error = nil
                        }
                    Button(L10n.text("Use Default URL")) { server = CatalogDanmakuClient.defaultServer }
                } header: { Text(L10n.text("Danmaku Service")) }
                  footer: { Text(L10n.text("Uses the official Dandanplay service. You can also enter your own compatible server.")) }
            }
            .navigationTitle(L10n.text("Danmaku"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 500)
        #endif
        .onAppear {
            if server.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")) == CatalogDanmakuClient.legacyDefaultServer { server = CatalogDanmakuClient.defaultServer }
            keyword = channelName.components(separatedBy: " · ").first ?? channelName
        }
        .onDisappear { work?.cancel() }
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

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        work?.cancel(); busy = true; error = nil
        work = Task { @MainActor in
            do { try await operation() }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            if !Task.isCancelled { busy = false }
        }
    }
    private func search() {
        guard !busy else { return }
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        selectedAnime = nil; episodes = []; animes = []; searched = true
        let address = server
        perform {
            let results = try await CatalogDanmakuClient(address: address).search(query)
            try Task.checkCancellation(); animes = results
        }
    }
    private func select(_ anime: CatalogDanmakuAnime) {
        let address = server
        perform {
            let results = try await CatalogDanmakuClient(address: address).episodes(anime)
            try Task.checkCancellation(); episodes = results; selectedAnime = anime
            if results.isEmpty { error = L10n.text("No danmaku found. Try another title or server.") }
        }
    }
    private func load(_ episode: CatalogDanmakuEpisode, anime: CatalogDanmakuAnime) {
        let address = server
        perform { try await model.load(episode, anime: anime, client: CatalogDanmakuClient(address: address), siblings: episodes); dismiss() }
    }
}
#endif

import SwiftUI
import TVCore

@MainActor @Observable final class Store {
    let searchModel = SearchModel()
    /// Song search and the music player; both outlive the Music page, so a song keeps playing elsewhere in the app.
    /// The Mac and Apple TV list every kind at once, in rows; a phone or iPad starts on songs.
    /// Music extensions the listener imported search alongside the catalogs; with none, they answer nothing at once.
    #if os(macOS) || os(tvOS)
    let musicSearch = MusicSearchModel(catalogs: MusicSearchModel.defaultCatalogs() + [MusicExtensionCatalog()], kind: .top)
    #else
    let musicSearch = MusicSearchModel(catalogs: MusicSearchModel.defaultCatalogs() + [MusicExtensionCatalog()])
    #endif
    let music = MusicPlaybackSession()
    /// The Music page's charts, playlists and new albums; fetched when that page first shows.
    /// The music extensions' library groups come after the catalogs' shelves.
    let musicBrowse = MusicBrowseModel(sources: MusicBrowseModel.defaultSources() + [MusicExtensionCatalog()])
    let recommendationModel = RecommendationModel()
    let playbackHistory: PlaybackHistory
    let playbackDefaults: UserDefaults
    let pinnedSources: PinnedSources
    let hiddenSources: HiddenSources
    let sourceOrder: SourceOrder
    /// Keeps the viewer's library the same on their other devices; nil for tests and QA's isolated data.
    let cloudSync: CloudSync?
    /// The history entry being resumed; another entry, or leaving the page, replaces or cancels it.
    private(set) var resumingHistoryID: String?
    private var resumeTask: Task<Void, Never>?
    /// Every enabled subscription merged in list order, plus configured cloud drives.
    var subscription: Subscription?
    /// The address being typed in to add a subscription.
    var subscriptionAddress: String
    /// What to call the subscription being added; empty shows where it lives instead.
    var subscriptionName = ""
    /// Every subscription the viewer added, in the order they merge.
    var subscriptions: [SubscriptionEntry] = []
    /// Why a subscription last failed to refresh, by address; its last good copy stays in use.
    var subscriptionErrors: [String: String] = [:]
    /// The last good copy of each subscription, by address.
    private(set) var documents: [String: Subscription] = [:]
    let favorites: Favorites
    var importing = false
    var error: String?
    /// Why the last subscription import failed. It shows under the address field, not in the app-wide alert: on
    /// iPhone and iPad that alert closed the Add Subscription sheet over it and took the viewer out of the form (#357).
    var importError: String?
    var notice: String?
    var playing: Channel? {
        // An episode of a listening source (audiobooks, radio, songs) plays in the music player instead (#289).
        didSet { if let channel = playing, let queue = listeningQueue(for: channel) { playing = nil; listen(queue, from: channel) } }
    }
    /// Set while a listening source's episode goes to the video player on purpose.
    @ObservationIgnored private var playsAsVideo = false
    /// The videos whose iPhone watch page is on screen (`PlaybackHistoryContext.id`): their episodes play at the top
    /// of the page instead of in the full-screen player.
    var watchPageScopes: Set<String> = []
    func playsInWatchPage(_ channel: Channel?) -> Bool {
        guard let scope = channel?.historyContext?.id else { return false }
        return watchPageScopes.contains(scope)
    }
    var playbackCatalog: PlaybackCatalog?
    /// The Cloud Files folder the playing file came from; its next file plays after it.
    var filesFolder: CloudFilesFolder?
    var resolvingEpisode: Episode?
    var episodeError: String?
    var autoPlayNext: Bool {
        didSet { if persistsChanges { defaults.set(autoPlayNext, forKey: "autoPlayNextEpisode") } }
    }
    private var episodeRequest = UUID()
    private var episodeTask: Task<Void, Never>?
    var section: AppSection = .home
    /// The Mac sidebar folds away while the manga reader fills the window, and comes back when it closes.
    /// macOS 26 floats the sidebar over the page, so it covered the left part of every comic page.
    var hidesSidebar = false
    /// Unlock additional sections once an enabled subscription has sources or live playlists.
    var extrasUnlocked: Bool {
        subscriptions.contains { $0.enabled && documents[$0.address].map { !$0.sites.isEmpty || !$0.lives.isEmpty } == true }
    }
    /// Sections kept out of the tab bar and sidebar until then; Manga while no Venera comic source list
    /// is subscribed (one is added with Add Subscription, like any other).
    var hiddenSections: [AppSection] {
        var hidden: [AppSection] = extrasUnlocked ? [] : [.music]
        if MangaStore.shared.repositories.isEmpty { hidden.append(.manga) }
        return hidden
    }
    private let defaults: UserDefaults
    private let http = HTTPClient()
    /// Rebuilt source rows are expensive (every source is classified and copied) and Watch Now reads
    /// them many times while drawing one frame. The stamp is the inputs, so a later frame reuses the row.
    /// Not observed: views fill these while drawing, and a write would draw every reader again.
    @ObservationIgnored private var siteListStamp = ""
    @ObservationIgnored private var cloudDrivesObserver: NSObjectProtocol?
    @ObservationIgnored private var livePluginsObserver: NSObjectProtocol?
    /// The installed live plugins' platforms, shown in Live TV even without a subscription.
    private(set) var livePluginPlatforms = LivePlugins.shared.platforms
    /// Live TV's sources: the subscription's (with the plugins' platforms), or the plugins' alone.
    var liveSources: [LiveSource] { subscription?.lives ?? livePluginPlatforms.map(\.source) }
    @ObservationIgnored private var automaticCache: [Site]?
    @ObservationIgnored private var orderedCache: [Site]?
    @ObservationIgnored private var recommendationCache: [Site]?
    @ObservationIgnored private var groupsCache: [Bool: [SourceGroup]] = [:]
    /// What the cached rows were built from: the merged subscription, which subscriptions are on, and the viewer's pins, hides, and order.
    private func currentSiteListStamp() -> String {
        let imported = subscription?.importedAt.timeIntervalSince1970 ?? 0
        let entries = subscriptions.map { "\($0.address)=\($0.enabled)" }.joined(separator: "\n")
        return "\(subscription?.origin.absoluteString ?? "")|\(imported)|\(subscription?.sites.count ?? 0)|\(entries)|\(pinnedSources.revision)|\(hiddenSources.revision)|\(sourceOrder.revision)"
    }
    private var persistsChanges: Bool {
        #if DEBUG
        return !defaults.bool(forKey: "qaIsolatedData")
        #else
        return true
        #endif
    }
    init(defaults: UserDefaults = .standard) {
        #if os(macOS)
        if defaults === UserDefaults.standard { Self.adoptPreviousBundleDefaults(defaults) }
        #endif
        self.defaults = defaults
        #if DEBUG
        playbackDefaults = defaults.bool(forKey: "qaIsolatedData")
            ? UserDefaults(suiteName: "com.tvbox.yingxia.qa.player") ?? defaults : defaults
        playbackHistory = defaults.bool(forKey: "qaIsolatedData")
            ? PlaybackHistory(file: URL.cachesDirectory.appending(path: "qa-player-history.json"), defaults: playbackDefaults) : .shared
        #else
        playbackDefaults = defaults
        playbackHistory = .shared
        #endif
        pinnedSources = PinnedSources(defaults: playbackDefaults)
        hiddenSources = HiddenSources(defaults: playbackDefaults)
        #if os(macOS) || os(iOS)
        WebSniff.install(WKWebSniffer())
        #endif
        sourceOrder = SourceOrder(defaults: playbackDefaults)
        cloudSync = defaults === UserDefaults.standard && !defaults.bool(forKey: "qaIsolatedData") ? CloudSync() : nil
        favorites = Favorites(defaults: defaults)
        autoPlayNext = defaults.object(forKey: "autoPlayNextEpisode") == nil || defaults.bool(forKey: "autoPlayNextEpisode")
        let saved = defaults.data(forKey: "subscriptions").flatMap { try? JSONDecoder().decode([SubscriptionEntry].self, from: $0) }
        var entries = saved ?? [], copies: [String: Subscription] = [:]
        for entry in entries {
            if let data = try? Data(contentsOf: Self.file(for: entry)),
               let value = try? JSONDecoder().decode(Subscription.self, from: data) { copies[entry.address] = value }
        }
        // Builds before several subscriptions kept one, in subscription.json, and before that in defaults.
        let legacyAddress = saved == nil ? defaults.string(forKey: "subscriptionAddress") : nil
        let legacy = legacyAddress == nil ? nil : (try? Data(contentsOf: Self.legacyFile)) ?? defaults.data(forKey: "subscription")
        if let legacyAddress {
            entries = [SubscriptionEntry(address: legacyAddress)]
            copies[legacyAddress] = legacy.flatMap { try? JSONDecoder().decode(Subscription.self, from: $0) }
        }
        subscriptions = entries
        documents = copies
        subscriptionAddress = ""
        if persistsChanges, let legacyAddress {
            if let legacy, copies[legacyAddress] != nil { try? Self.save(legacy, to: Self.file(for: entries[0])) }
            saveSubscriptionList()
            try? FileManager.default.removeItem(at: Self.legacyFile)
            defaults.removeObject(forKey: "subscription")
        }
        rebuildSubscription(resetting: false)
        // Signing in to a drive or adding a server adds its source; signing out or removing one takes it away.
        cloudDrivesObserver = NotificationCenter.default.addObserver(forName: CloudFiles.drivesChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshCloudFilesSources() }
        }
        // Installing or removing a live plugin adds or takes away its platform.
        livePluginsObserver = NotificationCenter.default.addObserver(forName: LivePlugins.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.livePluginPlatforms = LivePlugins.shared.platforms
                self.rebuildSubscription(resetting: false)
            }
        }
        searchModel.order = sourceOrder
        DownloadLibrary.shared.resolver = { [weak self] item in
            guard let self else { throw CancellationError() }
            return try await self.resolveDownload(item)
        }
        // Songs that were downloading when the app quit carry on.
        MusicDownloadLibrary.shared.wake()
        setUpListening()
        setUpCloudSync()
    }
    // MARK: Listening sources (#289)

    /// The music player's queue for an episode of a listening source: the episodes of its line, from it on. Nil for
    /// other sources, for one whose streams turned out to be videos, and when the episode's details aren't at hand.
    private func listeningQueue(for channel: Channel) -> MusicQueue? {
        guard !playsAsVideo, let context = channel.historyContext, let catalog = catalog(for: channel),
              AudioSources.isCandidate(catalog.client.site),
              !AudioSourceVerdicts(defaults: playbackDefaults).showsVideo(context),
              let episode = context.episode(in: catalog.video.episodes) else { return nil }
        return AudioSources.queue(video: catalog.video, from: episode, site: catalog.client.site, origin: catalog.client.origin)
    }

    /// Plays the queue from the channel's stream, where this chapter stopped last time.
    private func listen(_ queue: MusicQueue, from channel: Channel) {
        var position = channel.resumePosition
        if position == nil, let context = channel.historyContext,
           let saved = playbackHistory.entries.first(where: { $0.id == context.id }),
           saved.context.episodeID == context.episodeID, saved.context.episodeFlag == context.episodeFlag, saved.resumePosition > 1 {
            position = saved.resumePosition
        }
        Diagnostics.shared.record(.info, "music", "listening source \(channel.historyContext?.sourceKey ?? "-") queue=\(queue.tracks.count)")
        music.play(queue, at: position, stream: channel)
        #if os(iOS)
        // Opened as a video opens its player (Apple TV's `play` does the same). The page the chapter was chosen on
        // has no music strip: the iPhone watch page hides the tab bar that holds it, and an iPad shows it only on
        // Music's pages, so the song played with its controls only in Control Center (#570).
        music.presentsPlayer = true
        #endif
    }

    /// The music player gets a source's streams from here, saves where a book is in the playback history, and hands
    /// an episode with a picture, or one it can't play, to the video player.
    private func setUpListening() {
        music.resolveSource = { [weak self] source in
            guard let self else { throw CancellationError() }
            return try await self.resolveListening(source)
        }
        music.recordSource = { [weak self] source, position, duration in
            self?.playbackHistory.record(source.context, position: position, duration: duration)
        }
        music.handOffSource = { [weak self] stream, position, picture, covered in
            guard let self, let context = stream.historyContext else { return }
            if picture { AudioSourceVerdicts(defaults: self.playbackDefaults).recordVideo(context) }
            let channel = Channel(name: stream.name, group: stream.group, url: stream.url, logo: stream.logo, headers: stream.headers,
                                  skipScope: stream.skipScope, historyContext: context, resumePosition: position > 1 ? position : nil,
                                  subtitles: stream.subtitles)
            Task { @MainActor [weak self] in
                // The video player can't open while Now Playing is still closing (as PlayOn waits for the player).
                if covered { try? await Task.sleep(for: .milliseconds(700)) }
                guard let self, self.playing == nil else { return }
                self.playsAsVideo = true
                self.playing = channel
                self.playsAsVideo = false
            }
        }
    }

    /// A chapter's stream from its source, as Continue Watching gets an episode's.
    private func resolveListening(_ source: MusicSourceEpisode) async throws -> Channel {
        let context = source.context
        guard let client = historyClient(PlaybackHistoryEntry(context: context, position: 0, duration: 0, updatedAt: Date())) else {
            throw TVError.unsupported(L10n.text("This history source is no longer in the current subscription. Restore that subscription to continue."))
        }
        let resolved = try await client.playback(source.episode)
        return Channel(name: "\(context.videoName) · \(context.episodeName)", group: resolved.group, url: resolved.url, logo: resolved.logo,
                       headers: resolved.headers, skipScope: context.id, historyContext: context, subtitles: resolved.subtitles)
    }

    /// The current media address of a downloading episode, from its source; the queue asks again when a link expires.
    private func resolveDownload(_ item: DownloadItem) async throws -> Channel {
        let config = subscription
        guard let site = config?.sites.first(where: { $0.key == item.source.siteKey })
                ?? CloudSources.current?.sites.first(where: { $0.key == item.source.siteKey }) else {
            throw TVError.unsupported(L10n.text("%@ is no longer in your subscription, so caching can't continue.", item.source.siteName))
        }
        let base = CatalogClient(site: site, origin: config?.origin ?? URL(string: "https://example.invalid/")!, jarURL: config?.spiderURL)
        let client = config.map { base.applying($0) } ?? base
        let plan = try await client.preparePlayback(item.source.episode, forDownload: true)
        let channel = try await client.resolvePlayback(plan, choice: plan.choices[0])
        // A cloud-drive file downloads straight from its CDN, as it plays: through the plugin's
        // proxy every part costs the embedded runtime download threads and interpreted TLS.
        // A file of a drive in Cloud Files downloads from the address its stream reads.
        if channel.url.scheme == CloudStreams.scheme, let media = await CloudStreams.source(for: channel.url) {
            CloudStreams.stop(channel.url)
            return Channel(name: channel.name, group: channel.group, url: media.url, headers: media.headers)
        }
        // A drive's HLS copy downloads with the headers its CDN wants.
        if let headers = CloudStreams.playlistHeaders(for: channel.url) {
            CloudStreams.stop(channel.url)
            return Channel(name: channel.name, group: channel.group, url: channel.url, headers: channel.headers.merging(headers) { $1 })
        }
        let address = try await EmbeddedJarHost.shared.recoverProxy(channel.url)
        if let media = await EmbeddedJarHost.shared.directMedia(address) {
            Diagnostics.shared.record(.info, "download", "cloud direct host=\(media.url.host() ?? "-") length=\(media.length)")
            return Channel(name: channel.name, group: channel.group, url: media.url, headers: media.headers)
        }
        return address == channel.url ? channel : Channel(name: channel.name, group: channel.group, url: address, headers: channel.headers)
    }
    /// Large subscriptions run to megabytes, past the defaults size limit that aborts tvOS apps,
    /// so each parsed subscription lives in a file. tvOS only offers Caches, which the system may purge;
    /// `restoreSubscription()` refetches what is gone from the saved addresses.
    private static var subscriptionDirectory: URL {
        #if os(tvOS)
        return URL.cachesDirectory
        #else
        return URL.applicationSupportDirectory
        #endif
    }
    private static var legacyFile: URL { subscriptionDirectory.appending(path: "subscription.json") }
    private static func file(for entry: SubscriptionEntry) -> URL {
        subscriptionDirectory.appending(path: "subscriptions").appending(path: entry.cacheName)
    }
    private static func save(_ data: Data, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }
    /// Lets sources on a shared spider borrow classes from the subscription's other plugin archives.
    private static func registerPlugins(_ subscription: Subscription) {
        let archives = subscription.pluginArchives
        Task { await PluginLocator.shared.use(archives) }
    }
    /// Refetches enabled subscriptions whose cached copy is gone.
    func restoreSubscription() async {
        let missing = subscriptions.filter { $0.enabled && documents[$0.address] == nil }
        guard !missing.isEmpty, !importing else { return }
        importing = true
        defer { importing = false }
        await fetch(missing)
    }
    /// Adds the typed address, or refreshes it when it is already in the list. A directory (多仓)
    /// adds every subscription it lists, switched off, for the viewer to choose from.
    /// `address` is one typed in Settings, or one a link or a file handed over; `name` labels it the way a
    /// typed name does, and stays empty for a file.
    func importSubscription(address: String? = nil, name: String? = nil) async {
        guard !importing else { return }
        importing = true; importError = nil; notice = nil
        defer { importing = false }
        let typed = (address ?? subscriptionAddress).trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let url = try WebAddress.resolve(typed: typed)
            switch try await http.subscriptionImport(url) {
            case .subscription(let value):
                let title = (address == nil ? subscriptionName : (name ?? "")).trimmingCharacters(in: .whitespacesAndNewlines)
                let entry = SubscriptionEntry(address: url.absoluteString, name: title)
                if let index = subscriptions.firstIndex(where: { $0.address == entry.address }) {
                    subscriptions[index].enabled = true
                    if !title.isEmpty { subscriptions[index].name = title }
                } else { subscriptions.append(entry) }
                keep(value, for: entry)
                if persistsChanges { defaults.set(url.absoluteString, forKey: "subscriptionAddress") }
                notice = L10n.text("Imported sources: %lld · Live playlists: %lld", value.sites.count, value.lives.count)
            case .directory(let entries):
                let added = entries.filter { entry in !subscriptions.contains { $0.address == entry.address } }
                subscriptions += added
                notice = L10n.text("This address lists %lld subscriptions. They were added switched off; turn on the ones you want.", added.count)
            case .comicSources(let count):
                // Comic source lists feed Manga (and show it); they are listed under Subscriptions too.
                MangaStore.shared.addRepository(url)
                notice = L10n.text("Added a Venera comic source list (%lld sources). Choose the ones to install in Comic Sources.", count)
            case .alist(let servers):
                // AList servers are browsed in Cloud Files, not merged as sources.
                let saved = try AListServers.add(servers)
                notice = saved.count == 1 ? L10n.text("Added the AList server %@. Browse it in Cloud Files.", saved[0].name)
                    : L10n.text("Added %lld AList servers. Browse them in Cloud Files.", saved.count)
            }
            if address == nil { subscriptionAddress = ""; subscriptionName = "" }
            saveSubscriptionList()
            rebuildSubscription()
        } catch {
            Diagnostics.shared.failure("subscription", "import host=\((try? WebAddress.resolve(typed: typed))?.host() ?? "-")", error)
            importError = L10n.text("Import failed: %@", error.localizedDescription)
        }
    }
    /// Adds a subscription, or one spider script, from a file the viewer picked. The file is copied
    /// into the app (see `ImportedFiles`) and then added like an address.
    func importSubscriptionFile(_ file: URL) async {
        let scoped = file.startAccessingSecurityScopedResource()
        let copied = Result { try ImportedFiles.add(file) }
        if scoped { file.stopAccessingSecurityScopedResource() }
        guard case .success(let url) = copied else {
            if case .failure(let error) = copied { importError = L10n.text("Import failed: %@", error.localizedDescription) }
            return
        }
        let address = url.absoluteString, known = subscriptions.contains { $0.address == address }
        await importSubscription(address: address)
        // A file that added no subscription of its own leaves no copy behind.
        if !known, !subscriptions.contains(where: { $0.address == address }) { ImportedFiles.remove(address) }
    }
    /// Fetches every enabled subscription again; one that fails keeps its last good copy.
    func refreshSubscriptions() async {
        guard !importing else { return }
        importing = true; importError = nil; notice = nil
        defer { importing = false }
        await fetch(subscriptions.filter(\.enabled))
        let failed = subscriptions.filter { $0.enabled && subscriptionErrors[$0.address] != nil && !ImportedFiles.isMissing($0.address) }.count
        if failed > 0 { notice = L10n.text("%lld subscriptions could not be refreshed; their last copies stay in use.", failed) }
    }
    func setSubscription(_ entry: SubscriptionEntry, enabled: Bool) async {
        guard let index = subscriptions.firstIndex(where: { $0.address == entry.address }) else { return }
        subscriptions[index].enabled = enabled
        saveSubscriptionList()
        if enabled, documents[entry.address] == nil { await restoreSubscription() } else { rebuildSubscription() }
    }
    /// Names a subscription in Settings and Sources; an empty name shows where it lives again.
    func renameSubscription(_ entry: SubscriptionEntry, to name: String) {
        guard let index = subscriptions.firstIndex(where: { $0.address == entry.address }), subscriptions[index].name != name else { return }
        subscriptions[index].name = name
        saveSubscriptionList()
    }
    func removeSubscription(_ entry: SubscriptionEntry) { removeSubscriptions([entry.address]) }
    /// Removes several subscriptions and their saved copies, then merges what is left once.
    func removeSubscriptions(_ addresses: Set<String>) {
        let removed = subscriptions.filter { addresses.contains($0.address) }
        guard !removed.isEmpty else { return }
        subscriptions.removeAll { addresses.contains($0.address) }
        for entry in removed {
            documents[entry.address] = nil; subscriptionErrors[entry.address] = nil
            if persistsChanges { try? FileManager.default.removeItem(at: Self.file(for: entry)); ImportedFiles.remove(entry.address) }
        }
        saveSubscriptionList()
        rebuildSubscription()
    }
    /// Moves a subscription one place up (-1) or down (1); earlier subscriptions win duplicate sources.
    func moveSubscription(_ entry: SubscriptionEntry, by offset: Int) {
        guard let index = subscriptions.firstIndex(where: { $0.address == entry.address }),
              subscriptions.indices.contains(index + offset) else { return }
        subscriptions.swapAt(index, index + offset)
        saveSubscriptionList()
        rebuildSubscription()
    }
    func moveSourceGroup(_ address: String, onto target: String, includeHidden: Bool) {
        let shown = sourceGroups(includeHidden: includeHidden).compactMap { group -> String? in
            guard case .subscription(let value) = group.kind else { return nil }
            return value
        }
        let next = SubscriptionOrder.moving(address, onto: target, in: shown)
        guard next != shown else { return }
        subscriptions = SubscriptionOrder.applying(displayed: next, to: subscriptions)
        saveSubscriptionList()
        rebuildSubscription()
    }

    /// Fetches subscriptions side by side, keeps what arrives, and shows the merged result. A
    /// subscription that turns out to be a directory is replaced by the ones it lists, switched off.
    private func fetch(_ entries: [SubscriptionEntry]) async {
        // A file added on another device has no copy here to read. Its row says so; it is not fetched, counted or
        // reported as a failed refresh (#842).
        let entries = entries.filter { entry in
            guard ImportedFiles.isMissing(entry.address) else { return true }
            subscriptionErrors[entry.address] = ImportedFiles.missingMessage
            return false
        }
        let http = http
        let results = await withTaskGroup(of: (SubscriptionEntry, Result<SubscriptionImport, any Error>).self) { group in
            for entry in entries {
                group.addTask {
                    do { return (entry, .success(try await http.subscriptionImport(WebAddress.resolve(entry.address)))) }
                    catch { return (entry, .failure(error)) }
                }
            }
            var all: [(SubscriptionEntry, Result<SubscriptionImport, any Error>)] = []
            for await result in group { all.append(result) }
            return all
        }
        for (entry, result) in results {
            switch result {
            case .success(.subscription(let value)): keep(value, for: entry)
            case .success(.directory(let listed)):
                guard let index = subscriptions.firstIndex(where: { $0.address == entry.address }) else { continue }
                let known = Set(subscriptions.map(\.address))
                subscriptions.replaceSubrange(index...index, with: listed.filter { !known.contains($0.address) })
            case .success(.comicSources):
                subscriptionErrors[entry.address] = L10n.text("This address is now a comic source list. Add it again to use it for Manga.")
            case .success(.alist):
                subscriptionErrors[entry.address] = L10n.text("This address is now an AList server. Add it again to browse it in Cloud Files.")
            case .failure(let error):
                Diagnostics.shared.failure("subscription", "refresh host=\(URL(string: entry.address)?.host() ?? "-")", error)
                subscriptionErrors[entry.address] = error.localizedDescription
            }
        }
        saveSubscriptionList()
        rebuildSubscription()
    }
    private func keep(_ value: Subscription, for entry: SubscriptionEntry) {
        documents[entry.address] = value
        subscriptionErrors[entry.address] = nil
        if persistsChanges, let data = try? JSONEncoder().encode(value) { try? Self.save(data, to: Self.file(for: entry)) }
    }
    private func saveSubscriptionList() {
        guard persistsChanges else { return }
        defaults.set(try? JSONEncoder().encode(subscriptions), forKey: "subscriptions")
        cloudSync?.changed("subscriptions")
    }
    /// Favorites, Continue Watching, subscriptions and the viewer's pins, hides and order follow them to their other
    /// devices. Continue Watching changes every few seconds while a video plays, so it waits longer between writes.
    private func setUpCloudSync() {
        guard let sync = cloudSync else { return }
        let favorites = favorites, history = playbackHistory, pinned = pinnedSources, hidden = hiddenSources, order = sourceOrder
        sync.register("favorites", current: { favorites.syncValues }, apply: { favorites.adopt($0) })
        sync.register("history", delay: .seconds(30), current: { Dictionary(history.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) },
                      apply: { history.adopt($0.map(\.value)) })
        sync.register("subscriptions", current: { [weak self] in self?.syncedSubscriptions ?? [:] }, apply: { [weak self] in self?.adoptSubscriptions($0) })
        sync.register("pinnedSources", current: { CloudSync.ranks(pinned.savedKeys) }, apply: { pinned.adopt(CloudSync.ordered($0)) })
        sync.register("hiddenSources", current: { Dictionary(hidden.savedKeys.map { ($0, true) }, uniquingKeysWith: { first, _ in first }) },
                      apply: { hidden.adopt($0.sorted { ($0.stamp, $0.id) < ($1.stamp, $1.id) }.map(\.id)) })
        sync.register("sourceOrder", current: { CloudSync.ranks(order.savedKeys) }, apply: { order.adopt(CloudSync.ordered($0)) })
        // Only "on" is an item: a new device's default (off) is no change, so it can't switch the order off everywhere.
        sync.register("sourceOrderOn", current: { order.enabled ? ["on": true] : [:] }, apply: { if order.enabled == $0.isEmpty { order.enabled = !$0.isEmpty } })
        favorites.onChange = { sync.changed("favorites") }
        history.onChange = { sync.changed("history") }
        pinned.onChange = { sync.changed("pinnedSources") }
        hidden.onChange = { sync.changed("hiddenSources") }
        order.onChange = { sync.changed("sourceOrder"); sync.changed("sourceOrderOn") }
    }
    private var syncedSubscriptions: [String: SyncedSubscription] {
        Dictionary(subscriptions.enumerated().map { ($0.element.address, SyncedSubscription(entry: $0.element, rank: $0.offset)) },
                   uniquingKeysWith: { first, _ in first })
    }
    /// Subscriptions another device added, renamed, switched, moved or removed. A new one that is on loads.
    private func adoptSubscriptions(_ synced: [CloudSyncItem<SyncedSubscription>]) {
        let next = synced.sorted { ($0.value.rank, $0.id) < ($1.value.rank, $1.id) }.map(\.value.entry)
        guard next != subscriptions else { return }
        let kept = Set(next.map(\.address))
        for entry in subscriptions where !kept.contains(entry.address) {
            documents[entry.address] = nil; subscriptionErrors[entry.address] = nil
            try? FileManager.default.removeItem(at: Self.file(for: entry))
        }
        subscriptions = next
        saveSubscriptionList()
        if subscriptions.contains(where: { $0.enabled && documents[$0.address] == nil }) { Task { await restoreSubscription() } }
        else { rebuildSubscription() }
    }
    /// Shows every enabled subscription that has a copy, merged in list order.
    private func rebuildSubscription(resetting: Bool = true) {
        if resetting { searchModel.reset(); recommendationModel.reset() }
        let enabled = subscriptions.filter(\.enabled).compactMap { documents[$0.address] }
        // Only an explicitly enabled subscription may supply service metadata. Ignore the old automatic cache.
        CloudSources.current = enabled.first(where: CloudSources.accepts)
        subscription = Subscription.merge(enabled)?.withCloudFiles().withLivePlugins()
        if let subscription {
            Self.registerPlugins(subscription)
            hiddenSources.restoreBuiltIns(subscription.sites, origin: subscription.origin)
            hiddenSources.restoreAutoHidden(subscription.sites, origin: subscription.origin, health: .shared)
            #if os(iOS) || os(tvOS)
            // Converts the visible JAR sources' likely classes while the app sits idle (issue #274).
            let visible = subscription.sites.filter { !hiddenSources.contains($0, origin: subscription.origin) }
            let origin = subscription.origin, spider = subscription.spiderURL
            Task { await PluginConversionAhead.shared.schedule(sites: visible, origin: origin, spider: spider) }
            #endif
        }
    }
    private func refreshCloudFilesSources() {
        guard let subscription, subscription.sites.filter(\.isCloudFiles) != CloudFilesSource.sites() else { return }
        rebuildSubscription()
    }
    func searchVideos(_ title: String) {
        guard let config = subscription else { return }
        let keyword = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        let old = defaults.data(forKey: "videoSearchHistory").flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        defaults.set(try? JSONEncoder().encode(Array(([keyword] + old.filter { $0 != keyword }).prefix(20))), forKey: "videoSearchHistory")
        searchModel.search(keyword, config: config) { [hiddenSources] site in
            hiddenSources.contains(site, origin: config.origin)
        }
        section = .search
    }
    func toggleFavorite(_ channel: Channel) { favorites.toggle(.live(channel)) }
    func isFavorite(_ channel: Channel) -> Bool { favorites.contains(.live(channel)) }

    func catalogClient(for video: FavoriteVideo) -> CatalogClient? {
        guard let config = subscription,
              let site = config.sites.first(where: { $0.origin(or: config.origin) == video.origin && $0.sourceKey == video.sourceKey }) else { return nil }
        return CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL)
    }
    func reportMissingFavoriteSource() {
        error = L10n.text("This favorite's source is no longer in the current subscription. Restore that subscription to open it.")
    }

    func play(_ episode: FavoriteEpisode) {
        guard catalogClient(for: episode.video) != nil else { reportMissingFavoriteSource(); return }
        let position = episode.resumePosition(in: playbackHistory.entries)
        resume(PlaybackHistoryEntry(context: episode.historyContext(), position: position, duration: 0, updatedAt: Date()))
    }

    func play(_ file: FavoriteCloudFile) {
        guard let drive = CloudFiles.drive(key: file.driveKey) else {
            error = L10n.text("This file's drive is no longer in Cloud Files.")
            return
        }
        let cloud = CloudFile(id: file.fileID, name: file.fileName, isFolder: false, size: file.size)
        playFile(cloud, in: CloudFilesFolder(drive: drive, id: file.folderID, name: file.folderName, files: [cloud]))
    }

    /// The Watch Now source row: pinned, then built-in, then the sources page's subscription order.
    func recommendationSites(_ config: Subscription) -> [Site] {
        let stamp = currentSiteListStamp()
        if stamp == siteListStamp, let cached = recommendationCache { return cached }
        let leading = automaticSites(config)
        let pinned = leading.filter { pinnedSources.contains($0, origin: config.origin) }
        let builtIn = leading.filter { $0.isBuiltIn && !pinnedSources.contains($0, origin: config.origin) }
        let groups = sourceGroups(includeHidden: false)
        let result = SourceGroups.homeRow(pinned: pinned, builtIn: builtIn, groups: groups)
        rememberSiteLists(stamp)
        recommendationCache = result
        return result
    }

    /// The sources to show, in the viewer's own order while it is on.
    func orderedSites(_ config: Subscription) -> [Site] {
        let stamp = currentSiteListStamp()
        if stamp == siteListStamp, let cached = orderedCache { return cached }
        let sites = automaticSites(config)
        let arranged = sourceOrder.enabled ? sourceOrder.arrange(sites, origin: config.origin) : sites
        rememberSiteLists(stamp)
        orderedCache = arranged
        return arranged
    }

    /// The order the app picks: built-in sources, then `SourceStrategy`'s, with pinned sources first. Hidden sources stay out.
    func automaticSites(_ config: Subscription) -> [Site] {
        let stamp = currentSiteListStamp()
        if stamp == siteListStamp, let cached = automaticCache { return cached }
        let sites = SourceLists.browsable(config.sites, jarURL: config.spiderURL) { hiddenSources.contains($0, origin: config.origin) }
        let arranged = pinnedSources.arrange(sites.filter(\.isBuiltIn) + sites.filter { !$0.isBuiltIn }, origin: config.origin)
        rememberSiteLists(stamp)
        automaticCache = arranged
        return arranged
    }

    /// Drops cached rows when their inputs changed. Each list fills itself, so a caller that only needs one does not build the others.
    private func rememberSiteLists(_ stamp: String) {
        guard stamp != siteListStamp else { return }
        siteListStamp = stamp
        automaticCache = nil
        orderedCache = nil
        recommendationCache = nil
        groupsCache = [:]
    }

    /// Turns the viewer's own source order on or off. The first time, it starts from the order on
    /// screen, so nothing jumps.
    func setCustomSourceOrder(_ enabled: Bool) {
        if enabled, sourceOrder.isEmpty, let config = subscription { sourceOrder.save(automaticSites(config), origin: config.origin) }
        sourceOrder.enabled = enabled
    }

    /// Moves a source within the viewer's order; `offset` is a position in `orderedSites`, as `move(fromOffsets:toOffset:)` takes it.
    func moveSource(_ site: Site, to offset: Int) {
        guard let config = subscription else { return }
        var sites = orderedSites(config)
        guard let index = sites.firstIndex(where: { $0.id == site.id }) else { return }
        sites.move(fromOffsets: [index], toOffset: max(0, min(offset, sites.count)))
        sourceOrder.save(sites, origin: config.origin)
    }

    /// The sources page's sections: pinned, built-in, then one per subscription.
    func sourceGroups(includeHidden: Bool) -> [SourceGroup] {
        let stamp = currentSiteListStamp()
        if stamp == siteListStamp, let cached = groupsCache[includeHidden] { return cached }
        guard let config = subscription else { return [] }
        let pins = pinnedSources.arrange(config.sites, origin: config.origin).filter { pinnedSources.contains($0, origin: config.origin) }
        var groups = SourceGroups.make(entries: subscriptions, documents: documents, builtIns: config.sites.filter(\.isBuiltIn), builtInOrigin: config.origin, mergedSites: config.sites, pinOrder: pins, userHidden: { hiddenSources.contains($0, origin: config.origin) }, includeHidden: includeHidden, jarURL: config.spiderURL)
        // The viewer's own order, while it is on, orders the sources inside each group too.
        if sourceOrder.enabled { groups = sourceOrder.arrange(groups, origin: config.origin) }
        rememberSiteLists(stamp)
        groupsCache[includeHidden] = groups
        return groups
    }

    func catalogChannel(_ resolved: Channel, video: Video, episode: Episode, client: CatalogClient,
                        resumePosition: Double? = nil) -> Channel {
        let channel = episodeChannel(resolved, video: video, episode: episode, client: client, resumePosition: resumePosition)
        remember(video, client: client.with(parses: subscription?.parseServices ?? client.parses), for: channel)
        return channel
    }

    /// The channel that plays `episode`, without making its video the one playing.
    private func episodeChannel(_ resolved: Channel, video: Video, episode: Episode, client: CatalogClient,
                                resumePosition: Double? = nil) -> Channel {
        let context = PlaybackHistoryContext(origin: client.origin, site: client.site, video: video, episode: episode)
        return Channel(name: "\(video.name) · \(episode.name)", group: resolved.group, url: resolved.url,
                       logo: resolved.logo, headers: resolved.headers, skipScope: context.id,
                       historyContext: context, resumePosition: resumePosition, subtitles: resolved.subtitles, skips: resolved.skips,
                       bilibiliPart: client.site.isBilibili ? BilibiliAPI.Part(address: episode.address) : nil)
    }

    /// The video and its episode list, for the player's episode buttons and the next episode.
    private func remember(_ video: Video, client: CatalogClient, for channel: Channel) {
        guard let context = channel.historyContext else { return }
        if let data = try? JSONEncoder().encode(video) {
            MediaCache.shared.store(data, for: "detail", kind: .catalog, scope: context.id, ttl: 6 * 3600, ticket: MediaCache.shared.ticket())
        }
        // The Episodes menu's short labels (#318): kept from the episode before on the same video, else worked out off the
        // main thread.
        let kept = playbackCatalog.flatMap { $0.video == video ? $0 : nil }
        playbackCatalog = PlaybackCatalog(video: video, client: client, scope: context.id, labels: kept?.labels ?? [:], details: kept?.details ?? [:])
        guard kept == nil else { return }
        let episodes = video.episodes
        Task { [weak self] in
            let (labels, details) = await Task.detached(priority: .utility) {
                let labels = EpisodeLabels.labels(episodes)
                return (labels, EpisodeFileInfo.details(episodes, labels: labels))
            }.value
            // Still this video, though maybe the next episode by now.
            guard let self, !labels.isEmpty || !details.isEmpty, self.playbackCatalog?.video == video else { return }
            self.playbackCatalog?.labels = labels
            self.playbackCatalog?.details = details
        }
    }

    /// The next episode's stream, resolved ahead so the player can queue it behind this one; nil when
    /// auto-play is off, there is no next episode, or the source can't resolve it now.
    func upcomingEpisode(after channel: Channel) async -> Channel? {
        // Only while `channel` still plays: once the queue moves on, this was asked about the one before.
        if CloudFiles.isFile(channel.url) || channel.url.scheme == DownloadLibrary.scheme {
            return autoPlayNext && playing == channel ? nextFile(after: channel) : nil
        }
        guard autoPlayNext, let catalog = catalog(for: channel), let next = nextEpisode(after: channel) else { return nil }
        do {
            let resolved = try await catalog.client.playback(next)
            guard !Task.isCancelled, playing == channel else { return nil }
            return episodeChannel(resolved, video: catalog.video, episode: next, client: catalog.client)
        } catch {
            if !(error is CancellationError) { Diagnostics.shared.failure("catalog", "upcoming episode \(catalog.client.reportContext) flag=\(next.flag)", error) }
            return nil
        }
    }

    /// The queued episode started playing by itself: it becomes the one playing, as if it had been chosen.
    func advance(to next: Channel, from channel: Channel) {
        if CloudFiles.isFile(next.url) || next.url.scheme == DownloadLibrary.scheme, playing == channel { playing = next; return }
        guard playing == channel, let catalog = catalog(for: channel) else { return }
        cancelEpisodeSelection()
        remember(catalog.video, client: catalog.client, for: next)
        playing = next
    }

    func catalog(for channel: Channel) -> PlaybackCatalog? {
        guard let catalog = playbackCatalog, catalog.scope == channel.historyContext?.id else { return nil }
        return catalog
    }

    func nextEpisode(after channel: Channel) -> Episode? {
        guard let context = channel.historyContext else { return nil }
        return catalog(for: channel)?.playlist.next(after: context)
    }

    func previousEpisode(before channel: Channel) -> Episode? {
        guard let context = channel.historyContext else { return nil }
        return catalog(for: channel)?.playlist.previous(before: context)
    }

    /// The same episode on a transcoded line (FTY's 智 lines are the drive's own HLS) when the
    /// playing original can't play here. The same drive's line comes first: 夸父原1 → 夸父智1.
    func transcodedLine(for channel: Channel) -> Episode? {
        guard let context = channel.historyContext, let catalog = catalog(for: channel) else { return nil }
        let current = context.episodeFlag
        let candidates = catalog.video.episodes.filter {
            $0.name == context.episodeName && $0.flag != current && $0.flag.contains("智")
        }
        let sameDrive = current.replacingOccurrences(of: "原", with: "智").replacingOccurrences(of: "无限", with: "智")
        return candidates.first { $0.flag == sameDrive } ?? candidates.first
    }

    func selectEpisode(_ episode: Episode, from channel: Channel, failed: ((String) -> Void)? = nil) {
        guard playing == channel, let catalog = catalog(for: channel),
              catalog.video.episodes.contains(episode) else { return }
        cancelEpisodeSelection()
        let request = episodeRequest
        resolvingEpisode = episode; episodeError = nil
        episodeTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.episodeRequest == request { self.resolvingEpisode = nil; self.episodeTask = nil } }
            do {
                let resolved = try await catalog.client.playback(episode)
                guard !Task.isCancelled, self.episodeRequest == request, self.playing == channel else { return }
                self.playing = self.catalogChannel(resolved, video: catalog.video, episode: episode, client: catalog.client)
            } catch {
                guard !Task.isCancelled, self.episodeRequest == request, self.playing == channel else { return }
                Diagnostics.shared.failure("catalog", "episode \(catalog.client.reportContext) flag=\(episode.flag)", error)
                self.episodeError = error.localizedDescription
                failed?(error.localizedDescription)
            }
        }
    }

    func cancelEpisodeSelection() {
        episodeRequest = UUID()
        episodeTask?.cancel(); episodeTask = nil; resolvingEpisode = nil
    }

    /// Resumes a watched title. Choosing another title while one is still being prepared switches
    /// to it: the earlier request is cancelled, which also stops its plugin call.
    func resume(_ entry: PlaybackHistoryEntry) {
        guard resumingHistoryID != entry.id else { return }
        resumeTask?.cancel()
        resumingHistoryID = entry.id
        resumeTask = Task { await resumeHistory(entry) }
    }

    func cancelResume() {
        resumeTask?.cancel(); resumeTask = nil
        resumingHistoryID = nil
    }

    /// The source a watched title came from. Any enabled subscription can hold it: it is found by its own origin
    /// and original key. Nil for Cloud Files, and once the source is gone.
    func historyClient(_ entry: PlaybackHistoryEntry) -> CatalogClient? {
        guard entry.context.sourceKey != CloudFiles.sourceKey, let config = subscription,
              let site = config.sites.first(where: { $0.origin(or: config.origin) == entry.context.origin && $0.sourceKey == entry.context.sourceKey })
        else { return nil }
        return CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL).applying(config)
    }

    func resumeHistory(_ entry: PlaybackHistoryEntry) async {
        resumingHistoryID = entry.id
        defer { if resumingHistoryID == entry.id, !Task.isCancelled { resumingHistoryID = nil } }
        if entry.context.sourceKey == CloudFiles.sourceKey { return resumeFile(entry) }
        guard let config = subscription, let client = historyClient(entry) else {
            error = L10n.text("This history source is no longer in the current subscription. Restore that subscription to continue.")
            return
        }
        let site = client.site
        let previousPlayback = playing
        do {
            // Plugin/API sources resolve an episode again. Direct-file APIs must refresh
            // their detail first so an expiring media address never becomes a resume shortcut.
            var video = try await client.detail(entry.context.videoID, cached: site.type == 3 || site.type == 4)
            guard var episode = entry.context.episode(in: video.episodes) else {
                throw TVError.unsupported(L10n.text("The saved episode is no longer available from this source. Choose an episode again."))
            }
            let channel: Channel
            do { channel = try await client.playback(episode) }
            catch {
                try Task.checkCancellation()
                video = try await client.detail(entry.context.videoID)
                guard let refreshed = entry.context.episode(in: video.episodes) else { throw error }
                episode = refreshed
                channel = try await client.playback(refreshed)
            }
            guard !Task.isCancelled, playing == previousPlayback, subscription?.origin == config.origin else { return }
            // A source whose details carry no poster keeps the one saved with the entry.
            playing = catalogChannel(channel, video: video.keepingPoster(entry.context.poster, headers: entry.context.posterHeaders),
                                     episode: episode, client: client, resumePosition: entry.resumePosition)
        } catch {
            guard !(error is CancellationError), !Task.isCancelled else { return }
            Diagnostics.shared.failure("catalog", "resume source=\(entry.context.sourceKey)", error)
            self.error = L10n.text("Unable to resume playback: %@", error.localizedDescription)
        }
    }
}

#if os(macOS)
extension Store {
    /// The Developer ID app uses `com.jo32.yingxia.macos`. Adopt settings from the previous Mac
    /// domains once, newest first, keeping any values already set in this domain. The app isn't
    /// sandboxed, so it can read the old domains. Application Support and Caches keep their
    /// `com.tvbox.yingxia` folder and need nothing.
    static func adoptPreviousBundleDefaults(_ defaults: UserDefaults) {
        for previous in ["com.jo32.yingxia.mac", "com.tvbox.yingxia.mac"] {
            let done = "adoptedDefaults." + previous
            guard Bundle.main.bundleIdentifier != previous, !defaults.bool(forKey: done) else { continue }
            for (key, value) in defaults.persistentDomain(forName: previous) ?? [:] where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
            defaults.set(true, forKey: done)
        }
    }
}
#endif

/// How this build reaches people. App Store and TestFlight builds are archived with
/// `SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) APPSTORE'`; direct downloads and sideloaded
/// builds leave it out. `-qaAppStore 1` makes a debug build act as one.
enum Distribution {
    static var isAppStore: Bool {
        #if APPSTORE
        return true
        #elseif DEBUG
        return UserDefaults.standard.bool(forKey: "qaAppStore")
        #else
        return false
        #endif
    }

    /// An App Store build installed from TestFlight, which leaves a sandbox receipt. A build promoted to the
    /// App Store gets a production receipt, so it stops sending people to TestFlight. `-qaTestFlight 1` in debug builds.
    static let isTestFlight: Bool = {
        #if APPSTORE
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #elseif DEBUG
        return UserDefaults.standard.bool(forKey: "qaTestFlight")
        #else
        return false
        #endif
    }()
}

// MARK: Cloud Files

/// A Cloud Files folder being played through: its files of the kind chosen, in order.
struct CloudFilesFolder {
    let drive: CloudFilesDrive
    let id: String
    let name: String
    let files: [CloudFile]
    /// The folder's subtitle files and archives (#576), offered beside each of its videos.
    var subtitles: [ExternalSubtitle] = []
}

extension Store {
    /// Plays a file from Cloud Files, where it was left if it was being watched; the folder's other
    /// files follow it.
    func playFile(_ file: CloudFile, in folder: CloudFilesFolder) {
        let channel = CloudFiles.channel(file, in: folder.drive, folder: folder.id, folderName: folder.name, subtitles: folder.subtitles)
        let saved = playbackHistory.entries.first { $0.id == channel.historyContext?.id && $0.context.episodeID == file.id && !$0.completed }
        filesFolder = folder
        playing = saved.map { CloudFiles.channel(file, in: folder.drive, folder: folder.id, folderName: folder.name, resumePosition: $0.resumePosition,
                                                 subtitles: folder.subtitles) } ?? channel
    }

    func nextFile(after channel: Channel) -> Channel? { file(1, from: channel) }
    func previousFile(before channel: Channel) -> Channel? { file(-1, from: channel) }

    /// The file `offset` places from the playing one in its folder, for the player's Previous and Next. A saved
    /// episode steps through the others saved from its show (#835, #820).
    private func file(_ offset: Int, from channel: Channel) -> Channel? {
        if channel.url.scheme == DownloadLibrary.scheme {
            let library = DownloadLibrary.shared
            return library.neighbor(of: channel.url, offset: offset).map(library.channel(for:))
        }
        guard let context = channel.historyContext, context.sourceKey == CloudFiles.sourceKey, let folder = filesFolder,
              folder.drive.key == context.episodeFlag, folder.id == context.videoID,
              let index = folder.files.firstIndex(where: { $0.id == context.episodeID }),
              folder.files.indices.contains(index + offset) else { return nil }
        return CloudFiles.channel(folder.files[index + offset], in: folder.drive, folder: folder.id, folderName: folder.name, subtitles: folder.subtitles)
    }

    /// Continue Watching on a Cloud Files folder: the file plays at once, and the folder is listed
    /// again meanwhile so the files after it still follow.
    fileprivate func resumeFile(_ entry: PlaybackHistoryEntry) {
        let context = entry.context
        guard let drive = CloudFiles.drive(key: context.episodeFlag) else {
            error = L10n.text("This file's drive is no longer in Cloud Files.")
            return
        }
        filesFolder = nil
        let channel = CloudFiles.channel(context, resumePosition: entry.resumePosition)
        playing = channel
        Task { [weak self] in
            guard let files = try? await CloudFiles.list(drive, folder: context.videoID), let self, self.playing == channel else { return }
            let kind = CloudFile.kind(of: context.episodeName)
            self.filesFolder = CloudFilesFolder(drive: drive, id: context.videoID, name: context.videoName,
                                                files: files.filter { $0.kind == kind && drive.plays($0) },
                                                subtitles: CloudFiles.subtitles(files, in: drive))
        }
    }
}

struct PlaybackCatalog {
    let video: Video
    let client: CatalogClient
    let scope: String
    /// Short labels (第1集) for lines whose episode names are file names, by episode id.
    var labels: [Episode.ID: String] = [:]
    /// Resolution and size read from file names (4K · 5.2G, #620), shown under the episodes, by episode id.
    var details: [Episode.ID: String] = [:]
    var playlist: EpisodePlaylist { EpisodePlaylist(video.episodes) }
}

/// A subscription as iCloud sync keeps it: the entry and its place in the list.
struct SyncedSubscription: Codable, Equatable, Sendable {
    var entry: SubscriptionEntry
    var rank: Int
}

import SwiftUI
import TVCore

@MainActor @Observable final class Store {
    static let defaultURL = "https://raw.githubusercontent.com/qist/tvbox/master/fty.json"
    /// Every subscription a fresh install should carry. The three addresses aggregate the two
    /// bundles' sources so an overwritten install keeps nothing orphaned: the public fty.json,
    /// the 124.223.214.31 server, and the local Rex aggregate served by the Mac on the LAN.
    /// Feeds this build adds on a fresh install.
    ///
    /// A `.local` name is not one of them: `macdemacbook-pro.local` only resolves on the LAN it was
    /// named on, so every fresh install on a phone elsewhere spent its first launch on a DNS failure
    /// and an error banner. The development Mac's feed is kept for debug builds, where the Mac is
    /// usually the machine serving it.
    static let aggregatedSubscriptionAddresses: [String] = {
        var addresses = [
            "https://raw.githubusercontent.com/qist/tvbox/master/fty.json",
            "http://124.223.214.31:55316/9981",
        ]
        #if DEBUG
        addresses.append("http://macdemacbook-pro.local:8081/api/rex/movie-degraded.json")
        #endif
        return addresses
    }()
    private static let dismissedAggregatesKey = "dismissedAggregateSubscriptions"
    /// Aggregate addresses the viewer deleted on purpose. Launch-time seeding skips them; adding one
    /// back by hand clears it again.
    private(set) var dismissedAggregateAddresses: Set<String> = []
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
    /// Per-source direct/proxy choices and the automatic connectivity fallback.
    let sourceRouting: SourceRouting
    /// The viewer's own HTTP/HTTPS/SOCKS5 proxy endpoints, chosen per source instead of the built-in relay.
    let customProxy: CustomProxyRouter
    /// Per-source rename and API override (the viewer edits one source without editing the subscription).
    let sourceOverrides: SourceOverrides
    /// Per-line (flag) route and hide choices, finer than the source-level routing.
    let lineSettings: LineSettings
    /// Where a source was dragged across subscriptions (displayed group override).
    let sourceReassignment: SourceReassignment
    /// Keeps the viewer's library the same on their other devices; nil for tests and QA's isolated data.
    let cloudSync: CloudSync?
    /// The history entry being resumed; another entry, or leaving the page, replaces or cancels it.
    private(set) var resumingHistoryID: String?
    private var resumeTask: Task<Void, Never>?
    /// Every enabled subscription merged in list order, plus the built-in sources.
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
    /// Passcode-locked hiding of subscriptions and sources. Reads go through its `visible…` and
    /// `permits…` methods so a hidden source disappears from every listing at once, rather than
    /// being filtered again in each view.
    var vault = PrivacyVault()
    /// Which language artwork comes in. Persisted beside the vault, in the playback defaults.
    var artworkLanguage = ArtworkLanguage()
    /// Separate viewing lives. See `Environments`.
    var environments = Environments()
    /// Where intro/credits markers come from, in priority order.
    var skipSources = SkipSegmentSources()
    /// How to order several files of the same title.
    var resourceRanking = ResourceRanking.standard
    private static let vaultKey = "privacyVault"
    private static let artworkLanguageKey = "artworkLanguage"
    private static let environmentsKey = "environments"
    private static let skipSourcesKey = "skipSegmentSources"
    private static let resourceRankingKey = "resourceRanking"

    /// Persists the vault. Called by every mutation so a passcode change or a hide survives a crash.
    func saveVault() {
        if let blob = try? JSONEncoder().encode(vault) { playbackDefaults.set(blob, forKey: Self.vaultKey) }
        if let blob = try? JSONEncoder().encode(artworkLanguage) { playbackDefaults.set(blob, forKey: Self.artworkLanguageKey) }
        if let blob = try? JSONEncoder().encode(environments) { playbackDefaults.set(blob, forKey: Self.environmentsKey) }
        if let blob = try? JSONEncoder().encode(skipSources) { playbackDefaults.set(blob, forKey: Self.skipSourcesKey) }
        if let blob = try? JSONEncoder().encode(resourceRanking) { playbackDefaults.set(blob, forKey: Self.resourceRankingKey) }
    }

    /// Relocks the vault the moment the screen is captured — a screenshot or an active screen
    /// recording / mirroring — so a hidden subscription or source is never caught mid-view. The
    /// lock only matters when a passcode is set; otherwise the vault hides nothing.
    #if os(iOS)
    func installCaptureGuards() {
        // No `guard vault.hasPasscode` here: it is installed once at init, before a passcode exists, so
        // a passcode set later in the same session must still get the guard. `relock` re-checks the
        // passcode at the moment of the capture, which is the only time it matters.
        let relock = { [weak self] in
            guard let self, self.vault.hasPasscode else { return }
            Task { @MainActor in
                guard self.vault.isUnlocked() else { return }
                self.vault.lock()
                self.saveVault()
            }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.userDidTakeScreenshotNotification,
                                               object: nil, queue: .main) { _ in relock() }
        NotificationCenter.default.addObserver(forName: UIScreen.capturedDidChangeNotification,
                                               object: nil, queue: .main) { note in
            guard let screen = note.object as? UIScreen, screen.isCaptured else { return }
            relock()
        }
    }
    #endif

    /// Rows the viewer may see. Every listing that shows history goes through this.
    var visibleHistory: [PlaybackHistoryEntry] { vault.visibleHistory(playbackHistory.entries) }
    /// Favourites the viewer may see.
    var visibleFavorites: [FavoriteItem] { vault.visibleFavorites(favorites.items) }
    /// Sources a search or a recommendation may fan out to.
    func searchableSites(_ sites: [Site], origin: URL) -> [Site] {
        sites.filter { maySee($0, origin: origin) }
    }
    /// Whether an episode may be opened, for a deep link or a resumed session.
    func mayPlay(sourceKey: String, origin: URL) -> Bool { vault.permitsPlayback(sourceKey: sourceKey, origin: origin) }
    /// Whether the vault lets this source be listed, searched or opened right now. `origin` is the merged
    /// subscription's, used only where the source carries no origin of its own.
    func maySee(_ site: Site, origin: URL) -> Bool { vault.permits(site: site, fallback: origin) }
    var importing = false
    /// Whether an import owns the gate, and who is waiting for it.
    ///
    /// A second import used to be dropped on the floor: `guard !importing else { return }` meant a
    /// `yingxia://subscribe` link that arrived while launch-time seeding was still running — the
    /// normal case on a fresh install — silently imported nothing. Imports now queue behind the one
    /// running, which is what the caller already assumed when it awaited them in a loop.
    @ObservationIgnored private var importBusy = false
    @ObservationIgnored private var importWaiters: [CheckedContinuation<Void, Never>] = []

    /// Waits for the running import, then takes the gate.
    private func beginImport() async {
        if !importBusy {
            importBusy = true
            return
        }
        await withCheckedContinuation { importWaiters.append($0) }
    }

    /// Hands the gate to the next waiter, or releases it.
    private func endImport() {
        if importWaiters.isEmpty {
            importBusy = false
        } else {
            importWaiters.removeFirst().resume()
        }
    }
    var error: String?
    /// Why the last subscription import failed. It shows under the address field, not in the app-wide alert: on
    /// iPhone and iPad that alert closed the Add Subscription sheet over it and took the viewer out of the form (#357).
    var importError: String?
    var notice: String?
    var playing: Channel? {
        // An episode of a listening source (audiobooks, radio, songs) plays in the music player instead (#289).
        didSet {
            if let channel = playing, let queue = listeningQueue(for: channel) { playing = nil; listen(queue, from: channel); return }
            // The session playing survives an iPhone Duo fold/unfold. It is dropped when playback stops, or when
            // a different channel starts playing.
            if playing == nil { activeSession = nil; activeSessionChannel = nil }
            else if let session = activeSession, !session.isPlaying(playing!) { activeSession = nil; activeSessionChannel = nil }
        }
    }
    /// The playback session handed across an iPhone Duo fold/unfold, so the watch page and the full-screen player
    /// reuse the same player instead of each building a new one (which dropped the position and episode).
    @ObservationIgnored private var activeSession: PlaybackSession?
    /// The channel the session was handed out for. `isPlaying` only reports true once the async `prepare`
    /// has finished, so a fold/unfold during that load would otherwise build a fresh session and restart
    /// the episode. Matching on the channel keeps the in-flight session.
    @ObservationIgnored private var activeSessionChannel: Channel?
    func playbackSession(for channel: Channel) -> PlaybackSession {
        if let session = activeSession, activeSessionChannel == channel { return session }
        let session = PlaybackSession()
        activeSession = session
        activeSessionChannel = channel
        return session
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
    /// Set when the last episode of a line ends: what the end screen should offer.
    /// Nil while nothing has finished, which is also what dismisses the screen.
    var seriesEnd: SeriesEnd?
    /// What the end-of-series screen draws. `suggestions` is ranked with the same
    /// source and the same show first (a follow-up season, 红果 style); the
    /// screen auto-plays the top "next season" row after a countdown.
    struct SeriesEnd: Identifiable {
        let id = UUID()
        let channel: Channel
        let title: String
        let suggestions: [SeriesSuggestion]
    }
    /// The Cloud Files folder the playing file came from; its next file plays after it.
    var filesFolder: CloudFilesFolder?
    var resolvingEpisode: Episode?
    var episodeError: String?
    var autoPlayNext: Bool {
        didSet { if persistsChanges { defaults.set(autoPlayNext, forKey: "autoPlayNextEpisode") } }
    }
    private var episodeRequest = UUID()
    private var episodeTask: Task<Void, Never>?
    /// Loads the end-of-series suggestions; cancelled when the screen is dismissed.
    private var seriesEndTask: Task<Void, Never>?
    var section: AppSection = .home
    /// Every build shows the built-in services (Music, Bilibili, Douyin), the default subscription and
    /// the plugin pages only once a subscription that works has been added: one that is on and whose
    /// copy has sources or live playlists.
    var extrasUnlocked: Bool {
        subscriptions.contains { $0.enabled && documents[$0.address].map { !$0.sites.isEmpty || !$0.lives.isEmpty } == true }
    }
    /// Yingxia's own sources (`CloudSources`), added beside the viewer's subscriptions once one works.
    private(set) var cloudDocument: Subscription?
    @ObservationIgnored private var cloudFetchedAt: Date?
    @ObservationIgnored private var cloudFetch: Task<Void, Never>?
    /// Sections kept out of the tab bar and sidebar until then.
    var hiddenSections: [AppSection] { extrasUnlocked ? [] : [.music] }
    private let defaults: UserDefaults
    private let http = HTTPClient()
    /// Rebuilt source rows are expensive (every source is classified and copied) and Watch Now reads
    /// them many times while drawing one frame. The stamp is the inputs, so a later frame reuses the row.
    /// Not observed: views fill these while drawing, and a write would draw every reader again.
    @ObservationIgnored private var siteListStamp = ""
    @ObservationIgnored private var cloudDrivesObserver: NSObjectProtocol?
    @ObservationIgnored private var automaticCache: [Site]?
    @ObservationIgnored private var orderedCache: [Site]?
    @ObservationIgnored private var recommendationCache: [Site]?
    @ObservationIgnored private var groupsCache: [Bool: [SourceGroup]] = [:]
    /// What the cached rows were built from: the merged subscription, which subscriptions are on, and the viewer's pins, hides, and order.
    private func currentSiteListStamp() -> String {
        let imported = subscription?.importedAt.timeIntervalSince1970 ?? 0
        let entries = subscriptions.map { "\($0.address)=\($0.enabled)" }.joined(separator: "\n")
        return "\(subscription?.origin.absoluteString ?? "")|\(imported)|\(subscription?.sites.count ?? 0)|\(entries)|\(pinnedSources.revision)|\(hiddenSources.revision)|\(vault.revision)|\(sourceOrder.revision)|\(sourceReassignment.revision)"
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
        dismissedAggregateAddresses = Set(defaults.stringArray(forKey: Self.dismissedAggregatesKey) ?? [])
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
        sourceRouting = SourceRouting(defaults: playbackDefaults)
        customProxy = CustomProxyRouter.shared
        // These two are read from global `.shared` singletons in the playback/edit paths
        // (PlaybackSession has no Store), so they must BE those singletons — a separate instance
        // here would silently split the data and break per-line routing and source overrides.
        sourceOverrides = SourceOverrides.shared
        lineSettings = LineSettings.shared
        sourceReassignment = SourceReassignment(defaults: playbackDefaults)
        cloudSync = defaults === UserDefaults.standard && !defaults.bool(forKey: "qaIsolatedData") ? CloudSync() : nil
        favorites = Favorites(defaults: defaults)
        if let blob = playbackDefaults.data(forKey: Self.artworkLanguageKey),
           let decoded = try? JSONDecoder().decode(ArtworkLanguage.self, from: blob) { artworkLanguage = decoded }
        if let blob = playbackDefaults.data(forKey: Self.environmentsKey),
           let decoded = try? JSONDecoder().decode(Environments.self, from: blob) { environments = decoded }
        if let blob = playbackDefaults.data(forKey: Self.skipSourcesKey),
           let decoded = try? JSONDecoder().decode(SkipSegmentSources.self, from: blob) { skipSources = decoded }
        if let blob = playbackDefaults.data(forKey: Self.resourceRankingKey),
           let decoded = try? JSONDecoder().decode(ResourceRanking.self, from: blob) { resourceRanking = decoded }
        if let blob = playbackDefaults.data(forKey: Self.vaultKey),
           let saved = try? JSONDecoder().decode(PrivacyVault.self, from: blob) {
            vault = saved
        }
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
        let cloud = (try? Data(contentsOf: Self.cloudFile)).flatMap { try? JSONDecoder().decode(Subscription.self, from: $0) }.flatMap { CloudSources.accepts($0) ? $0 : nil }
        cloudDocument = cloud
        CloudSources.current = cloud
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
        searchModel.order = sourceOrder
        DownloadLibrary.shared.resolver = { [weak self] item in
            guard let self else { throw CancellationError() }
            return try await self.resolveDownload(item)
        }
        // Songs that were downloading when the app quit carry on.
        MusicDownloadLibrary.shared.wake()
        setUpListening()
        setUpCloudSync()
        #if os(iOS)
        installCaptureGuards()
        #endif
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
        guard let found = config?.sites.first(where: { $0.key == item.source.siteKey })
                ?? cloudDocument?.sites.first(where: { $0.key == item.source.siteKey }) else {
            throw TVError.unsupported(L10n.text("%@ is no longer in your subscription, so this download can't continue.", item.source.siteName))
        }
        let origin = config?.origin ?? URL(string: "https://example.invalid/")!
        let site = config == nil ? found : resolvedSite(found, origin: origin)
        let base = CatalogClient(site: site, origin: origin, jarURL: config?.spiderURL)
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
    private static var cloudFile: URL { subscriptionDirectory.appending(path: "cloud-sources.json") }
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
        guard !missing.isEmpty else { return }
        await beginImport()
        importing = true
        defer { importing = false; endImport() }
        await fetch(missing)
    }
    /// On launch, makes sure the aggregated subscriptions are all present, importing any that are
    /// missing. Existing entries are left untouched (their saved copy wins), so overwriting either
    /// bundle never orphans the other bundle's sources.
    ///
    /// One exception, and it is the viewer's: an address they deleted is not put back. Without it,
    /// deleting the local Rex feed or the 124.223 server was undone by the next launch, which reads
    /// as the app refusing to take no for an answer.
    func seedAggregatedSubscriptions() async {
        guard !Distribution.isAppStore else { return }
        for address in Self.aggregatedSubscriptionAddresses
        where !dismissedAggregateAddresses.contains(address) && !subscriptions.contains(where: { $0.address == address }) {
            guard !Task.isCancelled else { break }
            await importSubscription(address: address)
        }
    }
    /// Adds the typed address, or refreshes it when it is already in the list. A directory (多仓)
    /// adds every subscription it lists, switched off, for the viewer to choose from.
    func importSubscription(address: String? = nil) async {
        await beginImport()
        importing = true; importError = nil; notice = nil
        defer { importing = false; endImport() }
        let typed = (address ?? subscriptionAddress).trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let url = try WebAddress.resolve(typed)
            switch try await http.subscriptionImport(url) {
            case .subscription(let value):
                let name = address == nil ? subscriptionName.trimmingCharacters(in: .whitespacesAndNewlines) : ""
                let entry = SubscriptionEntry(address: url.absoluteString, name: name)
                if let index = subscriptions.firstIndex(where: { $0.address == entry.address }) {
                    subscriptions[index].enabled = true
                    if !name.isEmpty { subscriptions[index].name = name }
                } else { subscriptions.append(entry) }
                // Added back by hand: forget that it was ever deleted, so launch-time seeding
                // treats it like any other subscription again.
                if dismissedAggregateAddresses.remove(entry.address) != nil { saveDismissedAggregates() }
                keep(value, for: entry)
                if persistsChanges { defaults.set(url.absoluteString, forKey: "subscriptionAddress") }
                notice = L10n.text("Imported sources: %lld · Live playlists: %lld", value.sites.count, value.lives.count)
            case .directory(let entries):
                let added = entries.filter { entry in !subscriptions.contains { $0.address == entry.address } }
                subscriptions += added
                notice = L10n.text("This address lists %lld subscriptions. They were added switched off; turn on the ones you want.", added.count)
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
            Diagnostics.shared.failure("subscription", "import host=\((try? WebAddress.resolve(typed))?.host() ?? "-")", error)
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
        await beginImport()
        importing = true; importError = nil; notice = nil
        defer { importing = false; endImport() }
        await fetch(subscriptions.filter(\.enabled))
        refreshCloudSources(force: true)
        let failed = subscriptions.filter { $0.enabled && subscriptionErrors[$0.address] != nil }.count
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
        // Deleting one of the feeds this build seeds at launch has to stick, or the next launch
        // adds it back and the delete looked like it failed.
        let aggregates = removed.map(\.address).filter(Self.aggregatedSubscriptionAddresses.contains)
        if !aggregates.isEmpty {
            dismissedAggregateAddresses.formUnion(aggregates)
            saveDismissedAggregates()
        }
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
    /// Switches every subscription on or off at once — the fast path out of a directory import,
    /// which adds every listed subscription switched off.
    func setAllSubscriptions(enabled: Bool) {
        guard !subscriptions.isEmpty else { return }
        subscriptions = subscriptions.map { var entry = $0; entry.enabled = enabled; return entry }
        saveSubscriptionList()
        if enabled { Task { await restoreSubscription() } } else { rebuildSubscription() }
    }
    /// Total bytes of the parsed subscription copies on disk, for the cache row in Settings.
    func subscriptionCacheSize() -> Int64 {
        let dir = Self.subscriptionDirectory.appending(path: "subscriptions")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { total, url in
            total + (Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
        }
    }
    /// Deletes the on-disk copies; enabled subscriptions are re-fetched, so nothing is lost.
    func clearSubscriptionCache() {
        let dir = Self.subscriptionDirectory.appending(path: "subscriptions")
        try? FileManager.default.removeItem(at: dir)
        documents.removeAll()
        Task { await restoreSubscription() }
    }
    /// A portable copy of every subscription and its parsed content, for a file or a share.
    func exportConfig() -> SubscriptionConfig {
        SubscriptionConfig(subscriptions: subscriptions.enumerated().map { index, entry in
            SyncedSubscription(entry: entry, rank: index, document: documents[entry.address])
        })
    }
    /// Merges a configuration file in. `overwrite` decides what happens to an address that is
    /// already present: by default (merge) it is left untouched, so re-importing never duplicates or
    /// overwrites; with `overwrite` the file's name, enabled state and routing win, so a backup
    /// restores the exact state it was exported in. In both modes the list is reordered to the
    /// file's rank, and a fresh entry that carries a content snapshot is restored without a fetch.
    func importConfig(_ config: SubscriptionConfig, overwrite: Bool = false) {
        guard config.isValid else {
            importError = L10n.text("This isn't a Mi3s configuration file.")
            return
        }
        let incoming = config.subscriptions.sorted { ($0.rank, $0.entry.address) < ($1.rank, $1.entry.address) }
        let incomingSet = Set(incoming.map(\.entry.address))

        // The file is the authority on which subscriptions exist. This used to be a merge that never
        // appended the new ones and never dropped the old ones: `added` was collected and then
        // dropped on the floor, so the sheet said "Imported 3" and the list was unchanged, and an
        // address removed from the file was deleted from disk only to be appended back at the end
        // and re-fetched as "missing content". Both directions now go through `next`.
        var current: [String: SubscriptionEntry] = [:]
        for entry in subscriptions { current[entry.address] = entry }

        var removedCount = 0
        for entry in subscriptions where !incomingSet.contains(entry.address) {
            current[entry.address] = nil
            removedCount += 1
            documents[entry.address] = nil; subscriptionErrors[entry.address] = nil
            if persistsChanges { try? FileManager.default.removeItem(at: Self.file(for: entry)); ImportedFiles.remove(entry.address) }
        }

        var added: [SubscriptionEntry] = []
        var restored: [(SubscriptionEntry, Subscription)] = []
        var next: [SubscriptionEntry] = []

        for synced in incoming {
            if var entry = current[synced.entry.address] {
                if overwrite {
                    // Restore the exported name / switch / routing over the current copy.
                    entry.name = synced.entry.name
                    entry.enabled = synced.entry.enabled
                    entry.routing = synced.entry.routing
                    if let document = synced.document { restored.append((entry, document)) }
                }
                next.append(entry)
            } else {
                // A subscription the file has and this device does not. It used to be collected and
                // never inserted, which is why a fresh install could not restore anything.
                next.append(synced.entry)
                added.append(synced.entry)
                if let document = synced.document { restored.append((synced.entry, document)) }
            }
        }

        subscriptions = next

        guard !added.isEmpty || overwrite || removedCount > 0 else {
            notice = L10n.text("Every subscription in this file is already imported; nothing was added.")
            return
        }

        for (entry, document) in restored { keep(document, for: entry) }
        saveSubscriptionList()
        rebuildSubscription()
        // Entries that carried no snapshot still need their content fetched.
        let needFetch = subscriptions.filter { $0.enabled && documents[$0.address] == nil }
        if !needFetch.isEmpty { Task { await restoreSubscription() } }

        if overwrite {
            notice = L10n.text("Restored %lld subscriptions from the backup.", incoming.count)
        } else if !added.isEmpty {
            notice = L10n.text("Imported %lld subscriptions.", added.count)
        } else {
            notice = L10n.text("Removed %lld subscriptions that this file does not list.", removedCount)
        }
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
    private func saveDismissedAggregates() {
        guard persistsChanges else { return }
        defaults.set(Array(dismissedAggregateAddresses), forKey: Self.dismissedAggregatesKey)
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
        Dictionary(subscriptions.enumerated().map { ($0.element.address, SyncedSubscription(entry: $0.element, rank: $0.offset, document: documents[$0.element.address])) },
                   uniquingKeysWith: { first, _ in first })
    }
    /// Subscriptions another device added, renamed, switched, moved or removed. A new one that is on loads.
    /// Subscription content another device synced, so a second device lists a feed's sources without
    /// fetching it again. A copy already on disk wins.
    private func adoptSyncedDocuments(_ synced: [CloudSyncItem<SyncedSubscription>]) {
        for item in synced {
            guard let document = item.value.document, documents[item.id] == nil else { continue }
            documents[item.id] = document
            if persistsChanges, let data = try? JSONEncoder().encode(document) { try? Self.save(data, to: Self.file(for: SubscriptionEntry(address: item.id))) }
        }
    }
    private func adoptSubscriptions(_ synced: [CloudSyncItem<SyncedSubscription>]) {
        adoptSyncedDocuments(synced)
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
        subscription = Subscription.merge(subscriptions.filter(\.enabled).compactMap { documents[$0.address] })?.withCloudSources(extrasUnlocked ? cloudDocument : nil)
        if let subscription { applySourceRouting(subscription) }
        refreshCloudSources()
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
        adoptLegacyMoves()
    }

    /// Folds moves saved by a build that keyed them by the subscription's origin into the record the
    /// maintenance list reads. Without this an upgraded library keeps *applying* those moves but can
    /// never show or undo them: they are invisible in the list and their source's menu offers no
    /// "move back". Runs after every rebuild, and is a no-op once each one has been rewritten.
    /// Rewrites each source's `api` to direct or proxy according to the viewer's choices; `.auto`
    /// follows connectivity: a source that is failing on its own address is retried through the relay,
    /// and switched back once the direct line recovers.
    private func applySourceRouting(_ config: Subscription) {
        let byAddress = Dictionary(subscriptions.map { ($0.address, $0) }, uniquingKeysWith: { $1 })
        let sites = config.sites.map { site -> Site in
            let origin = site.origin(or: config.origin)
            let sub: SubscriptionEntry? = {
                if let po = site.provenance?.origin, let entry = byAddress[po.absoluteString] { return entry }
                return byAddress[origin.absoluteString]
            }()
            let explicit = sourceRouting.route(site, origin: origin)
            let effective = explicit ?? (sub?.routing ?? .auto)
            switch effective {
            case .direct:
                return site.routed(.direct)
            case .proxy:
                return site.routed(.proxy)
            case .auto:
                // Follow connectivity only for native sources whose address can be relayed.
                guard site.native, !site.api.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return site }
                let relayed = SourceRelay.isRelayed(site.api)
                let failing = SourceHealth.shared.failedRepeatedly(site, origin: origin)
                if failing && !relayed {
                    return site.routed(.proxy)
                } else if !failing && relayed {
                    return site.routed(.direct)
                }
                return site
            }
        }
        subscription = config.with(sites: sites)
    }

    private func adoptLegacyMoves() {
        guard let config = subscription else { return }
        for legacy in sourceReassignment.pendingLegacy {
            guard let origin = URL(string: legacy.origin),
                  let address = subscriptions.first(where: { documents[$0.address]?.origin == origin })?.address,
                  let site = config.sites.first(where: { $0.sourceKey == legacy.sourceKey && $0.origin(or: config.origin) == origin })
            else { continue }
            sourceReassignment.reassign(site, address: address, origin: origin,
                                        to: legacy.target,
                                        targetName: subscriptions.first { $0.address == legacy.target }?.title ?? "")
        }
    }
    /// Fetches Yingxia's own subscription while a subscription works: at once when there is no copy, else
    /// every ten minutes at most. A failed fetch keeps the last copy.
    private func refreshCloudSources(force: Bool = false) {
        guard extrasUnlocked, cloudFetch == nil else { return }
        if !force, cloudDocument != nil, let fetched = cloudFetchedAt, Date.now.timeIntervalSince(fetched) < 600 { return }
        let http = http, persists = persistsChanges
        cloudFetch = Task { [weak self] in
            let result: Result<Subscription, any Error>
            do { result = .success(try await CloudSources.fetch(http: http)) } catch { result = .failure(error) }
            guard let self else { return }
            self.cloudFetch = nil
            self.cloudFetchedAt = .now
            switch result {
            case .success(let document):
                if persists, let data = try? JSONEncoder().encode(document) { try? Self.save(data, to: Self.cloudFile) }
                CloudSources.current = document
                let changed = (try? JSONEncoder().encode(document.raw)) != (try? JSONEncoder().encode(self.cloudDocument?.raw))
                self.cloudDocument = document
                if changed { self.rebuildSubscription() }
            case .failure(let error):
                Diagnostics.shared.failure("subscription", "built-in sources", error)
            }
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
        searchModel.search(keyword, config: config) { [hiddenSources, vault] site in
            hiddenSources.contains(site, origin: config.origin) || !vault.permits(site: site, fallback: config.origin)
        }
        section = .search
    }
    func toggleFavorite(_ channel: Channel) { favorites.toggle(.live(channel)) }
    func isFavorite(_ channel: Channel) -> Bool { favorites.contains(.live(channel)) }

    func resolvedSite(_ site: Site, origin: URL) -> Site {
        sourceOverrides.apply(to: site, origin: origin)
    }

    func catalogClient(for video: FavoriteVideo) -> CatalogClient? {
        guard let config = subscription,
              let site = config.sites.first(where: { $0.origin(or: config.origin) == video.origin && $0.sourceKey == video.sourceKey }) else { return nil }
        return CatalogClient(site: resolvedSite(site, origin: config.origin), origin: config.origin, jarURL: config.spiderURL)
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

    // MARK: 源改派（拖到别的订阅 / 维护清单）

    /// Files one source under another subscription (dragged onto that subscription's header, or chosen
    /// from its menu), or back into its own.
    ///
    /// The move is recorded against the subscription's *address* — what the viewer added — so a
    /// refresh that lands on a new mirror keeps it. It also outlives a disabled or removed target:
    /// the record stays until the viewer removes it, and files the source again once the target is back.
    func reassignSource(_ site: Site, to address: String?) {
        // The built-in sources belong to no subscription; a move would file them under a feed that
        // does not know them, and a refresh that drops that feed would leave them in "Other Sources".
        guard !site.isBuiltIn, let config = subscription else { return }
        let origin = site.origin(or: config.origin)
        let own = entryAddress(of: site) ?? origin.absoluteString
        let target = subscriptions.first { $0.address == address }
        sourceReassignment.reassign(site, address: own, origin: origin,
                                    to: address, targetName: target?.title ?? "")
        rebuildSubscription()
    }

    /// The subscription a source currently files under, after any move.
    func reassignedAddress(_ site: Site) -> String? {
        guard let config = subscription else { return nil }
        let origin = site.origin(or: config.origin)
        return sourceReassignment.destination(address: entryAddress(of: site) ?? origin.absoluteString,
                                              sourceKey: site.sourceKey, origin: origin)
    }

    /// Drag-and-drop entry point: finds the source by its key + origin and files it under `address`.
    func reassignSourceByKey(_ key: String, origin: String, to address: String?) {
        guard let config = subscription else { return }
        let site = config.sites.first { $0.sourceKey == key && $0.origin(or: config.origin).absoluteString == origin }
        guard let site else { return }
        reassignSource(site, to: address)
    }

    /// The address of the subscription a source came from: the entry whose copy has this origin.
    func entryAddress(of site: Site) -> String? {
        guard let origin = site.provenance?.origin else { return nil }
        return subscriptions.first { documents[$0.address]?.origin == origin }?.address
    }

    /// The route a source is using right now (explicit choice, then its subscription's).
    func effectiveRoute(_ site: Site) -> SourceRoute {
        guard let config = subscription else { return .auto }
        let origin = site.origin(or: config.origin)
        let sub: SubscriptionEntry? = {
            if let po = site.provenance?.origin, let entry = subscriptions.first(where: { $0.address == po.absoluteString }) { return entry }
            return subscriptions.first { $0.address == origin.absoluteString }
        }()
        return sourceRouting.effectiveRoute(site, origin: origin, subscription: sub?.routing)
    }

    /// Sets one source's route; `.auto` follows connectivity, the others pin it.
    func setRoute(_ route: SourceRoute, for site: Site) {
        guard let config = subscription else { return }
        sourceRouting.set(route, for: site, origin: site.origin(or: config.origin))
        rebuildSubscription()
    }

    /// Sets a whole subscription's default route; its sources without their own choice follow it.
    func setRoute(_ route: SourceRoute, for entry: SubscriptionEntry) {
        guard let index = subscriptions.firstIndex(where: { $0.address == entry.address }) else { return }
        subscriptions[index].routing = route
        saveSubscriptionList()
        rebuildSubscription()
    }

    /// Whether a source's direct line is what is failing right now (drives the automatic switch).
    func directLineFailing(_ site: Site) -> Bool {
        guard let config = subscription else { return false }
        return SourceHealth.shared.failedRepeatedly(site, origin: site.origin(or: config.origin))
    }

    /// One row of the maintenance list: a move, where it came from, where it went, and whether it
    /// still describes anything.
    struct SourceMoveEntry: Identifiable {
        enum State: Equatable {
            /// The source is in its target's group now.
            case applied
            /// The target subscription was removed; the move waits for it to come back.
            case missingTarget
            /// The target subscription is switched off, so the source waits in "Other Sources".
            case targetOff
            /// The source is no longer in the feed (renamed or dropped); the move no longer applies.
            case missingSource
        }
        let move: SourceMove
        let state: State
        let ownTitle: String
        let targetTitle: String
        var id: String { move.id }
        var title: String { move.title }
    }

    /// Every recorded move, newest first, with the names as they are now.
    func sourceMoveEntries() -> [SourceMoveEntry] {
        let sites = subscription?.sites ?? []
        return sourceReassignment.moves.map { move in
            let own = subscriptions.first { $0.address == move.address }
            let target = subscriptions.first { $0.address == move.target }
            let sourceStillThere = sites.contains { $0.sourceKey == move.sourceKey && entryAddress(of: $0) == move.address }
            let state: SourceMoveEntry.State
            if own == nil || !sourceStillThere { state = .missingSource }
            else if target == nil { state = .missingTarget }
            else if target?.enabled == false { state = .targetOff }
            else { state = .applied }
            return SourceMoveEntry(move: move,
                                   state: state,
                                   ownTitle: own?.title ?? (move.address.isEmpty ? move.origin : move.address),
                                   targetTitle: target?.title ?? (move.targetName.isEmpty ? move.target : move.targetName))
        }
    }

    /// Puts one source back under its own subscription.
    func undoSourceMove(_ entry: SourceMoveEntry) {
        sourceReassignment.remove(entry.move.id)
        rebuildSubscription()
    }

    /// Puts every moved source back at once.
    func undoAllSourceMoves() {
        sourceReassignment.removeAll()
        rebuildSubscription()
    }

    /// Files a moved source under another subscription, from the maintenance list.
    func moveMovedSource(_ entry: SourceMoveEntry, to target: SubscriptionEntry?) {
        guard let target else {
            undoSourceMove(entry)
            return
        }
        guard let site = subscription?.sites.first(where: { $0.sourceKey == entry.move.sourceKey && entryAddress(of: $0) == entry.move.address }) else { return }
        reassignSource(site, to: target.address)
    }

    // MARK: 批量测速

    /// A bulk probe in flight: how many sources are done, and how many there are.
    struct ProbeRun: Equatable { var done: Int; var total: Int }

    /// What the Sources page shows while a probe runs, and the way to stop it.
    private(set) var probeRun: ProbeRun?
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    /// Identifies the run in flight, so a stopped run finishing late cannot clear the next one's
    /// progress or its handle.
    @ObservationIgnored private var probeToken = UUID()

    /// One source to measure: everything a `CatalogClient` needs, copied so the work can leave the
    /// main actor.
    private struct ProbeTarget: Sendable {
        let site: Site
        let origin: URL
        let jarURL: URL?
    }

    private struct ProbeRow: Sendable {
        let flag: String
        let result: SourceProbeResult
    }

    private struct ProbeBatch: Sendable {
        let sourceKey: String
        let videoID: String
        let rows: [ProbeRow]
    }

    /// Starts measuring every listed source — built-in ones included.
    ///
    /// The sweep runs off the main actor, a few sources at a time, and each source is given a
    /// deadline. It used to run on the main actor, one source after another, waiting for a plugin to
    /// compile and a dead host to time out at every step: the app looked frozen because it was. The
    /// reader can stop it, and the progress is visible while it runs.
    func startProbingAllSources() {
        guard probeTask == nil, let config = subscription else { return }
        let targets = probeTargets(config)
        guard !targets.isEmpty else { return }
        probeRun = ProbeRun(done: 0, total: targets.count)
        let token = UUID()
        probeToken = token
        probeTask = Task { [weak self] in
            var done = 0
            for await batch in Self.probeBatches(targets) {
                if !batch.videoID.isEmpty {
                    SourceProbeStore.shared.record(batch.rows.map { ($0.result, $0.flag) },
                                                   sourceKey: batch.sourceKey, videoID: batch.videoID)
                }
                done += 1
                guard self?.probeToken == token else { return }
                self?.probeRun = ProbeRun(done: done, total: targets.count)
                if Task.isCancelled { break }
            }
            guard self?.probeToken == token else { return }
            self?.probeRun = nil
            self?.probeTask = nil
        }
    }

    /// Stops a running sweep. Results already measured stay.
    func cancelProbingAllSources() {
        probeTask?.cancel()
        probeTask = nil
        probeRun = nil
        probeToken = UUID()
    }

    /// Every source the page lists, once each: pinned, built-in, then each subscription's, in the
    /// order they are drawn. Built-in sources are as much a part of "probe everything" as the rest,
    /// and used to be left out because the sweep only walked the automatic list.
    private func probeTargets(_ config: Subscription) -> [ProbeTarget] {
        var seen = Set<String>()
        var targets: [ProbeTarget] = []
        for group in sourceGroups(includeHidden: false) where group.kind != .hidden {
            for site in group.sites where seen.insert(site.id).inserted {
                targets.append(ProbeTarget(site: site, origin: config.origin, jarURL: config.spiderURL))
            }
        }
        return targets
    }

    /// The sweep, as a stream of per-source batches. The producer runs detached, so neither a slow
    /// host nor a plugin's first compile can hold the main actor.
    private nonisolated static func probeBatches(_ targets: [ProbeTarget]) -> AsyncStream<ProbeBatch> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                await withTaskGroup(of: ProbeBatch?.self) { group in
                    // Two sources at a time: enough to keep the network busy without a burst of
                    // plugin compiles competing for the same device.
                    let width = 2
                    var next = 0
                    func launch() -> Bool {
                        guard next < targets.count, !Task.isCancelled else { return false }
                        let target = targets[next]
                        next += 1
                        group.addTask { await probe(target) }
                        return true
                    }
                    for _ in 0..<width { if !launch() { break } }
                    for await batch in group {
                        if let batch { continuation.yield(batch) }
                        if !launch() { continue }
                    }
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One source: its home page for a representative video, then that video's lines.
    private nonisolated static func probe(_ target: ProbeTarget) async -> ProbeBatch {
        let client = CatalogClient(site: target.site, origin: target.origin, jarURL: target.jarURL)
        let empty = ProbeBatch(sourceKey: target.site.sourceKey, videoID: "", rows: [])
        guard let page = await withDeadline(seconds: 25, { try await client.home() }),
              let video = page.videos.first else { return empty }
        let lines = video.episodes.filter { !$0.flag.isEmpty && URL(string: $0.address) != nil }
        var rows: [ProbeRow] = []
        await withTaskGroup(of: ProbeRow?.self) { group in
            var next = 0
            func launch() -> Bool {
                guard next < lines.count, !Task.isCancelled else { return false }
                let episode = lines[next]
                next += 1
                group.addTask {
                    guard let url = URL(string: episode.address) else { return nil }
                    return ProbeRow(flag: episode.flag, result: await SourceProbeRunner.probe(url: url))
                }
                return true
            }
            for _ in 0..<4 { if !launch() { break } }
            for await row in group {
                if let row { rows.append(row) }
                if !launch() { continue }
            }
        }
        return ProbeBatch(sourceKey: target.site.sourceKey, videoID: video.id, rows: rows)
    }

    /// Runs `operation`, giving up after `seconds`. The result is nil on a timeout or a throw, so a
    /// host that never answers cannot hold a whole sweep.
    private nonisolated static func withDeadline<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { try? await operation() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
    }

    /// After a full probe, applies one fix to every line that came back unreachable: route it
    /// through the first custom proxy, force it direct, or hide it from the picker.
    ///
    /// The work comes from the probe store, not from the feeds. Asking each source for its home page
    /// to rediscover which lines are dead meant one request per source, covered only the first video
    /// in each, and took long enough to look frozen. The sweep has already measured every video it
    /// touched, and a route is stored per (origin, source, line) — no episode is needed to fix one.
    ///
    /// The origin is the source's own, not the merged document's: a source that came from a second
    /// subscription is read back with its own origin, so writing under the first one silently fixed
    /// nothing for it. `notice` reports what actually happened, including the honest zero.
    @discardableResult
    func batchFixUnreachableLines(_ fix: LineFix) async -> Int {
        guard let config = subscription else { return 0 }
        let rows = SourceProbeStore.shared.unreadableLines()
        guard !rows.isEmpty else {
            notice = L10n.text("No dead lines have been measured yet. Run Probe All first — this uses those readings rather than asking every source again.")
            return 0
        }
        var proxy: CustomProxyEndpoint?
        if case .proxy = fix {
            guard let first = customProxy.store.endpoints.first else {
                notice = L10n.text("No custom proxy is set up. Add one under Playback → Custom Proxy, or force the lines direct instead.")
                return 0
            }
            proxy = first
        }

        // One lookup for the whole batch: the origin a source belongs to is what the player reads
        // back when it picks a line, so it has to be the same value on both sides.
        var origins: [String: URL] = [:]
        for site in config.sites where origins[site.sourceKey] == nil {
            origins[site.sourceKey] = site.origin(or: config.origin)
        }

        var touched = 0
        for row in rows {
            guard !Task.isCancelled else { break }
            let origin = origins[row.sourceKey] ?? config.origin
            switch fix {
            case .proxy:
                guard let proxy else { continue }
                lineSettings.setRoute(.proxy(proxy.id), origin: origin, sourceKey: row.sourceKey, flag: row.lineFlag)
            case .direct:
                lineSettings.setRoute(.direct, origin: origin, sourceKey: row.sourceKey, flag: row.lineFlag)
            case .hide:
                lineSettings.setHidden(true, origin: origin, sourceKey: row.sourceKey, flag: row.lineFlag)
            }
            touched += 1
        }

        // Counted rather than pluralised: "1 dead lines" is the kind of detail that makes a fix look
        // unfinished, and a bare number after a colon reads correctly for one and for many.
        switch fix {
        case .proxy: notice = L10n.text("Dead lines routed through the proxy: %lld", touched)
        case .direct: notice = L10n.text("Dead lines set to play direct: %lld", touched)
        case .hide: notice = L10n.text("Dead lines hidden from the episode list: %lld", touched)
        }
        return touched
    }

    enum LineFix { case proxy, direct, hide }

    /// The order the app picks: built-in sources, then `SourceStrategy`'s, with pinned sources first. Hidden sources stay out.
    func automaticSites(_ config: Subscription) -> [Site] {
        let stamp = currentSiteListStamp()
        if stamp == siteListStamp, let cached = automaticCache { return cached }
        let sites = SourceLists.browsable(config.sites, jarURL: config.spiderURL) {
            hiddenSources.contains($0, origin: config.origin) || !vault.permits(site: $0, fallback: config.origin)
        }
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

    /// Reorders the sources by what the last sweep measured: the sharpest picture first, and a source
    /// that has never been probed after every one that has. The result is saved as the viewer's own
    /// order, which is what makes it survive a subscription refreshing and a relaunch.
    ///
    /// Built-in sources keep the top of the page. They are not a subscription's rows, a probe never
    /// compares them with one, and burying Bilibili under a 480p source would read as a bug.
    func rankSourcesByMeasuredQuality() {
        guard let config = subscription else { return }
        let sites = orderedSites(config)
        let probes = SourceProbeStore.shared
        // The viewer's own order of attributes, not a preset: a list they composed and can reorder
        // is the whole point of having a ranking page.
        let ranking = resourceRanking.keys.isEmpty ? ResourceRanking.standard : resourceRanking
        let ranked = ranking.sort(sites.filter { !$0.isBuiltIn }) { site in
            guard let reading = probes.latest(sourceKey: site.sourceKey) else { return ResourceRanking.Candidate() }
            return ResourceRanking.Candidate(reading)
        }
        sourceOrder.save(sites.filter(\.isBuiltIn) + ranked, origin: config.origin)
        sourceOrder.enabled = true
        notice = L10n.text("Sorted by measured picture quality. Sources that were never probed are last.")
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
        var groups = SourceGroups.make(entries: subscriptions, documents: documents, builtIns: config.sites.filter(\.isBuiltIn), builtInOrigin: config.origin, mergedSites: config.sites, pinOrder: pins, userHidden: { hiddenSources.contains($0, origin: config.origin) || !vault.permits(site: $0, fallback: config.origin) }, includeHidden: includeHidden, jarURL: config.spiderURL, reassign: { site, address in
            // Address first: the subscription keeps the address the viewer added, so a refresh that
            // lands on a new mirror keeps every move. The origin is only for older records.
            sourceReassignment.destination(address: address, sourceKey: site.sourceKey, origin: site.provenance?.origin)
        })
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
                       historyContext: context, resumePosition: resumePosition, subtitles: resolved.subtitles)
    }

    /// The video and its episode list, for the player's episode buttons and the next episode.
    private func remember(_ video: Video, client: CatalogClient, for channel: Channel) {
        guard let context = channel.historyContext else { return }
        if let data = try? JSONEncoder().encode(video) {
            MediaCache.shared.store(data, for: "detail", kind: .catalog, scope: context.id, ttl: 6 * 3600, ticket: MediaCache.shared.ticket())
        }
        // The Episodes menu's short labels (#318): kept from the episode before on the same video, else worked out off the
        // main thread.
        let kept = playbackCatalog.flatMap { $0.video == video ? $0.labels : nil }
        playbackCatalog = PlaybackCatalog(video: video, client: client, scope: context.id, labels: kept ?? [:])
        guard kept == nil else { return }
        let episodes = video.episodes
        Task { [weak self] in
            let labels = await Task.detached(priority: .utility) { EpisodeLabels.labels(episodes) }.value
            // Still this video, though maybe the next episode by now.
            guard let self, !labels.isEmpty, self.playbackCatalog?.video == video else { return }
            self.playbackCatalog?.labels = labels
        }
    }

    /// The next episode's stream, resolved ahead so the player can queue it behind this one; nil when
    /// auto-play is off, there is no next episode, or the source can't resolve it now.
    func upcomingEpisode(after channel: Channel) async -> Channel? {
        // Only while `channel` still plays: once the queue moves on, this was asked about the one before.
        if CloudFiles.isFile(channel.url) { return autoPlayNext && playing == channel ? nextFile(after: channel) : nil }
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
        if CloudFiles.isFile(next.url), playing == channel { playing = next; return }
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

    /// The last episode of a line just ended. Ask the same source for titles that
    /// belong with this one — a follow-up season, 红果 style — and let the end
    /// screen offer them. When the source answers nothing useful, the screen is
    /// still shown (empty) so the viewer is not dropped onto a dead player.
    func finishSeries(_ channel: Channel) {
        guard let context = channel.historyContext, let catalog = catalog(for: channel) else { return }
        let title = catalog.video.name
        let client = catalog.client
        seriesEndTask?.cancel()
        seriesEndTask = Task { [weak self] in
            guard let self else { return }
            let candidates = await self.seriesCandidates(for: catalog, client: client)
            guard !Task.isCancelled else { return }
            let ranked = SeriesSuggestionRanker.rank(
                finished: catalog.video,
                candidates: candidates,
                sourceKey: context.sourceKey,
                sourceName: context.sourceName,
                origin: context.origin
            )
            self.seriesEnd = SeriesEnd(channel: channel, title: title, suggestions: ranked)
            #if os(iOS)
            ExternalDisplay.shared.seriesEndChanged()
            #endif
        }
    }

    /// Titles from the same source that could follow `catalog.video`.
    /// Searches the base title (season wording stripped), which is how a series
    /// lists its other seasons on these sources. A failure is not an error the
    /// viewer needs to see: the end screen simply arrives with no rows.
    private func seriesCandidates(for catalog: PlaybackCatalog, client: CatalogClient) async -> [Video] {
        let base = SeriesTitleMatcher.split(catalog.video.name).base
        guard base.count >= 2 else { return [] }
        var found: [Video] = []
        if let page = try? await client.list(category: nil, query: base, page: 1) {
            found.append(contentsOf: page.videos)
        }
        return found
    }

    func dismissSeriesEnd() {
        seriesEndTask?.cancel(); seriesEndTask = nil
        seriesEnd = nil
        #if os(iOS)
        ExternalDisplay.shared.seriesEndChanged()
        #endif
    }

    /// Play a suggestion from the end screen: open that title on its own line.
    func playSeriesSuggestion(_ suggestion: SeriesSuggestion) {
        seriesEnd = nil
        seriesEndTask?.cancel(); seriesEndTask = nil
        openSeriesVideo(suggestion)
    }

    /// Resolves the suggestion's detail and starts its first episode.
    private func openSeriesVideo(_ suggestion: SeriesSuggestion) {
        guard let config = subscription,
              let site = config.sites.first(where: {
                  $0.origin(or: config.origin) == suggestion.origin && $0.sourceKey == suggestion.sourceKey
              }) else { reportMissingFavoriteSource(); return }
        let client = CatalogClient(site: resolvedSite(site, origin: config.origin), origin: config.origin, jarURL: config.spiderURL).applying(config)
        let known = suggestion.video
        seriesEndTask = Task { [weak self] in
            guard let self else { return }
            let video = (try? await client.detail(known.id))?.keepingPoster(known.poster, headers: known.posterHeaders) ?? known
            guard !Task.isCancelled, let first = video.episodes.first else { return }
            do {
                let channel = try await client.playback(first)
                self.remember(video, client: client, for: channel)
                self.playing = channel
            } catch {
                Diagnostics.shared.failure("catalog", "series suggestion \(client.reportContext) id=\(video.id)", error)
                self.error = error.localizedDescription
            }
        }
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
        return CatalogClient(site: resolvedSite(site, origin: config.origin), origin: config.origin, jarURL: config.spiderURL).applying(config)
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
    /// 1.7.7 moved the Mac app from `com.tvbox.yingxia.mac` to `com.jo32.yingxia.mac`, which starts a
    /// new defaults domain: subscriptions, favorites and settings would look lost. Copy the old domain
    /// over once (the app isn't sandboxed, so it can read it). Files under Application Support and
    /// Caches keep their `com.tvbox.yingxia` folder and need nothing.
    static func adoptPreviousBundleDefaults(_ defaults: UserDefaults) {
        let previous = "com.tvbox.yingxia.mac", done = "adoptedDefaults." + previous
        guard Bundle.main.bundleIdentifier != previous, !defaults.bool(forKey: done) else { return }
        for (key, value) in defaults.persistentDomain(forName: previous) ?? [:] where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: done)
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
}

extension Store {
    /// Plays a file from Cloud Files, where it was left if it was being watched; the folder's other
    /// files follow it.
    func playFile(_ file: CloudFile, in folder: CloudFilesFolder) {
        let channel = CloudFiles.channel(file, in: folder.drive, folder: folder.id, folderName: folder.name)
        let saved = playbackHistory.entries.first { $0.id == channel.historyContext?.id && $0.context.episodeID == file.id && !$0.completed }
        filesFolder = folder
        playing = saved.map { CloudFiles.channel(file, in: folder.drive, folder: folder.id, folderName: folder.name, resumePosition: $0.resumePosition) } ?? channel
    }

    func nextFile(after channel: Channel) -> Channel? { file(1, from: channel) }
    func previousFile(before channel: Channel) -> Channel? { file(-1, from: channel) }

    /// The file `offset` places from the playing one in its folder, for the player's Previous and Next.
    private func file(_ offset: Int, from channel: Channel) -> Channel? {
        guard let context = channel.historyContext, context.sourceKey == CloudFiles.sourceKey, let folder = filesFolder,
              folder.drive.key == context.episodeFlag, folder.id == context.videoID,
              let index = folder.files.firstIndex(where: { $0.id == context.episodeID }),
              folder.files.indices.contains(index + offset) else { return nil }
        return CloudFiles.channel(folder.files[index + offset], in: folder.drive, folder: folder.id, folderName: folder.name)
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
                                                files: files.filter { $0.kind == kind && drive.plays($0) })
        }
    }
}

struct PlaybackCatalog {
    let video: Video
    let client: CatalogClient
    let scope: String
    /// Short labels (第1集) for lines whose episode names are file names, by episode id.
    var labels: [Episode.ID: String] = [:]
    var playlist: EpisodePlaylist { EpisodePlaylist(video.episodes) }
}

/// A self-contained configuration file the viewer exports to a file (or shares) and imports later,
/// on this device or another. It carries the subscription list with each address's parsed content
/// snapshot, so importing it restores the sources even offline, and — because `importConfig` merges
/// by address — re-importing the same file never duplicates or overwrites what is already there.
struct SubscriptionConfig: Codable, Sendable {
    static let format = "mi3s-config"
    static let version = 1
    var format: String
    var version: Int
    var exportedAt: Date
    /// The subscriptions in list order, each with its last good copy.
    var subscriptions: [SyncedSubscription]

    init(subscriptions: [SyncedSubscription], exportedAt: Date = Date()) {
        self.format = Self.format; self.version = Self.version; self.exportedAt = exportedAt
        self.subscriptions = subscriptions
    }

    var isValid: Bool { format == Self.format && version == Self.version }

    static func decode(_ data: Data) -> SubscriptionConfig? {
        try? JSONDecoder().decode(SubscriptionConfig.self, from: data)
    }
}

/// A subscription as iCloud sync keeps it: the entry and its place in the list.
struct SyncedSubscription: Codable, Equatable, Sendable {
    var entry: SubscriptionEntry
    var rank: Int
    /// The subscription's parsed content, so a fresh install restores its sources without re-fetching.
    var document: Subscription?

    /// Equality ignores the document cache: it only decides whether the subscription list changed.
    static func == (lhs: SyncedSubscription, rhs: SyncedSubscription) -> Bool {
        lhs.entry == rhs.entry && lhs.rank == rhs.rank
    }
}

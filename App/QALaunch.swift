#if DEBUG
import AVFoundation
import SwiftUI
import TVCore

/// Debug-only launch hooks for screenshot QA on simulators without input:
/// `simctl launch <device> <bundle> -qaSection live -qaPage channels:0`.
/// Launch arguments land in UserDefaults' argument domain, so nothing persists.
enum QALaunch {
    static var section: AppSection? { UserDefaults.standard.string(forKey: "qaSection").flatMap(AppSection.init(rawValue:)) ?? sectionByKey }
    private static var sectionByKey: AppSection? {
        switch UserDefaults.standard.string(forKey: "qaSection") {
        case "home": .home
        case "discover": .discover
        case "live": .live
        case "music": .music
        case "search": .search
        case "sites": .sites
        case "favorites": .favorites
        case "downloads": .downloads
        case "files": .files
        case "history": .history
        case "settings": .settings
        case "messages": .messages
        case "more": .more
        default: nil
        }
    }
    static var page: String? { UserDefaults.standard.string(forKey: "qaPage") }
    /// `-qaScroll live` scrolls Watch Now to that section once recommendations have loaded.
    static var scrollTarget: String? { UserDefaults.standard.string(forKey: "qaScroll") }

    @MainActor static func start(_ store: Store) async {
        #if os(iOS)
        // Temporary screenshot sessions only; a regular launch restores normal auto-lock.
        UIApplication.shared.isIdleTimerDisabled = UserDefaults.standard.bool(forKey: "qaKeepAwake")
        UserDefaults.standard.removeObject(forKey: "qaDiscoverTrailer")
        #endif
        // `-qaAListServer <address>` adds that AList server to Cloud Files, as the Add form would.
        if let address = UserDefaults.standard.string(forKey: "qaAListServer"), let url = try? WebAddress.resolve(address) {
            if let server = await AList.probe(url) { _ = try? AListServers.add([server]) }
        }
        guard section != nil || page != nil || UserDefaults.standard.string(forKey: "qaPlay") != nil
                || UserDefaults.standard.string(forKey: "qaDownload") != nil
                || UserDefaults.standard.string(forKey: "qaPlayLive") != nil
                || UserDefaults.standard.string(forKey: "qaPlayURL") != nil else { return }
        if UserDefaults.standard.bool(forKey: "qaResetHistory") { store.playbackHistory.clear() }
        #if os(macOS)
        // `-qaWindowSnapshot <png> [-qaWindowSize 1230x830] [-qaSnapshotDelay 20]`: draws the main window into a PNG
        // itself, for a Mac with no display or no screen-recording permission.
        if let path = UserDefaults.standard.string(forKey: "qaWindowSnapshot") {
            Task { @MainActor in
                let size = (UserDefaults.standard.string(forKey: "qaWindowSize") ?? "").split(separator: "x").compactMap { Double($0) }
                try? await Task.sleep(for: .seconds(1))
                if size.count == 2 { NSApp.windows.first { $0.isVisible }?.setContentSize(NSSize(width: size[0], height: size[1])) }
                let delay = UserDefaults.standard.object(forKey: "qaSnapshotDelay") == nil ? 20 : UserDefaults.standard.double(forKey: "qaSnapshotDelay")
                try? await Task.sleep(for: .seconds(delay))
                guard let view = NSApp.windows.first(where: { $0.isVisible })?.contentView?.superview,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
        #endif
        // `-qaEnhance up,smooth` saves the Picture settings (unlike passing the keys, which would pin them
        // and stop the player's menu from switching them).
        if let enhance = UserDefaults.standard.string(forKey: "qaEnhance") {
            UserDefaults.standard.set(enhance.contains("up"), forKey: VideoEnhancement.upscaleKey)
            UserDefaults.standard.set(enhance.contains("smooth"), forKey: VideoEnhancement.smoothKey)
        }
        if UserDefaults.standard.bool(forKey: "qaResetPlayerSettings") {
            EpisodeSkipSettings().saveGlobal(defaults: store.playbackDefaults)
            for key in store.playbackDefaults.dictionaryRepresentation().keys where key.hasPrefix("episodeSkip.v1.") || key == "episodeSkip.auto.v2" {
                store.playbackDefaults.removeObject(forKey: key)
            }
        }
        if UserDefaults.standard.bool(forKey: "qaResetCache") { MediaCache.shared.clear() }
        if let subscription = UserDefaults.standard.string(forKey: "qaSubscription") {
            // With isolated data the QA subscription is the only one, as before several subscriptions:
            // one left from an earlier run would come first and win the duplicate source keys.
            if UserDefaults.standard.bool(forKey: "qaIsolatedData") {
                for entry in store.subscriptions where entry.address != subscription { store.removeSubscription(entry) }
            }
            await store.importSubscription(address: subscription)
        }
        else if section != .discover, store.subscription == nil, !Distribution.isAppStore { await store.importSubscription(address: Store.defaultURL) }
        if QASweep.enabled, let config = store.subscription { Task.detached(priority: .utility) { await QASweep.run(config) } }
        if let section { store.section = section }
        if let page, page.hasPrefix("search:") {
            // Let the tab settle first: switching sections suspends a search that is already running.
            try? await Task.sleep(for: .seconds(2))
            store.searchVideos(String(page.dropFirst(7)))
        }
        // `-qaPlayLive [<platform>:]<room>` opens a live room (Bilibili by default) in the player.
        if let target = UserDefaults.standard.string(forKey: "qaPlayLive") {
            let parts = target.split(separator: ":", maxSplits: 1).map(String.init)
            let platform = parts.count == 2 ? LivePlatform(rawValue: parts[0]) ?? .bilibili : .bilibili
            if let room = parts.last, let url = URL(string: "\(platform.scheme)://room/\(room)") {
                store.playing = Channel(name: "Live \(room)", group: platform.name, url: url)
            }
        }
        // `-qaPlayURL <address>` plays a media link as it is (an MKV on a local server, say).
        if let address = UserDefaults.standard.string(forKey: "qaPlayURL"), let url = URL(string: address) {
            store.playing = Channel(name: url.lastPathComponent, group: "QA", url: url)
        }
        // `-qaPlay <site key>:<video id>[:<episode index>]` opens that source's video in the player.
        if let target = UserDefaults.standard.string(forKey: "qaPlay"), let config = store.subscription {
            let parts = target.split(separator: ":", maxSplits: 2).map(String.init)
            if parts.count >= 2, let site = config.sites.first(where: { $0.key == parts[0] }) {
                let client = CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL)
                do {
                    let video = try await client.detail(parts[1])
                    let index = min(parts.count > 2 ? Int(parts[2]) ?? 0 : 0, max(0, video.episodes.count - 1))
                    if video.episodes.indices.contains(index) {
                        let episode = video.episodes[index]
                        store.playing = store.catalogChannel(try await client.playback(episode), video: video, episode: episode, client: client)
                    }
                } catch { store.error = error.localizedDescription }
            }
        }
        // `-qaDownload <site key>:<video id>[:<count>]` queues that video's first episodes (2 by default).
        if let target = UserDefaults.standard.string(forKey: "qaDownload"), let config = store.subscription {
            let parts = target.split(separator: ":", maxSplits: 2).map(String.init)
            if parts.count >= 2, let site = config.sites.first(where: { $0.key == parts[0] }) {
                do {
                    let video = try await CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL).detail(parts[1])
                    for episode in video.episodes.prefix(parts.count > 2 ? Int(parts[2]) ?? 2 : 2) {
                        DownloadLibrary.shared.download(DownloadSource(site: site, videoID: parts[1], episode: episode), title: video.name,
                                                        poster: video.poster, posterHeaders: video.posterHeaders)
                    }
                } catch { store.error = error.localizedDescription }
            }
        }
        if let page, page.hasPrefix("play-source:"), let config = store.subscription {
            let key = String(page.dropFirst("play-source:".count))
            do {
                guard let site = config.sites.first(where: { $0.key == key }) else { throw QASweep.Failure(message: "Source not found") }
                let client = CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL).applying(config)
                var videos: [Video]
                if let query = UserDefaults.standard.string(forKey: "qaVideoQuery") {
                    videos = try await QASweep.limit(60) { try await client.list(category: nil, query: query, page: 1).videos }
                } else {
                    let home = try await QASweep.limit(60) { try await client.home() }
                    videos = home.videos
                    if videos.isEmpty, let category = home.categories.first {
                        videos = try await QASweep.limit(60) { try await client.list(category: category.id, query: "", page: 1).videos }
                    }
                }
                let videoID = UserDefaults.standard.string(forKey: "qaVideoID")
                guard let first = videoID.flatMap({ id in videos.first { $0.id == id } }) ?? videos.first else { throw QASweep.Failure(message: "No videos") }
                let video = try await QASweep.limit(60) { try await client.detail(first.id) }
                let selectedEpisode = UserDefaults.standard.string(forKey: "qaEpisodeName")
                // `-qaEpisodeFlag <text>` keeps to lines whose name contains it (嘟嘟 for Baidu).
                let line = UserDefaults.standard.string(forKey: "qaEpisodeFlag")
                let episodes = line.map { line in video.episodes.filter { $0.flag.contains(line) } } ?? video.episodes
                guard let episode = selectedEpisode.flatMap({ name in episodes.first { $0.name == name } ?? episodes.first { $0.name.contains(name) } })
                    ?? (selectedEpisode == nil ? episodes.first : nil) else { throw QASweep.Failure(message: "No episodes") }
                // Long enough for a Baidu or Aliyun line's sign-in code to be scanned (PluginSignIn).
                let channel = try await QASweep.limit(240) { try await client.playback(episode) }
                let start = UserDefaults.standard.object(forKey: "qaStartAt") == nil ? nil : UserDefaults.standard.double(forKey: "qaStartAt")
                store.playing = store.catalogChannel(channel, video: video, episode: episode, client: client, resumePosition: start)
            } catch {
                store.error = error.localizedDescription
                let file = URL.cachesDirectory.appending(path: "qa-playback.json")
                try? JSONSerialization.data(withJSONObject: ["source": key, "stage": "resolve", "error": error.localizedDescription]).write(to: file, options: .atomic)
            }
        }
        // `-qaPage play-file:<quark|uc|alist|drive key>:<folder>` plays the folder's first video, or with
        // `-qaFileName <text>` the first whose name contains it, as choosing it in Cloud Files does.
        if let page, page.hasPrefix("play-file:") {
            let parts = page.split(separator: ":", maxSplits: 2).map(String.init)
            if parts.count == 3, let drive = filesDrive(parts[1]) {
                do {
                    let files = try await CloudFiles.list(drive, folder: parts[2])
                    let wanted = UserDefaults.standard.string(forKey: "qaFileName")
                    guard let file = files.first(where: { drive.plays($0) && (wanted == nil || $0.name.contains(wanted!)) }) else { throw QASweep.Failure(message: "No file") }
                    store.playFile(file, in: CloudFilesFolder(drive: drive, id: parts[2], name: folderName(parts[2], drive),
                                                              files: files.filter { $0.kind == file.kind && drive.plays($0) }))
                } catch { store.error = error.localizedDescription }
            }
        }
        if page == "resume-last", let entry = store.playbackHistory.entries.first {
            await store.resumeHistory(entry)
        }
        if page == "player", let url = URL(string: "http://127.0.0.1:8765/clip.mp4") {
            store.playing = Channel(name: "测试频道 01", url: url)
        }
        if page == "player-error", let url = URL(string: "http://127.0.0.1:8765/missing.mp4") {
            store.playing = Channel(name: "无法播放的频道", url: url)
        }
        // A live channel whose stream never answers, from Scripts/test-tv-ui.sh's server.
        if page == "player-stall", let url = URL(string: "http://127.0.0.1:8776/stall.m3u8") {
            store.playing = Channel(name: "卡住的直播", url: url)
        }
    }

    /// "quark", "uc", "alist" (the first AList server) or a drive's key.
    static func filesDrive(_ spec: String) -> CloudFilesDrive? {
        spec == "alist" ? CloudFiles.drives().first { if case .alist = $0 { true } else { false } } : CloudFiles.drive(key: spec)
    }

    static func folderName(_ folder: String, _ drive: CloudFilesDrive) -> String {
        folder == drive.root ? drive.name : (folder as NSString).lastPathComponent
    }

    /// The pushed page to show as the section's root, so detail screens can be captured without taps.
    @MainActor @ViewBuilder static func page(for section: AppSection, store: Store) -> some View {
        // Pages that need no subscription, so an App Store build (`-qaAppStore 1`) can show them before one is added.
        if section == self.section, store.subscription == nil, page == "cloud-accounts" {
            CloudDriveView()
        } else if section == self.section, let page, let config = store.subscription {
            let parts = page.split(separator: ":", maxSplits: 2).map(String.init)
            switch parts.first {
            case "site":
                if let site = config.sites.first(where: { $0.key == parts.dropFirst().first }) {
                    SiteView(site: site, origin: config.origin, jarURL: config.spiderURL, initialQuery: UserDefaults.standard.string(forKey: "qaQuery") ?? "")
                }
            case "detail":
                if parts.count == 3, let site = config.sites.first(where: { $0.key == parts[1] }),
                   // `-qaVideoName`, `-qaVideoPoster` and `-qaVideoRemarks` stand in for the list card a real video opens from.
                   let video = Video(json: ["vod_id": .string(parts[2]), "vod_name": .string(UserDefaults.standard.string(forKey: "qaVideoName") ?? "测试影片 \(parts[2])"),
                                            "vod_pic": .string(UserDefaults.standard.string(forKey: "qaVideoPoster") ?? "http://127.0.0.1:8765/poster.png"),
                                            "vod_remarks": .string(UserDefaults.standard.string(forKey: "qaVideoRemarks") ?? "更新至 36 集")],
                                     origin: config.origin) {
                    VideoDetailView(video: video, client: CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL))
                }
            case "open-detail":
                if parts.count == 3, let site = config.sites.first(where: { $0.key == parts[1] }),
                   let video = Video(json: ["vod_id": .string(parts[2]), "vod_name": .string("测试影片 \(parts[2])")], origin: config.origin) {
                    RouteLink { VideoDetailView(video: video, client: CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL)) } label: {
                        Text("Open video").font(.title2).padding(24)
                    }
                    .accessibilityIdentifier("qa.open-detail")
                }
            case "channels":
                if let index = Int(parts.dropFirst().first ?? ""), config.lives.indices.contains(index) {
                    ChannelListView(source: config.lives[index])
                }
            // `-qaPage folder:<quark|uc|alist|drive key>:<folder>` opens that Cloud Files folder.
            case "folder":
                if parts.count == 3, let drive = filesDrive(parts[1]) {
                    CloudFolderView(drive: drive, folder: parts[2], name: folderName(parts[2], drive))
                }
            case "alist-add": QASheet { AListServerForm(server: AListServer(name: "", address: "")) {} }
            case "runtime": RuntimeView()
            case "logs": DiagnosticsView()
            case "feedback": FeedbackView()
            #if os(tvOS)
            case "telegram": TelegramGroupView()
            #endif
            case "cache": CacheSettingsView()
            #if os(iOS)
            case "playback": PlaybackSettingsView()
            case "privacy": PrivacySettingsView()
            #endif
            case "licenses": LicensesView()
            case "bilibili-account": BilibiliAccountView()
            case "douyin-account": DouyinAccountView()
            #if !os(tvOS)
            case "douyin-login": DouyinLoginView { _ in }
            #endif
            #if os(iOS)
            // The sheet a scanned Apple TV code opens, for a TV at a made-up address.
            case "douyin-handoff":
                if let link = DouyinHandoff.Link(URL(string: "yingxia://douyin-login?host=192.168.1.20&port=50000&key=" + String(repeating: "A", count: 43))!) {
                    DouyinHandoffView(link: link)
                }
            #endif
            case "bilibili-live": LivePlatformView(platform: .bilibili)
            // `-qaPage live:<douyu|huya|douyin|bilibili>`, with `-qaQuery <text>` to show its search.
            case "live":
                if let platform = parts.dropFirst().first.flatMap(LivePlatform.init(rawValue:)) {
                    LivePlatformView(platform: platform, initialQuery: UserDefaults.standard.string(forKey: "qaQuery") ?? "")
                }
            case "danmaku-list": QADanmakuList()
            // `-qaPage cloud-login:<quark|uc|baidu|aliyun>`; `cloud-accounts` shows the accounts page.
            case "cloud-login": CloudQRLoginView(drive: parts.dropFirst().first.flatMap(CloudDriveQRLogin.Drive.init(rawValue:)) ?? .quark) {}
            case "cloud-accounts": CloudDriveView()
            #if os(iOS)
            // `-qaPage web-sign-in:<bilibili|quark|uc|baidu|aliyun>`: the service's sign-in sheet; with
            // `-qaShowCode 1` it opens on the code for another phone.
            case "web-sign-in":
                if let service = parts.dropFirst().first.flatMap(WebSignIn.init(rawValue:)) {
                    QASheet {
                        WebSignInView(service: service, showingCode: UserDefaults.standard.bool(forKey: "qaShowCode"), signedIn: {}) {
                            if let drive = CloudDriveQRLogin.Drive(rawValue: service.rawValue) { CloudQRLoginView(drive: drive) {} }
                            else { ScrollView { BilibiliCodeSignIn { _ in }.padding(24) }.screenBackdrop() }
                        }
                    }
                }
            #endif
            #if DEBUG
            // `-qaPage plugin-sign-in:<baidu|aliyun>`: a source's sign-in prompt with a made-up code.
            case "plugin-sign-in":
                if let prompt = PluginSignIn.Prompt.sample(drive: parts.dropFirst().first ?? "baidu") { QASheet { PluginSignInView(prompt: prompt) } }
            #if !os(tvOS)
            // `-qaPage catpaw-sign-in -qaCatPawBundle <index.js address> -qaCatPawSource /spider/<key>/3`: UC's TV token
            // sheet against that bundle (on iPhone and iPad, a simulator with NodeMobile).
            case "catpaw-sign-in":
                let bundle = UserDefaults.standard.string(forKey: "qaCatPawBundle") ?? ""
                let source = UserDefaults.standard.string(forKey: "qaCatPawSource") ?? "/spider/wogg/3"
                let entry = try? JSONSerialization.data(withJSONObject: ["key": "qa_catpaw", "name": "CatPawOpen", "type": 3, "api": bundle, "catPawOpen": source])
                if let origin = URL(string: bundle), let entry, let site = try? JSONDecoder().decode(Site.self, from: entry) {
                    QASheet { CatPawSignInView(client: CatalogClient(site: site, origin: origin), provider: "ucToken") {} }
                }
            #endif
            #endif
            default: EmptyView()
            }
        }
    }

    static func overrides(_ section: AppSection) -> Bool {
        guard section == self.section, let page else { return false }
        return ["site", "detail", "open-detail", "channels", "runtime", "logs", "feedback", "telegram", "cache", "playback", "privacy", "licenses", "cloud-login", "cloud-accounts", "bilibili-account", "douyin-account", "douyin-login", "douyin-handoff", "bilibili-live", "live", "danmaku-list", "web-sign-in", "plugin-sign-in", "catpaw-sign-in", "folder", "alist-add"].contains(page.split(separator: ":").first.map(String.init) ?? "")
    }
}

/// Shows a page the app presents as a sheet the same way, over an empty page.
private struct QASheet<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var shown = false
    var body: some View {
        Color.clear.task { shown = true }.sheet(isPresented: $shown) { content() }
    }
}

/// Debug-only on-device source sweep: `-qaSection settings -qaSweep 1 [-qaSweepWorkers 1] [-qaSweepFresh 1] [-qaSweepHomeTimeout 60] [-qaSweepRuntime javascript] [-qaSweepPorted 1]`.
/// `-qaSweepPorted 1` runs only sources with a bundled lite port; each record then says whether the port or the JAR answered.
/// Use one worker for JAR sources: the embedded runtime keeps two plugin runtimes, so parallel sources evict each other.
/// Runs every source the platform can run through the app's own CatalogClient
/// (home -> category -> detail -> playback -> first media bytes) and writes
/// Library/Caches/qa-sweep/results.json after each source, so a relaunch resumes where it stopped.
enum QASweep {
    struct Record: Codable, Sendable {
        var key: String, name: String, type: Int, api: String, runtime: String, hidden: Bool
        var ok = false
        var stage = "home"
        var error: String?
        var steps: [String] = []
        var seconds = 0.0
    }
    struct Timeout: LocalizedError { let seconds: Double; var errorDescription: String? { "timed out after \(Int(seconds))s" } }
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    static var enabled: Bool { UserDefaults.standard.bool(forKey: "qaSweep") }
    static let folder = URL.cachesDirectory.appending(path: "qa-sweep")

    static func run(_ config: Subscription) async {
        await PluginLocator.shared.use(config.pluginArchives)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "results.json")
        let fresh = UserDefaults.standard.bool(forKey: "qaSweepFresh")
        let previous = fresh ? [] : ((try? JSONDecoder().decode([Record].self, from: Data(contentsOf: file))) ?? [])
        let recorder = Recorder(file: file, records: previous)
        let done = Set(previous.map(\.key))
        let only = UserDefaults.standard.string(forKey: "qaSweepRuntime")
        let ported = UserDefaults.standard.bool(forKey: "qaSweepPorted")
        let sites = config.sites.filter { !done.contains($0.key) && (only == nil || "\($0.runtime)" == only) && (!ported || $0.runsLitePort) }
        let workers = max(1, UserDefaults.standard.integer(forKey: "qaSweepWorkers").nonZero ?? 3)
        await recorder.status("running \(sites.count) of \(config.sites.count) sources, \(done.count) already done")
        await withTaskGroup(of: Void.self) { group in
            var iterator = sites.makeIterator()
            for _ in 0..<workers { if let site = iterator.next() { group.addTask { await recorder.add(test(site, config)) } } }
            while await group.next() != nil {
                if let site = iterator.next() { group.addTask { await recorder.add(test(site, config)) } }
            }
        }
        await recorder.status("finished")
    }

    static func test(_ site: Site, _ config: Subscription) async -> Record {
        var record = Record(key: site.key, name: site.name, type: site.type, api: site.api, runtime: "\(site.runtime)", hidden: site.hidden)
        let started = Date()
        defer { record.seconds = Date().timeIntervalSince(started) }
        guard site.canBrowse(jarURL: config.spiderURL) else {
            record.stage = "support"; record.error = site.compatibility
            return record
        }
        let client = CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL).applying(config)
        do {
            let homeLimit = UserDefaults.standard.double(forKey: "qaSweepHomeTimeout")
            let home = try await limit(homeLimit > 0 ? homeLimit : 120) { try await client.home() }
            record.steps.append("home: \(home.categories.count) categories, \(home.videos.count) videos")
            var videos = home.videos
            if videos.isEmpty {
                record.stage = "category"
                for category in home.categories.prefix(3) {
                    do {
                        videos = try await limit(60) { try await client.list(category: category.id, query: "", page: 1) }.videos
                        record.steps.append("category \(category.name): \(videos.count) videos")
                    } catch { record.steps.append("category \(category.name): \(describe(error))") }
                    if !videos.isEmpty { break }
                }
            }
            if videos.isEmpty, site.searchable {
                record.stage = "search"
                videos = try await limit(60) { try await client.list(category: nil, query: "我的", page: 1) }.videos
                record.steps.append("search: \(videos.count) videos")
            }
            guard let first = videos.first else { throw Failure(message: "no videos from home, categories or search") }
            record.stage = "detail"
            let video = try await limit(60) { try await client.detail(first.id) }
            record.steps.append("detail \(video.name): \(video.episodes.count) episodes")
            guard let episode = video.episodes.first else { throw Failure(message: "detail has no episodes") }
            record.stage = "play"
            let channel = try await limit(60) { try await client.playback(episode) }
            record.steps.append("play: \(channel.url.absoluteString.prefix(160))")
            record.stage = "media"
            record.steps.append("media: " + (try await limit(30) { try await probe(channel) }))
            record.ok = true
            record.stage = "done"
        } catch { record.error = describe(error) }
        if site.runsLitePort {
            let fallbacks = await Diagnostics.shared.snapshot().entries.filter { $0.category == "lite.fallback" && $0.message.hasPrefix(site.key + " ") }
            record.steps.append(fallbacks.isEmpty ? "runtime: lite port" : "runtime: JAR fallback (\(fallbacks.last!.message))")
        }
        return record
    }

    /// Reads the first bytes of the media and names what it looks like.
    static func probe(_ channel: Channel) async throws -> String {
        var request = URLRequest(url: channel.url, timeoutInterval: 20)
        for (field, value) in channel.headers { request.setValue(value, forHTTPHeaderField: field) }
        request.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        var head: [UInt8] = []
        for try await byte in bytes { head.append(byte); if head.count >= 512 { break } }
        guard (200..<300).contains(status) else { throw Failure(message: "media HTTP \(status)") }
        let text = String(decoding: head, as: UTF8.self)
        let page = response.mimeType == "text/html" || ["<html", "<!doctype", "<head"].contains { text.lowercased().contains($0) }
        let kind = text.hasPrefix("#EXTM3U") ? "m3u8" : head.count > 8 && String(decoding: head[4..<8], as: UTF8.self) == "ftyp" ? "mp4"
            : head.first == 0x47 ? "mpeg-ts" : page ? "HTML page" : "unknown"
        if kind == "HTML page" { throw Failure(message: "media URL returned an HTML page") }
        return "HTTP \(status) \(response.mimeType ?? "?") \(kind)"
    }

    static func describe(_ error: Error) -> String {
        let text = error.localizedDescription
        let detail = String(describing: error)
        return (text == detail ? text : text + " | " + detail).prefix(400).description
    }

    /// A stuck plugin call cannot be cancelled, so the caller stops waiting instead.
    static func limit<T: Sendable>(_ seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let gate = Gate()
        return try await withCheckedThrowingContinuation { continuation in
            let work = Task {
                do { let value = try await operation(); if gate.claim() { continuation.resume(returning: value) } }
                catch { if gate.claim() { continuation.resume(throwing: error) } }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if gate.claim() { work.cancel(); continuation.resume(throwing: Timeout(seconds: seconds)) }
            }
        }
    }
    final class Gate: @unchecked Sendable {
        private let lock = NSLock(); private var claimed = false
        func claim() -> Bool { lock.withLock { defer { claimed = true }; return !claimed } }
    }
    actor Recorder {
        let file: URL
        var records: [Record]
        init(file: URL, records: [Record]) { self.file = file; self.records = records }
        func add(_ record: Record) {
            records.append(record)
            try? JSONEncoder().encode(records).write(to: file, options: .atomic)
            status("\(records.count) done, \(records.filter(\.ok).count) ok, last \(record.key)")
        }
        func status(_ text: String) {
            try? Data(text.utf8).write(to: file.deletingLastPathComponent().appending(path: "status.txt"), options: .atomic)
        }
    }
}

private extension Int { var nonZero: Int? { self == 0 ? nil : self } }

/// `-qaPage danmaku-list`: the player's 弹幕 tab with sample comments, to check the focused row.
private struct QADanmakuList: View {
    /// `-qaDanmakuPlayer <hls url>` gives the list a real clock (paused at 2:20) for the now-highlight and the strip.
    @State private var player: AVPlayer = {
        guard let address = UserDefaults.standard.string(forKey: "qaDanmakuPlayer"), let url = URL(string: address) else { return AVPlayer() }
        let player = AVPlayer(url: url)
        player.seek(to: CMTime(seconds: 140, preferredTimescale: 600))
        return player
    }()
    private let comments: [Danmaku] = {
        let texts = ["失恋模式", "有用的小玩意增加了", "见缝插针属于是", "我曾经有一部手机", "这个好", "直击要害", "前方高能",
                     "哈哈哈哈哈哈哈", "这一段的配乐真的绝了，建议单曲循环", "第一次看到这里的人举个手", "细节拉满", "泪目", "打卡", "这个镜头太美了"]
        let colors: [UInt32] = [0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0xFFD700, 0xFE0302, 0x00CD00, 0x4266BE, 0xFFFFFF, 0xCC0273]
        var list: [Danmaku] = []
        for index in 0..<300 {
            // Clusters around 1:00, 2:20 and 7:30, like a real episode's busy moments.
            let centre = [60.0, 140.0, 450.0, Double(index % 600)][index % 4]
            let time = max(1, min(599, centre + Double((index * 37) % 41) - 20))
            list.append(Danmaku(time: time, position: .scroll, color: colors[index % colors.count], text: texts[(index * 5 + index / 14) % texts.count]))
        }
        return list.sorted { $0.time < $1.time }
    }()
    var body: some View {
        #if os(tvOS)
        // A cover so focus starts on the first row instead of the tab bar.
        Color.clear.fullScreenCover(isPresented: .constant(true)) { DanmakuListView(player: player, comments: comments) }
        #else
        // The list as the player shows it: a sheet over the picture.
        LinearGradient(colors: [Color(red: 0.1, green: 0.16, blue: 0.3), .black], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
            .sheet(isPresented: .constant(true)) { DanmakuListView(player: player, comments: comments).danmakuListPresentation() }
        #endif
    }
}
#endif

#if DEBUG
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
        case "live": .live
        case "search": .search
        case "sites": .sites
        case "favorites": .favorites
        case "settings": .settings
        case "more": .more
        default: nil
        }
    }
    static var page: String? { UserDefaults.standard.string(forKey: "qaPage") }

    @MainActor static func start(_ store: Store) async {
        guard section != nil || page != nil else { return }
        if let subscription = UserDefaults.standard.string(forKey: "qaSubscription") { await store.importSubscription(address: subscription) }
        else if store.subscription == nil { await store.importSubscription() }
        if QASweep.enabled, let config = store.subscription { Task.detached(priority: .utility) { await QASweep.run(config) } }
        if let section { store.section = section }
        if let page, page.hasPrefix("search:") { store.searchVideos(String(page.dropFirst(7))) }
        if page == "player", let url = URL(string: "http://127.0.0.1:8765/clip.mp4") {
            store.playing = Channel(name: "测试频道 01", url: url)
        }
        if page == "player-error", let url = URL(string: "http://127.0.0.1:8765/missing.mp4") {
            store.playing = Channel(name: "无法播放的频道", url: url)
        }
    }

    /// The pushed page to show as the section's root, so detail screens can be captured without taps.
    @MainActor @ViewBuilder static func page(for section: AppSection, store: Store) -> some View {
        if section == self.section, let page, let config = store.subscription {
            let parts = page.split(separator: ":", maxSplits: 2).map(String.init)
            switch parts.first {
            case "site":
                if let site = config.sites.first(where: { $0.key == parts.dropFirst().first }) {
                    SiteView(site: site, origin: config.origin, jarURL: config.spiderURL, initialQuery: UserDefaults.standard.string(forKey: "qaQuery") ?? "")
                }
            case "detail":
                if parts.count == 3, let site = config.sites.first(where: { $0.key == parts[1] }),
                   let video = Video(json: ["vod_id": .string(parts[2]), "vod_name": .string("测试影片 \(parts[2])"),
                                            "vod_pic": .string("http://127.0.0.1:8765/poster.png"), "vod_remarks": .string("更新至 36 集")],
                                     origin: config.origin) {
                    VideoDetailView(video: video, client: CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL))
                }
            case "channels":
                if let index = Int(parts.dropFirst().first ?? ""), config.lives.indices.contains(index) {
                    ChannelListView(source: config.lives[index])
                }
            case "runtime": RuntimeView()
            case "logs": DiagnosticsView()
            case "licenses": LicensesView()
            #if !os(macOS)
            case "cloud-login": CloudQRLoginView(drive: parts.dropFirst().first == "uc" ? .uc : .quark) {}
            #endif
            default: EmptyView()
            }
        }
    }

    static func overrides(_ section: AppSection) -> Bool {
        guard section == self.section, let page else { return false }
        return ["site", "detail", "channels", "runtime", "logs", "licenses", "cloud-login"].contains(page.split(separator: ":").first.map(String.init) ?? "")
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
        let client = CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL).with(parses: config.parseServices)
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
#endif

import Foundation
import AVFoundation
import TVCore

@main struct Probe {
    @MainActor static func download(_ target: String, folder: URL, pauseAfter: Double?) async throws {
        let library = DownloadLibrary(root: folder, defaults: UserDefaults(suiteName: "probe-downloads")!)
        library.resolver = { _ in
            guard target.hasPrefix("bili:") else { return Channel(name: "probe", url: URL(string: target)!) }
            let parts = target.split(separator: ":").map(String.init)
            let client = CatalogClient(site: .bilibili, origin: URL(string: "https://example.invalid/")!)
            let video = try await client.detail(parts[1])
            let channel = try await client.playback(video.episodes[min(parts.count > 2 ? Int(parts[2]) ?? 0 : 0, video.episodes.count - 1)])
            print("resolved \(channel.url.absoluteString.prefix(100))")
            return channel
        }
        let episode = Episode(id: target, name: "Probe", address: target, flag: "probe")
        let item = library.download(DownloadSource(site: .bilibili, videoID: target, episode: episode), title: "Probe", poster: nil)
        let started = Date()
        var paused = false
        while true {
            try await Task.sleep(for: .seconds(1))
            guard let current = library.item(id: item.id) else { return }
            let rate = library.rates[item.id].map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) + "/s" } ?? "-"
            print("\(Int(Date().timeIntervalSince(started)))s \(current.status.rawValue) kind=\(current.kind?.rawValue ?? "-") \(current.quality ?? "") \(String(format: "%.1f%%", current.fraction * 100)) \(current.received)/\(current.expected ?? -1) parts=\(current.completedParts)/\(current.totalParts) \(rate) \(current.failure ?? "")")
            if let pauseAfter, !paused, Date().timeIntervalSince(started) > pauseAfter {
                paused = true
                library.pause(item.id); print("paused")
                try await Task.sleep(for: .seconds(2))
                library.resume(item.id); print("resumed")
            }
            if current.status == .failed { return }
            if current.status == .completed { break }
        }
        await library.measure()
        print("usage downloads=\(library.usage.downloads) free=\(library.usage.available ?? -1) capacity=\(library.usage.capacity ?? -1)")
        let address = try await library.playbackAddress(for: library.channel(for: library.item(id: item.id)!).url)
        print("playing \(address)")
        let player = AVPlayer(playerItem: AVPlayerItem(url: address))
        player.isMuted = true; player.play()
        for second in 1...5 {
            try await Task.sleep(for: .seconds(1))
            let current = player.currentItem!
            print("t=\(second) status=\(current.status.rawValue) time=\(String(format: "%.1f", player.currentTime().seconds)) size=\(Int(current.presentationSize.width))x\(Int(current.presentationSize.height)) tracks=\(current.tracks.count) error=\(current.error.map { "\($0)" } ?? "-")")
        }
        if let duration = player.currentItem?.duration.seconds, duration.isFinite, duration > 30 {
            await player.seek(to: CMTime(seconds: duration - 10, preferredTimescale: 600))
            try await Task.sleep(for: .seconds(2))
            print("after seek duration=\(Int(duration)) time=\(String(format: "%.1f", player.currentTime().seconds))")
        }
    }
    /// For each drive (play flag) of one video, how playback gets its bytes: straight from the CDN
    /// (CloudStreams) or through the plugin's proxy, with the address lookup time and a read speed.
    static func driveCheck(subscription: String, source: String, query: String?) async throws {
        let config = try await HTTPClient().subscription(WebAddress.resolve(subscription))
        guard let site = config.sites.first(where: { $0.key == source || $0.name.contains(source) }) else { print("no source matches \(source)"); return }
        let client = CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL)
        print("loading \(site.name)")
        let videos = if let query { try await client.list(category: nil, query: query, page: 1).videos } else { try await client.home().videos }
        guard let first = videos.first else { print("no videos"); return }
        print("\(videos.count) videos, opening \(first.name)")
        let video = try await client.detail(first.id)
        print("\(site.name) · \(video.name) · drives: \(EpisodePlaylist(video.episodes).flags.joined(separator: ", "))")
        for flag in EpisodePlaylist(video.episodes).flags {
            guard let episode = video.episodes.first(where: { $0.flag == flag }) else { continue }
            do {
                let channel = try await client.playback(episode)
                let address = try await EmbeddedJarHost.shared.recoverProxy(channel.url)
                guard EmbeddedJarHost.isPluginProxy(address) else {
                    print("\(flag): no proxy, plays from \(address.host() ?? address.scheme ?? "-")")
                    continue
                }
                let started = Date()
                let media = await EmbeddedJarHost.shared.directMedia(address)
                let lookup = String(format: "%.1f", Date().timeIntervalSince(started))
                if let media {
                    print("\(flag): DIRECT \(media.url.host() ?? "-") \(media.length / 1_048_576) MB, lookup \(lookup)s, \(try await readSpeed(media.url, headers: media.headers, parallel: true))")
                } else {
                    print("\(flag): PROXY \(EmbeddedJarHost.proxyRoute(address)), lookup \(lookup)s, \(try await readSpeed(address, headers: [:], parallel: false))")
                }
            } catch { print("\(flag): failed \(error.localizedDescription)") }
        }
    }
    /// Reads the first 8 MB in 2 MB ranges, four at once like CloudStreams or one after another like AVPlayer on a proxy.
    static func readSpeed(_ url: URL, headers: [String: String], parallel: Bool) async throws -> String {
        let piece = 2 << 20
        @Sendable func fetch(_ index: Int) async throws -> Int {
            var request = URLRequest(url: url, timeoutInterval: 30)
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            request.setValue("bytes=\(index * piece)-\((index + 1) * piece - 1)", forHTTPHeaderField: "Range")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 206 else { throw TVError.unsupported("HTTP \(status) for a range") }
            return data.count
        }
        let started = Date()
        var bytes = 0
        if parallel {
            bytes = try await withThrowingTaskGroup(of: Int.self) { group in
                for index in 0..<4 { group.addTask { try await fetch(index) } }
                return try await group.reduce(0, +)
            }
        } else {
            for index in 0..<4 { bytes += try await fetch(index) }
        }
        let seconds = Date().timeIntervalSince(started)
        return String(format: "%d MB in %.1fs = %.2f MB/s", bytes >> 20, seconds, Double(bytes) / seconds / 1_048_576)
    }
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            print("Usage: TVBoxProbe <jar path> [class descriptor] [static int method]")
            print("       TVBoxProbe --subscription-check <URL> [...]")
            return
        }
        if args[1] == "--download", args.count >= 4 {
            // --download <media URL | bili:<BV>[:part]> <folder> [pause after seconds]: the download queue end to end,
            // optionally paused and resumed partway, then the result played through AVPlayer.
            setvbuf(stdout, nil, _IONBF, 0)
            try await download(args[2], folder: URL(filePath: args[3]), pauseAfter: args.count > 4 ? Double(args[4]) : nil)
            return
        }
        if args[1] == "--cast-upgrade", args.count >= 4, let cid = Int(args[2]) {
            // --cast-upgrade <cid> <title>: finds the video a DLNA cast belongs to.
            print("aid", await Bilibili.castVideo(cid: cid, title: args[3]).map(String.init) ?? "not found")
            return
        }
        if args[1] == "--bili-chat", args.count >= 3, let room = Int(args[2]) {
            // --bili-chat <room> [seconds]: prints a live room's comments as they arrive.
            setvbuf(stdout, nil, _IONBF, 0)
            let chat = BilibiliLiveChat(room: room)
            chat.start { text, color, position in print("danmaku \(String(format: "%06x", color)) \(position) \(text)") }
            try await Task.sleep(for: .seconds(args.count > 3 ? Double(args[3]) ?? 20 : 20))
            chat.stop()
            return
        }
        if args[1] == "--bili-rooms" {
            // --bili-rooms: the built-in Bilibili Live source's channels, by group, then plays the first.
            let channels = try await HTTPClient().channels(.bilibili)
            for group in Dictionary(grouping: channels, by: \.group).sorted(by: { $0.key < $1.key }) { print(group.key, group.value.count, group.value.first?.name ?? "") }
            if let first = channels.first { let live = try await BilibiliLive.resolve(first); print("resolved", live.channel.url.absoluteString.prefix(90), "qualities", live.qualities.map { "\($0.id) \($0.label)" }, "current", live.current ?? -1) }
            return
        }
        if args[1] == "--douyin-sign", args.count >= 4, let now = Int64(args[3]) {
            // --douyin-sign <query> <epoch ms>: a_bogus with every random draw 0.5, to compare with the reference.
            print(DouyinSign.aBogus(query: args[2], now: now, random: { 0.5 }))
            return
        }
        if args[1] == "--douyin-handoff" {
            // --douyin-handoff: a TV-side receiver and an iPhone-side send over the LAN address, plus a
            // forged send (wrong key) that must be refused.
            let receiver = DouyinHandoff.Receiver()
            let got = AsyncStream<DouyinAccount> { continuation in
                _ = Task { let link = try await receiver.start { continuation.yield($0); continuation.finish() }
                    print("link", link.url.absoluteString.replacingOccurrences(of: #"key=[^&]+"#, with: "key=…", options: .regularExpression))
                    var forged = URLComponents(url: link.url, resolvingAgainstBaseURL: false)!
                    forged.queryItems = forged.queryItems!.map { $0.name == "key" ? URLQueryItem(name: "key", value: String(repeating: "A", count: 43)) : $0 }
                    do { try await DouyinHandoff.send(DouyinAccount(cookie: "sessionid=forged"), to: DouyinHandoff.Link(forged.url!)!); print("forged send ACCEPTED (bad)") }
                    catch { print("forged send refused:", error.localizedDescription) }
                    try await DouyinHandoff.send(DouyinAccount(cookie: "sessionid=test; ttwid=x", name: "probe"), to: DouyinHandoff.Link(link.url)!)
                    print("sent")
                }
            }
            for await account in got { print("received", account.name, account.cookie) }
            receiver.stop()
            return
        }
        if args[1] == "--live", args.count >= 3, let platform = LivePlatform(rawValue: args[2]) {
            // --live <bilibili|douyu|huya|douyin> [keyword|room:<id>]: areas, the first area's rooms (or the
            // search results), then the first room's stream through AVPlayer for a few seconds.
            setvbuf(stdout, nil, _IONBF, 0)
            var rooms: [LiveRoom] = []
            if args.count > 3, args[3].hasPrefix("room:") {
                rooms = [] // played directly below
            } else if args.count > 3 {
                rooms = try await LiveCatalog.search(platform, keyword: args[3])
                print("search \(args[3]): \(rooms.count) rooms")
            } else {
                let areas = try await LiveCatalog.areas(platform)
                print("areas \(areas.map(\.name).joined(separator: " "))")
                let first = try await LiveCatalog.rooms(platform, area: areas[0], page: 1)
                let second = try await LiveCatalog.rooms(platform, area: areas[0], page: 2)
                print("\(areas[0].name): page 1 \(first.count) rooms, page 2 \(second.count)")
                if areas.count > 1 { print("\(areas[1].name): \(try await LiveCatalog.rooms(platform, area: areas[1], page: 1).count) rooms") }
                rooms = first
            }
            for room in rooms.prefix(4) { print("  \(room.roomID) | \(room.host) | \(room.title) | \(room.online) | \(room.area) | \(room.cover?.absoluteString.prefix(50) ?? "-")") }
            let address = args.count > 3 && args[3].hasPrefix("room:") ? URL(string: "\(platform.scheme)://room/\(args[3].dropFirst(5))")! : rooms.first?.url
            guard let address else { return }
            let live = try await LiveCatalog.resolve(Channel(name: "", url: address))
            print("resolved \(live.channel.name) \(live.channel.url.absoluteString.prefix(110))")
            print("qualities \(live.qualities.map { "\($0.id) \($0.label)" }) current \(live.current ?? -1)")
            let item = AVPlayerItem(asset: DouyuStreams.asset(for: live.channel.url)
                ?? AVURLAsset(url: live.channel.url, options: ["AVURLAssetHTTPHeaderFieldsKey": live.channel.headers]))
            let player = AVPlayer(playerItem: item); player.isMuted = true; player.play()
            for second in 1...10 {
                try await Task.sleep(for: .seconds(1))
                print("t=\(second) status=\(item.status.rawValue) time=\(String(format: "%.1f", player.currentTime().seconds)) size=\(Int(item.presentationSize.width))x\(Int(item.presentationSize.height)) error=\(item.error.map { "\($0)" } ?? "-")")
            }
            // Recoverable problems too, such as a playlist contradicting an earlier reload (-12312).
            for event in item.errorLog()?.events ?? [] { print("errorlog \(event.errorStatusCode) \(event.errorComment ?? "-")") }
            return
        }
        if args[1] == "--bili-live", args.count >= 3, let room = Int(args[2]) {
            // --bili-live <room>: a live room's stream through AVPlayer for a few seconds.
            setvbuf(stdout, nil, _IONBF, 0)
            let channel = try await Bilibili.liveChannel(room: room)
            print("live \(channel.name) \(channel.url.absoluteString.prefix(100))")
            let item = AVPlayerItem(asset: AVURLAsset(url: channel.url, options: ["AVURLAssetHTTPHeaderFieldsKey": channel.headers]))
            let player = AVPlayer(playerItem: item); player.isMuted = true; player.play()
            for second in 1...8 {
                try await Task.sleep(for: .seconds(1))
                print("t=\(second) status=\(item.status.rawValue) time=\(String(format: "%.1f", player.currentTime().seconds)) size=\(Int(item.presentationSize.width))x\(Int(item.presentationSize.height)) error=\(item.error.map { "\($0)" } ?? "-")")
            }
            return
        }
        if args[1] == "--cast-listen" {
            // --cast-listen [seconds]: runs the Bilibili cast receiver and prints what phones send.
            setvbuf(stdout, nil, _IONBF, 0)
            let receiver = BilibiliCastReceiver.shared
            receiver.name = "Yingxia Probe"
            receiver.onEvent = { event in print("event \(event)") }
            receiver.start()
            receiver.update(.init(playing: true, position: 12, duration: 300))
            print("listening")
            try await Task.sleep(for: .seconds(args.count > 2 ? Double(args[2]) ?? 60 : 60))
            return
        }
        if args[1] == "--drama-check", args.count > 2 {
            // --drama-check xifan|hema [keyword]: home, search, a detail and two seconds of its first episode.
            setvbuf(stdout, nil, _IONBF, 0)
            let site: Site = args[2] == "hema" ? .hema : .xifan
            let client = CatalogClient(site: site, origin: URL(string: "https://example.invalid/")!)
            let home = try await client.home()
            print("home categories=\(home.categories.count) videos=\(home.videos.count) first=\(home.categories.prefix(3).map(\.name))")
            let search = try await client.list(category: nil, query: args.count > 3 ? args[3] : "总裁", page: 1)
            print("search videos=\(search.videos.count) pages=\(search.pageCount)")
            guard let first = home.videos.first else { throw TVError.emptyPlaylist }
            let video = try await client.detail(first.id)
            print("detail \(video.name) episodes=\(video.episodes.count) remarks=\(video.remarks) poster=\(video.poster?.absoluteString ?? "-")")
            guard let episode = video.episodes.first else { throw TVError.emptyPlaylist }
            let channel = try await client.playback(episode)
            print("resolve host=\(channel.url.host ?? "-")")
            let item = AVPlayerItem(asset: AVURLAsset(url: channel.url, options: ["AVURLAssetHTTPHeaderFieldsKey": channel.headers]))
            let player = AVPlayer(playerItem: item)
            player.isMuted = true; player.play()
            for _ in 0..<75 where player.currentTime().seconds < 2 && item.status != .failed { try await Task.sleep(for: .milliseconds(200)) }
            print("play status=\(item.status.rawValue) time=\(player.currentTime().seconds) size=\(item.presentationSize) error=\(item.error?.localizedDescription ?? "-")")
            guard player.currentTime().seconds >= 2 else { throw TVError.emptyPlaylist }
            return
        }
        if args[1] == "--hongguo-check" || args[1] == "--hongguo-play" {
            // --hongguo-play <series id> [episode number] isolates playback from catalog/search availability.
            // --hongguo-check [series id] [episode number] also checks the catalog, search and rankings.
            setvbuf(stdout, nil, _IONBF, 0)
            let client = CatalogClient(site: .hongguo, origin: URL(string: "https://example.invalid/")!)
            var defaultID: String?
            if args[1] == "--hongguo-check" {
                let home = try await client.home()
                defaultID = home.videos.first?.id
                print("home categories=\(home.categories.count) videos=\(home.videos.count)")
                let search = try await client.list(category: nil, query: "总裁", page: 1)
                print("search videos=\(search.videos.count) pages=\(search.pageCount)")
                let rank = try await client.list(category: "hot-drama", query: "", page: 1)
                print("ranking videos=\(rank.videos.count) pages=\(rank.pageCount)")
            }
            guard let id = args.count > 2 ? args[2] : defaultID else { throw TVError.emptyPlaylist }
            let video = try await client.detail(id)
            let index = args.count > 3 ? (Int(args[3]) ?? 4) - 1 : 3
            guard video.episodes.indices.contains(index) else { throw TVError.emptyPlaylist }
            print("detail episodes=\(video.episodes.count) selected=\(index + 1)")
            let started = Date()
            let channel = try await client.playback(video.episodes[index])
            print("resolve seconds=\(Date().timeIntervalSince(started)) streaming=\(channel.url.scheme == HongguoStreams.scheme)")
            let asset = HongguoStreams.asset(for: channel.url) ?? AVURLAsset(url: channel.url, options: ["AVURLAssetHTTPHeaderFieldsKey": channel.headers])
            let item = AVPlayerItem(asset: asset), player = AVPlayer()
            item.preferredForwardBufferDuration = HongguoStreams.forwardBufferDuration
            player.replaceCurrentItem(with: item); player.isMuted = true; player.play()
            let positionUpdates = Task {
                while !Task.isCancelled {
                    HongguoStreams.updatePosition(for: channel.url, seconds: player.currentTime().seconds)
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            defer { positionUpdates.cancel(); HongguoStreams.stop(channel.url) }
            var firstFrame = false
            for _ in 0..<100 {
                try await Task.sleep(for: .milliseconds(200))
                if item.status == .failed { throw item.error ?? TVError.emptyPlaylist }
                if !firstFrame, player.currentTime().seconds > 0.05 {
                    firstFrame = true
                    let stats = await HongguoStreams.statistics(for: channel.url)
                    print("first frame seconds=\(Date().timeIntervalSince(started)) bytes=\(stats?.received ?? 0)/\(stats?.total ?? 0)")
                }
                if player.currentTime().seconds > 2 { break }
            }
            let duration = try await asset.load(.duration).seconds
            print("play status=\(item.status.rawValue) time=\(player.currentTime().seconds) size=\(item.presentationSize) duration=\(duration)")
            if let stats = await HongguoStreams.statistics(for: channel.url) {
                print("startup seconds=\(Date().timeIntervalSince(started)) bytes=\(stats.received)/\(stats.total) cache=\(stats.cached) requests=\(stats.requests)")
            }
            guard player.currentTime().seconds > 2 else { throw TVError.emptyPlaylist }
            player.pause()
            try await Task.sleep(for: .seconds(3))
            let beforePause = await HongguoStreams.statistics(for: channel.url)
            try await Task.sleep(for: .seconds(3))
            let afterPause = await HongguoStreams.statistics(for: channel.url)
            if let beforePause, let afterPause {
                print("paused bytes=\(afterPause.received)/\(afterPause.total) additional=\(afterPause.received - beforePause.received) cache=\(afterPause.cached) bufferedThrough=\(afterPause.bufferedThrough)s")
                guard afterPause.received == beforePause.received else { throw TVError.emptyPlaylist }
                guard afterPause.bufferedThrough <= player.currentTime().seconds + HongguoStreams.forwardBufferDuration + 10 else { throw TVError.emptyPlaylist }
                if duration > 90 { guard afterPause.received < afterPause.total else { throw TVError.emptyPlaylist } }
            }
            player.play()
            await player.seek(to: CMTime(seconds: max(0, duration - 15), preferredTimescale: 600))
            try await Task.sleep(for: .seconds(3))
            print("seek time=\(player.currentTime().seconds) status=\(item.status.rawValue)")
            guard item.status == .readyToPlay, player.currentTime().seconds >= duration - 16 else { throw TVError.emptyPlaylist }
            await player.seek(to: CMTime(seconds: 5, preferredTimescale: 600))
            try await Task.sleep(for: .seconds(2))
            print("seek back time=\(player.currentTime().seconds) status=\(item.status.rawValue)")
            guard item.status == .readyToPlay, (5...10).contains(player.currentTime().seconds) else { throw TVError.emptyPlaylist }
            player.pause()
            HongguoStreams.stop(channel.url)
            return
        }
        if args[1] == "--bili-categories" {
            // --bili-categories [filter]: every category of the built-in Bilibili source with its first page's size.
            setvbuf(stdout, nil, _IONBF, 0)
            let client = CatalogClient(site: .bilibili, origin: URL(string: "https://example.invalid/")!)
            let home = try await client.home()
            print("home categories=\(home.categories.count) videos=\(home.videos.count)")
            for category in home.categories where args.count < 3 || category.id.contains(args[2]) || category.name.contains(args[2]) {
                do {
                    let page = try await client.list(category: category.id, query: "", page: 1)
                    print("\(page.videos.isEmpty ? "EMPTY" : "OK   ") \(category.id) \(category.name) videos=\(page.videos.count)")
                } catch {
                    print("FAIL  \(category.id) \(category.name) \(error.localizedDescription)")
                }
            }
            return
        }
        if args[1] == "--bili-play", args.count >= 3 {
            // --bili-play <BV id | season_N> [part index] [seconds]: the built-in Bilibili source end to end,
            // through its script port, playback resolution and AVPlayer.
            setvbuf(stdout, nil, _IONBF, 0)
            let client = CatalogClient(site: .bilibili, origin: URL(string: "https://example.invalid/")!)
            let video = try await client.detail(args[2])
            let episode = video.episodes[min(args.count > 3 ? Int(args[3]) ?? 0 : 0, video.episodes.count - 1)]
            print("detail \(video.name) parts=\(video.episodes.count) playing=\(episode.name) \(episode.address)")
            let channel = try await client.playback(episode)
            print("channel \(channel.url.absoluteString.prefix(120))")
            let comments = await DanmakuSource.comments(for: channel.url) ?? []
            print("danmaku \(comments.count) first=\(comments.prefix(3).map { "\(String(format: "%.1f", $0.time)) \($0.text)" })")
            let windows = Dictionary(grouping: comments) { Int($0.time / 10) * 10 }.mapValues(\.count)
            print("busiest 10s windows \(windows.sorted { $0.value > $1.value }.prefix(5).map { "\($0.key)s:\($0.value)" })")
            print("per 10s \(windows.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " "))")
            let asset = BilibiliStreams.asset(for: channel.url) ?? AVURLAsset(url: channel.url, options: ["AVURLAssetHTTPHeaderFieldsKey": channel.headers])
            if channel.url.scheme == BilibiliStreams.scheme {
                for variant in try await asset.load(.variants) {
                    let video = variant.videoAttributes
                    print("variant peak=\(Int(variant.peakBitRate ?? 0)) size=\(video.map { "\(Int($0.presentationSize.width))x\(Int($0.presentationSize.height))" } ?? "-") codecs=\(video?.codecTypes.map { String(format: "%08x", $0) } ?? [])")
                }
            }
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            player.play()
            for second in 1...(args.count > 4 ? Int(args[4]) ?? 12 : 12) {
                try await Task.sleep(for: .seconds(1))
                let log = item.accessLog()?.events.last
                print("t=\(second) status=\(item.status.rawValue) time=\(String(format: "%.1f", player.currentTime().seconds)) size=\(Int(item.presentationSize.width))x\(Int(item.presentationSize.height)) indicated=\(Int(log?.indicatedBitrate ?? 0)) error=\(item.error.map { "\($0)" } ?? item.errorLog()?.events.last?.errorComment ?? "-")")
                if item.status == .failed { break }
            }
            // Seek near the end: fragments far from the start must resolve too.
            let duration = try await asset.load(.duration).seconds
            if duration.isFinite, duration > 30 {
                await player.seek(to: CMTime(seconds: duration - 20, preferredTimescale: 600))
                try await Task.sleep(for: .seconds(4))
                print("after seek duration=\(Int(duration)) time=\(String(format: "%.1f", player.currentTime().seconds)) status=\(item.status.rawValue)")
            }
            return
        }
        if args[1] == "--subscription-check" {
            struct Result: Encodable, Sendable {
                let address: String
                var origin: String? = nil
                var sites: Int? = nil
                var lives: Int? = nil
                var error: String? = nil
            }
            var results: [Result] = []
            let addresses = Array(args.dropFirst(2))
            for start in stride(from: 0, to: addresses.count, by: 6) {
                await withTaskGroup(of: Result.self) { group in
                    for address in addresses[start..<min(start + 6, addresses.count)] {
                        group.addTask {
                            do {
                                let config = try await HTTPClient().subscription(WebAddress.resolve(address))
                                return Result(address: address, origin: config.origin.absoluteString, sites: config.sites.count, lives: config.lives.count)
                            } catch { return Result(address: address, error: error.localizedDescription) }
                        }
                    }
                    for await result in group { results.append(result) }
                }
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(results.sorted { $0.address < $1.address }), as: UTF8.self))
            return
        }
        if args[1] == "--drive-check", args.count >= 4 {
            // --drive-check <subscription> <source> [search]: each drive of a cloud-drive source's first
            // video, DIRECT (CDN, CloudStreams) or PROXY (every byte through the plugin runtime).
            setvbuf(stdout, nil, _IONBF, 0)
            do { try await driveCheck(subscription: args[2], source: args[3], query: args.count > 4 ? args[4] : nil) }
            catch { print("failed: \(error.localizedDescription)") }
            for entry in await Diagnostics.shared.snapshot().entries where entry.category.hasPrefix("jar") || entry.category.hasPrefix("plugin") {
                print("  \(entry.category): \(entry.message.prefix(240))")
            }
            return
        }
        if args[1] == "--catalog-check", args.count >= 3 {
            // Browses sources the way the app does (CatalogClient, so lite ports with their JAR
            // fallback): home, a category when home has no videos, detail, then playback.
            let config = try await HTTPClient().subscription(WebAddress.resolve(args[2]))
            let filters = Array(args.dropFirst(3))
            let sites = config.sites.filter { site in filters.isEmpty || filters.contains { site.name.contains($0) || site.key.contains($0) } }
            var passed = 0
            for site in sites {
                let client = CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL)
                var stage = "home"
                do {
                    let home = try await client.home()
                    var videos = home.videos
                    if videos.isEmpty, let category = home.categories.first {
                        stage = "category"
                        videos = try await client.list(category: category.id, query: "", page: 1).videos
                    }
                    guard let first = videos.first else { throw TVError.unsupported("no videos") }
                    stage = "detail"
                    let video = try await client.detail(first.id)
                    guard let episode = video.episodes.first else { throw TVError.unsupported("no episodes") }
                    stage = "play"
                    let plan = try await client.preparePlayback(episode)
                    passed += 1
                    print("OK   \(site.name)  [\(site.compatibility)]  \(home.categories.count) categories, play \(plan.choices[0].address.prefix(90))")
                } catch {
                    print("FAIL \(site.name)  [\(site.compatibility)]  [\(stage)] \(error.localizedDescription)")
                }
            }
            for entry in await Diagnostics.shared.snapshot().entries where entry.category == "lite.fallback" { print("     fallback: \(entry.message)") }
            print("\(passed)/\(sites.count) sources reached playback")
            return
        }
        if args[1] == "--tmdb-sample", args.count >= 4, let perSource = Int(args[3]) {
            // --tmdb-sample <subscription> <videos per source> [source filters]: one JSON line per video with what
            // the app sends the TMDB matcher (TMDBMatch.Request), from home and the first categories, for
            // Scripts/tmdb-sample.py.
            setvbuf(stdout, nil, _IONBF, 0)
            let config = try await HTTPClient().subscription(WebAddress.resolve(args[2]))
            let filters = Array(args.dropFirst(4))
            let sites = config.sites.filter { site in filters.isEmpty || filters.contains { site.name.contains($0) || site.key.contains($0) } }
            struct Sample: Encodable { let source: String; let sourceName: String; let id: String; let request: TMDBMatch.Request }
            func deadline<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
                try await withThrowingTaskGroup(of: T.self) { group in
                    group.addTask { try await work() }
                    group.addTask { try await Task.sleep(for: .seconds(seconds)); throw TVError.unsupported("timed out") }
                    defer { group.cancelAll() }
                    return try await group.next()!
                }
            }
            for site in sites {
                let client = CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL)
                do {
                    let home = try await deadline(40) { try await client.home() }
                    // Home often shows one kind only: mix in the first categories (movies, series, anime…).
                    var lists = [home.videos]
                    for category in home.categories.prefix(4) {
                        lists.append((try? await deadline(40) { try await client.list(category: category.id, query: "", page: 1).videos }) ?? [])
                    }
                    var videos: [Video] = [], seen = Set<String>()
                    for index in 0..<40 where videos.count < perSource {
                        for list in lists where index < list.count && videos.count < perSource && seen.insert(list[index].id).inserted { videos.append(list[index]) }
                    }
                    for video in videos {
                        guard let detail = try? await deadline(40, { try await client.detail(video.id) }) else { continue }
                        let line = Sample(source: site.key, sourceName: site.name, id: video.id,
                                          request: TMDBMatch.Request(video: detail.keepingPoster(video.poster), listVideo: video))
                        print(String(decoding: try JSONEncoder().encode(line), as: UTF8.self))
                    }
                } catch {
                    FileHandle.standardError.write(Data("FAIL \(site.key) \(site.name): \(error.localizedDescription)\n".utf8))
                }
            }
            return
        }
        if args[1] == "--tmdb-check", args.count >= 3 {
            // --tmdb-check <samples.jsonl> [parallel]: asks the TMDB matcher about each --tmdb-sample line through the app's
            // client (TMDBMatch), and prints one JSON line per video: the answer, its steps and time, and how the
            // source's episodes line up with TMDB's.
            setvbuf(stdout, nil, _IONBF, 0)
            struct Sample: Decodable { let source: String; let sourceName: String; let id: String; let request: TMDBMatch.Request }
            struct Line: Encodable {
                let source: String, title: String, year: String?, episodes: Int
                var status = "", seconds = 0.0, steps: [String] = [], error: String? = nil
                var work: String? = nil, season: Int? = nil, numbering: String? = nil, unmatched: String? = nil, candidates: [String] = []
                var tmdbEpisodes: Int? = nil, mapped: Int? = nil, mapping: [String] = []
            }
            let samples = try String(contentsOfFile: args[2], encoding: .utf8).split(separator: "\n").compactMap {
                try? JSONDecoder().decode(Sample.self, from: Data($0.utf8))
            }
            let parallel = args.count > 3 ? max(Int(args[3]) ?? 2, 1) : 2
            final class Steps: @unchecked Sendable { var list: [String] = []; let lock = NSLock()
                func add(_ step: String) { lock.lock(); list.append(step); lock.unlock() } }
            func check(_ sample: Sample) async -> Line {
                var line = Line(source: sample.sourceName, title: sample.request.title, year: sample.request.year, episodes: sample.request.episodes.count)
                let started = Date(), steps = Steps()
                do {
                    let answer = try await TMDBMatch.lookup(sample.request) { step in
                        switch step {
                        case .searching(let query): steps.add("search:\(query)")
                        case .checking(let name, let year): steps.add("details:\(name ?? "?")(\(year.map(String.init) ?? "?"))")
                        case .season(let number): steps.add("season:\(number)")
                        default: break
                        }
                    }
                    line.status = answer.status.rawValue
                    line.unmatched = answer.unmatched.isEmpty ? nil : answer.unmatched
                    line.candidates = answer.candidates.map { "\($0.mediaType.rawValue):\($0.id) \($0.name) (\($0.year.map(String.init) ?? "?"))" }
                    if let details = answer.details, let match = answer.match {
                        line.work = "\(details.mediaType.rawValue):\(details.id) \(details.name) (\(details.year.map(String.init) ?? "?"))"
                        line.season = match.season; line.numbering = match.numbering.rawValue
                        if let season = details.season {
                            line.tmdbEpisodes = season.episodes.count
                            let mapped = details.episodes(for: sample.request.episodes, numbering: match.numbering, offset: match.offset ?? 0)
                            line.mapped = mapped.compactMap { $0 }.count
                            let picks = Array(Set([0, 1, sample.request.episodes.count / 2, sample.request.episodes.count - 1])).sorted()
                            line.mapping = picks.filter { $0 >= 0 && $0 < mapped.count }.map { index in
                                "\(sample.request.episodes[index]) → \(mapped[index].map { "E\($0.number) \($0.name)" } ?? "–")"
                            }
                        }
                    }
                } catch {
                    line.status = "error"; line.error = error.localizedDescription
                }
                line.seconds = (Date().timeIntervalSince(started) * 10).rounded() / 10
                line.steps = steps.list
                return line
            }
            await withTaskGroup(of: Line.self) { group in
                var next = 0
                func add() { if next < samples.count { let sample = samples[next]; next += 1; group.addTask { await check(sample) } } }
                for _ in 0..<parallel { add() }
                for await line in group {
                    print(String(decoding: (try? JSONEncoder().encode(line)) ?? Data(), as: UTF8.self))
                    add()
                }
            }
            return
        }
        if args[1] == "--home-check", args.count >= 3 {
            // Loads each source's home the way the app's source page does and reports what its
            // category bar would show.
            let config = try await HTTPClient().subscription(WebAddress.resolve(args[2]))
            let filters = Array(args.dropFirst(3))
            let sites = config.sites.filter { site in filters.isEmpty || filters.contains { site.name.contains($0) || site.key.contains($0) } }
            // One at a time: the plugin runtime turns away interactive calls beyond a short queue.
            for site in sites {
                let client = CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL)
                do {
                    let home = try await client.home()
                    print("\(home.categories.isEmpty ? "NONE" : "OK  ") \(site.key)  \(site.name)  [\(site.compatibility) \(site.preferredRuntime)]  categories=\(home.categories.count) videos=\(home.videos.count)")
                } catch {
                    print("FAIL \(site.key)  \(site.name)  [\(site.compatibility) \(site.preferredRuntime)]  \(error.localizedDescription)")
                }
            }
            for entry in await Diagnostics.shared.snapshot().entries where entry.category == "lite.fallback" { print("     fallback: \(entry.message)") }
            return
        }
        if args[1] == "--script-check", args.count >= 3 {
            // Runs a subscription's JavaScript sources on the in-process QuickJS runtime (as iOS and
            // tvOS do): home, a category when home has no videos, detail, then playback.
            let config = try await HTTPClient().subscription(WebAddress.resolve(args[2]))
            let filters = Array(args.dropFirst(3))
            let sites = config.sites.filter { site in site.preferredRuntime == .javascript && (filters.isEmpty || filters.contains { site.name.contains($0) || site.key.contains($0) }) }
            var passed = 0
            for site in sites {
                func call(_ params: [String: String]) async throws -> [String: JSONValue] {
                    // Lite ports run alone here, without the JAR fallback, so the check measures the ports.
                    try await ScriptRuntime.shared.request(site: site, scriptURL: site.liteScript ?? site.scriptURL(origin: config.origin), params: params, http: HTTPClient(), origin: config.origin)
                }
                var stage = "home"
                do {
                    let home = CatalogPage(json: try await call(site.type == 4 ? ["filter": "true"] : [:]), origin: config.origin)
                    var videos = home.videos
                    if videos.isEmpty, let category = home.categories.first {
                        stage = "category"
                        videos = CatalogPage(json: try await call(["pg": "1", "ac": "detail", "t": category.id]), origin: config.origin).videos
                    }
                    guard let first = videos.first else { throw TVError.unsupported("no videos") }
                    stage = "detail"
                    let detail = CatalogPage(json: try await call(["ac": "detail", "ids": first.id]), origin: config.origin).videos.first
                    guard let episode = detail?.episodes.first else { throw TVError.unsupported("no episodes") }
                    stage = "play"
                    let play = try await call(["play": episode.address, "flag": episode.flag])
                    let address = play["url"]?.string ?? play["url"]?.array.map { "\($0.count / 2) choices" } ?? "none"
                    passed += 1
                    print("OK   \(site.name.prefix(24))  \(home.categories.count) categories, \(videos.count) videos, play \(address.prefix(80))")
                } catch {
                    print("FAIL \(site.name.prefix(24))  [\(stage)] \(error.localizedDescription.prefix(160))")
                }
            }
            print("\(passed)/\(sites.count) JavaScript sources reached playback on QuickJS")
            return
        }
        if args[1] == "--subscription-export", args.count == 3 {
            do {
                let config = try await HTTPClient().subscription(WebAddress.resolve(args[2]))
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try encoder.encode(config), as: UTF8.self))
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                exit(1)
            }
            return
        }
        if args[1] == "--live-check" {
            let origin = URL(string: "https://raw.githubusercontent.com/qist/tvbox/master/fty.json")!
            let config = try await HTTPClient().subscription(origin)
            print("Subscription: \(config.sites.count) sites, \(config.lives.count) live lists")
            await withTaskGroup(of: String.self) { group in
                for source in config.lives {
                    group.addTask {
                        do {
                            let channels = try await HTTPClient().channels(source)
                            return "\(source.name): \(channels.count) parsed channels (playback not verified)"
                        } catch { return "\(source.name): \(error.localizedDescription)" }
                    }
                }
                for await result in group { print(result) }
            }
            return
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
        let runtime = JarRuntime()
        let report: JarReport
        if args.count >= 4 { report = await runtime.runStaticInt(data, className: args[2], method: args[3]) }
        else { report = await runtime.inspect(data) }
        let values: [String: Any] = ["status": report.status, "dexFiles": report.dexFiles, "classes": report.classes,
                                    "nativeLibraries": report.nativeLibraries, "instructions": report.instructions,
                                    "value": report.value, "message": report.message]
        let json = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: json, as: UTF8.self))
        if report.status != 0 { exit(1) }
    }
}

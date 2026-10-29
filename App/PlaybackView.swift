import SwiftUI
import AVKit
import TVCore

@MainActor @Observable final class PlaybackSession {
    /// A queue, so the next episode can wait behind this one and play straight on.
    let player: AVQueuePlayer
    /// Upscaling and 60 fps smoothing, drawn over AVKit's picture when switched on in Settings.
    let enhancer: VideoEnhancer
    let catalogDanmaku = CatalogDanmakuModel()
    var history = PlaybackHistory.shared
    var skipDefaults = UserDefaults.standard
    private var historyContext: PlaybackHistoryContext?
    private var pendingResume: Double?
    private var restoringPosition = false
    private(set) var restoredPosition: Double?
    private(set) var requestedResumePosition: Double?
    private(set) var skipSettings = EpisodeSkipSettings()
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private var skipScope: String?
    private var skipPass = EpisodeSkipPass()
    private var editingSkip = false
    private var resumeAfterEditing = false
    private var seekingSegment = false

    func beginEditingSkip() {
        editingSkip = true
        resumeAfterEditing = player.rate > 0
        player.pause()
    }

    func endEditingSkip() {
        editingSkip = false
        if resumeAfterEditing { player.play() }
        resumeAfterEditing = false
    }

    func applySkipSettings(_ settings: EpisodeSkipSettings) {
        guard let skipScope else { return }
        settings.save(scope: skipScope, defaults: skipDefaults)
        skipSettings = settings
        skipPass = EpisodeSkipPass()
    }

    private func updateSkipping(_ item: AVPlayerItem) {
        let time = player.currentTime().seconds
        position = time.isFinite ? max(0, time) : 0
        let length = item.duration.seconds
        duration = length.isFinite ? max(0, length) : 0
        guard skipScope != nil, !editingSkip, !seekingSegment, pendingResume == nil, !restoringPosition,
              item.status == .readyToPlay else { return }
        var pass = skipPass
        guard let target = pass.target(time: time, duration: length, playing: player.rate > 0, settings: skipSettings) else {
            skipPass = pass
            return
        }
        guard item.seekableTimeRanges.contains(where: { CMTimeRangeContainsTime($0.timeRangeValue, time: CMTime(seconds: target, preferredTimescale: 600)) }) else { return }
        skipPass = pass
        seekingSegment = true
        let activeGeneration = generation
        Diagnostics.shared.record(.info, "player", "skip segment from=\(Int(time)) to=\(Int(target))")
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == activeGeneration else { return }
                self.seekingSegment = false
            }
        }
    }

    var error: String?
    var loading = true
    var looping = false { didSet { if looping { discardUpcoming() } } }
    var buffering = false
    /// Whether the picture has started moving: the waiting screen stays until then, so no black frame shows between.
    private(set) var showsPicture = false
    /// The SF Symbol that names the latest failure for the error screen.
    private(set) var errorSymbol = "play.slash.fill"
    /// Bullet comments for the media, when its source has them.
    private var sourceDanmaku: [Danmaku] = []
    var danmaku: [Danmaku] { sourceDanmaku.isEmpty ? catalogDanmaku.renderedComments : sourceDanmaku }
    var danmakuOpacity: Double { sourceDanmaku.isEmpty ? catalogDanmaku.opacity : 0.9 }
    var danmakuRevision: String { sourceDanmaku.isEmpty ? catalogDanmaku.renderedRevision : "" }
    var onPlaybackEnded: (() -> Void)?
    /// Plays another line of the same episode when this file can't play here (an MKV original);
    /// returns that line's name, or nil when there is none.
    var onUnplayableFile: (() -> String?)?
    /// The episode after this one, resolved for the queue; nil when there is none.
    var upcomingEpisode: (@MainActor () async -> Channel?)?
    /// Whether playback runs on into the next episode (auto-play can be switched off meanwhile).
    var playsOn: @MainActor () -> Bool = { false }
    /// The queued episode started playing by itself: it is now the episode on screen.
    var onAdvance: (@MainActor (Channel) -> Void)?
    /// The next episode, prepared near the end of this one and queued behind it, so playback runs
    /// straight on instead of stopping to load it.
    private struct Upcoming {
        let channel: Channel
        let item: AVPlayerItem
        let prepared: Prepared
    }
    private var upcoming: Upcoming?
    private var upcomingTask: Task<Void, Never>?
    private var upcomingObservation: NSKeyValueObservation?
    /// Whether this episode has already tried to queue the next one (once each, even when that failed).
    private var upcomingAttempted = false
    /// The queue moves past this episode because the next one was asked for, not because it ended.
    private var skipsToUpcoming = false
    /// The episode the queue moved on to, which `start` then finds already playing.
    private var advanced: Channel?
    /// The item of the episode on screen; during a move the queue's current item is already the next one.
    private var item: AVPlayerItem?
    private var queueObservation: NSKeyValueObservation?
    /// How long before an episode's end (or its skipped outro) the next one starts loading.
    static let upcomingLead: Double = 30
    /// Why the player is switching lines, shown while the other line loads.
    private var switchNotice: String?
    /// Qualities the stream can switch between (Bilibili), and the one chosen; nil is automatic.
    private(set) var qualities: [StreamQuality] = []
    /// A live stream: played at the live edge, without scrubbing.
    private(set) var isLive = false
    /// The item is ready and has a finite duration, so there is a timeline to scrub. A live stream that
    /// isn't a platform room (an IPTV channel, say) only shows itself here, as an indefinite duration.
    private(set) var hasTimeline = false
    /// Mirrors the player, for play and mute buttons drawn outside AVKit's controls.
    private(set) var paused = false
    private(set) var muted = false
    private(set) var quality: Int?
    private var playing: Channel?
    /// The episode plays from a download on this device, which no server or connection holds up.
    private var savedDownload = false
    private var automatic: URL?
    /// The live room playing (at the quality chosen), and whether it was already given a fresh address.
    private var liveRoom: Channel?
    private var liveRetried = false
    private var liveRetrying = false
    /// The episode was already asked for again after its server ignored AVPlayer's byte range.
    private var rangeRetried = false
    /// A live room's chat, whose comments join `danmaku` as they are sent.
    private var chat: BilibiliLiveChat?
    /// Download state while connecting or buffering, sampled once a second from AVFoundation's logs.
    struct Transfer {
        var received: Int64 = 0
        /// Over the last few seconds; nil until two samples exist.
        var bytesPerSecond: Double?
        /// What the playing variant needs to play without stalling.
        var required: Double?
        var host: String?
        /// The latest failure while loading media: an HTTP status, or a network error description.
        var failure: String?
        var httpStatus: Int?
    }
    private(set) var transfer = Transfer()
    /// What the player did for this episode so far, newest last: the wait's small print.
    private(set) var steps: [String] = []
    /// Adds a step to the wait's small print; once the picture shows there is no wait to tell about.
    private func note(_ step: String) {
        guard loading || !showsPicture, steps.last != step else { return }
        steps.append(step)
        if steps.count > 4 { steps.removeFirst() }
        noteKind = nil
    }
    /// A step that counts up: each count replaces the last one of the same `kind`.
    private func note(_ step: String, replacing kind: String) {
        guard loading || !showsPicture else { return }
        if noteKind == kind, !steps.isEmpty { steps[steps.count - 1] = step; return }
        note(step)
        noteKind = kind
    }
    private var noteKind: String?
    private var sampler: Task<Void, Never>?
    private var endObserver: NSObjectProtocol?
    private var timeObservation: NSKeyValueObservation?
    private var muteObservation: NSKeyValueObservation?

    func togglePlayback() {
        if player.timeControlStatus == .paused {
            if let item = player.currentItem, item.duration.seconds.isFinite,
               player.currentTime().seconds >= item.duration.seconds - 0.1 {
                player.seek(to: .zero)
            }
            player.play()
        } else { player.pause() }
        // The button follows the tap at once; the player's status (observed below) confirms it a moment later.
        paused = player.rate == 0
    }

    func skip(_ seconds: Double) {
        guard let item = player.currentItem, item.status == .readyToPlay else { return }
        let current = player.currentTime().seconds
        guard current.isFinite else { return }
        let ranges = item.seekableTimeRanges.map(\.timeRangeValue)
        guard let range = ranges.first(where: { CMTimeRangeContainsTime($0, time: player.currentTime()) }) ?? ranges.last else { return }
        let target = min(max(current + seconds, range.start.seconds), range.end.seconds)
        guard target.isFinite else { return }
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    /// Shows a live room's chat as danmaku: each comment enters as it arrives.
    private func listen(room: Int, generation active: UUID) {
        let chat = BilibiliLiveChat(room: room)
        self.chat = chat
        chat.start { text, color, position in
            Task { @MainActor [weak self] in
                guard let self, self.generation == active else { return }
                let now = self.player.currentTime().seconds
                let time = max(now.isFinite ? now + 0.2 : 0, self.sourceDanmaku.last?.time ?? 0)
                self.sourceDanmaku.append(Danmaku(time: time, position: position, color: color, text: text))
                // Keep the recent chat; dropping the oldest restarts the overlay's layout once.
                if self.sourceDanmaku.count > 4000 { self.sourceDanmaku.removeFirst(1000) }
            }
        }
    }

    /// Plays the stream at `quality` (nil: automatic) from where it is now.
    func choose(quality: Int?) {
        guard let channel = playing, quality != self.quality,
              let url = quality.flatMap({ id in qualities.first { $0.id == id }?.url }) ?? automatic else { return }
        if LiveCatalog.isRoom(url) {
            // A live quality is another stream address, fetched now; live has no position to keep.
            let active = generation
            Task {
                guard let resolved = try? await LiveCatalog.resolve(Channel(name: channel.name, group: channel.group, url: url, logo: channel.logo)),
                      self.generation == active else { return }
                self.detachItem()
                self.quality = resolved.current ?? quality
                self.liveRoom = Channel(name: channel.name, group: channel.group, url: url, logo: channel.logo)
                self.configure(resolved.channel, url: resolved.channel.url, generation: active)
            }
            return
        }
        let time = player.currentTime(), paused = player.rate == 0
        detachItem()
        self.quality = quality
        configure(Channel(name: channel.name, group: channel.group, url: url, logo: channel.logo, headers: channel.headers), url: url, generation: generation)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        if paused { player.pause() }
    }

    /// Stops listening to the current item, before another replaces it in the same playback.
    private func detachItem() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        endObserver = nil; failureObserver = nil
        sampler?.cancel(); sampler = nil
    }

    /// A live room whose playlist contradicted itself (CoreMedia -12312) gets one fresh address before
    /// the error shows: a platform's edge server can do this while it starts serving the room.
    private func retryLive(after failure: Error?) -> Bool {
        if liveRetrying { return true } // The failed item's other report of the same failure.
        guard let room = liveRoom, !liveRetried, let failure = failure as NSError?,
              failure.domain == "CoreMediaErrorDomain", failure.code == -12312 else { return false }
        liveRetried = true; liveRetrying = true; loading = true
        detachItem(); observation = nil
        let active = generation
        Diagnostics.shared.record(.warning, "player", "live retry room=\(room.url.absoluteString)")
        Task {
            do {
                let resolved = try await LiveCatalog.resolve(room)
                guard self.generation == active else { return }
                self.liveRetrying = false
                self.configure(resolved.channel, url: resolved.channel.url, generation: active)
            } catch {
                guard self.generation == active else { return }
                self.liveRetrying = false
                self.error = error.localizedDescription; self.loading = false
            }
        }
        return true
    }

    /// A server that answers the first request for a file with the whole file, ignoring the two bytes
    /// AVPlayer asked for (CoreMedia -12939), can answer properly the next time: 立播's v.vimsec.app does
    /// this for every episode nobody has opened lately. One more try, at once, does what Retry would.
    private func retryRange(after failure: Error?, channel: Channel, url: URL, generation active: UUID) -> Bool {
        guard !rangeRetried, Self.ignoredRange(failure) else { return false }
        rangeRetried = true
        detachItem(); observation = nil
        Diagnostics.shared.record(.warning, "player", "range retry host=\(url.host() ?? "-") \(failure.map(Self.describe) ?? "-")")
        configure(channel, url: url, generation: active)
        return true
    }

    /// An Apple TV can report HDR playback and still refuse a repackaged HDR10 file (-11868 with Core Media
    /// -17223, "cannot be played on this device"). The file opens again with its picture converted to SDR,
    /// and so do the files opened after it. A mirrored or recorded screen refuses HDR the same way, but only
    /// while it lasts: then this file alone converts. Dolby Vision 5 can't convert, so it isn't tried again.
    private func retryHDR(after failure: Error?, channel: Channel, url: URL, generation active: UUID) -> Bool {
        guard Remux.isHDR(url), !Remux.isDolbyVision(url), Self.refusedContent(failure) else { return false }
        let captured = Self.screenCaptured
        guard captured ? !Remux.screenCaptured : !Remux.refusesHDR else { return false }
        if captured { Remux.screenCaptured = true } else { Remux.refusesHDR = true }
        detachItem(); observation = nil
        Diagnostics.shared.record(.warning, "player", "hdr refused captured=\(captured); converting to sdr \(failure.map(Self.describe) ?? "-")")
        Remux.stop(url)
        preparation = Task { [weak self] in
            guard let self else { return }
            let prepared: Prepared
            do { prepared = try await self.prepare(channel) }
            catch {
                guard self.generation == active, !Task.isCancelled else { return }
                self.error = error.localizedDescription; self.loading = false; return
            }
            guard self.generation == active, !Task.isCancelled, !prepared.matroska else { return Self.stopAdapter(prepared) }
            self.configure(channel, url: prepared.url, generation: active)
            self.automatic = prepared.url
        }
        return true
    }

    /// The other line could not be resolved either: show why instead of loading forever.
    func lineSwitchFailed(_ message: String) {
        guard switchNotice != nil else { return }
        switchNotice = nil; error = message; loading = false
    }

    func setSpeed(_ speed: Float) {
        boost = nil
        player.defaultRate = speed
        if player.rate != 0 { player.rate = speed }
    }

    /// Another rate while the picture is held (`SpeedBoost`); nil plays at the chosen speed again. It never becomes
    /// the chosen speed, so the speed menu and a later play keep the one picked there. Pausing ends it.
    /// Up to 4× even where the item says it can't fast-forward: an HLS stream without I-frame playlists says so, yet
    /// plays at 3× and 4× in full, as the menu's speeds do.
    private(set) var boost: Float?
    func setBoost(_ rate: Float?) {
        guard rate == nil || !paused else { return }
        boost = rate
        if player.rate != 0 { player.rate = boost ?? player.defaultRate }
    }
    private var generation = UUID()
    init() {
        let player = AVQueuePlayer()
        // An episode ends paused on its last frame; only a queued next episode makes the queue move on.
        player.actionAtItemEnd = .pause
        #if DEBUG
        // `-qaMute 1`: QA runs on a shared Mac play silently.
        if UserDefaults.standard.bool(forKey: "qaMute") { player.isMuted = true }
        #endif
        self.player = player
        enhancer = VideoEnhancer(player: player)
        queueObservation = player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.queueMoved() }
        }
    }
    private var observation: NSKeyValueObservation?
    private var failureObserver: NSObjectProtocol?
    private var preparation: Task<Void, Never>?
    #if os(macOS)
    private var proxy: HLSProxy?
    #endif
    /// The session on screen, which casts from the Bilibili app control.
    static weak var current: PlaybackSession?
    func start(_ channel: Channel) {
        Self.current = self
        // The queue has already moved on to this episode by itself.
        if let advanced, advanced == channel { self.advanced = nil; return }
        savedDownload = channel.url.scheme == DownloadLibrary.scheme
        stop(); error = nil; errorSymbol = "play.slash.fill"; loading = true; showsPicture = false; sourceDanmaku = []; qualities = []; quality = nil; switchNotice = nil
        begin(channel)
        isLive = LiveCatalog.isRoom(channel.url) || channel.group == L10n.text("Bilibili Live")
        liveRoom = LiveCatalog.isRoom(channel.url) ? channel : nil; liveRetried = false; liveRetrying = false; rangeRetried = false
        ErrorReports.shared.playing(live: isLive, format: channel.url.pathExtension, source: channel.historyContext?.sourceKey,
                                    danmaku: UserDefaults.standard.object(forKey: DanmakuPreference.key) == nil || UserDefaults.standard.bool(forKey: DanmakuPreference.key),
                                    sharper: UserDefaults.standard.bool(forKey: VideoEnhancement.upscaleKey))
        let activeGeneration = generation
        Diagnostics.shared.record(.info, "player", "start name=\(channel.name) group=\(channel.group) url=\(channel.url.absoluteString) headers=\(channel.headers.keys.sorted().joined(separator: ","))")
        preparation = Task { [weak self] in
            guard let self else { return }
            // A live room becomes its current stream address now; the address expires.
            var channel = channel
            var liveQualities: [StreamQuality] = [], liveQuality: Int?
            if let room = BilibiliLive.room(channel.url) { self.listen(room: room, generation: activeGeneration) }
            if LiveCatalog.isRoom(channel.url) {
                self.note(L10n.text("Finding the live stream"))
                do { (channel, liveQualities, liveQuality) = try await LiveCatalog.resolve(channel) }
                catch {
                    guard self.generation == activeGeneration, !Task.isCancelled else { return }
                    Diagnostics.shared.failure("player", "live room=\(channel.url.absoluteString)", error)
                    self.error = error.localizedDescription; self.loading = false; return
                }
            } else {
                // A Huya stream a playlist reaches through an FLV relay plays as HLS.
                channel = await LiveCatalog.playable(channel)
            }
            let prepared: Prepared
            do { prepared = try await self.prepare(channel) }
            catch {
                guard self.generation == activeGeneration, !Task.isCancelled else { return }
                self.error = error.localizedDescription; self.loading = false; return
            }
            guard self.generation == activeGeneration, !Task.isCancelled else { return Self.stopAdapter(prepared) }
            #if os(macOS)
            self.proxy = prepared.adapter
            #endif
            // Drives keep originals as uploaded. One that couldn't be repackaged for AVPlayer: say so now, or
            // switch to the drive's transcoded line, instead of letting AVPlayer fail with a vague error.
            if prepared.matroska {
                if let line = self.onUnplayableFile?() {
                    Diagnostics.shared.record(.warning, "player", "mkv original; switching to line=\(line)")
                    self.switchNotice = L10n.text("The original file is MKV, which Apple devices can't play, so the %@ line is playing instead.", line)
                    return
                }
                Diagnostics.shared.record(.warning, "player", "mkv original; no transcoded line")
                self.error = L10n.text("This video is an MKV file, which Apple devices can't play."); self.loading = false; return
            }
            let address = prepared.url
            self.configure(channel, url: address, generation: activeGeneration)
            self.playing = channel; self.automatic = address
            self.qualities = liveQualities.isEmpty ? BilibiliStreams.qualities(for: address) : liveQualities
            self.quality = liveQuality
            if DanmakuSource.has(channel.url), let comments = await DanmakuSource.comments(for: channel.url),
               self.generation == activeGeneration { self.sourceDanmaku = comments }
        }
    }
    private func configure(_ channel: Channel, url: URL, generation activeGeneration: UUID) {
        #if !os(macOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { Diagnostics.shared.failure("player", "audio session", error); self.error = error.localizedDescription }
        #endif
        if !url.isFileURL {
            note(L10n.text("Connecting to %@", Self.server(CloudStreams.transfer(for: url)?.host ?? Remux.transfer(for: url)?.host ?? url.host())))
        }
        let item = makeItem(channel, url: url)
        watch(item, channel: channel, url: url, generation: activeGeneration)
        // A repackaged file is served on this device's loopback, which an AirPlay receiver can't reach.
        player.allowsExternalPlayback = !Remux.isRemuxed(url)
        player.preventsDisplaySleepDuringVideoPlayback = true
        player.replaceCurrentItem(with: item)
        if pendingResume == nil { player.play() }
        #if DEBUG
        // `-qaSeek <seconds>` starts playback there, for screenshots.
        let qaSeek = UserDefaults.standard.double(forKey: "qaSeek")
        if qaSeek > 0 { player.seek(to: CMTime(seconds: qaSeek, preferredTimescale: 600)) }
        #endif
    }

    /// The item for a prepared stream, with the request headers and buffer its source needs.
    private func makeItem(_ channel: Channel, url: URL) -> AVPlayerItem {
        // Some providers require request headers. AVURLAsset's HTTP-header option is
        // best-effort and is not a guarantee for every redirected HLS segment.
        let asset = CloudStreams.asset(for: url) ?? HongguoStreams.asset(for: url) ?? BilibiliStreams.asset(for: url) ?? DouyuStreams.asset(for: url)
            ?? AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": channel.headers])
        let item = AVPlayerItem(asset: asset)
        if url.scheme == HongguoStreams.scheme { item.preferredForwardBufferDuration = HongguoStreams.forwardBufferDuration }
        return item
    }

    /// The video's codec and size, for reports of sound without a picture (a codec the decoder
    /// refuses, such as HEVC tagged `hev1` in MP4, plays its audio only).
    private static func recordVideoFormat(_ item: AVPlayerItem) async {
        guard let tracks = try? await item.asset.loadTracks(withMediaType: .video) else { return }
        if tracks.isEmpty { Diagnostics.shared.record(.info, "player", "video none"); return }
        for track in tracks {
            let formats = (try? await track.load(.formatDescriptions)) ?? []
            let size = (try? await track.load(.naturalSize)) ?? .zero
            let playable = (try? await track.load(.isPlayable)) ?? false
            let codecs = formats.map { format -> String in
                let code = CMFormatDescriptionGetMediaSubType(format)
                return String(decoding: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }, as: UTF8.self)
            }
            Diagnostics.shared.record(.info, "player", "video codec=\(codecs.joined(separator: ",")) size=\(Int(size.width))x\(Int(size.height)) playable=\(playable)")
        }
    }

    /// Follows the episode's item (ready, failed, ended), the player's state, and the transfer, for this playback.
    private func watch(_ item: AVPlayerItem, channel: Channel, url: URL, generation activeGeneration: UUID) {
        self.item = item
        hasTimeline = item.status == .readyToPlay && item.duration.isNumeric
        observation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let status = item.status
            let timeline = status == .readyToPlay && item.duration.isNumeric
            let failure = item.error
            let message = failure?.localizedDescription
            let detail = failure.map(Self.describe) ?? "-"
            let refused = Self.refusedLink(failure, log: item.errorLog())
            let network = Self.networkFailure(failure)
            Task { @MainActor [weak self] in
                guard let self, self.generation == activeGeneration else { return }
                self.hasTimeline = timeline
                if status == .readyToPlay {
                    self.restorePositionIfNeeded(item)
                    self.loading = self.pendingResume != nil || self.restoringPosition
                    Diagnostics.shared.record(.info, "player", "ready host=\(self.transfer.host ?? channel.url.host() ?? "-")")
                    Task { await Self.recordVideoFormat(item) }
                }
                if status == .failed {
                    if self.retryRange(after: failure, channel: channel, url: url, generation: activeGeneration) { return }
                    if self.retryHDR(after: failure, channel: channel, url: url, generation: activeGeneration) { return }
                    Diagnostics.shared.record(.error, "player", "failed host=\(self.transfer.host ?? channel.url.host() ?? "-") \(self.transfer.failure.map { "upstream=\($0) " } ?? "")\(detail) \(self.failureContext(channel, url: url, item: item))")
                    if self.retryLive(after: failure) { return }
                    // A refused link is usually an expired one: say so in plain words rather than the system's.
                    let expired = refused || [401, 403, 404, 410].contains(self.transfer.httpStatus ?? 0)
                    self.loading = false
                    self.errorSymbol = expired ? "clock.badge.exclamationmark" : network ? "wifi.exclamationmark" : "play.slash.fill"
                    self.error = expired ? L10n.text("This episode's link may have expired. Open it again, or try another line.")
                        : Remux.isDolbyVision(url) && Self.refusedContent(failure) ? Self.dolbyVisionRefused
                        : message ?? L10n.text("This media cannot be played. Try another channel or source.")
                }
            }
        }
        failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self, weak item] notification in
            let failure = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            let message = failure?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, self.generation == activeGeneration else { return }
                Diagnostics.shared.record(.error, "player", "interrupted host=\(self.transfer.host ?? channel.url.host() ?? "-") at=\(Int(self.player.currentTime().seconds.isFinite ? self.player.currentTime().seconds : -1))s \(failure.map(Self.describe) ?? "-") \(self.failureContext(channel, url: url, item: item))")
                if self.retryLive(after: failure) { return }
                self.error = message ?? L10n.text("Playback was interrupted."); self.loading = false
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == activeGeneration else { return }
                // The queue plays the next episode by itself; `queueMoved` takes over from here.
                if self.upcoming != nil { return }
                self.saveHistory(completed: true)
                if self.looping {
                    self.skipPass = EpisodeSkipPass()
                    self.player.seek(to: .zero); self.player.play()
                } else { self.onPlaybackEnded?() }
            }
        }
        timeObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            let paused = player.timeControlStatus == .paused
            let playing = player.timeControlStatus == .playing
            Task { @MainActor [weak self] in
                guard let self, self.generation == activeGeneration else { return }
                self.buffering = waiting
                self.paused = paused
                if paused { self.boost = nil }
                // The first frame lands a beat after playback starts; keep the artwork until then, so no black flashes between.
                if playing, !self.showsPicture {
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(350))
                        guard let self, self.generation == activeGeneration, self.player.timeControlStatus == .playing else { return }
                        self.showsPicture = true
                    }
                }
            }
        }
        muteObservation = player.observe(\.isMuted, options: [.initial, .new]) { [weak self] player, _ in
            let muted = player.isMuted
            Task { @MainActor [weak self] in self?.muted = muted }
        }
        let origin = channel.url.host()
        sampler = Task { [weak self] in
            var history: [(date: Date, bytes: Int64)] = []
            var tick = 0
            while !Task.isCancelled {
                guard self?.sample(&history, tick: tick, origin: origin, generation: activeGeneration) == true else { return }
                tick += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    private func sample(_ history: inout [(date: Date, bytes: Int64)], tick: Int, origin: String?, generation activeGeneration: UUID) -> Bool {
        guard generation == activeGeneration else { return false }
        // Once the queue has moved on, `queueMoved` is about to take over the next episode.
        guard let item, player.currentItem === item else { return true }
        restorePositionIfNeeded(item)
        updateSkipping(item)
        queueUpcomingIfDue(item)
        if let url = playing?.url { HongguoStreams.updatePosition(for: url, seconds: pendingResume ?? player.currentTime().seconds) }
        if tick % 5 == 0 { saveHistory() }
        let events = item.accessLog()?.events ?? []
        let now = Date()
        var next = Transfer(received: events.reduce(Int64(0)) { $0 + max(0, $1.numberOfBytesTransferred) })
        // A resource-loader stream's bytes never reach the access log.
        let cloud = automatic.flatMap { CloudStreams.transfer(for: $0) ?? Remux.transfer(for: $0) }
        if let cloud { next.received = max(next.received, cloud.received) }
        #if os(macOS)
        // HLS goes through the local proxy, which sees upstream bytes as they arrive.
        let upstream = proxy?.stats.snapshot
        if let upstream { next.received = max(next.received, upstream.received) }
        #endif
        history.append((now, next.received))
        history.removeAll { now.timeIntervalSince($0.date) > 5 }
        if let first = history.first, now.timeIntervalSince(first.date) >= 1 {
            next.bytesPerSecond = Double(next.received - first.bytes) / now.timeIntervalSince(first.date)
        }
        // Prefer the decoded media's own bitrate; single-variant playlists declare none. AVFoundation's
        // average counts a half-fetched segment's bytes against finished durations, so it runs high
        // mid-segment and settles at each boundary: keep the lowest value seen.
        if let last = events.last {
            let media = max(0, last.averageVideoBitrate) + max(0, last.averageAudioBitrate)
            let current = media > 0 ? media / 8 : (last.indicatedBitrate > 0 ? last.indicatedBitrate / 8 : nil)
            next.required = [current, transfer.required].compactMap { $0 }.min()
        }
        // The Mac plays HLS through a local proxy; name the real server instead.
        let segmentHost = events.last?.uri.flatMap { URL(string: $0)?.host() }
        next.host = segmentHost.flatMap { ["127.0.0.1", "localhost"].contains($0) ? nil : $0 } ?? cloud?.host ?? origin
        #if os(macOS)
        if let upstream {
            next.host = upstream.host ?? next.host
            next.httpStatus = upstream.status.flatMap { (400..<600).contains($0) ? $0 : nil }
            next.failure = upstream.failure ?? upstream.status.map { "HTTP \($0)" }
        }
        #endif
        if next.failure == nil, let error = item.errorLog()?.events.last, let date = error.date, now.timeIntervalSince(date) < 30 {
            if (400..<600).contains(error.errorStatusCode) { next.httpStatus = error.errorStatusCode }
            next.failure = error.errorComment ?? "\(error.errorDomain) \(error.errorStatusCode)"
        }
        if transfer.received == 0, next.received > 0 { note(L10n.text("Receiving video from %@", Self.server(next.host))) }
        if let failure = next.failure, failure != transfer.failure { note(L10n.text("Trouble with %@ (%@), trying again", Self.server(next.host), failure)) }
        transfer = next
        #if DEBUG
        if QALaunch.page?.hasPrefix("play-source:") == true || QALaunch.page == "resume-last" || UserDefaults.standard.string(forKey: "qaPlay") != nil
            || UserDefaults.standard.string(forKey: "qaPlayURL") != nil {
            let report: [String: Any] = ["seconds": position, "duration": duration, "ready": item.status == .readyToPlay,
                "rate": player.rate, "error": error ?? "", "danmakuCount": danmaku.count,
                "errorDetail": item.error.map(Self.describe) ?? "", "videoWidth": item.presentationSize.width, "videoHeight": item.presentationSize.height,
                "enhance": enhancer.summary, "upscaling": enhancer.status.upscaling, "smoothing": enhancer.status.smoothing,
                "screenHz": Self.screenRate,
                "danmakuState": catalogDanmaku.automaticState, "cached": catalogDanmaku.fromCache,
                "introEnd": skipSettings.introEnd, "outroLength": skipSettings.outroLength,
                "requestedResumePosition": requestedResumePosition ?? 0, "restoredPosition": restoredPosition ?? 0]
            try? JSONSerialization.data(withJSONObject: report).write(to: URL.cachesDirectory.appending(path: "qa-playback.json"), options: .atomic)
        }
        #endif
        if (loading || buffering) && tick % 5 == 0 {
            Diagnostics.shared.record(.debug, "player", "waiting host=\(next.host ?? "-") received=\(next.received) speed=\(Int(next.bytesPerSecond ?? -1)) required=\(Int(next.required ?? -1)) failure=\(next.failure ?? "-")")
        }
        return true
    }
    /// Domain and code of the error and its underlying cause: AVFoundation's messages alone
    /// ("The operation could not be completed") don't tell an HTTP 403 from a decoder failure.
    nonisolated static func describe(_ error: Error) -> String { Diagnostics.describe(error) }
    #if DEBUG
    /// The screen's refresh rate now, which on Apple TV follows the display mode.
    private static var screenRate: Int {
        #if os(macOS)
        return NSScreen.main?.maximumFramesPerSecond ?? 0
        #else
        return (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.maximumFramesPerSecond ?? 0
        #endif
    }
    #endif
    /// What a failure report needs besides the error: the source, the way the stream reaches AVPlayer,
    /// its format, and AVPlayer's own last network error (often the HTTP status of one segment).
    private func failureContext(_ channel: Channel, url: URL, item: AVPlayerItem?) -> String {
        let scheme = url.scheme ?? "-"
        let via = ["http", "https"].contains(scheme) ? (["127.0.0.1", "localhost"].contains(url.host() ?? "") ? "local-proxy" : "direct") : scheme
        let format = channel.url.pathExtension.isEmpty ? "-" : String(channel.url.pathExtension.lowercased().prefix(5))
        var text = "source=\(channel.historyContext?.sourceKey ?? "-") live=\(isLive) via=\(via) format=\(format)"
        if let event = item?.errorLog()?.events.last {
            text += " log=\(event.errorStatusCode) \(event.errorDomain) \(event.errorComment ?? "-")"
        }
        return text
    }
    func stop() {
        saveHistory()
        discardUpcoming()
        upcomingAttempted = false; skipsToUpcoming = false; advanced = nil
        upcomingEpisode = nil; onAdvance = nil; playsOn = { false }; boost = nil
        if let url = playing?.url { HongguoStreams.stop(url) }
        if let automatic { CloudStreams.stop(automatic); Remux.stop(automatic) }
        if playing != nil { ErrorReports.shared.stoppedPlaying() }
        playing = nil
        catalogDanmaku.clear()
        historyContext = nil; pendingResume = nil; restoringPosition = false
        requestedResumePosition = nil; restoredPosition = nil
        skipScope = nil; skipSettings = EpisodeSkipSettings(); skipPass = EpisodeSkipPass()
        position = 0; duration = 0; editingSkip = false; resumeAfterEditing = false; seekingSegment = false
        onPlaybackEnded = nil; onUnplayableFile = nil
        if player.currentItem != nil {
            let seconds = player.currentTime().seconds
            Diagnostics.shared.record(.info, "player", "stop at=\(seconds.isFinite ? Int(seconds) : -1)s")
        }
        generation = UUID()
        chat?.stop(); chat = nil
        preparation?.cancel(); preparation = nil
        sampler?.cancel(); sampler = nil
        transfer = Transfer(); steps = []
        #if os(macOS)
        if let proxy { Task { await proxy.stop() } }; proxy = nil
        #endif
        observation = nil
        timeObservation = nil
        muteObservation = nil
        buffering = false
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = nil
        player.pause(); player.removeAllItems(); item = nil
    }
    /// Records where the episode is; `item` is the episode's own, which the queue may already have moved past.
    func saveHistory(completed: Bool = false, item: AVPlayerItem? = nil) {
        guard let context = historyContext, let item = item ?? self.item, item.status == .readyToPlay,
              pendingResume == nil, !restoringPosition, !seekingSegment else { return }
        let length = item.duration.seconds
        let time = completed && length.isFinite ? length : item.currentTime().seconds
        history.record(context, position: time, duration: length.isFinite ? length : 0)
    }

    /// Per-episode state: where its history goes, where it resumes, the intro and outro to skip, its danmaku.
    private func begin(_ channel: Channel) {
        historyContext = channel.historyContext
        requestedResumePosition = channel.resumePosition
        pendingResume = channel.resumePosition.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        restoringPosition = false; restoredPosition = nil
        skipScope = channel.skipScope
        skipSettings = skipScope.map { EpisodeSkipSettings.load(scope: $0, defaults: skipDefaults) } ?? EpisodeSkipSettings()
        skipPass = EpisodeSkipPass(); seekingSegment = false
        position = 0; duration = 0
        upcomingAttempted = false
        // A drive's folder and file names don't name a show to find comments for.
        let source = channel.historyContext?.sourceKey
        if !DanmakuSource.has(channel.url), source != Bilibili.siteKey, source != CloudFiles.sourceKey {
            catalogDanmaku.startAutomatic(channel.historyContext)
        }
    }

    private func restorePositionIfNeeded(_ item: AVPlayerItem) {
        guard let requested = pendingResume, !restoringPosition, item.status == .readyToPlay,
              let target = PlaybackHistoryEntry.resumeTarget(requested, duration: item.duration.seconds) else { return }
        restoringPosition = true
        let pattern: Duration.TimeFormatStyle.Pattern = target >= 3600 ? .hourMinuteSecond : .minuteSecond
        note(L10n.text("Jumping to %@", Duration.seconds(Int(target)).formatted(.time(pattern: pattern))))
        let activeGeneration = generation
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.generation == activeGeneration else { return }
                self.restoringPosition = false; self.pendingResume = nil; self.loading = false
                guard finished else {
                    self.error = L10n.text("The player could not restore the saved position. Try again.")
                    return
                }
                self.restoredPosition = self.player.currentTime().seconds
                Diagnostics.shared.record(.info, "player", "history resume requested=\(requested) restored=\(self.restoredPosition ?? -1)")
                if !self.editingSkip { self.player.play() }
                self.saveHistory()
            }
        }
    }
}

extension PlaybackSession {
    /// A catalog stream made ready for AVPlayer: past the plugin's proxy, at a cloud drive's CDN or a
    /// saved download, and on the Mac through the local HLS adapter, which stops with the episode.
    fileprivate struct Prepared {
        var url: URL
        /// A cloud drive's original in a container AVPlayer can't open (MKV, AVI, ...) that couldn't be repackaged.
        var matroska = false
        /// Every byte passes through the plugin runtime.
        var pluginProxy = false
        #if os(macOS)
        var adapter: HLSProxy?
        #endif
    }

    fileprivate func prepare(_ channel: Channel) async throws -> Prepared {
        var address = channel.url
        do { address = try await EmbeddedJarHost.shared.recoverProxy(address) }
        catch {
            if !Task.isCancelled { Diagnostics.shared.failure("player", "plugin proxy source=\(channel.historyContext?.sourceKey ?? "-")", error) }
            throw error
        }
        var prepared = Prepared(url: address)
        // A file from Cloud Files streams from its drive.
        if CloudFiles.isFile(address) {
            note(L10n.text("Getting the file from the drive"))
            do { address = try await CloudFiles.prepare(address) }
            catch {
                if !Task.isCancelled { Diagnostics.shared.failure("player", "cloud file \(channel.historyContext?.episodeFlag ?? "-")", error) }
                throw error
            }
            prepared.url = address
        }
        // A cloud-drive file streams straight from its CDN: the plugin's proxy only reveals the
        // address. Otherwise every range AVPlayer opens costs the plugin a set of threads.
        if let media = await EmbeddedJarHost.shared.directMedia(address) {
            try Task.checkCancellation()
            let proxied = address
            address = CloudStreams.register(media) { await EmbeddedJarHost.shared.directMedia(proxied) }
            prepared.url = address
            Diagnostics.shared.record(.info, "player", "cloud direct host=\(media.url.host() ?? "-") length=\(media.length)")
        } else if let media = await CatPawOpen.proxiedMedia(address, headers: channel.headers) {
            try Task.checkCancellation()
            // The bundle downloads each request with 10 to 16 threads of its own: reading ahead on six at once ran its
            // Node out of memory, and on one a 4K episode stalled whenever the drive slowed.
            address = CloudStreams.register(media, parallel: 2) { nil }
            prepared.url = address
            Diagnostics.shared.record(.info, "player", "catpaw stream length=\(media.length)")
        } else if EmbeddedJarHost.isPluginProxy(address) {
            Diagnostics.shared.record(.warning, "player", "plugin proxy stream \(EmbeddedJarHost.proxyRoute(address))")
            prepared.pluginProxy = true
        }
        // MKV, AVI, FLV, WMV and RMVB from a drive play repackaged as HLS; AVPlayer opens none of them.
        if address.scheme == CloudStreams.scheme, await CloudStreams.needsRemux(address) {
            try Task.checkCancellation()
            note(L10n.text("Repackaging the video for this device"))
            if let source = await CloudStreams.remuxSource(for: address), let url = await Self.remux(source, channel: channel) {
                prepared.url = url
                return prepared
            }
            try Task.checkCancellation()
            prepared.matroska = true
            return prepared
        }
        // A downloaded episode plays from disk: its file, or its HLS through a loopback server.
        if address.scheme == DownloadLibrary.scheme {
            note(L10n.text("Opening the saved download"))
            do {
                address = try await DownloadLibrary.shared.playbackAddress(for: address) { fraction in
                    Task { @MainActor [weak self] in
                        self?.note(L10n.text("Preparing the saved download for this device · %lld%%", Int(fraction * 100)), replacing: "rewrap")
                    }
                }
            }
            catch {
                if !Task.isCancelled { Diagnostics.shared.failure("player", "saved download", error) }
                throw error
            }
            prepared.url = address
        }
        // A link or saved file whose name says MKV and the like is repackaged too; when that fails AVPlayer
        // tries it as it is.
        if Remux.handles(name: address.lastPathComponent), ["http", "https", "file"].contains(address.scheme) {
            note(L10n.text("Repackaging the video for this device"))
            let source: RemuxSource?
            if address.isFileURL { source = try? Remux.fileSource(address) }
            else {
                do { source = try await Remux.httpSource(address, headers: channel.headers) }
                catch {
                    if !Task.isCancelled { Diagnostics.shared.failure("player", "remux link host=\(address.host() ?? "-")", error) }
                    source = nil
                }
            }
            try Task.checkCancellation()
            if let source, let url = await Self.remux(source, channel: channel) {
                prepared.url = url
                return prepared
            }
        }
        #if os(macOS)
        if address.pathExtension.lowercased() == "m3u8", ["http", "https"].contains(address.scheme), channel.url.scheme != DownloadLibrary.scheme {
            let adapter = HLSProxy(headers: channel.headers)
            do { prepared.url = try await adapter.start(url: address) }
            catch {
                if !Task.isCancelled { Diagnostics.shared.record(.error, "player", "proxy failed host=\(channel.url.host() ?? "-") \(Self.describe(error))") }
                throw error
            }
            prepared.adapter = adapter
        }
        #endif
        return prepared
    }

    /// Why a Dolby Vision 5 file was refused: while the screen is mirrored or recorded iOS plays no HDR stream.
    private static var dolbyVisionRefused: String {
        screenCaptured ? L10n.text("Dolby Vision video can't play while the screen is mirrored or recorded. Stop mirroring or recording, then try again.")
            : L10n.text("This device can't play this Dolby Vision video. Try another line.")
    }

    /// Whether the screen is mirrored or recorded right now (`Remux.screenCaptured`).
    static var screenCaptured: Bool {
        #if canImport(UIKit)
        UIApplication.shared.connectedScenes.contains { ($0 as? UIWindowScene)?.traitCollection.sceneCaptureState == .active }
        #else
        false
        #endif
    }

    /// The repackaged file's address, nil when FFmpeg can't read it.
    fileprivate static func remux(_ source: RemuxSource, channel: Channel) async -> URL? {
        Remux.screenCaptured = screenCaptured
        do { return try await Remux.open(source, subtitles: channel.subtitles, headers: channel.headers) }
        catch {
            if !Task.isCancelled { Diagnostics.shared.failure("player", "remux source=\(channel.historyContext?.sourceKey ?? "-")", error) }
            return nil
        }
    }

    /// The local HLS adapter, or repackager, of a stream that won't play after all.
    fileprivate static func stopAdapter(_ prepared: Prepared) {
        Remux.stop(prepared.url)
        #if os(macOS)
        if let adapter = prepared.adapter { Task { await adapter.stop() } }
        #endif
    }
}

extension PlaybackSession {
    /// Near the end of an episode, resolves the next one and queues it behind this one, where it loads
    /// while this one finishes; the queue then plays it straight on. When it can't be queued (no next
    /// episode, a plugin-proxied stream or an original that won't play, a failure), the episode ends and
    /// switches as before.
    fileprivate func queueUpcomingIfDue(_ item: AVPlayerItem) {
        if upcoming != nil, looping || !playsOn() { return discardUpcoming() }
        guard !upcomingAttempted, !looping, !isLive, playsOn(), let upcomingEpisode, item.status == .readyToPlay,
              pendingResume == nil, !restoringPosition else { return }
        let length = item.duration.seconds, time = item.currentTime().seconds
        guard length.isFinite, length > 0, time.isFinite else { return }
        let end = skipSettings.enabled && skipSettings.outroLength > 0 ? length - skipSettings.outroLength : length
        guard end - time <= Self.upcomingLead else { return }
        upcomingAttempted = true
        let activeGeneration = generation
        upcomingTask = Task { [weak self] in
            guard let next = await upcomingEpisode(), let self, self.generation == activeGeneration, !Task.isCancelled else { return }
            let prepared: Prepared
            do { prepared = try await self.prepare(next) }
            catch {
                Diagnostics.shared.record(.warning, "player", "upcoming not prepared \(Self.describe(error))")
                return
            }
            guard self.generation == activeGeneration, !Task.isCancelled, !self.looping, self.playsOn(),
                  !prepared.matroska, !prepared.pluginProxy, self.player.currentItem === item else {
                return Self.release(next, prepared)
            }
            let queued = self.makeItem(next, url: prepared.url)
            guard self.player.canInsert(queued, after: item) else { return Self.release(next, prepared) }
            self.player.insert(queued, after: item)
            self.player.actionAtItemEnd = .advance
            self.upcoming = Upcoming(channel: next, item: queued, prepared: prepared)
            Diagnostics.shared.record(.info, "player", "upcoming queued name=\(next.name) left=\(Int(length - item.currentTime().seconds))s")
            // The next episode starts past its intro when that is skipped, rather than jumping there once it plays.
            let intro = next.skipScope.map { EpisodeSkipSettings.load(scope: $0, defaults: self.skipDefaults) }
            self.upcomingObservation = queued.observe(\.status, options: [.initial, .new]) { [weak self] queued, _ in
                let status = queued.status, failure = queued.error
                Task { @MainActor [weak self] in
                    guard let self, self.upcoming?.item === queued else { return }
                    if status == .failed {
                        Diagnostics.shared.record(.warning, "player", "upcoming failed \(failure.map(Self.describe) ?? "-")")
                        self.discardUpcoming()
                    } else if status == .readyToPlay, let intro, intro.enabled, intro.introEnd > 0,
                              intro.validationError(duration: queued.duration.seconds) == nil, queued.currentTime().seconds < intro.introEnd {
                        queued.seek(to: CMTime(seconds: intro.introEnd, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil)
                    }
                }
            }
        }
    }

    /// Takes the queued episode out again: auto-play went off, looping came on, or its stream failed.
    /// The episode then ends paused and switches the ordinary way.
    fileprivate func discardUpcoming() {
        upcomingTask?.cancel(); upcomingTask = nil
        upcomingObservation = nil
        player.actionAtItemEnd = .pause
        guard let upcoming else { return }
        self.upcoming = nil
        player.remove(upcoming.item)
        Self.release(upcoming.channel, upcoming.prepared)
    }

    /// Stops the streams a prepared episode opened.
    fileprivate static func release(_ channel: Channel, _ prepared: Prepared) {
        HongguoStreams.stop(channel.url)
        CloudStreams.stop(prepared.url)
        stopAdapter(prepared)
    }

    /// Plays the queued next episode now (the Next Episode button); false when none is queued yet.
    func playUpcoming() -> Bool {
        guard let upcoming, upcoming.item.status != .failed, player.currentItem === item else { return false }
        skipsToUpcoming = true
        player.advanceToNextItem()
        player.play()
        return true
    }

    /// The queue moved on to the episode it held: that episode takes over the session, its item already
    /// playing, without the wait a new start would show.
    fileprivate func queueMoved() {
        guard let upcoming, player.currentItem === upcoming.item else { return }
        saveHistory(completed: !skipsToUpcoming, item: item)
        skipsToUpcoming = false
        let channel = upcoming.channel
        Diagnostics.shared.record(.info, "player", "advance name=\(channel.name) ready=\(upcoming.item.status == .readyToPlay)")
        // Let go of the finished episode's stream; the queued one's becomes the session's.
        if let url = playing?.url { HongguoStreams.stop(url) }
        if let automatic { CloudStreams.stop(automatic); Remux.stop(automatic) }
        #if os(macOS)
        if let proxy { Task { await proxy.stop() } }
        proxy = upcoming.prepared.adapter
        #endif
        detachItem(); observation = nil
        upcomingObservation = nil; upcomingTask = nil; self.upcoming = nil
        player.actionAtItemEnd = .pause
        generation = UUID()
        let activeGeneration = generation
        transfer = Transfer(); steps = []
        catalogDanmaku.clear(); sourceDanmaku = []
        error = nil; switchNotice = nil; quality = nil
        begin(channel)
        loading = upcoming.item.status != .readyToPlay
        playing = channel; automatic = upcoming.prepared.url
        player.allowsExternalPlayback = !Remux.isRemuxed(upcoming.prepared.url)
        qualities = BilibiliStreams.qualities(for: upcoming.prepared.url)
        watch(upcoming.item, channel: channel, url: upcoming.prepared.url, generation: activeGeneration)
        if DanmakuSource.has(channel.url) {
            Task { [weak self] in
                guard let comments = await DanmakuSource.comments(for: channel.url), let self, self.generation == activeGeneration else { return }
                self.sourceDanmaku = comments
            }
        }
        advanced = channel
        onAdvance?(channel)
    }
}

extension PlaybackSession {
    /// The player's wait, with download speed against what the video needs.
    var loadingProgress: LoadingProgress {
        let transfer = transfer
        // AVPlayer counts the first segment only once it finishes, so zero bytes means "not yet", not "stalled".
        let speed = transfer.received > 0 ? transfer.bytesPerSecond.map(Self.rate) : nil
        var progress = LoadingProgress(title: L10n.text(loading ? "Connecting…" : "Buffering…"))
        if loading || !showsPicture { progress.steps = steps }
        if let switchNotice {
            progress.reason = switchNotice
            return progress
        }
        if let speed {
            progress.detail = transfer.required.map { L10n.text("%@ · needs %@", speed, Self.rate($0)) }
                ?? L10n.text("Downloading at %@", speed)
        } else if let host = transfer.host {
            progress.detail = L10n.text("Waiting for %@", host)
        }
        let server = transfer.host ?? L10n.text("The video server")
        if let status = transfer.httpStatus {
            progress.reason = L10n.text("%@ returned an error (%@). The link may have expired: go back and play the episode again, or choose another line.", server, "HTTP \(status)")
        } else if let failure = transfer.failure {
            progress.reason = L10n.text("Couldn't load video from %@ (%@). Check the connection, or choose another line.", server, failure)
        } else if transfer.received == 0 {
            progress.reason = L10n.text("%@ hasn't delivered the first part of the video yet. The server may be slow or down; try another line.", server)
        } else if let bytes = transfer.bytesPerSecond, let required = transfer.required, bytes < required {
            progress.reason = L10n.text("%@ sends %@, but this video needs about %@. Try another line, or wait without skipping.", server, Self.rate(bytes), Self.rate(required))
        } else {
            progress.reason = L10n.text("The player is filling its buffer before playback continues.")
        }
        return progress
    }
    /// A server's name for the wait's small print; this device's own proxies stand for the source's server.
    static func server(_ host: String?) -> String {
        guard let host, !host.isEmpty, !["127.0.0.1", "localhost"].contains(host) else { return L10n.text("the video server") }
        return host
    }
    private static func rate(_ bytesPerSecond: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false // "0 KB", not "Zero KB"
        return L10n.text("%@/s", formatter.string(fromByteCount: Int64(max(0, bytesPerSecond))))
    }
}

extension PlaybackSession {
    /// Whether the server refused the link (HTTP 401, 403, 404 or 410), which for a catalog episode usually means it expired.
    /// AVFoundation reports these as URL or Core Media errors more often than as a status in the error log.
    nonisolated static func refusedLink(_ error: Error?, log: AVPlayerItemErrorLog?) -> Bool {
        if [401, 403, 404, 410].contains(log?.events.last?.errorStatusCode ?? 0) { return true }
        var current = error as NSError?
        while let error = current {
            if error.domain == NSURLErrorDomain,
               [NSURLErrorNoPermissionsToReadFile, NSURLErrorFileDoesNotExist, NSURLErrorUserAuthenticationRequired].contains(error.code) { return true }
            // Core Media's codes for HTTP 403 and 404.
            if error.domain == "CoreMediaErrorDomain", [-12660, -12938].contains(error.code) { return true }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// The server sent a different length than the byte range AVPlayer asked for (CoreMedia -12939,
    /// "byte range length mismatch"; an OSStatus on older systems).
    nonisolated static func ignoredRange(_ error: Error?) -> Bool {
        var current = error as NSError?
        while let error = current {
            if ["CoreMediaErrorDomain", NSOSStatusErrorDomain].contains(error.domain), error.code == -12939 { return true }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// AVPlayer won't play the stream's content on this device (AVFoundation -11868, Core Media -17223).
    nonisolated static func refusedContent(_ error: Error?) -> Bool {
        var current = error as NSError?
        while let error = current {
            if error.domain == AVFoundationErrorDomain, error.code == -11868 { return true }
            if error.domain == "CoreMediaErrorDomain", error.code == -17223 { return true }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// A failure to reach the server at all: offline, timed out, or the host could not be found.
    nonisolated static func networkFailure(_ error: Error?) -> Bool {
        var current = error as NSError?
        while let error = current {
            if error.domain == NSURLErrorDomain, [NSURLErrorNotConnectedToInternet, NSURLErrorTimedOut, NSURLErrorCannotFindHost,
                                                   NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost].contains(error.code) { return true }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}

extension PlaybackSession {
    /// The waiting screen's words: the facts `loadingProgress` reports, said calmly. Past
    /// `PlaybackWait.detailsAfter` the small print joins them: how the download goes, and what the player did to get here.
    func wait(elapsed: TimeInterval, resume: Double?, linesHint: Bool) -> PlaybackWait {
        var wait = message(elapsed: elapsed, resume: resume, linesHint: linesHint)
        if elapsed >= PlaybackWait.detailsAfter {
            wait.detail = downloadLine
            if loading || !showsPicture { wait.steps = steps }
        }
        return wait
    }

    /// How the download goes: its speed (against what the video needs, once known) and how much has arrived;
    /// before the first bytes, the server it waits on.
    private var downloadLine: String? {
        guard transfer.received > 0 else { return transfer.host.map { L10n.text("Waiting for %@", Self.server($0)) } }
        let received = L10n.text("%@ received", ByteCountFormatter.string(fromByteCount: transfer.received, countStyle: .file))
        guard let bytes = transfer.bytesPerSecond else { return received }
        let speed = transfer.required.map { L10n.text("%@ · needs %@", Self.rate(bytes), Self.rate($0)) } ?? Self.rate(bytes)
        return speed + " · " + received
    }

    /// The one calm line, and a second one suggesting another line only once the wait has run long.
    private func message(elapsed: TimeInterval, resume: Double?, linesHint: Bool) -> PlaybackWait {
        if let switchNotice { return PlaybackWait(message: Self.preparing(resume), caption: switchNotice) }
        // A saved download waits only on this device (making its MP4, say): no server, line or connection to blame.
        if savedDownload { return PlaybackWait(message: loading ? Self.preparing(resume) : L10n.text("Buffering…")) }
        // AVFoundation retries a failed request by itself; give it a moment before saying so.
        if elapsed >= 4, transfer.httpStatus != nil || transfer.failure != nil {
            return PlaybackWait(message: L10n.text("This line isn't answering right now."), suggestsLines: linesHint)
        }
        if elapsed >= LoadingCard.patience {
            if transfer.received == 0 {
                return PlaybackWait(message: L10n.text("The server hasn't answered yet. Still trying…"), suggestsLines: linesHint)
            }
            if let bytes = transfer.bytesPerSecond, let required = transfer.required, bytes < required {
                return PlaybackWait(message: L10n.text("The connection is a little slow. Still loading…"), suggestsLines: linesHint)
            }
        }
        return PlaybackWait(message: loading ? Self.preparing(resume) : L10n.text("Buffering…"))
    }

    /// "Getting it ready", with the place playback picks up from when there is one.
    static func preparing(_ resume: Double?) -> String {
        guard let resume, resume.isFinite, resume >= 5 else { return L10n.text("Getting it ready") }
        let pattern: Duration.TimeFormatStyle.Pattern = resume >= 3600 ? .hourMinuteSecond : .minuteSecond
        return L10n.text("Getting it ready · from %@", Duration.seconds(Int(resume)).formatted(.time(pattern: pattern)))
    }
}

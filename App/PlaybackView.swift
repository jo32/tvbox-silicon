import SwiftUI
import AVKit
import TVCore
#if os(macOS)
import IOKit.pwr_mgt
#endif

@MainActor @Observable final class PlaybackSession {
    /// A queue, so the next episode can wait behind this one and play straight on.
    let player: AVQueuePlayer
    /// Upscaling and 60 fps smoothing, drawn over AVKit's picture when switched on in Settings.
    let enhancer: VideoEnhancer
    let catalogDanmaku = CatalogDanmakuModel()
    #if os(macOS)
    /// Keeps the Mac from dimming, starting the screen saver and locking while a video plays (#565).
    private let displayAwake = DisplayAwake()
    #endif
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
    /// The source's opening and ending credits for this episode (the play result's `skips`), and the one playing now,
    /// which the player offers to skip.
    private(set) var sourceSkips: [PlaybackSkip] = []
    private(set) var skipOffer: PlaybackSkip?
    private var skippedSource = Set<PlaybackSkip>()
    /// The episode's chapters (Bilibili's 分段章节), for the player's Chapters menu and Apple TV's chapter markers.
    private(set) var chapters: [PlaybackChapter] = []
    /// The Bilibili part playing, whose progress goes back to the signed-in account.
    private var bilibiliPart: BilibiliAPI.Part?

    /// Skips the source's credits playing now: to their end, or for ending credits that run out the video, to the end.
    func skipSourceSegment() {
        guard let skip = skipOffer, let item, item.status == .readyToPlay else { return }
        skippedSource.insert(skip)
        skipOffer = nil
        let length = item.duration.seconds
        let target = length.isFinite && skip.end >= length - 1 ? max(0, length - 0.05) : skip.end
        Diagnostics.shared.record(.info, "player", "skip source \(skip.kind.rawValue) to=\(Int(target))")
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Plays from `seconds`, as a chapter in the Chapters menu does.
    func jump(to seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// The source's credits: skipped by themselves when the viewer has intros and outros skipped and set no times of
    /// their own for this video; otherwise offered while they play.
    private func updateSourceSkip(time: Double) {
        let current = PlaybackSkip.current(sourceSkips, at: time).flatMap { skippedSource.contains($0) ? nil : $0 }
        if current != skipOffer { skipOffer = current }
        guard current != nil, player.rate > 0, skipSettings.enabled, skipSettings.introEnd == 0, skipSettings.outroLength == 0 else { return }
        skipSourceSegment()
    }

    /// A Bilibili part's chapters and subtitle files, asked for once its picture is on its way so its start never waits.
    private func loadPartExtras(_ channel: Channel, generation activeGeneration: UUID) {
        guard let part = channel.bilibiliPart else { return }
        Task { [weak self] in
            guard let info = try? await BilibiliAPI.playerInfo(part), let self, self.generation == activeGeneration else { return }
            self.chapters = info.chapters
            #if os(tvOS)
            if let item = self.item { Self.mark(info.chapters, on: item) }
            #endif
            if !info.subtitles.isEmpty { self.externalSubtitles.offer(info.subtitles, automatic: info.uploaded) }
        }
    }

    #if os(tvOS)
    /// Chapters as AVKit's own chapter markers, which the Apple TV's scrubber shows and steps through.
    private static func mark(_ chapters: [PlaybackChapter], on item: AVPlayerItem) {
        guard !chapters.isEmpty else { return }
        let markers = chapters.map { chapter in
            let title = AVMutableMetadataItem()
            title.identifier = .commonIdentifierTitle
            title.value = chapter.title as NSString
            title.extendedLanguageTag = "und"
            return AVTimedMetadataGroup(items: [title], timeRange: CMTimeRange(start: CMTime(seconds: chapter.start, preferredTimescale: 600),
                                                                                  end: CMTime(seconds: chapter.end, preferredTimescale: 600)))
        }
        item.navigationMarkerGroups = [AVNavigationMarkersGroup(title: nil, timedNavigationMarkers: markers)]
    }
    #endif

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
        updateSourceSkip(time: time)
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
    var danmakuOpacity: Double { catalogDanmaku.opacity }
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
    /// The sound tracks of a file that groups none of them (`UngroupedAudio`), for the player's Audio choice, and the
    /// one playing. Empty when AVFoundation offers the choice itself, or there is none.
    private(set) var audioChoices: [UngroupedAudio.Choice] = []
    private(set) var audioChoice: CMPersistentTrackID?
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
    /// The live room playing (at the quality chosen), when it opens again with a fresh address (`LiveReopen`), and
    /// when its stream last became ready.
    private var liveRoom: Channel?
    private var liveReopen = LiveReopen()
    private var liveReadyAt: ContinuousClock.Instant?
    private var liveRetrying = false
    /// The episode was already asked for again after its server ignored AVPlayer's byte range.
    private var rangeRetried = false
    /// When the loopback server behind the episode last listened again (`recoverLoopback`).
    private var loopbackRecovered: ContinuousClock.Instant?
    /// How often the episode opened again after its connection dropped (`resumeAfterDrop`), and whether it did yet.
    private var dropRecovery = PlaybackDropRecovery()
    private var reopenedAfterDrop = false
    /// Whether AVPlayer shows the picture of the file it just opened is being checked; the saved position waits.
    private var checkingPicture = false
    /// The item whose HLS stream is being watched for sound without a picture (`checkSegmentedPicture`).
    private var checkingSegments: ObjectIdentifier?
    /// A live stream is being moved to its live edge (`catchUpLive`).
    private var catchingUpLive = false
    /// A live room's chat, whose comments join `danmaku` as they are sent.
    private var chat: (any LiveChat)?
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
    private func listen(_ chat: any LiveChat, generation active: UUID) {
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

    /// Plays the sound track `id` of a file whose tracks AVFoundation offers no choice between (`audioChoices`).
    func chooseAudio(_ id: CMPersistentTrackID) {
        guard let item else { return }
        UngroupedAudio.play(id, in: item)
        audioChoice = UngroupedAudio.playing(item)
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

    /// A live room that stopped asks its platform for a fresh address and plays on, instead of waiting for the viewer
    /// to try again: one that played a while each time (Huya refuses an address about two minutes in, #488), one
    /// that hasn't once for a playlist that contradicted itself (`LiveReopen`).
    private func retryLive(after failure: Error?) -> Bool {
        if liveRetrying { return true } // The failed item's other report of the same failure.
        let played = liveReadyAt.map { ContinuousClock.now - $0 }
        guard let room = liveRoom, liveReopen.shouldReopen(after: failure, playedFor: played) else { return false }
        liveRetrying = true; loading = true
        detachItem(); observation = nil
        let active = generation
        Diagnostics.shared.record(.warning, "player", "live retry room=\(room.url.absoluteString) played=\(played.map { "\(Int($0.components.seconds))s" } ?? "-")")
        note(L10n.text("The connection dropped. Reconnecting"))
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

    /// iOS and tvOS take back a suspended app's listening sockets: after a pause in the background, AVPlayer finds
    /// the loopback server behind a repackaged file or a plugin's proxy refusing (-1004) and gives up 30 s later.
    /// The server listens again, on a new port, and the episode opens there where it was. At most once a minute, so
    /// a server that stays down shows its error.
    private func recoverLoopback(_ code: Int?, channel: Channel, url: URL, generation active: UUID) -> Bool {
        guard let code, [NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost].contains(code),
              Remux.isRemuxed(url) || EmbeddedJarHost.isPluginProxy(url),
              loopbackRecovered.map({ $0.duration(to: .now) > .seconds(60) }) ?? true else { return false }
        loopbackRecovered = .now
        let position = player.currentTime().seconds
        detachItem(); observation = nil; loading = true
        Diagnostics.shared.record(.warning, "player", "loopback refused code=\(code) at=\(position.isFinite ? Int(position) : -1)s; listening again")
        preparation = Task { [weak self] in
            var fresh: URL?, failure: Error?
            do { fresh = Remux.isRemuxed(url) ? try await Remux.relisten(url) : try await EmbeddedJarHost.shared.recoverProxy(url) }
            catch { failure = error }
            guard let self, self.generation == active, !Task.isCancelled else { return }
            guard let fresh else {
                if let failure { Diagnostics.shared.failure("player", "loopback relisten", failure) }
                self.error = failure?.localizedDescription ?? L10n.text("Playback was interrupted."); self.loading = false; return
            }
            if position.isFinite, position > 0 { self.pendingResume = position }
            if self.automatic == url { self.automatic = fresh }
            self.configure(channel, url: fresh, generation: active)
        }
        return true
    }

    /// An on-demand episode whose connection dropped or stalled (NSURL -1005, or Core Media -15628 after "No response
    /// for media file") stops there: AVPlayer doesn't ask again by itself. It opens again where it was, a few times and
    /// a little later each time (`PlaybackDropRecovery`), and so does a reopening that can't connect yet. Live streams
    /// and saved downloads don't, and the error shows once the attempts are used up.
    private func resumeAfterDrop(_ failure: Error?, channel: Channel, url: URL, generation active: UUID) -> Bool {
        guard !isLive, !savedDownload, !url.isFileURL, hasTimeline || reopenedAfterDrop else { return false }
        let current = player.currentTime().seconds
        let position = pendingResume ?? (current.isFinite ? current : 0)
        guard let delay = dropRecovery.delay(after: failure, position: position) else { return false }
        reopenedAfterDrop = true
        detachItem(); observation = nil; loading = true
        Diagnostics.shared.record(.warning, "player", "dropped host=\(transfer.host ?? url.host() ?? "-") at=\(Int(position))s attempt=\(dropRecovery.attempts) \(failure.map(Self.describe) ?? "-"); reopening")
        note(L10n.text("The connection dropped. Reconnecting"))
        preparation = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, self.generation == active, !Task.isCancelled else { return }
            if position > 1 { self.pendingResume = position }
            self.configure(channel, url: url, generation: active)
        }
        return true
    }

    /// The URL error code behind a failure, through its underlying errors.
    nonisolated static func urlErrorCode(_ error: Error?) -> Int? {
        var current = error as NSError?
        while let error = current {
            if error.domain == NSURLErrorDomain { return error.code }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return nil
    }

    #if os(tvOS)
    /// Whether Match Dynamic Range was on when AVPlayer refused HDR (`Remux.refusesHDR`).
    private static var refusedMatching = false
    #endif

    /// An Apple TV can report HDR playback and still refuse a repackaged HDR10 file (-11868 with Core Media
    /// -17223, "cannot be played on this device"). The file opens again with its picture converted to SDR,
    /// and so do the files opened after it. A mirrored or recorded screen refuses HDR the same way, but only
    /// while it lasts: then this file alone converts. Dolby Vision 5 can't convert, so it isn't tried again.
    private func retryHDR(after failure: Error?, channel: Channel, url: URL, generation active: UUID) -> Bool {
        // A repackaged HLS stream's HDR variant is refused before any segment loads: -1002 or -12927 (#345).
        let refused = Self.refusedContent(failure) || Remux.isSegmented(url) && Self.refusedVariant(failure)
        guard Remux.isHDR(url), !Remux.isDolbyVision(url), refused else { return false }
        let captured = Self.screenCaptured
        guard captured ? !Remux.screenCaptured : !Remux.refusesHDR else { return false }
        if captured { Remux.screenCaptured = true } else { Remux.refusesHDR = true }
        #if os(tvOS)
        Self.refusedMatching = HDRDisplay.matching
        #endif
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
        clearBoost()
        player.defaultRate = speed
        if player.rate != 0 { player.rate = speed }
    }

    /// Another rate while the picture is held (`SpeedBoost`); nil plays at the chosen speed again. It never becomes
    /// the chosen speed, so the speed menu and a later play keep the one picked there. Pausing ends it.
    /// Up to 4× even where the item says it can't fast-forward: an HLS stream without I-frame playlists says so, yet
    /// plays at 3× and 4× in full, as the menu's speeds do. A connection too slow for it holds it lower
    /// (`SpeedBoost.Throttle`, issue #364); `boostWanted` is then the rate the hold asked for.
    private(set) var boost: Float?
    private(set) var boostWanted: Float?
    @ObservationIgnored private var throttle: SpeedBoost.Throttle?
    func setBoost(_ rate: Float?) {
        guard rate == nil || !paused else { return }
        throttle = rate.map { SpeedBoost.Throttle(wanted: Double($0), after: throttle) }
        applyBoost()
    }
    private func applyBoost() {
        boost = throttle.map { Float($0.rate) }
        boostWanted = throttle.flatMap { $0.limited ? Float($0.wanted) : nil }
        if player.rate != 0 { player.rate = boost ?? player.defaultRate }
    }
    private func clearBoost() { throttle = nil; boost = nil; boostWanted = nil }
    /// Once a second while a hold plays faster than normal: slower before the buffered video runs out, and faster
    /// again while the download keeps up.
    private func throttleBoost(_ item: AVPlayerItem) {
        guard var throttle, throttle.wanted > 1, player.rate != 0, item.status == .readyToPlay else { return }
        let now = player.currentTime()
        let buffered = item.loadedTimeRanges.lazy.map(\.timeRangeValue).first { CMTimeRangeContainsTime($0, time: now) }
        let ahead = buffered.map { CMTimeRangeGetEnd($0).seconds - now.seconds } ?? 0
        throttle.update(ahead: ahead, waiting: player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
        let changed = throttle.rate != self.throttle?.rate
        self.throttle = throttle
        guard changed else { return }
        Diagnostics.shared.record(.info, "player", "hold speed \(throttle.rate)x of \(throttle.wanted)x ahead=\(Int(ahead))s")
        applyBoost()
    }
    private var generation = UUID()
    init() {
        let player = AVQueuePlayer()
        // An episode ends paused on its last frame; only a queued next episode makes the queue move on.
        player.actionAtItemEnd = .pause
        #if DEBUG
        // `-qaMute 1`: QA runs on a shared Mac play silently.
        if UserDefaults.standard.bool(forKey: "qaMute") { player.isMuted = true }
        #if os(iOS) || os(tvOS)
        // `-qaPauseInBackground 1`: pause when the app leaves the screen and play when it is back, as a viewer
        // who pauses and locks the phone does; a paused app is suspended and loses its listening sockets.
        if UserDefaults.standard.bool(forKey: "qaPauseInBackground") {
            NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                Diagnostics.shared.record(.info, "player", "qa background pause at=\(Int(player.currentTime().seconds))s")
                player.pause()
            }
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                Diagnostics.shared.record(.info, "player", "qa active play at=\(Int(player.currentTime().seconds))s")
                player.play()
            }
        }
        #endif
        // `-qaSubtitleStyle <JSON>` saves that subtitle style, as Settings › Subtitle Style does.
        if let json = UserDefaults.standard.string(forKey: "qaSubtitleStyle"),
           let style = try? JSONDecoder().decode(SubtitleStyle.self, from: Data(json.utf8)) { style.save() }
        #endif
        self.player = player
        enhancer = VideoEnhancer(player: player)
        queueObservation = player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.subtitles.follow(self.player.currentItem)
                self.queueMoved()
            }
        }
        // A style chosen while a video plays (the Mac shows Settings beside the player) also reaches AVPlayer's own
        // subtitles, drawn in Picture in Picture.
        styleObserver = NotificationCenter.default.addObserver(forName: SubtitleStyle.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let rules = Self.subtitleRules()
                for item in self.player.items() { item.textStyleRules = rules }
            }
        }
        delayObserver = NotificationCenter.default.addObserver(forName: SubtitleDelay.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.followSubtitleDelay() }
        }
        externalSubtitles.cues = subtitles
        externalSubtitles.player = player
        externalSubtitles.changed = { [weak self] in self?.followSubtitleDelay() }
        subtitles.nativeChosen = { [weak self] in self?.externalSubtitles.nativeChosen() }
        followSubtitleDelay()
    }
    private var styleObserver: NSObjectProtocol?
    @ObservationIgnored private var delayObserver: NSObjectProtocol?
    /// Shows delayed subtitle lines at the player's clock (`SubtitleCues.advance`), only while a delay is set.
    @ObservationIgnored private var subtitleTimeObserver: Any?
    /// Delayed subtitles (#599) reach the screen on a quarter-second clock rather than on the once-a-second sample.
    /// A subtitle file the app shows itself (#576) has a twentieth-of-a-second one, so its lines are on time to a
    /// frame or so. Otherwise the lines go up as AVPlayer hands them over, so no clock runs: it would only wake the
    /// main thread.
    private func followSubtitleDelay() {
        let interval: Double? = subtitles.document != nil ? 0.05 : SubtitleDelay.load() > 0 ? 0.25 : nil
        guard interval != subtitleClockInterval else { return }
        if let observer = subtitleTimeObserver { player.removeTimeObserver(observer); subtitleTimeObserver = nil }
        subtitleClockInterval = interval
        guard let interval else { return }
        subtitleTimeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: interval, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.subtitles.advance(to: time.seconds) }
        }
    }
    @ObservationIgnored private var subtitleClockInterval: Double?
    /// Subtitle files beside the video, or added while it plays, that the app shows itself (#576).
    let externalSubtitles = ExternalSubtitles()
    /// The subtitle lines the player's overlay draws (`SubtitleOverlay`).
    let subtitles = SubtitleCues()
    /// The saved subtitle style as the rule AVPlayer lays over every subtitle cue it draws itself.
    private static func subtitleRules() -> [AVTextStyleRule] {
        AVTextStyleRule(textMarkupAttributes: SubtitleStyle.load().attributes).map { [$0] } ?? []
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
        liveRoom = LiveCatalog.isRoom(channel.url) ? channel : nil; liveReopen = LiveReopen(); liveRetrying = false; rangeRetried = false
        loopbackRecovered = nil; dropRecovery = PlaybackDropRecovery(); reopenedAfterDrop = false
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
            if let (platform, id) = LiveCatalog.room(channel.url), let chat = LiveChats.make(platform.chat, room: id) { self.listen(chat, generation: activeGeneration) }
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
            self.externalSubtitles.begin(channel, playing: address)
            self.loadPartExtras(channel, generation: activeGeneration)
            self.qualities = liveQualities.isEmpty ? DashStreams.qualities(for: address) : liveQualities
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
        #if os(tvOS)
        // In SDR mode AVPlayer refuses a repackaged HDR stream before it loads, so before AVKit could ask for HDR.
        if let picture = Remux.hdrPicture(url), HDRDisplay.needsSwitch(to: picture) {
            Task { [weak self] in
                await HDRDisplay.switchTo(picture)
                guard let self, self.generation == activeGeneration, !Task.isCancelled else { return }
                self.attach(channel, url: url, generation: activeGeneration)
            }
            return
        }
        #endif
        attach(channel, url: url, generation: activeGeneration)
    }

    private func attach(_ channel: Channel, url: URL, generation activeGeneration: UUID) {
        let item = makeItem(channel, url: url)
        watch(item, channel: channel, url: url, generation: activeGeneration)
        // A repackaged file is served on this device's loopback, which an AirPlay receiver can't reach.
        player.allowsExternalPlayback = !Remux.isRemuxed(url)
        player.preventsDisplaySleepDuringVideoPlayback = true
        player.replaceCurrentItem(with: item)
        #if DEBUG
        // `-qaSpeed <rate>` plays at that speed, as picking it in the speed menu does.
        let qaSpeed = UserDefaults.standard.float(forKey: "qaSpeed")
        if qaSpeed > 0 { player.defaultRate = qaSpeed }
        #endif
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
        let asset = CloudStreams.asset(for: url) ?? HongguoStreams.asset(for: url) ?? DashStreams.asset(for: url) ?? LiveRepair.asset(for: url)
            ?? AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": channel.headers])
        let item = AVPlayerItem(asset: asset)
        if url.scheme == HongguoStreams.scheme { item.preferredForwardBufferDuration = HongguoStreams.forwardBufferDuration }
        item.textStyleRules = Self.subtitleRules()
        subtitles.attach(item)
        #if DEBUG
        // `-qaSubtitle <n>` turns on the item's nth subtitle track, for screenshots of how subtitles look.
        if let index = UserDefaults.standard.string(forKey: "qaSubtitle").flatMap(Int.init) {
            // Or the system's own choice (subtitles off) replaces it once the item loads.
            player.appliesMediaSelectionCriteriaAutomatically = false
            Task { @MainActor in
                if let group = try? await asset.loadMediaSelectionGroup(for: .legible), group.options.indices.contains(index) {
                    item.select(group.options[index], in: group)
                }
            }
        }
        #endif
        return item
    }

    /// The video's codec and size, for reports of sound without a picture (a codec the decoder
    /// refuses, such as HEVC tagged `hev1` in MP4, plays its audio only). Returns the codecs of a picture
    /// AVPlayer can't decode; none when it decodes one, or there is none.
    private static func recordVideoFormat(_ item: AVPlayerItem) async -> [String] {
        guard let tracks = try? await item.asset.loadTracks(withMediaType: .video) else { return [] }
        if tracks.isEmpty { Diagnostics.shared.record(.info, "player", "video none"); return [] }
        var refused: [String] = [], decodes = false
        for track in tracks {
            let formats = (try? await track.load(.formatDescriptions)) ?? []
            let size = (try? await track.load(.naturalSize)) ?? .zero
            let playable = (try? await track.load(.isPlayable)) ?? false
            let codecs = formats.map { format -> String in
                let code = CMFormatDescriptionGetMediaSubType(format)
                return String(decoding: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }, as: UTF8.self)
            }
            Diagnostics.shared.record(.info, "player", "video codec=\(codecs.joined(separator: ",")) size=\(Int(size.width))x\(Int(size.height)) playable=\(playable)")
            if playable { decodes = true } else { refused += codecs }
        }
        return decodes ? [] : refused
    }

    /// A file AVPlayer reads by itself and `Remux` can read too: not HLS, and not already repackaged.
    private static func repackagable(_ url: URL) -> Bool {
        !Remux.isRemuxed(url) && url.pathExtension.lowercased() != "m3u8"
            && ["http", "https", "file", CloudStreams.scheme].contains(url.scheme)
    }

    /// A file whose picture AVPlayer can't decode plays its sound alone: HEVC that an MP4 tags `hev1`, or VP9
    /// (#215). It opens again repackaged as HLS (`Remux.showsPicture`) and resumes where it was asked to. When it
    /// can't be repackaged, the sound plays on as before.
    private func repackage(_ item: AVPlayerItem, channel: Channel, url: URL, generation active: UUID) {
        player.pause(); loading = true
        note(L10n.text("Repackaging the video for this device"))
        Diagnostics.shared.record(.warning, "player", "no picture; repackaging host=\(url.host() ?? "-")")
        preparation = Task { [weak self] in
            let source: RemuxSource?
            if url.scheme == CloudStreams.scheme { source = await CloudStreams.remuxSource(for: url) }
            else if url.isFileURL { source = try? Remux.fileSource(url) }
            else {
                do { source = try await Remux.httpSource(url, headers: channel.headers) }
                catch {
                    if !Task.isCancelled { Diagnostics.shared.failure("player", "remux link host=\(url.host() ?? "-")", error) }
                    source = nil
                }
            }
            var remuxed: URL?
            if let source { remuxed = try? await Self.remux(source, channel: channel) }
            guard let self, self.generation == active, !Task.isCancelled, self.item === item else {
                if let remuxed { Remux.stop(remuxed) }
                return
            }
            guard let remuxed else {
                self.checkingPicture = false
                self.restorePositionIfNeeded(item)
                self.loading = self.pendingResume != nil || self.restoringPosition
                if self.pendingResume == nil { self.player.play() }
                return
            }
            self.detachItem(); self.observation = nil
            self.configure(channel, url: remuxed, generation: active)
            self.externalSubtitles.playing(remuxed)
            self.automatic = remuxed
        }
    }

    /// HLS whose MPEG-TS segments carry HEVC plays its sound alone: AVPlayer drops that picture without an error (#292).
    /// An item that plays sound without a picture opens again repackaged (`HLSRemux`) where it was; a stream that can't
    /// be repackaged plays on as it is. A presentation size doesn't count as a picture (1280x720 for a 4K channel whose
    /// master names its resolution, #394), and neither does a video track that decodes no frames: an iOS that lists the
    /// HEVC track but doesn't show it, and a 4K stream that takes longer than eight seconds to start, both play sound
    /// alone otherwise (#585). Only frames count, watched for a minute so a slow 4K stream isn't given up on.
    private func checkSegmentedPicture(_ item: AVPlayerItem, channel: Channel, url: URL, generation active: UUID) {
        guard checkingSegments != ObjectIdentifier(item), !Remux.isRemuxed(url), ["http", "https"].contains(url.scheme) else { return }
        checkingSegments = ObjectIdentifier(item)
        Task { [weak self] in
            var pictureless = 0
            for _ in 0..<120 {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.generation == active, self.item === item, item.status == .readyToPlay else { return }
                let video = item.tracks.filter { $0.assetTrack?.mediaType == .video }
                if video.contains(where: { $0.isEnabled && $0.currentVideoFrameRate > 0 }) { return }
                // The rate counts frames drawn, so it reads 0 too for a picture nothing draws (a hidden or minimized
                // window). Only HEVC is listed without being shown; any other listed picture plays, as before #585.
                if !video.isEmpty, await !Self.mayBeHEVC(video) { return }
                guard self.generation == active, self.item === item else { return }
                // The first frames land a beat after sound starts; four checks without any is no picture.
                guard self.player.timeControlStatus == .playing else { pictureless = 0; continue }
                pictureless += 1
                guard pictureless >= 4 else { continue }
                // Only a playlist can be repackaged; a plain file mustn't be read whole to find that out.
                let playback = item.accessLog()?.events.last?.playbackType ?? ""
                guard ["VOD", "LIVE"].contains(playback) || url.absoluteString.lowercased().contains("m3u8") else { continue }
                self.repackageSegments(item, channel: channel, url: url, generation: active)
                return
            }
        }
    }

    /// Whether a listed picture is HEVC, or its codec is not known yet.
    private static func mayBeHEVC(_ tracks: [AVPlayerItemTrack]) async -> Bool {
        for track in tracks {
            guard let asset = track.assetTrack, let formats = try? await asset.load(.formatDescriptions), !formats.isEmpty else { return true }
            let codecs = formats.map { format -> String in
                let code = CMFormatDescriptionGetMediaSubType(format)
                return String(decoding: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }, as: UTF8.self)
            }
            if codecs.contains(where: { ["hvc1", "hev1", "dvh1", "dvhe"].contains($0) }) { return true }
        }
        return false
    }

    private func repackageSegments(_ item: AVPlayerItem, channel: Channel, url: URL, generation active: UUID) {
        Diagnostics.shared.record(.warning, "player", "hls plays no picture; repackaging host=\(url.host() ?? "-")")
        note(L10n.text("Repackaging the video for this device"))
        Remux.screenCaptured = Self.screenCaptured
        preparation = Task { [weak self] in
            var remuxed: URL?
            do { remuxed = try await HLSRemux.open(url, headers: channel.headers) }
            catch { if !Task.isCancelled { Diagnostics.shared.record(.info, "player", "hls not repackaged \(Self.describe(error))") } }
            guard let self, self.generation == active, !Task.isCancelled, self.item === item, let remuxed else {
                if let remuxed { Remux.stop(remuxed) }
                return
            }
            let position = self.player.currentTime().seconds
            // A live stream (no duration) has no place to return to: it opens again at its live edge.
            if self.pendingResume == nil, item.duration.isNumeric, position.isFinite, position > 1 { self.pendingResume = position }
            self.loading = true
            self.detachItem(); self.observation = nil
            self.configure(channel, url: remuxed, generation: active)
            self.externalSubtitles.playing(remuxed)
            self.automatic = remuxed
        }
    }

    /// Follows the episode's item (ready, failed, ended), the player's state, and the transfer, for this playback.
    private func watch(_ item: AVPlayerItem, channel: Channel, url: URL, generation activeGeneration: UUID) {
        self.item = item
        audioChoices = []; audioChoice = nil; liveReadyAt = nil
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
                    if self.isLive { self.liveReadyAt = .now }
                    if UngroupedAudio.playOne(item) { Diagnostics.shared.record(.info, "player", "ungrouped audio tracks; playing the first") }
                    Task { [weak self] in
                        let choices = await UngroupedAudio.choices(item)
                        guard let self, self.generation == activeGeneration, self.item === item else { return }
                        self.audioChoices = choices
                        self.audioChoice = choices.isEmpty ? nil : UngroupedAudio.playing(item)
                    }
                    self.checkingPicture = Self.repackagable(url)
                    self.restorePositionIfNeeded(item)
                    self.loading = self.pendingResume != nil || self.restoringPosition
                    Diagnostics.shared.record(.info, "player", "ready host=\(self.transfer.host ?? channel.url.host() ?? "-")")
                    Task { [weak self] in
                        let refused = await Self.recordVideoFormat(item)
                        guard let self, self.generation == activeGeneration, self.item === item, self.checkingPicture else { return }
                        // While it is repackaged, `checkingPicture` stays on: the once-a-second resume would otherwise
                        // jump to the saved position and play this item's sound with no picture until then (#515).
                        if Remux.showsPicture(refused) { self.repackage(item, channel: channel, url: url, generation: activeGeneration) }
                        else { self.checkingPicture = false; self.restorePositionIfNeeded(item) }
                    }
                    self.checkSegmentedPicture(item, channel: channel, url: url, generation: activeGeneration)
                }
                if status == .failed {
                    if self.retryRange(after: failure, channel: channel, url: url, generation: activeGeneration) { return }
                    if self.retryHDR(after: failure, channel: channel, url: url, generation: activeGeneration) { return }
                    if self.recoverLoopback(Self.urlErrorCode(failure), channel: channel, url: url, generation: activeGeneration) { return }
                    if self.reopenedAfterDrop, self.resumeAfterDrop(failure, channel: channel, url: url, generation: activeGeneration) { return }
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
                if self.recoverLoopback(Self.urlErrorCode(failure), channel: channel, url: url, generation: activeGeneration) { return }
                if self.resumeAfterDrop(failure, channel: channel, url: url, generation: activeGeneration) { return }
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
                #if os(macOS)
                self.displayAwake.hold(!paused)
                #endif
                if paused { self.clearBoost() }
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
        sampler = Task { [weak self] in
            var history: [(date: Date, bytes: Int64)] = []
            var tick = 0
            while !Task.isCancelled {
                guard self?.sample(&history, tick: tick, channel: channel, url: url, generation: activeGeneration) == true else { return }
                tick += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    private func sample(_ history: inout [(date: Date, bytes: Int64)], tick: Int, channel: Channel, url: URL, generation activeGeneration: UUID) -> Bool {
        guard generation == activeGeneration else { return false }
        let origin = channel.url.host()
        // Once the queue has moved on, `queueMoved` is about to take over the next episode.
        guard let item, player.currentItem === item else { return true }
        restorePositionIfNeeded(item)
        updateSkipping(item)
        throttleBoost(item)
        catchUpLive(item)
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
            // The access log can report an infinite bitrate (crash d7b70a868820); skip it rather than show it.
            let media = max(0, last.averageVideoBitrate) + max(0, last.averageAudioBitrate)
            let indicated = last.indicatedBitrate
            let current = media > 0 && media.isFinite ? media / 8 : (indicated > 0 && indicated.isFinite ? indicated / 8 : nil)
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
            // The loopback server behind the episode stopped listening: AVPlayer would keep trying it for 30 s.
            if error.errorDomain == NSURLErrorDomain,
               recoverLoopback(error.errorStatusCode, channel: channel, url: url, generation: activeGeneration) { return false }
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
    /// A live stream playing before everything its playlist still lists shows a frozen picture (`LiveEdge`); it
    /// jumps to the live edge, as a web player does, instead of waiting for someone to open it again.
    private func catchUpLive(_ item: AVPlayerItem) {
        guard !catchingUpLive, item.status == .readyToPlay, item.duration.isIndefinite, player.timeControlStatus == .playing,
              let edge = LiveEdge.target(position: player.currentTime(), seekable: item.seekableTimeRanges.map(\.timeRangeValue)) else { return }
        catchingUpLive = true
        Diagnostics.shared.record(.info, "player", "live catch-up from=\(Int(player.currentTime().seconds))s to=\(Int(edge.seconds))s")
        player.seek(to: edge) { [weak self] _ in
            Task { @MainActor [weak self] in self?.catchingUpLive = false }
        }
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
        return UIApplication.shared.appWindowScene?.screen.maximumFramesPerSecond ?? 0
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
        #if os(macOS)
        displayAwake.hold(false)
        #endif
        if let part = bilibiliPart, let item, item.status == .readyToPlay {
            let seconds = item.currentTime().seconds
            Task { await BilibiliHeartbeat.shared.report(part, seconds: seconds, final: true) }
        }
        saveHistory()
        discardUpcoming()
        upcomingAttempted = false; skipsToUpcoming = false; advanced = nil
        upcomingEpisode = nil; onAdvance = nil; playsOn = { false }; clearBoost()
        if let url = playing?.url { HongguoStreams.stop(url) }
        if let automatic { CloudStreams.stop(automatic); Remux.stop(automatic) }
        #if os(tvOS)
        HDRDisplay.reset()
        #endif
        if playing != nil { ErrorReports.shared.stoppedPlaying() }
        playing = nil
        catalogDanmaku.clear()
        externalSubtitles.stop()
        subtitles.follow(nil)
        historyContext = nil; pendingResume = nil; restoringPosition = false
        requestedResumePosition = nil; restoredPosition = nil
        skipScope = nil; skipSettings = EpisodeSkipSettings(); skipPass = EpisodeSkipPass()
        position = 0; duration = 0; editingSkip = false; resumeAfterEditing = false; seekingSegment = false
        sourceSkips = []; skipOffer = nil; skippedSource = []; chapters = []; bilibiliPart = nil
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
        if let part = bilibiliPart { Task { await BilibiliHeartbeat.shared.report(part, seconds: time, final: completed) } }
    }

    /// Per-episode state: where its history goes, where it resumes, the intro and outro to skip, its danmaku.
    private func begin(_ channel: Channel) {
        historyContext = channel.historyContext
        requestedResumePosition = channel.resumePosition
        pendingResume = channel.resumePosition.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        restoringPosition = false; restoredPosition = nil; checkingPicture = false
        skipScope = channel.skipScope
        skipSettings = skipScope.map { EpisodeSkipSettings.load(scope: $0, defaults: skipDefaults) } ?? EpisodeSkipSettings()
        skipPass = EpisodeSkipPass(); seekingSegment = false
        sourceSkips = channel.skips; skipOffer = nil; skippedSource = []; chapters = []
        bilibiliPart = channel.bilibiliPart
        position = 0; duration = 0
        upcomingAttempted = false
        // A drive's folder and file names don't name a show to find comments for.
        let source = channel.historyContext?.sourceKey
        if !DanmakuSource.has(channel.url), source != Bilibili.siteKey, source != CloudFiles.sourceKey {
            catalogDanmaku.startAutomatic(channel.historyContext)
        }
    }

    private func restorePositionIfNeeded(_ item: AVPlayerItem) {
        guard let requested = pendingResume, !restoringPosition, !checkingPicture, item.status == .readyToPlay,
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
        #if os(tvOS)
        // An HDR refusal while the TV stayed in SDR says nothing once Match Dynamic Range is switched (and back).
        if Remux.refusesHDR, Self.refusedMatching != HDRDisplay.matching { Remux.refusesHDR = false }
        #endif
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
            if let direct = await CatPawOpen.directMedia(media) {
                try Task.checkCancellation()
                // A drive file whose link the bundle's proxy reveals streams straight from the drive, like the plugins'
                // (above): through the bundle, a 4K file filled the heap of the phone's Node until it stopped (#530).
                address = CloudStreams.register(direct) { await CatPawOpen.directMedia(media) }
                Diagnostics.shared.record(.info, "player", "catpaw direct host=\(direct.url.host() ?? "-") length=\(direct.length)")
            } else {
                // The bundle downloads each request with 10 to 16 threads of its own: reading ahead on six at once ran its
                // Node out of memory, and on one a 4K episode stalled whenever the drive slowed.
                // Its proxy moves to a new port when iOS took back the sockets of the suspended app (#485).
                address = CloudStreams.register(media, parallel: 2) { await CatPawOpen.relocated(media) }
                Diagnostics.shared.record(.info, "player", "catpaw stream length=\(media.length)")
            }
            prepared.url = address
        } else if EmbeddedJarHost.isPluginProxy(address) {
            Diagnostics.shared.record(.warning, "player", "plugin proxy stream \(EmbeddedJarHost.proxyRoute(address))")
            prepared.pluginProxy = true
        }
        // MKV, AVI, FLV, WMV and RMVB from a drive play repackaged as HLS; AVPlayer opens none of them.
        if address.scheme == CloudStreams.scheme, await CloudStreams.needsRemux(address) {
            try Task.checkCancellation()
            note(L10n.text("Repackaging the video for this device"))
            if let source = await CloudStreams.remuxSource(for: address), let url = try await Self.remux(source, channel: channel) {
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
        // A link or saved file whose name says MKV, a disc image and the like is repackaged too; when that fails
        // AVPlayer tries it as it is.
        if Remux.handles(name: address.lastPathComponent) || DiscImage.handles(name: address.lastPathComponent),
           ["http", "https", "file"].contains(address.scheme) {
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
            if let source, let url = try await Self.remux(source, channel: channel) {
                prepared.url = url
                return prepared
            }
        }
        #if os(macOS)
        if address.pathExtension.lowercased() == "m3u8", ["http", "https"].contains(address.scheme), channel.url.scheme != DownloadLibrary.scheme {
            let adapter = HLSProxy(headers: channel.headers.merging(CloudStreams.playlistHeaders(for: address) ?? [:]) { $1 })
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
        #if os(tvOS)
        // Dolby Vision 5 has no HDR10 picture to convert to SDR: only an HDR display mode shows it.
        if !HDRDisplay.matching {
            return L10n.text("This Dolby Vision video needs HDR. To keep your Apple TV in SDR and still play it, turn on Settings › Video and Audio › Match Content › Match Dynamic Range: the TV then switches to HDR only while such a video plays.")
        }
        #endif
        return screenCaptured ? L10n.text("Dolby Vision video can't play while the screen is mirrored or recorded. Stop mirroring or recording, then try again.")
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

    /// The repackaged file's address, nil when FFmpeg can't read it. A disc image that can't play says why:
    /// AVPlayer can't open it either.
    fileprivate static func remux(_ source: RemuxSource, channel: Channel) async throws -> URL? {
        Remux.screenCaptured = screenCaptured
        // Only the files for this episode: a drive's folder holds every episode's.
        let video = SubtitleMatch.episode(channel.name) != nil ? channel.name : channel.url.lastPathComponent.removingPercentEncoding ?? channel.name
        let files = Array(SubtitleMatch.candidates(channel.subtitles, video: video).prefix(8))
        do { return try await Remux.open(source, subtitles: files, headers: channel.headers) }
        catch let error as DiscImage.Failure {
            Diagnostics.shared.record(.warning, "player", "disc image \(error)")
            throw error
        } catch {
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
                    } else if status == .readyToPlay {
                        // Before it plays, so a file with ungrouped dubs starts with one of them.
                        UngroupedAudio.playOne(queued)
                        if let intro, intro.enabled, intro.introEnd > 0,
                           intro.validationError(duration: queued.duration.seconds) == nil, queued.currentTime().seconds < intro.introEnd {
                            queued.seek(to: CMTime(seconds: intro.introEnd, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil)
                        }
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
        externalSubtitles.begin(channel, playing: upcoming.prepared.url)
        loadPartExtras(channel, generation: activeGeneration)
        player.allowsExternalPlayback = !Remux.isRemuxed(upcoming.prepared.url)
        qualities = DashStreams.qualities(for: upcoming.prepared.url)
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
        // Int64(_:) traps on infinity, NaN and anything past Int64.max.
        let bytes = bytesPerSecond.isFinite ? Int64(min(max(0, bytesPerSecond), 1e15)) : 0
        return L10n.text("%@/s", formatter.string(fromByteCount: bytes))
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
    /// Core Media refusing every variant of a stream: -1002 when the variant names its HDR range, else -12927.
    nonisolated static func refusedVariant(_ error: Error?) -> Bool {
        var current = error as NSError?
        while let error = current {
            if error.domain == "CoreMediaErrorDomain", [-1002, -12927].contains(error.code) { return true }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

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

#if os(macOS)
/// Our own hold on the Mac's display while a video plays. AVPlayer's `preventsDisplaySleepDuringVideoPlayback`
/// leaves it to Core Media, which holds the display only while it counts the picture as on screen, so a Mac
/// could still dim, start the screen saver and lock mid-film (#565). IINA and VLC hold one of their own too.
final class DisplayAwake {
    private var assertion: IOPMAssertionID?

    func hold(_ on: Bool) {
        if on, assertion == nil {
            var id = IOPMAssertionID(0)
            let made = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                   IOPMAssertionLevel(kIOPMAssertionLevelOn), "Yingxia is playing a video" as CFString, &id)
            if made == kIOReturnSuccess { assertion = id }
        } else if !on, let id = assertion {
            IOPMAssertionRelease(id)
            assertion = nil
        }
    }

    deinit { if let assertion { IOPMAssertionRelease(assertion) } }
}
#endif

#if os(tvOS)
/// With Match Dynamic Range on, an Apple TV kept in SDR switches to HDR for an HDR video. AVKit asks for the switch
/// once the item has loaded, but AVPlayer refuses the HDR variant of a repackaged HLS stream (-11868/-17223) while the
/// display is still in SDR, before it loads. So the player asks for the switch itself first, and waits for it.
@MainActor enum HDRDisplay {
    /// The picture the display was last asked to show, until the player stops.
    private(set) static var requested: Remux.HDRPicture?

    private static var manager: AVDisplayManager? {
        UIApplication.shared.connectedScenes.compactMap { scene -> UIWindow? in
            guard let scene = scene as? UIWindowScene else { return nil }
            return scene.keyWindow ?? scene.windows.first
        }.first?.avDisplayManager
    }

    /// Settings › Video and Audio › Match Content › Match Dynamic Range.
    static var matching: Bool { manager?.isDisplayCriteriaMatchingEnabled ?? false }

    /// Only with Match Dynamic Range on: otherwise tvOS keeps the mode, and waiting for a switch only costs a second.
    static func needsSwitch(to picture: Remux.HDRPicture) -> Bool { matching && requested != picture }

    /// Asks for `picture`'s dynamic range (and frame rate, with Match Frame Rate on) and returns once the TV has
    /// switched, or when it doesn't begin to (already in that mode).
    static func switchTo(_ picture: Remux.HDRPicture) async {
        guard let manager, manager.isDisplayCriteriaMatchingEnabled, let format = format(picture) else { return }
        requested = picture
        manager.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: Float(picture.frameRate), formatDescription: format)
        let start = Date()
        var began = false
        while Date().timeIntervalSince(start) < 10 {
            if manager.isDisplayModeSwitchInProgress { began = true }
            else if began || Date().timeIntervalSince(start) > 1 { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        Diagnostics.shared.record(.info, "player", "display hdr matching=\(manager.isDisplayCriteriaMatchingEnabled) transfer=\(picture.transfer) dv=\(picture.dolbyVision) rate=\(picture.frameRate) switched=\(began) ms=\(Int(Date().timeIntervalSince(start) * 1000))")
    }

    /// Back to the mode chosen in Settings.
    static func reset() {
        guard requested != nil else { return }
        requested = nil
        manager?.preferredDisplayCriteria = nil
    }

    private static func format(_ picture: Remux.HDRPicture) -> CMFormatDescription? {
        let extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
            kCMFormatDescriptionExtension_TransferFunction: picture.transfer == 18
                ? kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG : kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ,
            kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020,
        ]
        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                       codecType: picture.dolbyVision ? kCMVideoCodecType_DolbyVisionHEVC : kCMVideoCodecType_HEVC,
                                       width: Int32(max(picture.width, 1)), height: Int32(max(picture.height, 1)),
                                       extensions: extensions as CFDictionary, formatDescriptionOut: &format)
        return format
    }
}
#endif

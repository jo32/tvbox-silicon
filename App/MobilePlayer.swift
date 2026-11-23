#if os(iOS)
import SwiftUI
import AVKit
import MediaPlayer
import TVCore

/// The iPhone and iPad player. The picture plays in a layer of our own and every control is drawn here: AVKit's
/// controls on iOS keep AirPlay and volume in a row of their own above anything laid over them and take no buttons
/// of ours, so the title, our buttons, AirPlay and Picture in Picture couldn't share one row. Back and the title sit
/// on the left of the top row, the buttons on the right, play and skip in the middle, and the seek bar at the bottom.
struct MobilePlayerView: View {
    let channel: Channel
    let session: PlaybackSession
    /// The player screen's: it goes with the session when the video carries on in Picture in Picture after the screen
    /// closes (`FloatingPlayback`).
    let pip: PictureInPicture
    @Binding var showsDanmaku: Bool
    @Binding var upscalesVideo: Bool
    @Binding var smoothsVideo: Bool
    var waiting: PlaybackWaitContent?
    /// Whether the controls show. The player screen runs the timer that hides them.
    let chromeVisible: Bool
    /// A tap on the picture shows or hides the controls.
    let toggleChrome: () -> Void
    /// A control was used: the controls stay up a while longer.
    let poke: () -> Void
    /// The seek bar is held (true) or let go (false): the controls stay up until it is let go.
    let hold: (Bool) -> Void
    let close: () -> Void
    /// The whole screen, or the top of an iPhone watch page.
    var layout: MobilePlayerLayout = .screen
    /// On a watch page: Full Screen, or back to the page.
    var toggleFullScreen: (() -> Void)? = nil

    @Environment(Store.self) private var store
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var clock = PlayerClock()
    @State private var tracks = MediaTracks()
    @State private var importsSubtitleFile = false
    @State private var asksSubtitleAddress = false
    @State private var searchesSubtitles = false
    @State private var nowPlaying = VideoNowPlaying()
    /// Save Frame in the options (#1342).
    @State private var frames = FrameSaver()
    /// Fit, Fill or Stretch; kept for the next video, as other players do.
    @AppStorage(VideoFill.key) private var videoFill = VideoFill.fit
    /// The time and battery in the full-screen controls (#996).
    @AppStorage(PlayerStatusBadge.key) private var showsStatus = true
    @AppStorage(SkipInterval.key) private var skipInterval = SkipInterval.standard
    @State private var speed: Float = 1
    @AppStorage(DanmakuArea.key) private var danmakuArea = DanmakuArea.standard
    @State private var showsDanmakuList = false
    @State private var showsDanmakuSettings = false
    @State private var showsSkip = false
    @State private var showsEpisodes = false
    @State private var showsChannels = false
    /// Devices with Yingxia open, for the Play On button; and the one the video was sent to.
    @State private var tvBrowser = PlayOnBrowser()
    @State private var playingOn: String?

    /// Stops the TV and carries on here from where it reached (#749).
    private func playHereFromTV() {
        Task {
            let reached = await CastController.shared.stop()
            playingOn = nil
            if let reached, reached > 0, !session.isLive { await session.player.seek(to: CMTime(seconds: reached, preferredTimescale: 600)) }
            if session.paused { session.togglePlayback() }
        }
    }
    /// Touching and holding the picture plays faster while the finger is down, or after sliding down kept it.
    @State private var boost: SpeedBoost?
    @State private var keyboardBoost = false
    @State private var holding = false
    @AppStorage(SpeedBoost.key) private var holdSpeed = SpeedBoost.standard
    @AppStorage(PlaybackInfo.key) private var showsPlaybackInfo = false
    /// The full-screen top row's height, which the info panel keeps clear of while the controls show.
    @State private var topRowHeight: CGFloat = 44
    /// Double taps on a side skip (YouTube); the run's total shows on that side for a moment.
    @State private var taps = PictureTaps()
    @State private var skipped: (forward: Bool, total: Double)?
    @State private var skippedTask: Task<Void, Never>?
    /// Controls a tap just brought up let a second tap through to the picture, which may be a double tap.
    @State private var settling = false
    @State private var settleTask: Task<Void, Never>?
    /// Sliding sideways across the picture: where the slide began.
    @State private var swipeStart: Double?
    /// Sliding up or down: the brightness on the left, the volume on the right, from where the slide began.
    @AppStorage(PictureLevel.key) private var slidesLevels = true
    /// Off: two taps anywhere play or pause, and the sides don't skip.
    @AppStorage(PictureDoubleTap.key) private var doubleTapSkips = true
    @State private var level: (volume: Bool, start: Double, value: Double)?
    @State private var leveling = false
    @State private var levelTask: Task<Void, Never>?
    /// The system's volume slider, on screen only around a slide, which keeps the system's own volume overlay away.
    @State private var systemVolume = MusicVolumeSlider.SystemSlider()
    @State private var mountsVolume = false
    @State private var keyboardVolume: Double?
    /// The screen's brightness before the first slide changed it, put back when the player closes.
    @State private var brightnessBefore: CGFloat?
    /// Full screen, the controls and every touch on the picture can be locked, so a hand on the screen doesn't skip or
    /// pause. A tap then shows the lock button alone for a moment.
    @State private var locked = false
    @State private var showsLock = false
    @State private var lockTask: Task<Void, Never>?
    /// The episode that Next, or the end of this one, asked for and its source couldn't give: said over the picture for
    /// a moment. Only the options menu and the episode list said so, and the button seemed to do nothing (#865).
    @State private var episodeFailure: EpisodeFailure?
    @State private var episodeFailureTask: Task<Void, Never>?
    @State private var askedEpisode = ""

    var body: some View {
        ZStack {
            PlayerLayerView(player: session.player, gravity: videoFill.gravity, pip: pip).playerBleed(!inline)
                // Picture in Picture shows only the player's layer, so AVPlayer draws the subtitles there.
                .onChange(of: pip.active) { _, active in session.subtitles.native = active }
                // A connected display (USB-C, HDMI) takes the same Picture Size: Fill covers a monitor of another
                // shape, as asked in #1151.
                .onChange(of: videoFill, initial: true) { _, fill in ExternalDisplay.shared.gravity = fill.gravity }
            // The enhanced picture covers the layer's own, under everything else.
            EnhancedVideoSurface(enhancer: session.enhancer, fills: videoFill == .fill, stretches: videoFill == .stretch, bleeds: !inline)
            if showsDanmaku && !session.danmaku.isEmpty {
                DanmakuOverlay(player: session.player, comments: session.danmaku, opacity: session.danmakuOpacity, revision: session.danmakuRevision)
                    // Across the whole width, but below the Dynamic Island and above the home indicator when upright.
                    .playerBleed(!inline, edges: .horizontal)
            }
            SubtitleOverlay(cues: session.subtitles, fills: videoFill == .fill, stretches: videoFill == .stretch).playerBleed(!inline)
            // The artwork dissolves into the first frame.
            if let waiting {
                if inline {
                    // On a watch page: the cover across the player, blurred, as before it started; the full-screen
                    // player keeps its own wait.
                    Group {
                        if waiting.starting { WatchCoverBackdrop(poster: waiting.artwork.poster, headers: waiting.artwork.headers, loading: session.error == nil) }
                        else { WaitSpinner(status: waiting.state) }
                    }
                    .transition(PlaybackWaitContent.transition)
                } else {
                    waiting.view.playerBleed(true).transition(PlaybackWaitContent.transition)
                }
            }
            if pip.active { pipPlaceholder }
            if playingOn != nil { Color.black.playerBleed(!inline) }
            // A tap on the picture shows or hides the controls; a tap on a control keeps them up (see `rows`).
            // Two taps on a side skip, touching and holding plays faster, and sliding sideways seeks.
            PictureGestures(tap: tapped, hold: held, swipe: swiped, levels: slidesLevels) { wider in
                guard !locked else { return }
                withAnimation(.easeInOut(duration: 0.25)) { videoFill = wider ? .fill : .fit }
            }
            .playerBleed(!inline)
            // Moved to its new frame at once, not animated with a watch page going full screen: on iOS 26 the animated
            // move left the UIKit view's host with a shifted bounds origin, and no tap reached the recognizers after
            // it, so the controls never came back and there was no way out but leaving the app (#729, #766, #767).
            .transaction { $0.animation = nil }
            .accessibilityHidden(true)
            if mountsVolume {
                MusicVolumeSlider.HiddenVolumeView(system: systemVolume).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
                    .onAppear { if let keyboardVolume { systemVolume.set(keyboardVolume) } }
            }
            boostLabel
            skippedLabel
            swipeLabel
            levelLabel
            episodeFailureLabel
            FrameSaverNotice(saver: frames, top: inline ? (chromeVisible ? 58 : 10) : chromeVisible ? 112 : 24)
                .animation(.easeOut(duration: 0.2), value: chromeVisible)
            if let playingOn {
                if CastController.shared.device?.name == playingOn {
                    CastPanel { playHereFromTV() }
                } else {
                    PlayOnPlaceholder(receiver: playingOn) {
                        self.playingOn = nil
                        if session.paused { session.togglePlayback() }
                    }
                }
            }
            // Part of the controls (#1446): below their top row, and gone with them, so the picture is the viewer's
            // again a few seconds after a tap. On a watch page, too small for both, the controls take its corner and
            // it comes back with the bare picture.
            if showsPlaybackInfo && session.error == nil && session.showsPicture && !pip.active && playingOn == nil
                && (inline ? !chromeVisible : chromeVisible && !locked) {
                PlaybackInfoPanel(session: session)
                    .padding(inline ? 8 : 16)
                    .padding(.top, inline ? 0 : topRowHeight + 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(.opacity)
            }
            // Faded out, the controls take no touches (a view at opacity 0 isn't hit). Hit testing isn't turned off as they
            // fade: on iOS 17 that closes a menu opened from them, so the Subtitles menu shut 3 s after the last tap (#1449).
            controls.opacity(chromeVisible && !locked ? 1 : 0).allowsHitTesting(!locked && !settling)
            if !inline { lockButton }
        }
        // In with a fade; out at once, so the first frame replaces the wait with no pause or crossfade.
        .animation(waiting == nil ? nil : .easeInOut(duration: 0.7), value: waiting == nil)
        .animation(waiting == nil ? nil : .easeInOut(duration: 0.4), value: waiting?.starting)
        .onAppear {
            clock.attach(session.player)
            speed = session.player.defaultRate
            nowPlaying.start(session)
            nowPlaying.update(title: channel.name, session: session)
            tvBrowser.start()
            CastController.shared.refresh()
            if let chosen = PlayerBrightness.chosen, let screen, brightnessBefore == nil {
                brightnessBefore = screen.brightness; screen.brightness = chosen
            }
        }
        .onDisappear {
            clock.detach(); nowPlaying.stop(); tvBrowser.stop(); CastController.shared.detach()
            if let brightnessBefore { screen?.brightness = brightnessBefore }
        }
        // Played here again (the Lock Screen, say): the other device no longer has it to itself.
        .onChange(of: session.paused) { _, paused in
            guard !paused else { return }
            playingOn = nil
            // Played here again (the Lock Screen, say): the TV stops, as Play Here would.
            if CastController.shared.device != nil { Task { await CastController.shared.stop() } }
        }
        .onChange(of: nowPlayingState, initial: true) { nowPlaying.update(title: channel.name, session: session) }
        .onChange(of: nowPlayingArtwork, initial: true) { _, artwork in nowPlaying.show(artwork, session: session) }
        // Pausing ends the faster speed in the session; another episode or quality plays at the chosen one.
        .onChange(of: session.boost == nil) { _, ended in if ended { boost = nil; keyboardBoost = false } }
        .onChange(of: clock.item) { endBoost() }
        .onChange(of: store.resolvingEpisode?.name) { _, name in
            if let name { askedEpisode = name; showEpisodeFailure(nil) }
        }
        .onChange(of: store.episodeError) { _, reason in showEpisodeFailure(reason) }
        .sensoryFeedback(trigger: boost) { old, new in
            guard let new else { return nil }
            guard let old else { return .impact(weight: .light) }
            return new.locked != old.locked ? .impact(weight: .medium) : new.rate != old.rate ? .selection : nil
        }
        .task(id: clock.item.map(ObjectIdentifier.init)) { await tracks.load(clock.item) }
        .sensoryFeedback(.impact(weight: .medium), trigger: locked)
        // Full screen, the status bar stays hidden, controls or not: with it came the Dynamic Island's Now Playing
        // activity over the picture each time the controls showed (#1149). The controls have the time and battery of
        // their own (`statusBadge`, `titleStatus`), so a long video doesn't hide the time (#901). A watch page shows
        // the status bar above it.
        .statusBarHidden(!inline)
        // A failure, or a watch page's player back from full screen, has controls to reach.
        .onChange(of: session.error != nil || inline) { _, unlock in if unlock { setLocked(false) } }
        .modifier(MobilePlayerKeyboard(enabled: keyboardEnabled, canPlay: showsTransport,
                                       canSeek: seekable, canBoost: boosts && !holding, item: clock.item.map(ObjectIdentifier.init),
                                       action: keyboardAction))
        .subtitleImport(files: $importsSubtitleFile, address: $asksSubtitleAddress, search: $searchesSubtitles, subtitles: session.externalSubtitles)
        .playerEpisodesSheet(isPresented: $showsEpisodes, channel: channel)
        .playerChannelsSheet(isPresented: $showsChannels, channel: channel, session: session)
        .sheet(isPresented: $showsDanmakuList) {
            DanmakuListView(player: session.player, comments: session.danmaku) { showsDanmakuList = false }
                .danmakuListPresentation().environment(store)
        }
        .sheet(isPresented: $showsDanmakuSettings) {
            CatalogDanmakuSettingsView(model: session.catalogDanmaku, channelName: channel.name).playerSheet().environment(store)
        }
        .sheet(isPresented: $showsSkip) { EpisodeSkipSettingsView(session: session).playerSheet().environment(store) }
    }

    // MARK: Hardware keyboard

    private var keyboardEnabled: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && scenePhase == .active && !locked && !pip.active && playingOn == nil
            && !importsSubtitleFile && !asksSubtitleAddress && !searchesSubtitles && !showsEpisodes && !showsChannels
            && !showsDanmakuList && !showsDanmakuSettings && !showsSkip
    }

    private func keyboardAction(_ action: PlaybackKeyboard.Action) {
        switch action {
        case .playPause: session.togglePlayback(); poke()
        case .seek(let seconds): session.skip(seconds); poke()
        case .mute: session.player.isMuted.toggle(); poke()
        case .beginBoost:
            guard boosts, !holding else { return }
            let started = SpeedBoost(rate: SpeedBoost.isOn(holdSpeed) ? holdSpeed : SpeedBoost.standard)
            keyboardBoost = true
            boost = started
            session.setBoost(Float(started.rate))
            hideChrome()
        case .endBoost: if keyboardBoost { endBoost() }
        case .volume(let delta):
            // Use the same system volume as a swipe, including the first press before MPVolumeView is mounted.
            let current = level.flatMap { $0.volume ? $0.value : nil } ?? Double(AVAudioSession.sharedInstance().outputVolume)
            let value = min(1, max(0, current + delta))
            keyboardVolume = value
            mountsVolume = true
            systemVolume.set(value)
            session.player.isMuted = false
            level = (true, current, value)
            hideChrome()
            levelTask?.cancel()
            levelTask = Task {
                try? await Task.sleep(for: .seconds(0.8))
                guard !Task.isCancelled else { return }
                level = nil; mountsVolume = false; keyboardVolume = nil
            }
        case .waitForHold: break
        }
        nowPlaying.update(title: channel.name, session: session)
    }

    /// What the Lock Screen's Now Playing shows, besides the position the system runs on from the rate.
    private struct NowPlayingState: Equatable {
        var title: String
        var paused: Bool
        var live: Bool
        var timeline: Bool
        var duration: Double
        var speed: Float
        var boost: Float?
    }

    private var nowPlayingState: NowPlayingState {
        NowPlayingState(title: channel.name, paused: session.paused, live: session.isLive, timeline: session.hasTimeline,
                        duration: clock.duration, speed: speed, boost: session.boost)
    }

    /// The poster the waiting screen shows, for the Lock Screen and Control Center.
    private var nowPlayingArtwork: PlaybackArtwork {
        let catalog = store.catalog(for: channel)
        return PlaybackArtwork(poster: catalog?.video.poster ?? channel.historyContext?.poster,
                               headers: catalog?.video.posterHeaders ?? channel.historyContext?.posterHeaders ?? [:])
    }

    // MARK: Taps and slides

    private func tapped(_ x: CGFloat, _ width: CGFloat) {
        // Locked, a tap shows (or hides) the lock button and nothing else: no controls, no skip, no pause.
        if locked {
            if showsLock { withAnimation(.easeOut(duration: 0.2)) { showsLock = false } } else { flashLock() }
            return
        }
        let zone = PictureTaps.zone(x: x, width: width, seekable: doubleTapSkips && seekable && showsTransport && playingOn == nil && !pip.active)
        switch taps.tap(at: ProcessInfo.processInfo.systemUptime, in: zone, step: SkipInterval.seconds(skipInterval)) {
        case .toggleControls:
            let showing = !chromeVisible
            toggleChrome()
            if showing { settle(); clearLabels() }
        case .togglePlayback:
            toggleChrome()
            session.togglePlayback()
        case .skip(let seconds, let total, _):
            // Hidden whether the first tap showed the controls or hid them.
            hideChrome()
            session.skip(seconds)
            nowPlaying.update(title: channel.name, session: session)
            withAnimation(.snappy(duration: 0.25)) { skipped = (seconds > 0, total) }
            skippedTask?.cancel()
            skippedTask = Task {
                try? await Task.sleep(for: .seconds(PictureTaps.streak + 0.1))
                if !Task.isCancelled { withAnimation(.easeOut(duration: 0.2)) { skipped = nil } }
            }
        }
    }

    /// For as long as a second tap would make a double tap, it reaches the picture rather than the controls it showed.
    private func settle() {
        settling = true
        settleTask?.cancel()
        settleTask = Task {
            try? await Task.sleep(for: .seconds(PictureTaps.interval))
            if !Task.isCancelled { settling = false }
        }
    }

    /// A gesture's label has the picture to itself: the controls make way, unless loading or a failure keeps them up.
    private func hideChrome() {
        if chromeVisible && showsTransport { toggleChrome() }
    }

    /// The controls a tap brings up replace the labels a skip or a slide leaves for a moment.
    private func clearLabels() {
        skippedTask?.cancel(); skipped = nil
        guard !leveling else { return }
        levelTask?.cancel(); level = nil; mountsVolume = false
    }

    private var screen: UIScreen? { UIApplication.shared.appWindowScene?.screen }

    private func swiped(_ phase: PictureGestures.Swipe) {
        if locked, case .began = phase { return }
        switch phase {
        case .began(.seek):
            guard showsTransport, seekable, clock.duration > 0, playingOn == nil, !pip.active else { return }
            let start = clock.currentPosition
            swipeStart = start
            clock.scrub(to: start)
            hideChrome()
        case .began(let slide):
            let volume = slide == .volume
            guard volume || screen != nil else { return }
            keyboardVolume = nil
            let start = volume ? Double(AVAudioSession.sharedInstance().outputVolume) : Double(screen?.brightness ?? 0)
            if !volume, brightnessBefore == nil { brightnessBefore = screen?.brightness }
            levelTask?.cancel()
            if volume { mountsVolume = true }
            level = (volume, start, start)
            leveling = true
            hideChrome()
        case .moved(let moved, let size):
            if let swipeStart {
                clock.scrub(to: PictureSeek.target(from: swipeStart, moved: moved.width, width: size.width, duration: clock.duration),
                            secondsPerPoint: PictureSeek.secondsPerPoint(width: size.width, duration: clock.duration))
            } else if leveling, var level {
                level.value = PictureLevel.value(from: level.start, moved: moved.height, height: size.height)
                self.level = level
                if level.volume { systemVolume.set(level.value) } else { screen?.brightness = CGFloat(level.value); PlayerBrightness.choose(level.value) }
            }
        case .ended:
            if swipeStart != nil {
                swipeStart = nil
                clock.endScrub()
                nowPlaying.update(title: channel.name, session: session)
            }
            if leveling {
                leveling = false
                levelTask = Task {
                    try? await Task.sleep(for: .seconds(0.8))
                    guard !Task.isCancelled else { return }
                    level = nil; mountsVolume = false
                }
            }
        }
    }

    /// The brightness or the volume a slide up or down sets, in the middle.
    @ViewBuilder private var levelLabel: some View {
        if let level {
            HStack(spacing: 12) {
                Image(systemName: level.volume ? (level.value <= 0 ? "speaker.slash.fill" : "speaker.wave.2.fill") : "sun.max.fill")
                    .frame(width: 26)
                Capsule().fill(.white.opacity(0.3)).frame(width: 150, height: 6)
                    .overlay(alignment: .leading) { Capsule().fill(.white).frame(width: 150 * level.value, height: 6) }
            }
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 14)
            .glassSurface(.regular, in: Capsule())
            .environment(\.colorScheme, .dark)
            .allowsHitTesting(false)
            .transition(.opacity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text(level.volume ? "Volume" : "Brightness"))
            .accessibilityValue(Text(level.value, format: .percent.precision(.fractionLength(0))))
            .accessibilityIdentifier("player.level")
        }
    }

    private struct EpisodeFailure: Equatable {
        var name: String
        var reason: String
    }

    /// The episode list says it itself, and a player that stopped with an error shows that instead.
    private func showEpisodeFailure(_ reason: String?) {
        episodeFailureTask?.cancel()
        guard let reason, !showsEpisodes, session.error == nil else {
            if episodeFailure != nil { withAnimation(.easeOut(duration: 0.3)) { episodeFailure = nil } }
            return
        }
        withAnimation(.easeOut(duration: 0.2)) { episodeFailure = EpisodeFailure(name: askedEpisode, reason: reason) }
        episodeFailureTask = Task {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { episodeFailure = nil }
        }
    }

    /// At the top, where the faster speed shows: below the top row when the controls are up.
    @ViewBuilder private var episodeFailureLabel: some View {
        if let episodeFailure {
            VStack(spacing: 3) {
                Label(L10n.text("Couldn't play %@", EpisodeRow.title(episodeFailure.name)), systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(episodeFailure.reason).font(.caption).lineLimit(2).multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .glassSurface(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .environment(\.colorScheme, .dark)
            .padding(.horizontal, 24)
            .padding(.top, inline ? (chromeVisible ? 58 : 10) : chromeVisible ? 112 : 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(.easeOut(duration: 0.2), value: chromeVisible)
            .allowsHitTesting(false)
            .transition(.opacity)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("player.episodeFailure")
        }
    }

    /// How far a run of double taps skipped, on its side.
    @ViewBuilder private var skippedLabel: some View {
        if let skipped {
            // Glass like the other gesture labels, with the skip buttons' symbol; it bounces on each further tap.
            VStack(spacing: 4) {
                Image(systemName: SkipInterval.symbol(forward: skipped.forward, seconds: skipInterval))
                    .font(.system(size: 30, weight: .medium))
                    .symbolEffect(.bounce, value: skipped.total)
                Text((skipped.forward ? "+" : "\u{2212}") + L10n.text("%lld s", Int(skipped.total)))
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText(value: skipped.total))
            }
            .foregroundStyle(.white)
            .frame(width: 96, height: 96)
            .glassSurface(.regular, in: Circle())
            .environment(\.colorScheme, .dark)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: skipped.forward ? .trailing : .leading)
            .padding(.horizontal, 48)
            .allowsHitTesting(false)
            .transition(.scale(scale: 0.8, anchor: skipped.forward ? .trailing : .leading).combined(with: .opacity))
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("player.tapSkip")
            .accessibilityValue("\(skipped.forward ? "+" : "-")\(Int(skipped.total))")
        }
    }

    /// Where a slide across the picture will seek to: the frame there, the time and how far it moves.
    @ViewBuilder private var swipeLabel: some View {
        if let swipeStart {
            let target = clock.scrubbing ?? swipeStart
            let moved = target - swipeStart
            VStack(spacing: 10) {
                if let preview = clock.preview {
                    Image(decorative: preview, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                Text(SeekBar<EmptyView>.format(target) + " / " + SeekBar<EmptyView>.format(clock.duration))
                    .font(.title3.weight(.semibold).monospacedDigit())
                Text((moved < 0 ? "\u{2212}" : "+") + SeekBar<EmptyView>.format(abs(moved)))
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.white.opacity(0.75))
            }
            .foregroundStyle(.white)
            .padding(16)
            .glassSurface(.regular, in: RoundedRectangle(cornerRadius: 20))
            .environment(\.colorScheme, .dark)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("player.swipeSeek")
            .accessibilityValue("\(Int(target))")
        }
    }

    // MARK: Lock

    /// On the left edge, halfway down, as in Bilibili: with the controls while unlocked, alone for a moment after a tap
    /// while locked.
    @ViewBuilder private var lockButton: some View {
        let visible = locked ? showsLock : chromeVisible && showsTransport
        Button {
            setLocked(!locked)
        } label: {
            // Locked, the button says what it undoes: with every control hidden, a bare padlock left people stuck
            // in a player that seemed frozen (#729, #731).
            HStack(spacing: 8) {
                Image(systemName: locked ? "lock.fill" : "lock.open.fill").font(.headline).frame(width: 22, height: 22)
                    .contentTransition(.symbolEffect(.replace))
                if locked { Text(L10n.text("Unlock Controls")).font(.subheadline.weight(.semibold)).fixedSize() }
            }
        }
        .modifier(LockButtonStyle(locked: locked))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .accessibilityLabel(L10n.text(locked ? "Unlock Controls" : "Lock Controls"))
        .accessibilityIdentifier("player.lock")
        .padding(.leading, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible && !settling)
        .animation(.easeOut(duration: 0.2), value: visible)
    }

    private func setLocked(_ lock: Bool) {
        guard lock != locked else { return }
        lockTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { locked = lock }
        if lock {
            // The picture to itself; the lock button stays a moment to show where it is.
            endBoost()
            hideChrome()
            clearLabels()
            flashLock()
        } else {
            showsLock = false
            if !chromeVisible { toggleChrome() } else { poke() }
        }
    }

    private func flashLock() {
        withAnimation(.easeOut(duration: 0.2)) { showsLock = true }
        lockTask?.cancel()
        lockTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { showsLock = false }
        }
    }

    // MARK: Touch and hold

    /// Only while a video with a timeline plays here.
    private var boosts: Bool { showsTransport && seekable && !session.paused && playingOn == nil && !pip.active }

    private func held(_ phase: PictureGestures.Hold) {
        switch phase {
        case .began:
            guard boosts, !locked, SpeedBoost.isOn(holdSpeed) else { return }
            keyboardBoost = false
            // A new hold replaces a kept speed: it ends with the finger unless slid down again.
            let started = SpeedBoost(rate: holdSpeed)
            boost = started; holding = true
            session.setBoost(Float(started.rate))
            // The picture to itself, as in YouTube and Douyin.
            hideChrome()
        case .moved(let offset):
            guard holding, var moved = boost else { return }
            moved.moved(x: offset.width, y: offset.height)
            guard moved != boost else { return }
            if moved.rate != boost?.rate { session.setBoost(Float(moved.rate)) }
            boost = moved
        case .ended:
            guard holding else { return }
            holding = false
            if boost?.locked != true { endBoost() }
        }
    }

    private func endBoost() {
        boost = nil; holding = false; keyboardBoost = false
        session.setBoost(nil)
    }

    /// The faster speed at the top, as in Douyin and YouTube; once kept, a tap on it goes back to the chosen speed.
    @ViewBuilder private var boostLabel: some View {
        if let boost {
            let rate = session.boost ?? Float(boost.rate)
            VStack(spacing: 8) {
                Button(action: endBoost) {
                    HStack(spacing: 6) {
                        if boost.locked { Image(systemName: "lock.fill") }
                        Text(Self.speedLabel(rate))
                        // Held lower than asked: the connection can't keep up with the faster speed.
                        if let wanted = session.boostWanted { Text(Self.speedLabel(wanted)).strikethrough().opacity(0.55) }
                        Image(systemName: "forward.fill")
                    }
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    // A plain tint, not glass: it sits over the picture for the whole hold, where a blur redraws
                    // every frame, and its blur coming and going hitched the picture as a hold began and ended (#1457).
                    .background(.black.opacity(0.45), in: Capsule())
                    .overlay { Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1) }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .allowsHitTesting(boost.locked)
                .accessibilityLabel(L10n.text("Back to Normal Speed"))
                .accessibilityValue(Self.speedLabel(rate))
                .accessibilityIdentifier("player.boost")
                if session.boostWanted != nil {
                    Text(L10n.text("Slowed down to keep up with the connection"))
                        .font(.caption).shadow(color: .black.opacity(0.6), radius: 4)
                        .accessibilityHidden(true)
                } else if holding && !boost.locked {
                    Text(L10n.text("Slide sideways to change the speed, or down to keep it"))
                        .font(.caption).shadow(color: .black.opacity(0.6), radius: 4)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
            // Below the top row when the controls show.
            .padding(.top, inline ? (chromeVisible ? 58 : 10) : chromeVisible ? 112 : 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(.easeOut(duration: 0.2), value: chromeVisible)
            .transition(.opacity)
        }
    }

    /// Play, skip and the seek bar wait for the stream: while it connects or after it fails, only the top row shows.
    private var showsTransport: Bool { !session.loading && session.error == nil }
    /// At the top of a watch page: smaller controls, and the page has the title.
    private var inline: Bool { layout == .inline }
    private var seekable: Bool { session.hasTimeline && !session.isLive }

    private var controls: some View {
        ZStack {
            // Scrims, so white controls read over a bright picture.
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom).frame(height: inline ? 70 : 150)
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom).frame(height: inline ? 80 : 150)
            }
            .playerBleed(!inline)
            .allowsHitTesting(false)
            VStack(spacing: 0) {
                topRow
                Spacer(minLength: 0)
                if showsTransport {
                    if !inline { infoRow }
                    bottomRow
                }
            }
            .padding(inline ? 8 : 16)
            if showsTransport { centerRow }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Top row

    /// One row when it fits; on a phone held upright, Back and the buttons share the first row and the title has the
    /// next one to itself, as in YouTube's player.
    @ViewBuilder private var topRow: some View {
        if inline {
            HStack(spacing: 8) {
                Button(action: close) { Image(systemName: "chevron.backward").font(.headline).frame(width: 22, height: 22) }
                    .chromeButton(reach: 8)
                    .accessibilityLabel(L10n.text("Back"))
                    .accessibilityIdentifier("player.close")
                Spacer(minLength: 0)
                HStack(spacing: 0) { toolbar; optionsMenu }.chromeGroup()
            }
            .simultaneousGesture(TapGesture().onEnded { poke() })
        } else {
            screenTopRow
        }
    }

    private var screenTopRow: some View {
        PlayerTopBar {
            // The way out takes a touch that only comes near it (#1149): 64 points around its 44-point circle.
            Button(action: close) { Image(systemName: "chevron.backward").font(.headline).frame(width: 22, height: 22) }
                .chromeButton(reach: 10)
                .accessibilityLabel(L10n.text("Back"))
                .accessibilityIdentifier("player.close")
                .keyboardShortcut(.cancelAction)
            // An iPhone held upright has the time and battery at the end of the title's row, where the status bar was:
            // in the buttons' capsule they'd push Back down beside the title.
            HStack(spacing: 12) {
                Text(channel.name).font(.headline).lineLimit(1)
                if titleStatus { Spacer(minLength: 0); PlayerStatusBadge(grouped: false) }
            }
            .shadow(color: .black.opacity(0.6), radius: 4)
            HStack(spacing: 0) {
                if statusBadge { PlayerStatusBadge() }
                toolbar; optionsMenu
            }
            .chromeGroup()
        }
        .simultaneousGesture(TapGesture().onEnded { poke() })
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topRowHeight = $0 }
    }

    /// The time and battery at the start of the full-screen buttons (#996): on iPad, and on an iPhone held sideways.
    private var statusBadge: Bool { showsStatus && !inline && !upright }
    /// On an iPhone held upright, at the end of the title's row.
    private var titleStatus: Bool { showsStatus && !inline && upright }
    private var upright: Bool { horizontalSizeClass == .compact && verticalSizeClass == .regular }

    /// Over the seek bar, as in MiraPlay: the title's logo on the left and the video's tags on the right (#520).
    private var infoRow: some View {
        HStack(alignment: .bottom, spacing: 12) {
            PlayerTitleLogo(channel: channel, compact: verticalSizeClass != .compact && horizontalSizeClass == .compact)
            Spacer(minLength: 0)
            PlaybackBadges(session: session, active: chromeVisible) {
                withAnimation(.smooth(duration: 0.25)) { showsPlaybackInfo.toggle() }
                poke()
            }
        }
        .padding(.bottom, 2)
    }

    /// The buttons share one glass capsule with the options menu (`chromeGroup`), so none has glass of its own.
    private var toolbar: some View {
        HStack(spacing: 0) {
            // With Yingxia found on an Apple TV or Mac, one menu holds those and AirPlay.
            if tvBrowser.receivers.isEmpty && CastController.shared.devices.isEmpty {
                AirPlayButton()
            } else {
                PlayOnButton(channel: channel, session: session, browser: tvBrowser) { receiver in
                    session.player.pause()
                    playingOn = receiver
                }
            }
            if pip.supported {
                Button { pip.toggle() } label: {
                    Image(systemName: pip.active ? "pip.exit" : "pip.enter").font(.headline).frame(width: 22, height: 22)
                }
                .chromeButton()
                .disabled(!pip.possible && !pip.active)
                .accessibilityLabel(L10n.text("Picture in Picture"))
                .accessibilityIdentifier("player.pip")
            }
            // On a watch page the episodes are on the page itself.
            if !inline { CatalogPlaybackActions(channel: channel, session: session) }
            Menu {
                Toggle(isOn: $showsDanmaku) { Label(L10n.text("Show Danmaku"), systemImage: "text.bubble") }
                Button { showsDanmakuSettings = true } label: { Label(L10n.text("Danmaku Settings…"), systemImage: "slider.horizontal.3") }
                Picker(selection: $danmakuArea) {
                    ForEach(DanmakuArea.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: { Label(L10n.text("Danmaku Area"), systemImage: "rectangle.tophalf.inset.filled") }
                .pickerStyle(.menu)
                DanmakuStylePickers(model: session.catalogDanmaku)
                Button { showsDanmakuList = true } label: { Label(L10n.text("Danmaku List"), systemImage: "list.bullet.rectangle") }
                    .disabled(session.danmaku.isEmpty)
            } label: {
                // A wide, tall mark: a size down it sits level with AirPlay and the options beside it.
                Image(systemName: DanmakuPreference.symbol).font(.system(size: 16, weight: .semibold)).frame(width: 22, height: 22)
            }
            .chromeButton()
            .accessibilityLabel(L10n.text("Danmaku"))
            .accessibilityIdentifier("player.danmakuMenu")
            // Turns the picture even with Portrait Orientation Lock on, the way the system's own rotation can't.
            // Only on a phone-sized screen: iPhone Duo's inner display (regular both ways) ignores orientations.
            if !inline, PlayerOrientation.available, horizontalSizeClass == .compact || verticalSizeClass == .compact {
                let landscape = verticalSizeClass == .compact
                Button { PlayerOrientation.set(landscape: !landscape) } label: {
                    Image(systemName: landscape ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate").font(.headline).frame(width: 22, height: 22)
                }
                .chromeButton()
                .accessibilityLabel(L10n.text(landscape ? "Rotate to Portrait" : "Rotate to Landscape"))
                .accessibilityIdentifier("player.rotate")
            }
        }
    }

    /// Whether the options have the smoothing and upscaling switches (iPhone and iPad on OS 26).
    private var pictureSwitches: Bool { VideoEnhancement.canUpscale || VideoEnhancement.canSmooth }

    /// The picture, sound and subtitle settings in one menu: what AVKit's ⋯ menu held, and the stream's quality.
    private var optionsMenu: some View {
        Menu {
            if session.qualities.count > 1 { Menu(L10n.text("Quality")) { QualityPicker(session: session) } }
            if pictureSwitches {
                Section(L10n.text("Picture")) {
                    if VideoEnhancement.canSmooth { Toggle(L10n.text("Smooth Motion (60 fps)"), isOn: $smoothsVideo) }
                    if VideoEnhancement.canUpscale { Toggle(L10n.text("Sharper Picture"), isOn: $upscalesVideo) }
                }
            }
            if let audio = tracks.audio, audio.options.count > 1 {
                Menu(L10n.text("Audio")) {
                    Picker(L10n.text("Audio"), selection: Binding(get: { tracks.selected(in: audio) }, set: { tracks.select($0, in: audio) })) {
                        ForEach(audio.options, id: \.self) { Text(audio.name($0)).tag(Optional($0)) }
                    }
                    .pickerStyle(.inline)
                }
            }
            // A file whose sound tracks AVFoundation offers no choice between (#428).
            if session.audioChoices.count > 1 {
                Menu(L10n.text("Audio")) {
                    Picker(L10n.text("Audio"), selection: Binding(get: { session.audioChoice }, set: { if let id = $0 { session.chooseAudio(id) } })) {
                        ForEach(session.audioChoices) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .pickerStyle(.inline)
                }
            }
            // The item's own subtitles, then subtitle files beside the video or added now (#576).
            Menu(L10n.text("Subtitles")) {
                if let legible = tracks.legible, !legible.options.isEmpty {
                    Picker(L10n.text("Subtitles"), selection: Binding(get: { session.externalSubtitles.selected == nil ? tracks.selected(in: legible) : nil },
                                                                      set: { tracks.select($0, in: legible); session.choseSubtitle($0); session.externalSubtitles.nativeChosen() })) {
                        if legible.group.allowsEmptySelection { Text(L10n.text("Off")).tag(AVMediaSelectionOption?.none) }
                        ForEach(legible.options, id: \.self) { Text(legible.name($0)).tag(Optional($0)) }
                    }
                    .pickerStyle(.inline)
                } else if session.externalSubtitles.selected != nil {
                    Button(L10n.text("Off")) { session.externalSubtitles.select(nil) }
                }
                ExternalSubtitleMenu(subtitles: session.externalSubtitles, addFile: { importsSubtitleFile = true }, addAddress: { asksSubtitleAddress = true },
                                     searchOnline: { searchesSubtitles = true })
            }
            if session.externalSubtitles.selected == nil, let legible = tracks.legible, !legible.options.isEmpty {
                // A subtitle file that runs ahead of its picture (#599): each step holds it back half a second.
                Menu(L10n.text("Subtitle Delay")) {
                    Text(SubtitleDelay.title(session.subtitles.delay))
                    Button(String(format: "%+.1f s", -SubtitleDelay.step)) {
                        SubtitleDelay.save(session.subtitles.delay - SubtitleDelay.step)
                    }
                    .disabled(session.subtitles.delay <= SubtitleDelay.range.lowerBound)
                    Button(String(format: "%+.1f s", SubtitleDelay.step)) {
                        SubtitleDelay.save(session.subtitles.delay + SubtitleDelay.step)
                    }
                    .disabled(session.subtitles.delay >= SubtitleDelay.range.upperBound)
                    if session.subtitles.delay != 0 {
                        Button(L10n.text("Reset")) { SubtitleDelay.save(0) }
                    }
                }
            }
            // With a seek bar the speed has its own button beside it (`speedButton`).
            if !session.isLive, !session.hasTimeline {
                Menu(L10n.text("Playback Speed")) {
                    Picker(L10n.text("Playback Speed"), selection: Binding(get: { speed }, set: { speed = $0; session.setSpeed($0) })) {
                        ForEach(Self.speeds, id: \.self) { Text(Self.speedLabel($0)).tag($0) }
                    }
                    .pickerStyle(.inline)
                }
            }
            // A series' intro and outro (#1488), here with the player's other settings, on the video page too.
            if session.canSkip, !session.isLive { SkipTimesMenuButton(session: session) { showsSkip = true } }
            SleepTimerMenu(item: .episode, offersEnd: !session.isLive)
            Picker(selection: $videoFill) {
                ForEach(VideoFill.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
            } label: { Label(L10n.text("Picture Size"), systemImage: "aspectratio") }
            .pickerStyle(.menu)
            .accessibilityIdentifier("player.videoFill")
            // The frame on screen, to Photos at the video's own size (#1342, #1332).
            Button { frames.save(session.player, title: channel.name) } label: { Label(L10n.text("Save Frame"), systemImage: "camera") }
                .disabled(!session.showsPicture || frames.busy || playingOn != nil)
                .accessibilityIdentifier("player.saveFrame")
            Toggle(L10n.text("Show Video Info"), isOn: $showsPlaybackInfo)
            if !inline { Toggle(L10n.text("Show Time and Battery"), isOn: $showsStatus) }
        } label: {
            Image(systemName: "slider.horizontal.3").font(.headline).frame(width: 22, height: 22)
                .symbolVariant(pictureSwitches && (upscalesVideo || smoothsVideo) ? .fill : .none)
        }
        .chromeButton()
        // "Playback Options" is the catalog's episode menu beside it.
        .accessibilityLabel(L10n.text("Settings"))
        .accessibilityIdentifier("player.options")
    }

    private static let speeds: [Float] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4]
    private static func speedLabel(_ speed: Float) -> String {
        Double(speed).formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    // MARK: Middle and bottom

    private var centerRow: some View {
        HStack(spacing: 20) {
            if seekable && !inline {
                let step = SkipInterval.seconds(skipInterval)
                Button { session.skip(-step); sought() } label: { Image(systemName: SkipInterval.symbol(forward: false, seconds: step)) }
                    .buttonStyle(PlayerCircleStyle(size: 52))
                    .accessibilityLabel(L10n.text("Back %@ seconds", String(Int(step))))
            }
            Button { session.togglePlayback() } label: {
                // Swapped as the music player's is.
                Image(systemName: session.paused ? "play.fill" : "pause.fill").contentTransition(.symbolEffect(.replace))
            }
                .buttonStyle(PlayerCircleStyle(size: inline ? 50 : 68))
                .accessibilityLabel(L10n.text(session.paused ? "Play" : "Pause"))
                .accessibilityIdentifier("player.playPause")
            if seekable && !inline {
                let step = SkipInterval.seconds(skipInterval)
                Button { session.skip(step); sought() } label: { Image(systemName: SkipInterval.symbol(forward: true, seconds: step)) }
                    .buttonStyle(PlayerCircleStyle(size: 52))
                    .accessibilityLabel(L10n.text("Forward %@ seconds", String(Int(step))))
            }
        }
        .simultaneousGesture(TapGesture().onEnded { poke() })
    }

    /// Previous and Next Episode, small and at the right of the time above the seek bar. Beside ±10 and play, a tap
    /// that ran past +10 out of habit changed the episode. 选集 opens the episodes in a sheet (#524). Previous and Next
    /// sit at the two ends of the group, with the rest between: side by side, a tap meant for one changed the channel
    /// the other way (#1113). Full Screen is a button of its own in the corner, apart from the group, as in YouTube's
    /// and Bilibili's players: between the episode buttons, a tap meant for it changed the episode (#1217, #1222).
    /// At the top of a watch page the episodes are listed right under the picture, so the group leaves them out.
    @ViewBuilder private var stepButtons: some View {
        let previous = inline ? nil : store.step(back: true, from: channel, session: session)
        let next = inline ? nil : store.step(back: false, from: channel, session: session)
        // On a watch page the episodes are on the page itself.
        let episodes = !inline && PlayerEpisodesSheet.offered(for: channel, in: store)
        let channels = !inline && PlayerChannelsSheet.offered(for: channel, session: session, in: store)
        let speeds = session.hasTimeline && !session.isLive
        let grouped = speeds || previous != nil || next != nil || episodes || channels
        if grouped || toggleFullScreen != nil {
            HStack(spacing: 12) {
                if grouped {
                    // One glass capsule, as the top row's buttons (`chromeGroup`).
                    HStack(spacing: 0) {
                        if let previous {
                            Button { previous.go() } label: { Image(systemName: "backward.end.fill") }
                                .buttonStyle(PlayerCircleStyle(size: 36))
                                .disabled(previous.busy)
                                .accessibilityLabel(previous.title(back: true))
                        }
                        if speeds { speedButton }
                        if episodes {
                            PlayerEpisodesButton(channel: channel, isPresented: $showsEpisodes) {
                                HStack(spacing: 6) {
                                    Image(systemName: PlayerEpisodesSheet.symbol)
                                    Text(L10n.text("Episodes"))
                                }
                                .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 12).frame(height: 36)
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        if channels {
                            PlayerChannelsButton(channel: channel, session: session, isPresented: $showsChannels) {
                                HStack(spacing: 6) {
                                    Image(systemName: PlayerChannelsSheet.symbol)
                                    Text(L10n.text("Channel List"))
                                }
                                .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 12).frame(height: 36)
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        if let next {
                            Button { next.go() } label: { Image(systemName: "forward.end.fill") }
                                .buttonStyle(PlayerCircleStyle(size: 36))
                                .disabled(next.busy)
                                .accessibilityLabel(next.title(back: false))
                        }
                    }
                    .chromeGroup()
                }
                if let toggleFullScreen {
                    let full = layout == .pageFullScreen
                    // The system's own full-screen arrows, as AVKit and Photos show them; filling the screen, they point inward.
                    Button(action: toggleFullScreen) {
                        Image(systemName: full ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 15, weight: .semibold))
                    }
                        .buttonStyle(PlayerCircleStyle(size: 36))
                        .accessibilityLabel(L10n.text(full ? "Exit Full Screen" : "Full Screen"))
                        .accessibilityIdentifier("player.fullScreen")
                }
            }
            .simultaneousGesture(TapGesture().onEnded { poke() })
        }
    }

    /// The speed, by the seek bar: a tap lists them all, from a quarter to four times.
    private var speedButton: some View {
        Menu {
            Picker(L10n.text("Playback Speed"), selection: Binding(get: { speed }, set: { speed = $0; session.setSpeed($0) })) {
                ForEach(Self.speeds, id: \.self) { Text(Self.speedLabel($0)).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Text(Self.speedLabel(speed))
                .font(.system(size: 14, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
                .lineLimit(1).fixedSize()
                .frame(minWidth: 36).padding(.horizontal, 6).frame(height: 36)
                .contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .accessibilityLabel(L10n.text("Playback Speed"))
        .accessibilityValue(Self.speedLabel(speed))
        .accessibilityIdentifier("player.speed")
    }

    @ViewBuilder private var bottomRow: some View {
        if session.isLive {
            HStack {
                Text(L10n.text("LIVE")).font(.caption.weight(.bold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.red, in: Capsule())
                Spacer(minLength: 0)
                stepButtons
            }
        } else if session.hasTimeline {
            // Dragging holds the controls up itself (`hold`); a tap gesture here would compete with the scrubber's drag.
            SeekBar(clock: clock, moving: chromeVisible && !session.paused, hold: hold, sought: sought) { stepButtons }
        } else {
            HStack {
                Spacer(minLength: 0)
                stepButtons
            }
        }
    }

    /// The position moved by a button or the seek bar: the Lock Screen follows.
    private func sought() {
        poke()
        nowPlaying.update(title: channel.name, session: session)
    }

    private var pipPlaceholder: some View {
        VStack(spacing: 14) {
            Image(systemName: "pip").font(.system(size: 48, weight: .light))
            Text(L10n.text("Playing in Picture in Picture")).font(.callout)
        }
        .foregroundStyle(.white.opacity(0.6))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .playerBleed(!inline)
    }
}

/// The top of an iPhone watch page before the picture: the cover filling the width, blurred, under a spinner.
/// While nothing is starting, the whole cover shows clear over that blur.
struct WatchCoverBackdrop: View {
    let poster: URL?
    var headers: [String: String] = [:]
    var loading = true
    var clear = false
    /// What the wait has to say, by how long it has run (see `WaitSpinner`).
    var status: (@MainActor (TimeInterval) -> PlaybackWait)? = nil
    @State private var aspect: CGFloat?
    var body: some View {
        ZStack {
            Color.black
            PosterImage(url: poster, headers: headers)
                .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                .blur(radius: 24).scaleEffect(1.2)
                .overlay(Color.black.opacity(0.35))
                .accessibilityHidden(true)
            if clear, poster != nil {
                PosterImage(url: poster, headers: headers, aspect: $aspect)
                    .aspectRatio(aspect ?? 2.0 / 3, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
                    .padding(.vertical, 14)
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
            if loading { WaitSpinner(status: status) }
        }
        .animation(.easeOut(duration: 0.3), value: clear)
        .clipped()
    }
}

/// A spinner first; once the wait has run `PlaybackWait.detailsAfter`, its line and small print along the bottom,
/// so the spinner stays where it was.
struct WaitSpinner: View {
    var status: (@MainActor (TimeInterval) -> PlaybackWait)?
    @State private var started = Date()
    var body: some View {
        ZStack {
            ProgressView().appControlSize(.large).tint(.white)
            if let status {
                TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
                    let elapsed = max(0, timeline.date.timeIntervalSince(started))
                    let speaks = elapsed >= PlaybackWait.detailsAfter
                    VStack(spacing: 5) {
                        if speaks {
                            let wait = status(elapsed)
                            Text(wait.message).font(.footnote.weight(.medium)).foregroundStyle(.white).lineLimit(1)
                            WaitDetails(detail: wait.detail, steps: Array(wait.steps.suffix(2)))
                        }
                    }
                    .padding(.horizontal, 24).padding(.bottom, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .animation(.smooth(duration: 0.45), value: speaks)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

/// Whether a menu is open: SwiftUI's `Menu` opens UIKit's context menu, whose container joins the window while it
/// shows. Read only when the player's controls are about to fade (#1500).
@MainActor enum OpenMenu {
    static var showing: Bool {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).contains { window in
            !window.isHidden && window.subviews.contains { String(describing: type(of: $0)).contains("ContextMenuContainer") }
        }
    }
}

/// Where the iPhone and iPad player is drawn.
enum MobilePlayerLayout {
    /// A screen of its own (the full-screen player).
    case screen
    /// The top of an iPhone watch page, under the status bar.
    case inline
    /// A watch page's player filling the screen; Back returns to the page.
    case pageFullScreen
}

/// The player at the top of an iPhone watch page (`VideoDetailView`).
struct WatchPlayback {
    /// Filling the screen, or at the top of the page.
    var fullScreen: Bool
    /// Full Screen, or back to the page. True when the picture is wider than tall, so the phone turns.
    var toggleFullScreen: (_ landscape: Bool) -> Void
    /// Back, out of the page.
    var leave: () -> Void
    /// The picture, or an error, has taken the place of the wait: the page's cover can go.
    var started: (Bool) -> Void = { _ in }
    /// The page's player, so the cover over it can say how its wait goes.
    var opened: (PlaybackSession) -> Void = { _ in }
}

/// The full-screen player sets the app's appearance; one at the top of a page sets only its own.
struct PlayerScheme: ViewModifier {
    let ownsScreen: Bool
    func body(content: Content) -> some View {
        if ownsScreen { content.preferredColorScheme(.dark) } else { content.environment(\.colorScheme, .dark) }
    }
}

extension View {
    /// Under the status bar and the home indicator on a screen of its own; inside its frame at the top of a page,
    /// where reaching into the safe area would run the picture under the status bar. One view either way: a branch
    /// for each made a watch page going full screen build the picture's layer anew, and Picture in Picture stayed
    /// with the old one, off screen, so it couldn't start (#652).
    func playerBleed(_ bleeds: Bool, edges: Edge.Set = .all) -> some View {
        ignoresSafeArea(edges: bleeds ? edges : [])
    }
}

/// The position and the length in a capsule over a scrubber the width of the screen, as in YouTube's player, and
/// scrubbing as in Telegram's: while dragged, only the bar, the time and a frame from that point (above the handle)
/// follow the finger, and the video seeks once, when the finger lifts. Seeking the playing video along with the finger
/// left it stuttering behind. A view of its own, so only it redraws as the position moves.
private struct SeekBar<Accessory: View>: View {
    /// The height of the time's row, which the accessory shares: the episode buttons are 36 points round.
    static var timeRow: CGFloat { 36 }
    let clock: PlayerClock
    /// Playing with the controls showing: the bar follows the player every frame.
    let moving: Bool
    let hold: (Bool) -> Void
    let sought: () -> Void
    /// At the right of the time: the episode buttons.
    @ViewBuilder let accessory: () -> Accessory
    /// Where a drag began: the position then and the finger's start. The handle moves by as much as the finger does
    /// (Telegram), rather than jumping under it; a touch away from the handle puts it there first.
    @State private var drag: (position: Double, location: CGPoint)?
    /// Slower scrubbing while the finger moves away from the bar: half, a quarter and a tenth of the speed (Telegram).
    @State private var fineness = 1.0
    @State private var width: CGFloat = 0

    var body: some View {
        // While it plays, as often as the handle moves (`frameInterval`); paused, held or hidden, only when the clock changes.
        let follows = moving && clock.scrubbing == nil
        TimelineView(.animation(minimumInterval: Self.frameInterval(duration: clock.duration, width: width), paused: !follows)) { _ in
            bar(clock.scrubbing ?? (follows ? clock.currentPosition : clock.position))
        }
        // Outside the bar, which is one accessibility element. Gone while scrubbing, when the time grows with the
        // scrubbing speed's label and the finger is there to scrub.
        .overlay(alignment: .topTrailing) {
            if drag == nil { accessory().frame(height: Self.timeRow).transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.15), value: drag == nil)
        .sensoryFeedback(.selection, trigger: fineness)
    }

    /// How often the playing bar is drawn: each time its handle moves about half a point, at most 60 times a second, and
    /// at least twice a second for the time beside it. A film's handle moves a tenth of a point a second, and the bar
    /// was drawn on every frame of a 120 Hz screen while the controls showed (#1428).
    static func frameInterval(duration: Double, width: CGFloat) -> Double {
        guard duration.isFinite, duration > 0, width > 0 else { return 0.5 }
        return min(0.5, max(1.0 / 60, duration / Double(width) / 2))
    }

    private func bar(_ position: Double) -> some View {
        let duration = clock.duration
        let value = min(max(0, position), duration)
        let x = duration > 0 ? width * value / duration : 0
        // How far the video has loaded past the position (#900): a lighter part of the bar ahead of the played one.
        let loaded = duration > 0 ? width * min(max(clock.buffered, value), duration) / duration : 0
        let held = drag != nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(Self.format(value) + " / " + Self.format(duration))
                if let speed = Self.fineLabel(fineness) { Text(speed).foregroundStyle(.white.opacity(0.75)) }
            }
            .font(.footnote.monospacedDigit().weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .glassSurface(.regular, in: Capsule())
            .frame(height: Self.timeRow)
            .accessibilityHidden(true)
            ZStack(alignment: .leading) {
                // The played part is an overlay, so it never sizes the bar: at the very end it is the bar's whole
                // measured width, and as a child it held the bar (and the watch page around it) at the landscape
                // width after leaving Full Screen (#1008).
                Capsule().fill(.white.opacity(0.25)).frame(height: held ? 6 : 4)
                    .overlay(alignment: .leading) { Capsule().fill(.white.opacity(0.5)).frame(width: max(0, loaded)) }
                    .overlay(alignment: .leading) { Capsule().fill(.white).frame(width: max(0, x)) }
                Circle().fill(.white)
                    .frame(width: held ? 24 : 14, height: held ? 24 : 14)
                    .shadow(color: .black.opacity(0.35), radius: 3)
                    .offset(x: x - (held ? 12 : 7))
            }
            .frame(maxWidth: .infinity, minHeight: 32)
            .contentShape(Rectangle())
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { changed($0, value: value, duration: duration) }
                .onEnded { ended($0) })
            .animation(.spring(duration: 0.3, bounce: 0.3), value: held)
        }
        // The frame at the finger, above the time, centred on the handle and kept on screen.
        .overlay(alignment: .topLeading) {
            if held, let preview = clock.preview {
                let previewWidth: CGFloat = 160
                Image(decorative: preview, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: previewWidth)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.8), lineWidth: 1))
                    .shadow(color: .black.opacity(0.4), radius: 6)
                    .alignmentGuide(.top) { $0[.bottom] + 8 }
                    .offset(x: min(max(0, x - previewWidth / 2), max(0, width - previewWidth)))
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.12), value: held && clock.preview != nil)
        .accessibilityElement()
        .accessibilityLabel(L10n.text("Playback Position"))
        .accessibilityValue(Self.format(value))
        .accessibilityIdentifier("player.seek")
        .accessibilityAdjustableAction { direction in
            clock.seek(to: min(max(0, value + (direction == .increment ? 10 : -10)), duration), tolerance: SeekTolerance.skip(10))
            sought()
        }
    }

    private func changed(_ gesture: DragGesture.Value, value: Double, duration: Double) {
        guard duration > 0, width > 0 else { return }
        if drag == nil {
            // From where the video is, wherever the finger lands (YouTube, Telegram): a touch away from the handle used
            // to jump there first, and the picture lurched. A tap that doesn't slide still jumps (see `ended`).
            drag = (value, gesture.startLocation)
            hold(true)
            clock.scrub(to: value, secondsPerPoint: duration / Double(width))
        }
        guard let begin = drag else { return }
        let away = abs(gesture.location.y - begin.location.y)
        let wanted = away > 150 ? 0.1 : away > 100 ? 0.25 : away > 50 ? 0.5 : 1
        if wanted != fineness {
            // Carry on from here at the new speed, so the handle doesn't jump.
            fineness = wanted
            drag = (clock.scrubbing ?? begin.position, gesture.location)
            return
        }
        let moved = Double((gesture.location.x - begin.location.x) / width) * duration * fineness
        clock.scrub(to: min(max(0, begin.position + moved), duration), secondsPerPoint: duration / Double(width) * fineness)
    }

    private func ended(_ gesture: DragGesture.Value) {
        guard drag != nil else { return }
        // A tap on the bar, with no slide, goes to that point.
        if hypot(gesture.translation.width, gesture.translation.height) < 6, width > 0, clock.duration > 0 {
            clock.scrub(to: clock.duration * Double(min(max(0, gesture.startLocation.x / width), 1)), secondsPerPoint: clock.duration / Double(width))
        }
        drag = nil
        fineness = 1
        hold(false)
        clock.endScrub()
        sought()
    }

    private static func fineLabel(_ fineness: Double) -> String? {
        switch fineness {
        case 0.5: L10n.text("Half-Speed Scrubbing")
        case 0.25: L10n.text("Quarter-Speed Scrubbing")
        case ..<0.25: L10n.text("Fine Scrubbing")
        default: nil
        }
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.isFinite ? max(0, seconds) : 0)
        let hours = total / 3600, minutes = total / 60 % 60, rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
}

/// The top row's three parts: Back, the title and the buttons. All in one row while the title keeps `minimumTitle`;
/// otherwise Back and the buttons share the first row and the title has the next one to itself. On a screen too
/// narrow even for Back beside the buttons, the buttons take the first row alone and Back goes beside the title.
private struct PlayerTopBar: SwiftUI.Layout {
    var spacing: CGFloat = 12
    var rowSpacing: CGFloat = 10
    var minimumTitle: CGFloat = 160

    private enum Arrangement { case oneRow, titleBelow, buttonsAlone }

    private func arrangement(_ width: CGFloat, back: CGSize, buttons: CGSize) -> Arrangement {
        if back.width + spacing + minimumTitle + spacing + buttons.width <= width { return .oneRow }
        return back.width + spacing + buttons.width <= width ? .titleBelow : .buttonsAlone
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) -> CGSize {
        guard subviews.count == 3 else { return .zero }
        let back = subviews[0].sizeThatFits(.unspecified), buttons = subviews[2].sizeThatFits(.unspecified)
        let width = proposal.width ?? back.width + subviews[1].sizeThatFits(.unspecified).width + buttons.width + 2 * spacing
        func title(_ room: CGFloat) -> CGSize { subviews[1].sizeThatFits(ProposedViewSize(width: room, height: nil)) }
        switch arrangement(width, back: back, buttons: buttons) {
        case .oneRow:
            let title = title(width - back.width - buttons.width - 2 * spacing)
            return CGSize(width: width, height: max(back.height, buttons.height, title.height))
        case .titleBelow:
            return CGSize(width: width, height: max(back.height, buttons.height) + rowSpacing + title(width).height)
        case .buttonsAlone:
            return CGSize(width: width, height: buttons.height + rowSpacing + max(back.height, title(width - back.width - spacing).height))
        }
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let back = subviews[0].sizeThatFits(.unspecified), buttons = subviews[2].sizeThatFits(.unspecified)
        /// Places a subview with its vertical centre at `middle`; the title gets `room` and truncates to it.
        func place(_ index: Int, x: CGFloat, middle: CGFloat, room: CGFloat? = nil) {
            let size = room.map { subviews[index].sizeThatFits(ProposedViewSize(width: $0, height: nil)) } ?? subviews[index].sizeThatFits(.unspecified)
            subviews[index].place(at: CGPoint(x: x, y: middle - size.height / 2), proposal: ProposedViewSize(width: size.width, height: size.height))
        }
        switch arrangement(bounds.width, back: back, buttons: buttons) {
        case .oneRow:
            place(0, x: bounds.minX, middle: bounds.midY)
            place(1, x: bounds.minX + back.width + spacing, middle: bounds.midY, room: bounds.width - back.width - buttons.width - 2 * spacing)
            place(2, x: bounds.maxX - buttons.width, middle: bounds.midY)
        case .titleBelow:
            let row = max(back.height, buttons.height)
            place(0, x: bounds.minX, middle: bounds.minY + row / 2)
            place(2, x: bounds.maxX - buttons.width, middle: bounds.minY + row / 2)
            let title = subviews[1].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            place(1, x: bounds.minX, middle: bounds.minY + row + rowSpacing + title.height / 2, room: bounds.width)
        case .buttonsAlone:
            place(2, x: bounds.maxX - buttons.width, middle: bounds.minY + buttons.height / 2)
            let room = bounds.width - back.width - spacing
            let row = max(back.height, subviews[1].sizeThatFits(ProposedViewSize(width: room, height: nil)).height)
            let middle = bounds.minY + buttons.height + rowSpacing + row / 2
            place(0, x: bounds.minX, middle: middle)
            place(1, x: bounds.minX + back.width + spacing, middle: middle, room: room)
        }
    }
}

/// A round glass button of the given size, for play and skip in the middle of the picture.
private struct PlayerCircleStyle: ButtonStyle {
    var size: CGFloat
    @Environment(\.isEnabled) private var enabled
    @Environment(\.chromeGrouped) private var grouped
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            // In a button group (`chromeGroup`) the group's capsule is the glass.
            .glassSurface(grouped ? .identity : .regular.interactive(), in: Circle())
            .contentShape(Circle())
            .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.38)
            // Gives under the finger, so a tap shows before the player answers.
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

/// AirPlay, drawn like the buttons beside it: the system's own button (AVRoutePickerView) drew its mark bigger and heavier,
/// so it stays out of sight and this one opens its picker, as Play On's menu does.
private struct AirPlayButton: View {
    @State private var airPlay = AirPlayPicker()
    var body: some View {
        Button(action: airPlay.present) {
            Image(systemName: "airplay.video").font(.airPlayGlyph).frame(width: 22, height: 22)
        }
        .chromeButton()
        .background { AirPlayPickerView(picker: airPlay).opacity(0.02).allowsHitTesting(false) }
        .accessibilityLabel(L10n.text("AirPlay"))
        .accessibilityIdentifier("player.airPlay")
    }
}

/// The picture's own gestures, in UIKit: taps, a touch and hold followed while the finger moves, slides and a pinch.
/// SwiftUI's long press ends where a drag would begin, and a tap beside it can fire as the held finger lifts.
private struct PictureGestures: UIViewRepresentable {
    enum Hold { case began, moved(CGSize), ended }
    /// Sideways seeks; up or down sets the brightness on the left half and the volume on the right.
    enum Slide { case seek, brightness, volume }
    enum Swipe { case began(Slide), moved(CGSize, in: CGSize), ended }
    /// Where the tap landed across the picture, and the picture's width.
    let tap: (CGFloat, CGFloat) -> Void
    let hold: (Hold) -> Void
    let swipe: (Swipe) -> Void
    /// Whether slides up or down set the brightness and the volume.
    var levels = true
    /// Pinched out (true) or in, as in YouTube: fill the screen or fit the picture.
    let pinch: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pressed(_:)))
        press.minimumPressDuration = 0.35
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        // A touch that lifts before the hold begins is a tap, at once; each tap of a double tap comes on its own.
        tap.require(toFail: press)
        // A finger that moves before the hold begins slides instead.
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.panned(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinched(_:)))
        for recognizer in [press, tap, pan, pinch] { view.addGestureRecognizer(recognizer) }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { context.coordinator.parent = self }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PictureGestures?
        private var start = CGPoint.zero
        private var slide = Slide.seek

        @objc func tapped(_ tap: UITapGestureRecognizer) {
            guard let view = tap.view else { return }
            parent?.tap(tap.location(in: view).x, view.bounds.width)
        }

        @objc func pressed(_ press: UILongPressGestureRecognizer) {
            let location = press.location(in: press.view)
            switch press.state {
            case .began: start = location; parent?.hold(.began)
            case .changed: parent?.hold(.moved(CGSize(width: location.x - start.x, height: location.y - start.y)))
            case .ended, .cancelled, .failed: parent?.hold(.ended)
            default: break
            }
        }

        @objc func panned(_ pan: UIPanGestureRecognizer) {
            guard let view = pan.view else { return }
            switch pan.state {
            case .began: parent?.swipe(.began(slide))
            case .changed:
                let moved = pan.translation(in: view)
                parent?.swipe(.moved(CGSize(width: moved.x, height: moved.y), in: view.bounds.size))
            case .ended, .cancelled, .failed: parent?.swipe(.ended)
            default: break
            }
        }

        @objc func pinched(_ pinch: UIPinchGestureRecognizer) {
            guard pinch.state == .ended, abs(pinch.scale - 1) > 0.1 else { return }
            parent?.pinch(pinch.scale > 1)
        }

        /// Sideways anywhere; up or down only away from the edges that Notification Center, Control Center and the
        /// Home indicator use.
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer, let view = pan.view else { return true }
            let velocity = pan.velocity(in: view)
            if abs(velocity.x) > abs(velocity.y) { slide = .seek; return true }
            let location = pan.location(in: view)
            guard parent?.levels == true, PictureLevel.slides(fromY: location.y, height: view.bounds.height) else { return false }
            slide = location.x < view.bounds.width / 2 ? .brightness : .volume
            return true
        }
    }
}

/// The view of an AVPlayerLayer.
final class PlayerLayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// The picture in an AVPlayerLayer, which Picture in Picture takes over while it runs. A player screen opened again
/// for a video still floating in Picture in Picture takes the layer it left: the window returns into it.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    let gravity: AVLayerVideoGravity
    let pip: PictureInPicture
    func makeUIView(context: Context) -> PlayerLayerUIView {
        if let kept = pip.layerView, kept.superview == nil, kept.playerLayer.player === player { return kept }
        let view = PlayerLayerUIView()
        view.playerLayer.player = player
        pip.attach(view)
        return view
    }
    func updateUIView(_ view: PlayerLayerUIView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        view.playerLayer.videoGravity = gravity
    }
}

extension VideoFill {
    var gravity: AVLayerVideoGravity {
        switch self {
        case .fit: .resizeAspect
        case .fill: .resizeAspectFill
        case .stretch: .resize
        }
    }
    var title: String {
        switch self {
        case .fit: L10n.text("Fit")
        case .fill: L10n.text("Fill")
        case .stretch: L10n.text("Stretch")
        }
    }
    var symbol: String {
        switch self {
        case .fit: "rectangle.center.inset.filled"
        case .fill: "arrow.up.left.and.arrow.down.right"
        case .stretch: "arrow.left.and.right"
        }
    }
}

/// The time and the battery at the start of the full-screen buttons (#996). The battery is watched only while it
/// shows; the simulator, which has none, shows the time alone. The battery is a gauge without a number: iOS tells apps
/// the level in steps of 5%, so a number read 60% beside the system's 62% (#1366).
struct PlayerStatusBadge: View {
    static let key = "player.showsTimeAndBattery"
    /// In the buttons' glass capsule, or bare on the title's row.
    var grouped = true
    @State private var battery = PlayerBattery()

    var body: some View {
        HStack(spacing: 6) {
            TimelineView(.everyMinute) { context in
                // As the status bar shows it: no AM or PM.
                Text(context.date, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
            }
            if let level = battery.level {
                BatteryGauge(level: level, charging: battery.charging)
            }
        }
        .font(.system(size: 14, weight: .semibold)).monospacedDigit()
        .lineLimit(1).fixedSize()
        .padding(.leading, grouped ? 14 : 0).padding(.trailing, grouped ? 6 : 0).frame(height: grouped ? 44 : nil)
        .onAppear { battery.start() }
        .onDisappear { battery.stop() }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("player.status")
    }
}

/// The status bar's battery: an outline filled to the level, green while charging and red when low.
private struct BatteryGauge: View {
    let level: Double
    let charging: Bool
    var body: some View {
        let fill: Color = charging ? .green : level <= 0.2 ? .red : .white
        HStack(spacing: 1.5) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(.white.opacity(0.45), lineWidth: 1)
                .overlay(alignment: .leading) {
                    GeometryReader { box in
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(fill)
                            .frame(width: max(2, (box.size.width - 4) * min(max(level, 0), 1)))
                            .padding(2)
                    }
                }
                .frame(width: 25, height: 12)
            RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.45)).frame(width: 1.5, height: 4)
        }
        .accessibilityElement()
        .accessibilityLabel(L10n.text(charging ? "Battery, charging" : "Battery"))
        .accessibilityValue(Text(level, format: .percent.precision(.fractionLength(0))))
    }
}

@MainActor @Observable final class PlayerBattery {
    /// 0 to 1; nil where the device has no battery to report.
    private(set) var level: Double?
    private(set) var charging = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var enabledMonitoring = false

    func start() {
        guard observers.isEmpty else { return }
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true; enabledMonitoring = true }
        read()
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.read() }
            })
        }
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if enabledMonitoring { UIDevice.current.isBatteryMonitoringEnabled = false; enabledMonitoring = false }
    }

    private func read() {
        #if DEBUG
        // `-qaBattery 0.62`: that level, for screenshots on a simulator, which has no battery.
        if UserDefaults.standard.object(forKey: "qaBattery") != nil {
            level = UserDefaults.standard.double(forKey: "qaBattery"); charging = false
            return
        }
        #endif
        let device = UIDevice.current
        let value = device.batteryLevel
        level = value < 0 || device.batteryState == .unknown ? nil : Double(value)
        charging = device.batteryState == .charging || device.batteryState == .full
    }
}

/// Picture in Picture for the player layer: the button, and carrying on in a floating window when the app is left.
@MainActor @Observable final class PictureInPicture: NSObject, AVPictureInPictureControllerDelegate {
    let supported = AVPictureInPictureController.isPictureInPictureSupported()
    private(set) var possible = false
    private(set) var active = false
    /// The window is up (from its start until it closes): the player screen can go, and the video plays on in it.
    private(set) var floating = false
    /// The view of the layer the window shows, kept for a player screen opened again while it floats.
    @ObservationIgnored private(set) var layerView: PlayerLayerUIView?
    @ObservationIgnored private var controller: AVPictureInPictureController?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    func attach(_ view: PlayerLayerUIView) {
        guard supported else { return }
        let layer = view.playerLayer
        if controller?.isPictureInPictureActive != true { layerView = view }
        if let controller {
            // A new layer for the same player: Picture in Picture follows the one on screen.
            if controller.contentSource?.playerLayer !== layer, !controller.isPictureInPictureActive {
                controller.contentSource = .init(playerLayer: layer)
            }
            return
        }
        let controller = AVPictureInPictureController(contentSource: .init(playerLayer: layer))
        controller.delegate = self
        // Leaving the app while a video plays carries on in Picture in Picture, as AVKit's own player did.
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        observation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            let possible = controller.isPictureInPicturePossible
            Task { @MainActor [weak self] in self?.possible = possible }
        }
        self.controller = controller
    }

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive { controller.stopPictureInPicture() } else { controller.startPictureInPicture() }
    }

    /// Brings the video back from the window into its player.
    func stop() {
        if controller?.isPictureInPictureActive == true { controller?.stopPictureInPicture() }
    }

    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor [weak self] in self?.active = true }
    }
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor [weak self] in self?.floating = true }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            active = false; floating = false
            FloatingPlayback.shared.stopped(self)
        }
    }
    /// The window's button that returns to the app: the player screen opens again if it was closed.
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                               restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        nonisolated(unsafe) let done = completionHandler
        Task { @MainActor [weak self] in
            guard let self else { return done(true) }
            FloatingPlayback.shared.restore(self) { done($0) }
        }
    }
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        let detail = Diagnostics.describe(error)
        Task { @MainActor in Diagnostics.shared.record(.warning, "player", "Picture in Picture failed: \(detail)") }
    }
}

/// A video playing on in Picture in Picture after its player screen closed, as in the TV app (#1239, #1442): starting
/// Picture in Picture takes the player screen away, so the app is there to use under the window, and the window's
/// button that returns to the app opens the player again where the video is. Closing the window ends the video, and so
/// does another video starting.
@MainActor final class FloatingPlayback {
    static let shared = FloatingPlayback()
    struct Parked {
        let channel: Channel
        let session: PlaybackSession
        let pip: PictureInPicture
    }
    private(set) var parked: Parked?
    private weak var store: Store?
    /// The window's return to the app, waiting for the player screen to open.
    private var restoring: ((Bool) -> Void)?

    /// The player screen is closing while its window floats: the session plays on in it.
    func park(_ channel: Channel, session: PlaybackSession, pip: PictureInPicture, store: Store) {
        if let parked, parked.session !== session { end() }
        parked = Parked(channel: channel, session: session, pip: pip)
        self.store = store
        // Nothing comes next by itself while no player is open: the next episode would open the player over the app.
        session.onPlaybackEnded = nil; session.onAdvance = nil; session.upcomingEpisode = nil; session.playsOn = { false }
    }

    func holds(_ session: PlaybackSession) -> Bool { parked?.session === session }

    /// The video floating, for a player screen opening on `channel`.
    func parked(for channel: Channel) -> Parked? { parked?.channel == channel ? parked : nil }

    /// A player screen opened with the floating session: it is the screen's again. False for any other session.
    func take(_ session: PlaybackSession) -> Bool {
        guard let parked, parked.session === session else { return false }
        self.parked = nil
        // Opened from the app rather than the window's button: the video comes back from the window.
        if restoring == nil { parked.pip.stop() }
        finishRestoring()
        return true
    }

    /// The window's return button: the player opens again on the video. With the player still open there's nothing to do.
    func restore(_ pip: PictureInPicture, done: @escaping (Bool) -> Void) {
        guard let parked, parked.pip === pip, let store else { return done(true) }
        restoring?(true)
        restoring = done
        store.playing = parked.channel
        // The window waits for the answer: it is given once the player is up, or after a moment whatever happened.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.finishRestoring()
        }
    }

    private func finishRestoring() {
        restoring?(true)
        restoring = nil
    }

    /// The window closed. Without a player to return to, the video ends there.
    func stopped(_ pip: PictureInPicture) {
        guard let parked, parked.pip === pip, restoring == nil else { return }
        end()
    }

    /// Ends the floating video, if any.
    func end() {
        guard let parked else { return }
        self.parked = nil
        finishRestoring()
        parked.pip.stop()
        parked.session.stop()
    }
}

/// The playing item's position and duration, four times a second while it plays.
@MainActor @Observable final class PlayerClock {
    private(set) var position: Double = 0
    /// Zero until the item has a finite duration.
    private(set) var duration: Double = 0
    private(set) var item: AVPlayerItem?
    /// Where the seek bar is held, until the precise seek it ends with lands.
    private(set) var scrubbing: Double?
    /// Where the loaded part around the position ends: the seek bar shows it ahead of the played part (#900).
    private(set) var buffered: Double = 0
    @ObservationIgnored private weak var player: AVPlayer?
    @ObservationIgnored private var token: Any?
    /// The item's loaded ranges, which grow while it is paused too.
    @ObservationIgnored private var loading: NSKeyValueObservation?

    func attach(_ player: AVPlayer) {
        detach()
        self.player = player
        // The observer also fires on seeks and rate changes, so a new item shows up here while paused too.
        token = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        tick(player.currentTime())
    }

    func detach() {
        if let token { player?.removeTimeObserver(token) }
        token = nil
        loading = nil
    }

    /// The player's position now, read without waiting for the next tick.
    var currentPosition: Double {
        let seconds = player?.currentTime().seconds ?? 0
        return seconds.isFinite ? seconds : position
    }

    /// The frame the seek bar shows above its handle while dragged; nil until one is made, or where none can be.
    private(set) var preview: CGImage?
    @ObservationIgnored private var generator: AVAssetImageGenerator?
    @ObservationIgnored private var generatorItem: ObjectIdentifier?
    /// An item AVFoundation made no frame from (an HLS stream, say): no more tries for it.
    @ObservationIgnored private var previewless: ObjectIdentifier?
    @ObservationIgnored private var generating = false
    @ObservationIgnored private var nextPreview: Double?

    /// How much time one point of the drag moves (at its scrubbing speed): how close to the target the seek it ends
    /// with has to land (`SeekTolerance.release`).
    @ObservationIgnored private var scrubPrecision = 0.0

    /// While dragging, only the bar, the time and the preview follow the finger; the playing video is left alone
    /// until the finger lifts (Telegram).
    func scrub(to seconds: Double, secondsPerPoint: Double = 0) {
        scrubbing = seconds
        if secondsPerPoint > 0 { scrubPrecision = secondsPerPoint }
        nextPreview = seconds
        makePreview()
    }

    /// Let go: one seek to where the finger stopped, landing on a keyframe near it (#1213). An exact one first read and
    /// decoded the seconds before it, which a finger can't tell apart anyway: from a drive, seconds of waiting.
    func endScrub() {
        nextPreview = nil
        preview = nil
        let tolerance = SeekTolerance.release(secondsPerPoint: scrubPrecision)
        scrubPrecision = 0
        if let target = scrubbing { seek(to: target, tolerance: tolerance) }
    }

    /// A seek landing up to `tolerance` seconds either side of `seconds` (exact at 0); the bar stays at the target
    /// until it lands, rather than jumping back to the old position, then shows where it landed.
    func seek(to seconds: Double, tolerance: Double = 0) {
        guard let player else { scrubbing = nil; return }
        scrubbing = seconds
        let window = CMTime(seconds: max(0, tolerance), preferredTimescale: 600)
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: window, toleranceAfter: window) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.scrubbing == seconds else { return }
                let landed = self.player?.currentTime().seconds ?? seconds
                self.position = landed.isFinite ? max(0, landed) : seconds
                self.scrubbing = nil
            }
        }
    }

    /// One frame at a time, then the latest place asked for (Telegram's MediaPlayerFramePreview does the same), from
    /// a generator of its own so the playing video isn't disturbed. Nearby keyframes are good enough, and quick.
    private func makePreview() {
        guard !generating, let seconds = nextPreview, let item = player?.currentItem else { return }
        let identity = ObjectIdentifier(item)
        guard previewless != identity else { nextPreview = nil; return }
        if generatorItem != identity {
            let generator = AVAssetImageGenerator(asset: item.asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 320)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
            self.generator = generator
            generatorItem = identity
        }
        guard let generator else { return }
        nextPreview = nil
        generating = true
        generator.generateCGImageAsynchronously(for: CMTime(seconds: seconds, preferredTimescale: 600)) { [weak self] image, _, _ in
            nonisolated(unsafe) let frame = image
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.generating = false
                if let frame { if self.scrubbing != nil { self.preview = frame } }
                else if self.preview == nil { self.previewless = identity }
                self.makePreview()
            }
        }
    }

    private func tick(_ time: CMTime) {
        guard let player else { return }
        if item !== player.currentItem {
            item = player.currentItem
            buffered = 0
            loading = item?.observe(\.loadedTimeRanges, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.measureLoaded() }
            }
        }
        let seconds = time.seconds
        position = seconds.isFinite ? max(0, seconds) : 0
        let length = player.currentItem?.duration.seconds ?? 0
        let finite = length.isFinite ? max(0, length) : 0
        // Observation reports every assignment, even of the same value; the duration rarely changes.
        if finite != duration { duration = finite }
        measureLoaded()
    }

    /// Changed by a second or more, so the bar isn't redrawn for every few packets.
    private func measureLoaded() {
        guard let player, let item = player.currentItem else { return }
        let now = player.currentTime()
        let range = item.loadedTimeRanges.lazy.map(\.timeRangeValue).first { CMTimeRangeContainsTime($0, time: now) }
        let end = range.map { CMTimeRangeGetEnd($0).seconds } ?? 0
        let value = end.isFinite ? max(0, end) : 0
        if abs(value - buffered) >= 1 || (value == 0) != (buffered == 0) { buffered = value }
    }
}

/// The item's audio tracks and subtitles, for the options menu.
@MainActor @Observable final class MediaTracks {
    struct Group {
        let group: AVMediaSelectionGroup
        let options: [AVMediaSelectionOption]
        /// The menu's names for them (`TrackLabel`): the language and what else is known, not just the language.
        let names: [AVMediaSelectionOption: String]
        init(group: AVMediaSelectionGroup, options: [AVMediaSelectionOption], details: [String: TrackDetail]) {
            self.group = group; self.options = options
            let labels = TrackLabel.names(options.map { option in
                let title = AVMetadataItem.metadataItems(from: option.commonMetadata, filteredByIdentifier: .commonIdentifierTitle).first?.stringValue
                let detail = title.flatMap { details[$0] }
                return TrackLabel.Option(displayName: option.displayName, language: option.extendedLanguageTag ?? option.locale?.identifier,
                                         title: detail?.title ?? title, format: detail?.format)
            })
            names = Dictionary(zip(options, labels)) { first, _ in first }
        }
        func name(_ option: AVMediaSelectionOption) -> String { names[option] ?? option.displayName }
    }
    private(set) var audio: Group?
    private(set) var legible: Group?
    /// Bumped by a selection, so the menus show the new choice.
    private var revision = 0
    @ObservationIgnored private weak var item: AVPlayerItem?

    func load(_ item: AVPlayerItem?) async {
        self.item = item; audio = nil; legible = nil
        guard let item else { return }
        let asset = item.asset
        let audible = try? await asset.loadMediaSelectionGroup(for: .audible)
        let subtitles = try? await asset.loadMediaSelectionGroup(for: .legible)
        guard !Task.isCancelled, self.item === item else { return }
        // A repackaged file's tracks: their titles and formats, which the options don't carry.
        let details = (asset as? AVURLAsset).map { Remux.trackDetails($0.url) } ?? (audio: [:], subtitles: [:])
        audio = audible.map { Group(group: $0, options: $0.options, details: details.audio) }
        // Forced subtitles only translate foreign speech and come on by themselves; they aren't a choice.
        legible = subtitles.map { group in
            Group(group: group, options: group.options.filter { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }, details: details.subtitles)
        }
    }

    func selected(in group: Group) -> AVMediaSelectionOption? {
        _ = revision
        return item?.currentMediaSelection.selectedMediaOption(in: group.group)
    }

    func select(_ option: AVMediaSelectionOption?, in group: Group) {
        item?.select(option, in: group.group)
        revision += 1
    }
}

/// The video on the Lock Screen, in Control Center and on headphones, with play, pause, skip and scrub: AVKit's
/// own player published these by itself. Music holds Now Playing only while no video plays (MusicRemoteControl).
@MainActor final class VideoNowPlaying {
    private var targets: [(MPRemoteCommand, Any)] = []

    func start(_ session: PlaybackSession) {
        guard targets.isEmpty else { return }
        let commands = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ action: @escaping @MainActor (PlaybackSession, MPRemoteCommandEvent) -> Void) {
            command.isEnabled = true
            let target = command.addTarget { [weak self, weak session] event in
                MainActor.assumeIsolated {
                    guard let session else { return .noActionableNowPlayingItem }
                    action(session, event)
                    self?.update(title: nil, session: session)
                    return .success
                }
            }
            targets.append((command, target))
        }
        on(commands.playCommand) { session, _ in if session.paused { session.togglePlayback() } }
        on(commands.pauseCommand) { session, _ in session.player.pause() }
        on(commands.togglePlayPauseCommand) { session, _ in session.togglePlayback() }
        commands.skipForwardCommand.preferredIntervals = [10]
        commands.skipBackwardCommand.preferredIntervals = [10]
        on(commands.skipForwardCommand) { session, _ in session.skip(10) }
        on(commands.skipBackwardCommand) { session, _ in session.skip(-10) }
        on(commands.changePlaybackPositionCommand) { session, event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return }
            session.player.seek(to: CMTime(seconds: event.positionTime, preferredTimescale: 600))
        }
    }

    private var title = ""
    private var artworkSource: PlaybackArtwork?
    private var artwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?

    /// The video's poster beside its title, loaded once per poster; none until it has loaded.
    func show(_ source: PlaybackArtwork, session: PlaybackSession) {
        guard source != artworkSource else { return }
        artworkSource = source; artwork = nil
        artworkTask?.cancel()
        guard let url = source.poster else { return }
        artworkTask = Task { [weak self, weak session] in
            guard let bitmap = await PosterPalette.image(url, headers: source.headers), !Task.isCancelled,
                  let self, let session, self.artworkSource == source else { return }
            self.artwork = Self.artwork(UIImage(cgImage: bitmap))
            self.update(title: nil, session: session)
        }
    }

    /// MediaPlayer asks for the image on its own queue: a closure made on the main actor would
    /// trap there, checking it runs on the main thread.
    private nonisolated static func artwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    /// `title` nil keeps the one shown.
    func update(title: String?, session: PlaybackSession) {
        guard !targets.isEmpty else { return }
        if let title { self.title = title }
        let player = session.player, seekable = session.hasTimeline && !session.isLive
        let commands = MPRemoteCommandCenter.shared()
        for command in [commands.skipForwardCommand, commands.skipBackwardCommand, commands.changePlaybackPositionCommand] {
            command.isEnabled = seekable
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: self.title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: session.isLive,
            MPNowPlayingInfoPropertyPlaybackRate: session.paused ? 0.0 : Double(session.boost ?? player.defaultRate),
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(player.defaultRate),
        ]
        let elapsed = player.currentTime().seconds
        if elapsed.isFinite { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed }
        if seekable, let duration = player.currentItem?.duration.seconds, duration.isFinite {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = session.paused ? .paused : .playing
    }

    func stop() {
        for (command, target) in targets { command.removeTarget(target) }
        targets = []
        artworkTask?.cancel(); artworkTask = nil; artworkSource = nil; artwork = nil
        // Music may already have taken Now Playing back as the player closed.
        let center = MPNowPlayingInfoCenter.default()
        if center.nowPlayingInfo?[MPNowPlayingInfoPropertyMediaType] as? UInt == MPNowPlayingInfoMediaType.video.rawValue {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
        }
    }
}

/// The lock button: the round chrome button while the controls show, a capsule with its words once locked.
private struct LockButtonStyle: ViewModifier {
    let locked: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if locked {
            content.buttonStyle(.plain)
                .padding(.horizontal, 14).frame(height: 44)
                .glassSurface(.regular.interactive(), in: Capsule())
                .contentShape(Capsule())
        } else {
            content.chromeButton()
        }
    }
}

/// The brightness the viewer slid to in the player, put on again in the next video (#1174), until the app goes to the
/// background: the system puts its own back then, and a later sitting starts from that. Leaving the player still puts
/// the screen's own brightness back.
@MainActor enum PlayerBrightness {
    private(set) static var chosen: CGFloat?
    private static var observer: NSObjectProtocol?

    static func choose(_ value: Double) {
        chosen = CGFloat(value)
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { chosen = nil }
        }
    }
}
#endif

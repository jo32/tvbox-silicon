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
    @State private var pip = PictureInPicture()
    @State private var clock = PlayerClock()
    @State private var tracks = MediaTracks()
    @State private var nowPlaying = VideoNowPlaying()
    @State private var fillsScreen = false
    @State private var speed: Float = 1
    @AppStorage(DanmakuArea.key) private var danmakuArea = DanmakuArea.standard
    @State private var showsDanmakuList = false
    /// Devices with Yingxia open, for the Play On button; and the one the video was sent to.
    @State private var tvBrowser = PlayOnBrowser()
    @State private var playingOn: String?
    /// Touching and holding the picture plays faster while the finger is down, or after sliding down kept it.
    @State private var boost: SpeedBoost?
    @State private var holding = false
    @AppStorage(SpeedBoost.key) private var holdSpeed = SpeedBoost.standard
    @AppStorage(PlaybackInfo.key) private var showsPlaybackInfo = false
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
    @State private var level: (volume: Bool, start: Double, value: Double)?
    @State private var leveling = false
    @State private var levelTask: Task<Void, Never>?
    /// The system's volume slider, on screen only around a slide, which keeps the system's own volume overlay away.
    @State private var systemVolume = MusicVolumeSlider.SystemSlider()
    @State private var mountsVolume = false
    /// The screen's brightness before the first slide changed it, put back when the player closes.
    @State private var brightnessBefore: CGFloat?

    var body: some View {
        ZStack {
            PlayerLayerView(player: session.player, fills: fillsScreen, pip: pip).playerBleed(!inline)
            // The enhanced picture covers the layer's own, under everything else.
            EnhancedVideoSurface(enhancer: session.enhancer, fills: fillsScreen, bleeds: !inline)
            if showsDanmaku && !session.danmaku.isEmpty {
                DanmakuOverlay(player: session.player, comments: session.danmaku, opacity: session.danmakuOpacity, revision: session.danmakuRevision)
                    // Across the whole width, but below the Dynamic Island and above the home indicator when upright.
                    .playerBleed(!inline, edges: .horizontal)
            }
            // The artwork dissolves into the first frame.
            if let waiting {
                if inline {
                    // On a watch page: the cover across the player, blurred, as before it started; the full-screen
                    // player keeps its own wait.
                    Group {
                        if waiting.starting { WatchCoverBackdrop(poster: waiting.artwork.poster, headers: waiting.artwork.headers, loading: session.error == nil) }
                        else { WaitSpinner(status: waiting.state) }
                    }
                    .transition(.opacity)
                } else {
                    waiting.view.playerBleed(true).transition(.opacity)
                }
            }
            if pip.active { pipPlaceholder }
            if playingOn != nil { Color.black.playerBleed(!inline) }
            // A tap on the picture shows or hides the controls; a tap on a control keeps them up (see `rows`).
            // Two taps on a side skip, touching and holding plays faster, and sliding sideways seeks.
            PictureGestures(tap: tapped, hold: held, swipe: swiped, levels: slidesLevels) { wider in
                withAnimation(.easeInOut(duration: 0.25)) { fillsScreen = wider }
            }
            .playerBleed(!inline)
            .accessibilityHidden(true)
            if mountsVolume {
                MusicVolumeSlider.HiddenVolumeView(system: systemVolume).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
            }
            boostLabel
            skippedLabel
            swipeLabel
            levelLabel
            if let playingOn {
                PlayOnPlaceholder(receiver: playingOn) {
                    self.playingOn = nil
                    if session.paused { session.togglePlayback() }
                }
            }
            // The controls take its corner while they show; it comes back with the bare picture.
            if showsPlaybackInfo && session.error == nil && session.showsPicture && !pip.active && playingOn == nil {
                PlaybackInfoPanel(session: session)
                    .padding(inline ? 8 : 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .opacity(chromeVisible ? 0 : 1)
                    .animation(.smooth(duration: 0.25), value: chromeVisible)
            }
            controls.opacity(chromeVisible ? 1 : 0).allowsHitTesting(chromeVisible && !settling)
        }
        .animation(.easeInOut(duration: 0.7), value: waiting == nil)
        .animation(.easeInOut(duration: 0.4), value: waiting?.starting)
        .onAppear {
            clock.attach(session.player)
            speed = session.player.defaultRate
            nowPlaying.start(session)
            nowPlaying.update(title: channel.name, session: session)
            tvBrowser.start()
        }
        .onDisappear {
            clock.detach(); nowPlaying.stop(); tvBrowser.stop()
            if let brightnessBefore { screen?.brightness = brightnessBefore }
        }
        // Played here again (the Lock Screen, say): the other device no longer has it to itself.
        .onChange(of: session.paused) { _, paused in if !paused { playingOn = nil } }
        .onChange(of: nowPlayingState, initial: true) { nowPlaying.update(title: channel.name, session: session) }
        .onChange(of: nowPlayingArtwork, initial: true) { _, artwork in nowPlaying.show(artwork, session: session) }
        // Pausing ends the faster speed in the session; another episode or quality plays at the chosen one.
        .onChange(of: session.boost == nil) { _, ended in if ended { boost = nil } }
        .onChange(of: clock.item) { endBoost() }
        .sensoryFeedback(trigger: boost) { old, new in
            guard let new else { return nil }
            guard let old else { return .impact(weight: .light) }
            return new.locked != old.locked ? .impact(weight: .medium) : new.rate != old.rate ? .selection : nil
        }
        .task(id: clock.item.map(ObjectIdentifier.init)) { await tracks.load(clock.item) }
        .sheet(isPresented: $showsDanmakuList) {
            DanmakuListView(player: session.player, comments: session.danmaku) { showsDanmakuList = false }
                .danmakuListPresentation()
        }
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
        let zone = PictureTaps.zone(x: x, width: width, seekable: seekable && showsTransport && playingOn == nil && !pip.active)
        switch taps.tap(at: ProcessInfo.processInfo.systemUptime, in: zone) {
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

    private var screen: UIScreen? { (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen }

    private func swiped(_ phase: PictureGestures.Swipe) {
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
            let start = volume ? Double(AVAudioSession.sharedInstance().outputVolume) : Double(screen?.brightness ?? 0)
            if !volume, brightnessBefore == nil { brightnessBefore = screen?.brightness }
            levelTask?.cancel()
            if volume { mountsVolume = true }
            level = (volume, start, start)
            leveling = true
            hideChrome()
        case .moved(let moved, let size):
            if let swipeStart {
                clock.scrub(to: PictureSeek.target(from: swipeStart, moved: moved.width, width: size.width, duration: clock.duration))
            } else if leveling, var level {
                level.value = PictureLevel.value(from: level.start, moved: moved.height, height: size.height)
                self.level = level
                if level.volume { systemVolume.set(level.value) } else { screen?.brightness = CGFloat(level.value) }
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

    /// How far a run of double taps skipped, on its side.
    @ViewBuilder private var skippedLabel: some View {
        if let skipped {
            // Glass like the other gesture labels, with the skip buttons' symbol; it bounces on each further tap.
            VStack(spacing: 4) {
                Image(systemName: skipped.forward ? "goforward.10" : "gobackward.10")
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

    // MARK: Touch and hold

    /// Only while a video with a timeline plays here.
    private var boosts: Bool { showsTransport && seekable && !session.paused && playingOn == nil && !pip.active }

    private func held(_ phase: PictureGestures.Hold) {
        switch phase {
        case .began:
            guard boosts else { return }
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
        boost = nil; holding = false
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
                        Image(systemName: "forward.fill")
                    }
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glassSurface(.regular, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .allowsHitTesting(boost.locked)
                .accessibilityLabel(L10n.text("Back to Normal Speed"))
                .accessibilityValue(Self.speedLabel(rate))
                .accessibilityIdentifier("player.boost")
                if holding && !boost.locked {
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
                if showsTransport { bottomRow }
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
                    .chromeButton()
                    .accessibilityLabel(L10n.text("Back"))
                    .accessibilityIdentifier("player.close")
                Spacer(minLength: 0)
                toolbar
                optionsMenu
            }
            .simultaneousGesture(TapGesture().onEnded { poke() })
        } else {
            screenTopRow
        }
    }

    private var screenTopRow: some View {
        PlayerTopBar {
            Button(action: close) { Image(systemName: "chevron.backward").font(.headline).frame(width: 22, height: 22) }
                .chromeButton()
                .accessibilityLabel(L10n.text("Back"))
                .accessibilityIdentifier("player.close")
                .keyboardShortcut(.cancelAction)
            Text(channel.name).font(.headline).lineLimit(1)
                .shadow(color: .black.opacity(0.6), radius: 4)
            HStack(spacing: 10) { toolbar; optionsMenu }
        }
        .simultaneousGesture(TapGesture().onEnded { poke() })
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            // With Yingxia found on an Apple TV or Mac, one menu holds those and AirPlay.
            if tvBrowser.receivers.isEmpty {
                AirPlayButton()
                    .frame(width: 44, height: 44)
                    .glassSurface(.regular.interactive(), in: Circle())
                    .contentShape(Circle())
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
            // One button for danmaku: show or hide them, or open the list.
            if !session.danmaku.isEmpty {
                Menu {
                    Toggle(isOn: $showsDanmaku) { Label(L10n.text("Show Danmaku"), systemImage: "text.bubble") }
                    Picker(selection: $danmakuArea) {
                        ForEach(DanmakuArea.allCases, id: \.self) { Text($0.title).tag($0) }
                    } label: { Label(L10n.text("Danmaku Area"), systemImage: "rectangle.tophalf.inset.filled") }
                    .pickerStyle(.menu)
                    Button { showsDanmakuList = true } label: { Label(L10n.text("Danmaku List"), systemImage: "list.bullet.rectangle") }
                } label: {
                    Image(systemName: showsDanmaku ? "text.bubble.fill" : "text.bubble").font(.headline).frame(width: 22, height: 22)
                }
                .chromeButton()
                .accessibilityLabel(L10n.text("Danmaku"))
            }
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
                        ForEach(audio.options, id: \.self) { Text($0.displayName).tag(Optional($0)) }
                    }
                    .pickerStyle(.inline)
                }
            }
            if let legible = tracks.legible, !legible.options.isEmpty {
                Menu(L10n.text("Subtitles")) {
                    Picker(L10n.text("Subtitles"), selection: Binding(get: { tracks.selected(in: legible) }, set: { tracks.select($0, in: legible) })) {
                        if legible.group.allowsEmptySelection { Text(L10n.text("Off")).tag(AVMediaSelectionOption?.none) }
                        ForEach(legible.options, id: \.self) { Text($0.displayName).tag(Optional($0)) }
                    }
                    .pickerStyle(.inline)
                }
            }
            if !session.isLive {
                Menu(L10n.text("Playback Speed")) {
                    Picker(L10n.text("Playback Speed"), selection: Binding(get: { speed }, set: { speed = $0; session.setSpeed($0) })) {
                        ForEach(Self.speeds, id: \.self) { Text(Self.speedLabel($0)).tag($0) }
                    }
                    .pickerStyle(.inline)
                }
            }
            Toggle(L10n.text("Fill Screen"), isOn: $fillsScreen)
            Toggle(L10n.text("Show Video Info"), isOn: $showsPlaybackInfo)
        } label: {
            Image(systemName: "slider.horizontal.3").font(.headline).frame(width: 22, height: 22)
                .symbolVariant(pictureSwitches && (upscalesVideo || smoothsVideo) ? .fill : .none)
        }
        .chromeButton()
        // "Playback Options" is the catalog's episode menu beside it.
        .accessibilityLabel(L10n.text("Settings"))
        .accessibilityIdentifier("player.options")
    }

    private static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4]
    private static func speedLabel(_ speed: Float) -> String {
        Double(speed).formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    // MARK: Middle and bottom

    private var centerRow: some View {
        HStack(spacing: 20) {
            if seekable && !inline {
                Button { session.skip(-10); sought() } label: { Image(systemName: "gobackward.10") }
                    .buttonStyle(PlayerCircleStyle(size: 52))
                    .accessibilityLabel(L10n.text("Back 10 seconds"))
            }
            Button { session.togglePlayback() } label: {
                // Swapped as the music player's is.
                Image(systemName: session.paused ? "play.fill" : "pause.fill").contentTransition(.symbolEffect(.replace))
            }
                .buttonStyle(PlayerCircleStyle(size: inline ? 50 : 68))
                .accessibilityLabel(L10n.text(session.paused ? "Play" : "Pause"))
                .accessibilityIdentifier("player.playPause")
            if seekable && !inline {
                Button { session.skip(10); sought() } label: { Image(systemName: "goforward.10") }
                    .buttonStyle(PlayerCircleStyle(size: 52))
                    .accessibilityLabel(L10n.text("Forward 10 seconds"))
            }
        }
        .simultaneousGesture(TapGesture().onEnded { poke() })
    }

    /// Previous and Next Episode, small and at the right of the time above the seek bar. Beside ±10 and play, a tap
    /// that ran past +10 out of habit changed the episode.
    @ViewBuilder private var stepButtons: some View {
        let previous = store.step(back: true, from: channel, session: session)
        let next = store.step(back: false, from: channel, session: session)
        if previous != nil || next != nil || toggleFullScreen != nil {
            HStack(spacing: 10) {
                if let previous {
                    Button { previous.go() } label: { Image(systemName: "backward.end.fill") }
                        .buttonStyle(PlayerCircleStyle(size: 36))
                        .disabled(previous.busy)
                        .accessibilityLabel(L10n.text("Previous Episode"))
                }
                if let next {
                    Button { next.go() } label: { Image(systemName: "forward.end.fill") }
                        .buttonStyle(PlayerCircleStyle(size: 36))
                        .disabled(next.busy)
                        .accessibilityLabel(L10n.text("Next Episode"))
                }
                if let toggleFullScreen {
                    let full = layout == .pageFullScreen
                    Button(action: toggleFullScreen) {
                        Image(systemName: full ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(PlayerCircleStyle(size: 36))
                    .accessibilityLabel(L10n.text(full ? "Exit Full Screen" : "Full Screen"))
                    .accessibilityIdentifier("player.fullScreen")
                }
            }
            .simultaneousGesture(TapGesture().onEnded { poke() })
        }
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
struct WatchCoverBackdrop: View {
    let poster: URL?
    var headers: [String: String] = [:]
    var loading = true
    /// What the wait has to say, by how long it has run (see `WaitSpinner`).
    var status: (@MainActor (TimeInterval) -> PlaybackWait)? = nil
    var body: some View {
        ZStack {
            Color.black
            PosterImage(url: poster, headers: headers)
                .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                .blur(radius: 24).scaleEffect(1.2)
                .overlay(Color.black.opacity(0.35))
                .accessibilityHidden(true)
            if loading { WaitSpinner(status: status) }
        }
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
            ProgressView().controlSize(.large).tint(.white)
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
    /// where reaching into the safe area would run the picture under the status bar.
    @ViewBuilder func playerBleed(_ bleeds: Bool, edges: Edge.Set = .all) -> some View {
        if bleeds { ignoresSafeArea(edges: edges) } else { self }
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
        // Every display frame while it plays, as AVKit's bar does; paused, held or hidden, only when the clock changes.
        let follows = moving && clock.scrubbing == nil
        TimelineView(.animation(paused: !follows)) { _ in
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

    private func bar(_ position: Double) -> some View {
        let duration = clock.duration
        let value = min(max(0, position), duration)
        let x = duration > 0 ? width * value / duration : 0
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
                Capsule().fill(.white.opacity(0.3)).frame(height: held ? 6 : 4)
                Capsule().fill(.white).frame(width: max(0, x), height: held ? 6 : 4)
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
                .onEnded { _ in ended() })
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
            clock.seek(to: min(max(0, value + (direction == .increment ? 10 : -10)), duration))
            sought()
        }
    }

    private func changed(_ gesture: DragGesture.Value, value: Double, duration: Double) {
        guard duration > 0, width > 0 else { return }
        if drag == nil {
            let handle = width * value / duration
            let start = abs(gesture.startLocation.x - handle) <= 30 ? value : duration * Double(min(max(0, gesture.startLocation.x / width), 1))
            drag = (start, gesture.startLocation)
            hold(true)
            clock.scrub(to: start)
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
        clock.scrub(to: min(max(0, begin.position + moved), duration))
    }

    private func ended() {
        guard drag != nil else { return }
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
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .glassSurface(.regular.interactive(), in: Circle())
            .contentShape(Circle())
            .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.38)
            // Gives under the finger, so a tap shows before the player answers.
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

/// The system's AirPlay button, which presents the route picker itself.
private struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = true
        view.tintColor = .white
        return view
    }
    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
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

/// The picture in an AVPlayerLayer, which Picture in Picture takes over while it runs.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    let fills: Bool
    let pip: PictureInPicture
    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.player = player
        pip.attach(view.playerLayer)
        return view
    }
    func updateUIView(_ view: LayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        view.playerLayer.videoGravity = fills ? .resizeAspectFill : .resizeAspect
    }
}

/// Picture in Picture for the player layer: the button, and carrying on in a floating window when the app is left.
@MainActor @Observable final class PictureInPicture: NSObject, AVPictureInPictureControllerDelegate {
    let supported = AVPictureInPictureController.isPictureInPictureSupported()
    private(set) var possible = false
    private(set) var active = false
    @ObservationIgnored private var controller: AVPictureInPictureController?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    func attach(_ layer: AVPlayerLayer) {
        guard supported, controller == nil else { return }
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

    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor [weak self] in self?.active = true }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor [weak self] in self?.active = false }
    }
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        let detail = Diagnostics.describe(error)
        Task { @MainActor in Diagnostics.shared.record(.warning, "player", "Picture in Picture failed: \(detail)") }
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
    @ObservationIgnored private weak var player: AVPlayer?
    @ObservationIgnored private var token: Any?

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

    /// While dragging, only the bar, the time and the preview follow the finger; the playing video is left alone
    /// until the finger lifts (Telegram).
    func scrub(to seconds: Double) {
        scrubbing = seconds
        nextPreview = seconds
        makePreview()
    }

    /// Let go: one exact seek to where the finger stopped.
    func endScrub() {
        nextPreview = nil
        preview = nil
        if let target = scrubbing { seek(to: target) }
    }

    /// An exact seek; the bar stays at the target until it lands, rather than jumping back to the old position.
    func seek(to seconds: Double) {
        guard let player else { scrubbing = nil; return }
        scrubbing = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.scrubbing == seconds else { return }
                self.position = seconds
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
        if item !== player.currentItem { item = player.currentItem }
        let seconds = time.seconds
        position = seconds.isFinite ? max(0, seconds) : 0
        let length = player.currentItem?.duration.seconds ?? 0
        let finite = length.isFinite ? max(0, length) : 0
        // Observation reports every assignment, even of the same value; the duration rarely changes.
        if finite != duration { duration = finite }
    }
}

/// The item's audio tracks and subtitles, for the options menu.
@MainActor @Observable final class MediaTracks {
    struct Group {
        let group: AVMediaSelectionGroup
        let options: [AVMediaSelectionOption]
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
        audio = audible.map { Group(group: $0, options: $0.options) }
        // Forced subtitles only translate foreign speech and come on by themselves; they aren't a choice.
        legible = subtitles.map { group in
            Group(group: group, options: group.options.filter { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) })
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
#endif

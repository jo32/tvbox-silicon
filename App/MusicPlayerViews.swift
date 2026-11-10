import SwiftUI
import TVCore
import UniformTypeIdentifiers

extension View {
    /// The music player panel under a page, while a song is loaded.
    func musicPlayerInset() -> some View { modifier(MusicPlayerInset()) }
}

private struct MusicPlayerInset: ViewModifier {
    @Environment(Store.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass
    func body(content: Content) -> some View {
        #if os(tvOS) || os(macOS)
        // The remote could only reach a bottom panel through every result above it; Apple TV has
        // the Now Playing card at the top of the page and the full-screen player instead. The Mac's
        // bar floats over every page (`MusicMacBar`, in RootView).
        content
        #else
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if store.music.showsStrip(videoPlaying: store.playing != nil) {
                #if os(iOS)
                if sizeClass == .compact {
                    // A phone has Music's strip: in the tab bar's accessory slot where the system has
                    // one (it is drawn there, not here), otherwise floating just above the bar.
                    if !MusicAccessory.used(compact: true) {
                        MusicMiniPlayer().frame(height: 56)
                            .glassSurface(.regular.interactive(), in: Capsule())
                            .padding(.horizontal, Layout.gutter).padding(.bottom, 8)
                    }
                } else {
                    MusicNowPlaying().padding(.horizontal, Layout.gutter).padding(.bottom, 10)
                }
                #else
                MusicNowPlaying().padding(.horizontal, Layout.gutter).padding(.bottom, 10)
                #endif
            }
        }
        #endif
    }
}

/// A spinner while a channel is found, bars while sound plays.
/// In a fixed square: the symbols differ in width, and a row would shift as they change.
struct MusicActivityMark: View {
    @Environment(Store.self) private var store
    var body: some View {
        Group {
            if store.music.busy { ProgressView().appControlSize(.small) }
            else if store.music.phase == .playing { Image(systemName: "waveform").foregroundStyle(Brand.accent).symbolEffect(.variableColor.iterative) }
            else if store.music.failure != nil { Image(systemName: "exclamationmark.circle").foregroundStyle(Brand.amber) }
            else { Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary) }
        }
        .frame(width: 24, height: 24)
    }
}

enum MusicTime {
    static func text(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        let total = Int(max(0, seconds).rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The player panel: the song, the line being sung, progress, the format actually read, controls.
struct MusicNowPlaying: View {
    @Environment(Store.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showsChannels = false
    @State private var showsLyrics = false
    @State private var scrubbing: Double?
    #if os(tvOS)
    private let art: CGFloat = 96
    #else
    private let art: CGFloat = 52
    #endif

    var body: some View {
        let music = store.music
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Button {
                    #if os(macOS)
                    showsLyrics = true
                    #else
                    // Apple TV's full-screen player; the Now Playing screen on iPad.
                    music.presentsPlayer = true
                    #endif
                } label: {
                    HStack(spacing: 14) {
                        MusicArtwork(url: music.track?.artwork, size: art)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(music.track?.title ?? "").font(.headline).lineLimit(1)
                            Text([music.track?.artistLine, music.queue.flatMap(queueLine)].compactMap { $0 }.joined(separator: " · "))
                                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                #if os(tvOS)
                .buttonStyle(.plain)
                #else
                .buttonStyle(.plain)
                #endif
                .accessibilityHint(L10n.text("Lyrics"))
                Spacer(minLength: 8)
                if compact { extras(music) } else { controls(music) }
            }
            lyricLine(music)
            progress(music)
            // A phone gives the title its width and the playback controls a row of their own.
            if compact { controls(music).frame(maxWidth: .infinity) }
            // Its own full-width line, so the format is never cut short beside the controls.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { status(music); Spacer(minLength: 0); source(music) }
                VStack(alignment: .leading, spacing: 4) { status(music); source(music) }
            }
        }
        .padding(14)
        .contentPanel(cornerRadius: 20)
        .frame(maxWidth: Layout.maxWidth)
        .frame(maxWidth: .infinity)
        .tvFocusSection()
        .sheet(isPresented: $showsChannels) { MusicChannelsView() }
        .sheet(isPresented: $showsLyrics) { MusicLyricsView() }
        #if DEBUG
        // `-qaMusicLyrics 1` opens the lyrics once they load, for screenshots.
        .onChange(of: music.lyrics) { _, lyrics in
            if lyrics != nil, UserDefaults.standard.bool(forKey: "qaMusicLyrics") { showsLyrics = true }
        }
        #endif
    }

    private func queueLine(_ queue: MusicQueue) -> String? {
        queue.tracks.count > 1 ? "\(queue.index + 1)/\(queue.tracks.count)" : nil
    }

    /// The line being sung, shown as it changes.
    @ViewBuilder private func lyricLine(_ music: MusicPlaybackSession) -> some View {
        if let lyrics = music.lyrics, lyrics.synced, let index = music.currentLyric, !lyrics.lines[index].text.isEmpty {
            Button { showsLyrics = true } label: {
                Text(lyrics.lines[index].text)
                    .font(.subheadline.weight(.medium)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(index)
                    .transition(.opacity)
            }
            .buttonStyle(.plain)
            .animation(.easeInOut(duration: 0.25), value: index)
        }
    }

    @ViewBuilder private func status(_ music: MusicPlaybackSession) -> some View {
        Group {
            if let notice = music.notice, music.busy {
                Text(notice).foregroundStyle(Brand.amber)
            } else {
                switch music.phase {
                case .resolving: Text(L10n.text("Finding the best channel…")).foregroundStyle(.secondary)
                case .failed(let message): Text(message).foregroundStyle(Brand.amber)
                default:
                    if let selection = music.selection {
                        HStack(spacing: 6) {
                            Text(selection.probe.format.codec == .unknown ? L10n.text("Quality to be confirmed") : selection.probe.format.label)
                            if selection.degraded { Text("· " + L10n.text("Lossy quality")).foregroundStyle(Brand.amber) }
                            if selection.probe.completeness == .unknown { Text("· " + L10n.text("Length unconfirmed")) }
                        }
                        .foregroundStyle(.secondary)
                    } else {
                        Text(L10n.text("Quality to be confirmed")).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .font(.caption.weight(.medium)).monospacedDigit().lineLimit(2)
    }

    @ViewBuilder private func source(_ music: MusicPlaybackSession) -> some View {
        // Both services ask to be named when their audio plays.
        if music.failure == nil, let provider = music.selection?.candidate.provider {
            if provider == .gdstudio {
                Text(L10n.text("Source: GD Music (music.gdstudio.xyz)")).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            } else if provider == .xinghai {
                Text(L10n.text("Source: Xinghai (yy.zddyr.top)")).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
    }

    private var compact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    @ViewBuilder private func controls(_ music: MusicPlaybackSession) -> some View {
        let inQueue = (music.queue?.tracks.count ?? 0) > 1
        HStack(spacing: 8) {
            if inQueue {
                Button { music.previous() } label: { Image(systemName: "backward.fill") }
                    .controlButton().accessibilityLabel(L10n.text("Previous"))
            }
            #if os(tvOS)
            if !inQueue {
                Button { music.skip(by: -15) } label: { Image(systemName: "gobackward.15") }
                    .controlButton().accessibilityLabel(L10n.text("Back 15 Seconds"))
            }
            #endif
            if music.failure != nil {
                Button { music.retry() } label: { Image(systemName: "arrow.clockwise").frame(width: 22) }
                    .controlButton(prominent: true).accessibilityLabel(L10n.text("Retry"))
            } else {
                Button { music.toggle() } label: { Image(systemName: music.isPlaying ? "pause.fill" : "play.fill").frame(width: 22) }
                    .controlButton(prominent: true).disabled(music.phase == .resolving)
                    .accessibilityLabel(L10n.text(music.isPlaying ? "Pause" : "Play"))
            }
            if inQueue {
                Button { music.next() } label: { Image(systemName: "forward.fill") }
                    .controlButton().disabled(music.queue?.hasNext != true).accessibilityLabel(L10n.text("Next"))
            }
            #if os(tvOS)
            if !inQueue {
                Button { music.skip(by: 15) } label: { Image(systemName: "goforward.15") }
                    .controlButton().accessibilityLabel(L10n.text("Forward 15 Seconds"))
            }
            #endif
            if !compact {
                Button { showsLyrics = true } label: { Image(systemName: "quote.bubble") }
                    .controlButton().accessibilityLabel(L10n.text("Lyrics"))
                if music.sourceStream != nil {
                    Button { music.openInVideoPlayer() } label: { Image(systemName: "play.rectangle") }
                        .controlButton().accessibilityLabel(L10n.text("Open in Video Player"))
                } else {
                    Button { showsChannels = true } label: { Image(systemName: "antenna.radiowaves.left.and.right") }
                        .controlButton().accessibilityLabel(L10n.text("Channels"))
                }
                Button { music.stop() } label: { Image(systemName: "xmark") }
                    .controlButton().accessibilityLabel(L10n.text("Stop"))
            }
        }
        .labelStyle(.iconOnly)
    }

    /// On a phone: lyrics, channels and Stop behind one button beside the title.
    private func extras(_ music: MusicPlaybackSession) -> some View {
        Menu {
            Button { showsLyrics = true } label: { Label(L10n.text("Lyrics"), systemImage: "quote.bubble") }
            if music.sourceStream != nil {
                Button { music.openInVideoPlayer() } label: { Label(L10n.text("Open in Video Player"), systemImage: "play.rectangle") }
            } else {
                Button { showsChannels = true } label: { Label(L10n.text("Channels"), systemImage: "antenna.radiowaves.left.and.right") }
            }
            if let track = music.track { MusicDownloadMenuItems(tracks: [track]) }
            Button(role: .destructive) { music.stop() } label: { Label(L10n.text("Stop"), systemImage: "xmark") }
        } label: { Image(systemName: "ellipsis") }
            .controlButton().accessibilityLabel(L10n.text("More"))
    }

    @ViewBuilder private func progress(_ music: MusicPlaybackSession) -> some View {
        let total = max(music.duration ?? 0, 1)
        HStack(spacing: 10) {
            Text(MusicTime.text(scrubbing ?? music.seekingTo ?? music.position)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            #if os(tvOS)
            ProgressView(value: min(music.seekingTo ?? music.position, total), total: total).tint(Brand.accent)
            #else
            // While dragging the thumb follows the pointer; on release it stays at the target, since
            // the session holds its position there until the seek lands.
            Slider(value: Binding(get: { scrubbing ?? min(music.seekingTo ?? music.position, total) }, set: { scrubbing = $0 }), in: 0...total) { editing in
                if !editing, let target = scrubbing { music.seek(to: target); scrubbing = nil }
            }
            .tint(Brand.accent)
            .transaction { $0.animation = nil }
            .disabled(!music.hasStream || music.duration == nil)
            #endif
            Text(music.duration.map(MusicTime.text) ?? "--:--").font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

/// The song's lyrics, following playback: the line being sung is highlighted and kept in view,
/// with its translation under it. Tapping a line plays from there.
struct MusicLyricsView: View {
    @Environment(Store.self) private var store
    #if os(tvOS)
    private let size: CGFloat = 38, translationSize: CGFloat = 26
    #else
    private let size: CGFloat = 22, translationSize: CGFloat = 15
    #endif

    var body: some View {
        let music = store.music
        MusicSheet(title: music.track?.title ?? L10n.text("Lyrics"), symbol: "quote.bubble") {
            VStack(spacing: 0) {
            Group {
                if let lyrics = music.lyrics {
                    lines(lyrics, current: music.currentLyric)
                } else if music.lyricsLoading || music.busy {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EmptyResults(symbol: "quote.bubble", title: L10n.text("No Lyrics"), message: L10n.text("Neither catalog has lyrics for this song."), fills: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
                if music.lyrics?.synced == true {
                    Divider()
                    MusicLyricsTiming().padding(.vertical, 10)
                }
            }
        }
    }

    private func lines(_ lyrics: MusicLyrics, current: Int?) -> some View {
        MusicLyricLines(lyrics: lyrics, current: current, size: size, translationSize: translationSize)
    }
}

/// The lines themselves. The line being sung is kept in the middle through the scroll view's
/// own position binding; scrolling by hand works, and the next line brings the view back.
struct MusicLyricLines: View {
    @Environment(Store.self) private var store
    let lyrics: MusicLyrics
    let current: Int?
    let size: CGFloat
    let translationSize: CGFloat
    @State private var scrolled: Int?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: size * 0.8) {
                ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                    let active = lyrics.synced && index == current
                    VStack(alignment: .leading, spacing: 4) {
                        #if os(tvOS)
                        // As Music on Apple TV: every line bold and white, the others faded.
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.system(size: size, weight: .bold))
                            .foregroundStyle(.white.opacity(active || !lyrics.synced ? 1 : 0.32))
                        if let translation = line.translation {
                            Text(translation).font(.system(size: translationSize, weight: .semibold)).foregroundStyle(.white.opacity(active ? 0.7 : 0.25))
                        }
                        #else
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.system(size: size, weight: active ? .bold : .semibold))
                            .foregroundStyle(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary.opacity(lyrics.synced ? 0.6 : 1)))
                        if let translation = line.translation {
                            Text(translation).font(.system(size: translationSize)).foregroundStyle(active ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                        }
                        #endif
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .scaleEffect(active ? 1.03 : 1, anchor: .leading)
                    .animation(.easeOut(duration: 0.25), value: active)
                    .contentShape(Rectangle())
                    #if !os(tvOS)
                    .onTapGesture { if lyrics.synced { store.music.seek(toLyric: line) } }
                    #endif
                    .id(index)
                }
                Text(L10n.text("Lyrics from %@", lyrics.platform.name)).font(.caption).foregroundStyle(.tertiary).padding(.top, 12)
            }
            .scrollTargetLayout()
            .padding(.horizontal, Layout.gutter * 1.5).padding(.vertical, 40)
        }
        .scrollPosition(id: $scrolled, anchor: .center)
        // Once the lines are laid out: set as the view appeared, the position was dropped, and
        // reopening the player left the lyrics at the top until the next line.
        .task { try? await Task.sleep(for: .milliseconds(60)); scrolled = current }
        .onChange(of: current) { _, index in
            guard let index else { return }
            withAnimation(.smooth(duration: 0.45)) { scrolled = index }
        }
    }
}

/// Every channel tried for the song, what each served, and a way to switch.
struct MusicChannelsView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let music = store.music
        MusicSheet(title: L10n.text("Channels"), symbol: "antenna.radiowaves.left.and.right") {
            List {
                Section {
                    ForEach(Self.rows(music), id: \.candidate.id) { row in
                        let current = row.candidate == music.selection?.candidate && music.failure == nil
                        Button {
                            music.choose(row.candidate); dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: current ? "speaker.wave.2.fill" : row.symbol)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(current ? Brand.accent : row.tint)
                                    .frame(width: 26)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(row.candidate.name).font(.body.weight(.medium))
                                    Text(row.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if current { Image(systemName: "checkmark").foregroundStyle(Brand.accent) }
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .glassRow()
                        .disabled(current)
                    }
                } footer: {
                    Text(L10n.text("The quality shown is read from the audio itself, not taken from what a channel claims."))
                }
            }
        }
    }

    struct Row {
        var candidate: MusicCandidate
        var detail: String
        var symbol: String
        var tint: Color
    }

    static func rows(_ music: MusicPlaybackSession) -> [Row] {
        var rows = music.attempts.map { attempt in
            switch attempt.outcome {
            case .playable(let probe):
                var detail = probe.format.label
                if probe.completeness == .unknown { detail += " · " + L10n.text("Length unconfirmed") }
                return Row(candidate: attempt.candidate, detail: detail, symbol: probe.format.isLossless ? "waveform" : "waveform.badge.minus", tint: .secondary)
            case .failed(let error):
                return Row(candidate: attempt.candidate, detail: error.localizedDescription, symbol: "exclamationmark.triangle.fill", tint: Brand.amber)
            case .skipped:
                return Row(candidate: attempt.candidate, detail: L10n.text("Not tried yet"), symbol: "circle.dashed", tint: .secondary)
            }
        }
        for candidate in music.selection?.untried ?? [] where !rows.contains(where: { $0.candidate == candidate }) {
            rows.append(Row(candidate: candidate, detail: L10n.text("Not tried yet"), symbol: "circle.dashed", tint: .secondary))
        }
        return rows
    }
}

/// Quality preference and the channels to use.
struct MusicSettingsView: View {
    @Environment(Store.self) private var store

    /// Each channel and the services it plays from.
    private static var channels: [(MusicProviderID, String)] {
        [(.migu, L10n.text("Migu Music")),
         (.nianxin, L10n.text("Kuwo Music and NetEase Cloud Music")),
         (.vkeys, L10n.text("QQ Music")),
         (.gdstudio, L10n.text("NetEase Cloud Music")),
         (.xinghai, L10n.text("Kuwo Music and NetEase Cloud Music, when the others fail")),
         (.hyw, L10n.text("QQ Music, when VKeys fails"))]
    }
    private static var qualityNote: String {
        L10n.text("Lossless first plays the best lossy stream, marked as such, when no channel has lossless audio. Lossless only stops instead.")
    }
    private static var channelNotes: [String] {
        [L10n.text("HYW stays off until you enter the key from its published script. GD Music (music.gdstudio.xyz) is for personal, non-commercial use and allows 50 requests every 5 minutes."),
         L10n.text("Xinghai (yy.zddyr.top) asks to be credited and not overused, so it is only asked when the other channels fail.")]
    }

    var body: some View {
        @Bindable var music = store.music
        #if os(tvOS)
        // A page like Settings' own, over the whole screen: a tvOS sheet is a small card that cut the
        // channels off. Quality steps through its choices; Menu closes the page.
        TVSettingsSubpage(symbol: "slider.horizontal.3", title: L10n.text("Music Settings")) {
            TVSettingsSection(footer: Self.qualityNote) {
                TVSettingsAction(title: L10n.text("Audio Quality"), value: music.preferences.quality.name) {
                    let choices = MusicQualityPreference.allCases
                    music.preferences.quality = choices[((choices.firstIndex(of: music.preferences.quality) ?? 0) + 1) % choices.count]
                }
            }
            TVSettingsSection(title: L10n.text("Channels"), footer: Self.channelNotes.joined(separator: "\n\n")) {
                ForEach(Self.channels, id: \.0) { provider, detail in
                    TVSettingsToggle(title: provider.name, detail: detail, isOn: enabled(provider, music: music))
                }
                TVSettingsField(title: L10n.text("HYW key"), text: $music.preferences.hywKey)
            }
            MusicLXSourcesSection()
            MusicExtensionsSection()
        }
        #else
        MusicSheet(title: L10n.text("Music Settings"), symbol: "slider.horizontal.3") {
            Form {
                Section {
                    Picker(L10n.text("Audio Quality"), selection: $music.preferences.quality) {
                        ForEach(MusicQualityPreference.allCases, id: \.self) { Text($0.name).tag($0) }
                    }
                } footer: {
                    Text(Self.qualityNote)
                }
                Section {
                    ForEach(Self.channels, id: \.0) { provider, detail in
                        Toggle(isOn: enabled(provider, music: music)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.name)
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .settingsSwitch()
                    }
                    TextField(L10n.text("HYW key"), text: $music.preferences.hywKey)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                } header: {
                    Text(L10n.text("Channels"))
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Self.channelNotes, id: \.self) { Text($0) }
                    }
                }
                MusicLXSourcesSection()
                MusicExtensionsSection()
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
        }
        #endif
    }

    private func enabled(_ provider: MusicProviderID, music: MusicPlaybackSession) -> Binding<Bool> {
        Binding(get: { !music.preferences.disabled.contains(provider) }, set: { on in
            if on { music.preferences.disabled.remove(provider) } else { music.preferences.disabled.insert(provider) }
        })
    }
}

/// A sheet's frame: on the Mac a header with the sheet's symbol, title and Done, since a navigation
/// bar in a Mac sheet is an empty strip; elsewhere a titled navigation stack.
private struct MusicSheet<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                IconTile(symbol: symbol, tint: Brand.accent, size: 32)
                Text(title).font(.title3.weight(.semibold)).lineLimit(1)
                Spacer()
                Button(L10n.text("Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Divider()
            content
        }
        .frame(minWidth: 480, minHeight: 420)
        #else
        NavigationStack {
            content
                .navigationTitle(title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { dismiss() } } }
                #endif
        }
        #endif
    }
}

/// Moves the lyrics earlier or later against the audio, in half seconds, remembered per song.
struct MusicLyricsTiming: View {
    @Environment(Store.self) private var store
    var body: some View {
        let music = store.music
        HStack(spacing: 12) {
            Button { music.adjustLyrics(by: -0.5) } label: { Label(L10n.text("Lyrics Later"), systemImage: "minus") }
                .controlButton()
            Text(music.lyricsOffset == 0 ? L10n.text("Lyrics in sync") : String(format: "%+.1f s", music.lyricsOffset))
                .font(.callout.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
                .frame(minWidth: 110)
            Button { music.adjustLyrics(by: 0.5) } label: { Label(L10n.text("Lyrics Earlier"), systemImage: "plus") }
                .controlButton()
            if music.lyricsOffset != 0 {
                Button(L10n.text("Reset")) { music.resetLyricsOffset() }.controlButton()
            }
        }
        .labelStyle(.titleAndIcon)
        .frame(maxWidth: .infinity)
    }
}

#if !os(tvOS)
/// A thin bar that thickens while dragged, with elapsed and remaining time under it, as in Music.
/// The position follows the finger and holds at the target until the seek lands.
struct MusicScrubber: View {
    @Environment(Store.self) private var store
    @State private var dragging: Double?

    var body: some View {
        let music = store.music
        let total = music.duration ?? 0
        let position = dragging.map { $0 * total } ?? min(music.seekingTo ?? music.position, total)
        let fraction = total > 0 ? min(1, max(0, position / total)) : 0
        VStack(spacing: 6) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule().fill(.white.opacity(dragging == nil ? 0.78 : 1)).frame(width: max(0, proxy.size.width * fraction))
                }
                .frame(height: dragging == nil ? 7 : 12)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in if total > 0 { dragging = min(1, max(0, value.location.x / proxy.size.width)) } }
                    .onEnded { _ in
                        if let dragging { music.seek(to: dragging * total) }
                        dragging = nil
                    })
                .animation(.easeOut(duration: 0.15), value: dragging == nil)
            }
            .frame(height: 22)
            HStack {
                Text(MusicTime.text(position))
                Spacer()
                Text(total > 0 ? "-" + MusicTime.text(total - position) : "--:--")
            }
            .font(.caption2.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
        }
        .disabled(!music.hasStream || total == 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("Playback Position"))
        .accessibilityValue(MusicTime.text(position) + " / " + MusicTime.text(total))
        .accessibilityAdjustableAction { direction in
            music.skip(by: direction == .increment ? 10 : -10)
        }
    }
}
#endif

/// The LX Music custom sources in Music Settings: add one by address (or from a file on iPhone, iPad and
/// Mac), turn each on or off, remove it. Adding runs the script once to read which catalogs it covers.
@MainActor @Observable final class MusicLXSourcesModel {
    private(set) var sources: [LXSource] = LXSourceLibrary.shared.sources
    private(set) var busy = false
    var message: String?
    var failed = false

    static var note: String {
        L10n.text("Scripts made for LX Music's custom sources. They are asked for a song's audio after the channels above, for QQ Music, NetEase Cloud Music, Kuwo and Migu songs. Yingxia includes none: add only sources you trust.")
    }

    func add(address text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let url = URL(string: trimmed), url.host() != nil, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            report(TVError.invalidURL); return
        }
        run { try await LXSourceLibrary.shared.add(script: LXSourceLibrary.download(url), origin: url) }
    }

    func add(file: URL) {
        run {
            let scoped = file.startAccessingSecurityScopedResource()
            defer { if scoped { file.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: file)
            guard let script = String(data: data, encoding: .utf8) else { throw TVError.unsupported(L10n.text("This file is not an LX Music source.")) }
            return try await LXSourceLibrary.shared.add(script: script, origin: nil)
        }
    }

    func enabled(_ source: LXSource) -> Binding<Bool> {
        Binding(get: { self.sources.first { $0.id == source.id }?.enabled ?? false }, set: { on in
            LXSourceLibrary.shared.setEnabled(source.id, on)
            self.sources = LXSourceLibrary.shared.sources
        })
    }

    func remove(_ source: LXSource) {
        LXSourceLibrary.shared.remove(source.id)
        sources = LXSourceLibrary.shared.sources
        message = nil
    }

    static func detail(_ source: LXSource) -> String {
        ([source.info.version] + [source.platforms.map(\.name).joined(separator: ", ")]).filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func run(_ work: @escaping @MainActor () async throws -> LXSource) {
        guard !busy else { return }
        busy = true; message = nil; failed = false
        Task {
            do {
                let source = try await work()
                sources = LXSourceLibrary.shared.sources
                message = L10n.text("Added “%@”.", source.info.name)
            } catch { report(error) }
            busy = false
        }
    }

    private func report(_ error: Error) {
        failed = true
        message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

#if os(tvOS)
struct MusicLXSourcesSection: View {
    @State private var model = MusicLXSourcesModel()
    @State private var address = ""
    var body: some View {
        TVSettingsSection(title: L10n.text("LX Music Sources"), footer: [model.message, MusicLXSourcesModel.note].compactMap { $0 }.joined(separator: "\n\n")) {
            ForEach(model.sources) { source in
                TVSettingsToggle(title: source.info.name, detail: MusicLXSourcesModel.detail(source), isOn: model.enabled(source))
                TVSettingsAction(title: L10n.text("Remove “%@”", source.info.name), destructive: true) { model.remove(source) }
            }
            // Apple TV has no files to pick: sources come from an address.
            TVSettingsField(title: L10n.text("Add from Address"), text: $address)
                .disabled(model.busy)
                .onChange(of: address) { _, text in
                    guard !text.isEmpty else { return }
                    model.add(address: text)
                    address = ""
                }
        }
    }
}
#else
struct MusicLXSourcesSection: View {
    @State private var model = MusicLXSourcesModel()
    @State private var address = ""
    @State private var importing = false
    var body: some View {
        Section {
            ForEach(model.sources) { source in
                HStack {
                    Toggle(isOn: model.enabled(source)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.info.name)
                            Text(MusicLXSourcesModel.detail(source)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .settingsSwitch()
                    Button(role: .destructive) { model.remove(source) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(L10n.text("Remove “%@”", source.info.name))
                }
            }
            HStack {
                TextField(L10n.text("Source address"), text: $address)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never).keyboardType(.URL)
                    #endif
                    .onSubmit(add)
                if model.busy { ProgressView().appControlSize(.small) }
                else { Button(L10n.text("Add"), action: add).disabled(address.trimmingCharacters(in: .whitespaces).isEmpty) }
            }
            Button(L10n.text("Add from File…")) { importing = true }.disabled(model.busy)
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(model.failed ? Brand.amber : Color.secondary)
            }
        } header: {
            Text(L10n.text("LX Music Sources"))
        } footer: {
            Text(MusicLXSourcesModel.note)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.javaScript, .plainText, .data]) { result in
            if case .success(let file) = result { model.add(file: file) }
        }
    }

    private func add() {
        model.add(address: address)
        address = ""
    }
}
#endif

/// The music extensions in Music Settings (Listenify-format scripts such as allfm.js): add one by address (or
/// from a file on iPhone, iPad and Mac), turn each on or off, remove it. Their lists show on the Music page,
/// which reloads their shelves after a change; their songs show in Music search.
@MainActor @Observable final class MusicExtensionsModel {
    private(set) var items: [MusicExtension] = MusicExtensionLibrary.shared.extensions
    private(set) var busy = false
    var message: String?
    var failed = false
    /// Called after a change, to refresh the Music page's shelves.
    var changed: () -> Void = {}

    static var note: String {
        L10n.text("Scripts in the Listenify music extension format. Their charts and playlists show on the Music page and their songs in Music search; songs play from what the extension gives, or through your LX Music sources when it asks for one. Yingxia includes none: add only extensions you trust.")
    }

    func add(address text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let url = URL(string: trimmed), url.host() != nil, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            report(TVError.invalidURL); return
        }
        run { try await MusicExtensionLibrary.shared.add(script: MusicExtensionLibrary.download(url), origin: url) }
    }

    func add(file: URL) {
        run {
            let scoped = file.startAccessingSecurityScopedResource()
            defer { if scoped { file.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: file)
            guard let script = String(data: data, encoding: .utf8) else { throw TVError.unsupported(L10n.text("This file is not a music extension.")) }
            return try await MusicExtensionLibrary.shared.add(script: script, origin: nil)
        }
    }

    func enabled(_ item: MusicExtension) -> Binding<Bool> {
        Binding(get: { self.items.first { $0.id == item.id }?.enabled ?? false }, set: { on in
            MusicExtensionLibrary.shared.setEnabled(item.id, on)
            self.items = MusicExtensionLibrary.shared.extensions
            self.changed()
        })
    }

    func remove(_ item: MusicExtension) {
        MusicExtensionLibrary.shared.remove(item.id)
        items = MusicExtensionLibrary.shared.extensions
        message = nil
        changed()
    }

    static func detail(_ item: MusicExtension) -> String {
        [item.version, item.summary].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func run(_ work: @escaping @MainActor () async throws -> MusicExtension) {
        guard !busy else { return }
        busy = true; message = nil; failed = false
        Task {
            do {
                let item = try await work()
                items = MusicExtensionLibrary.shared.extensions
                message = L10n.text("Added “%@”.", item.name)
                changed()
            } catch { report(error) }
            busy = false
        }
    }

    private func report(_ error: Error) {
        failed = true
        message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

#if os(tvOS)
struct MusicExtensionsSection: View {
    @Environment(Store.self) private var store
    @State private var model = MusicExtensionsModel()
    @State private var address = ""
    var body: some View {
        TVSettingsSection(title: L10n.text("Music Extensions"), footer: [model.message, MusicExtensionsModel.note].compactMap { $0 }.joined(separator: "\n\n")) {
            ForEach(model.items) { item in
                TVSettingsToggle(title: item.name, detail: MusicExtensionsModel.detail(item), isOn: model.enabled(item))
                TVSettingsAction(title: L10n.text("Remove “%@”", item.name), destructive: true) { model.remove(item) }
            }
            // Apple TV has no files to pick: extensions come from an address.
            TVSettingsField(title: L10n.text("Add from Address"), text: $address)
                .disabled(model.busy)
                .onChange(of: address) { _, text in
                    guard !text.isEmpty else { return }
                    model.add(address: text)
                    address = ""
                }
        }
        .onAppear { model.changed = { [store] in Task { await store.musicBrowse.reload(.ext) } } }
    }
}
#else
struct MusicExtensionsSection: View {
    @Environment(Store.self) private var store
    @State private var model = MusicExtensionsModel()
    @State private var address = ""
    @State private var importing = false
    var body: some View {
        Section {
            ForEach(model.items) { item in
                HStack {
                    Toggle(isOn: model.enabled(item)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                            let detail = MusicExtensionsModel.detail(item)
                            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        }
                    }
                    .settingsSwitch()
                    Button(role: .destructive) { model.remove(item) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(L10n.text("Remove “%@”", item.name))
                }
            }
            HStack {
                TextField(L10n.text("Extension address"), text: $address)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never).keyboardType(.URL)
                    #endif
                    .onSubmit(add)
                if model.busy { ProgressView().appControlSize(.small) }
                else { Button(L10n.text("Add"), action: add).disabled(address.trimmingCharacters(in: .whitespaces).isEmpty) }
            }
            Button(L10n.text("Add from File…")) { importing = true }.disabled(model.busy)
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(model.failed ? Brand.amber : Color.secondary)
            }
        } header: {
            Text(L10n.text("Music Extensions"))
        } footer: {
            Text(MusicExtensionsModel.note)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.javaScript, .plainText, .data]) { result in
            if case .success(let file) = result { model.add(file: file) }
        }
        .onAppear { model.changed = { [store] in Task { await store.musicBrowse.reload(.ext) } } }
    }

    private func add() {
        model.add(address: address)
        address = ""
    }
}
#endif

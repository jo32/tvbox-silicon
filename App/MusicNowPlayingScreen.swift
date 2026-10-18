#if os(iOS)
import AVKit
import MediaPlayer
import SwiftUI
import TVCore

/// Now Playing, laid out as Music lays it out: the cover large on a backdrop tinted by it, the
/// title, a thin scrubber, the transport, the system volume, then Lyrics, AirPlay and Up Next.
/// Lyrics and Up Next take the cover's place, which shrinks into the corner beside the title.
struct MusicNowPlayingScreen: View {
    enum Panel: Hashable { case lyrics, queue }
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var panel: Panel?
    @State private var tint = Color(white: 0.24)
    @State private var showsChannels = false
    @Namespace private var cover

    var body: some View {
        let music = store.music
        VStack(spacing: 0) {
            if let panel {
                header(music, compact: true)
                Group {
                    switch panel {
                    case .lyrics: MusicNowPlayingLyrics()
                    case .queue: MusicUpNext()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            } else {
                Spacer(minLength: 12)
                MusicArtwork(url: music.track?.artwork)
                    .matchedGeometryEffect(id: "cover", in: cover)
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 14)
                    // As in Music, the cover steps back while paused.
                    .scaleEffect(music.isPlaying || music.busy ? 1 : 0.84)
                    .animation(.spring(response: 0.5, dampingFraction: 0.72), value: music.isPlaying)
                Spacer(minLength: 12)
                header(music, compact: false)
            }
            MusicScrubber().padding(.top, 16)
            quality(music)
            transport(music)
            MusicVolumeSlider().padding(.top, 4)
            bottomBar
        }
        .padding(.horizontal, 28).padding(.top, 30).padding(.bottom, 6)
        .foregroundStyle(.white)
        .tint(.white)
        .background { backdrop.ignoresSafeArea() }
        .environment(\.colorScheme, .dark)
        .presentationDragIndicator(.visible)
        .presentationBackground { backdrop }
        .task(id: music.track?.artwork) {
            guard let url = music.track?.artwork, let color = await PosterPalette.average(url) else { return }
            withAnimation(.easeInOut(duration: 0.6)) { tint = color }
        }
        .onChange(of: music.track == nil) { _, gone in if gone { dismiss() } }
        #if DEBUG
        .onAppear {
            switch UserDefaults.standard.string(forKey: "qaNowPlaying") {
            case "lyrics": panel = .lyrics
            case "queue": panel = .queue
            default: break
            }
        }
        #endif
        .sheet(isPresented: $showsChannels) { MusicChannelsView() }
    }

    private var backdrop: some View {
        LinearGradient(colors: [tint.blend(with: .black, by: 0.2), tint.blend(with: .black, by: 0.62)], startPoint: .top, endPoint: .bottom)
    }

    /// Title, artist and the menu; beside a small cover when a panel is open.
    private func header(_ music: MusicPlaybackSession, compact: Bool) -> some View {
        HStack(spacing: 14) {
            if compact {
                MusicArtwork(url: music.track?.artwork, size: 64)
                    .matchedGeometryEffect(id: "cover", in: cover)
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(music.track?.title ?? "").font(compact ? .headline : .title3.weight(.bold)).lineLimit(1)
                Text(music.track?.artistLine ?? "").font(compact ? .subheadline : .title3).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                Button { showsChannels = true } label: { Label(L10n.text("Channels"), systemImage: "antenna.radiowaves.left.and.right") }
                Button(role: .destructive) { music.stop() } label: { Label(L10n.text("Stop"), systemImage: "xmark") }
            } label: {
                Image(systemName: "ellipsis").font(.body.weight(.bold))
                    .frame(width: 32, height: 32).background(.white.opacity(0.16), in: Circle())
            }
            .accessibilityLabel(L10n.text("More"))
        }
        .padding(.bottom, compact ? 14 : 0)
    }

    /// What is actually playing, one line, the same height in every state; tapping lists channels.
    private func quality(_ music: MusicPlaybackSession) -> some View {
        Button { showsChannels = true } label: {
            Group {
                if let failure = music.failure {
                    Text(failure).foregroundStyle(Brand.amber)
                } else if music.phase == .resolving {
                    Text(L10n.text("Finding the best channel…"))
                } else if let selection = music.selection {
                    let format = selection.probe.format.codec == .unknown ? L10n.text("Quality to be confirmed") : selection.probe.format.label
                    Text(selection.degraded ? format + " · " + L10n.text("Lossy quality") : format)
                } else {
                    Text(" ")
                }
            }
            .font(.caption.weight(.semibold)).monospacedDigit().lineLimit(1)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(.white.opacity(music.selection == nil ? 0 : 0.1), in: Capsule())
        }
        .buttonStyle(.plain)
        .frame(height: 26)
        .padding(.top, 2)
    }

    private func transport(_ music: MusicPlaybackSession) -> some View {
        HStack {
            Spacer()
            control("backward.fill", size: 30, label: "Previous") { music.previous() }
            Spacer()
            Group {
                if music.failure != nil {
                    control("arrow.clockwise", size: 36, label: "Retry") { music.retry() }
                } else if music.busy && !music.isPlaying {
                    ProgressView().controlSize(.large).frame(width: 72, height: 72)
                } else {
                    control(music.isPlaying ? "pause.fill" : "play.fill", size: 44, label: music.isPlaying ? "Pause" : "Play") { music.toggle() }
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            Spacer()
            control("forward.fill", size: 30, label: "Next") { music.next() }.disabled(music.queue?.hasNext != true)
            Spacer()
        }
        .frame(height: 84)
    }

    private func control(_ symbol: String, size: CGFloat, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size)).frame(width: 72, height: 72).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text(label))
    }

    private var bottomBar: some View {
        HStack {
            Spacer()
            toggle(.lyrics, symbol: "quote.bubble", label: "Lyrics")
            Spacer()
            MusicRoutePicker().frame(width: 40, height: 40)
            Spacer()
            toggle(.queue, symbol: "list.bullet", label: "Up Next")
            Spacer()
        }
        .frame(height: 50)
    }

    private func toggle(_ target: Panel, symbol: String, label: String) -> some View {
        let on = panel == target
        return Button {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { panel = on ? nil : target }
        } label: {
            Image(systemName: symbol).font(.body.weight(.semibold))
                .foregroundStyle(on ? AnyShapeStyle(tint.blend(with: .black, by: 0.4)) : AnyShapeStyle(.secondary))
                .frame(width: 40, height: 40)
                .background(on ? Color.white.opacity(0.9) : .clear, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text(label))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The device volume, drawn like the scrubber: a thin bar between a quiet and a loud speaker that
/// thickens while dragged and follows the volume buttons. The system's own slider draws nothing in
/// the Simulator and looks unlike the rest; a hidden copy of it carries the changes, as players
/// do, and while it is on screen the system's volume overlay stays away.
struct MusicVolumeSlider: View {
    @State private var level = Double(AVAudioSession.sharedInstance().outputVolume)
    @State private var dragging = false
    @State private var system = SystemSlider()

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule().fill(.white.opacity(dragging ? 1 : 0.78)).frame(width: max(0, proxy.size.width * level))
                }
                .frame(height: dragging ? 12 : 7)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragging = true
                        level = min(1, max(0, value.location.x / proxy.size.width))
                        system.set(level)
                    }
                    .onEnded { _ in dragging = false })
                .animation(.easeOut(duration: 0.15), value: dragging)
            }
            .frame(height: 22)
            Image(systemName: "speaker.wave.3.fill")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(height: 40)
        .background { HiddenVolumeView(system: system).frame(width: 1, height: 1).opacity(0.01) }
        .onReceive(AVAudioSession.sharedInstance().publisher(for: \.outputVolume)) { volume in
            if !dragging { withAnimation(.easeOut(duration: 0.15)) { level = Double(volume) } }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("Volume"))
        .accessibilityValue(Text(level, format: .percent.precision(.fractionLength(0))))
        .accessibilityAdjustableAction { direction in
            level = min(1, max(0, level + (direction == .increment ? 0.0625 : -0.0625)))
            system.set(level)
        }
    }

    /// The system slider inside the hidden volume view, once it exists.
    @MainActor final class SystemSlider {
        weak var slider: UISlider?
        func set(_ value: Double) { slider?.setValue(Float(value), animated: false); slider?.sendActions(for: .valueChanged) }
    }

    private struct HiddenVolumeView: UIViewRepresentable {
        let system: SystemSlider
        func makeUIView(context: Context) -> MPVolumeView {
            let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            system.slider = view.subviews.compactMap { $0 as? UISlider }.first
            return view
        }
        func updateUIView(_ view: MPVolumeView, context: Context) {
            if system.slider == nil { system.slider = view.subviews.compactMap { $0 as? UISlider }.first }
        }
    }
}

/// The system's AirPlay button.
struct MusicRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = UIColor.white.withAlphaComponent(0.6)
        view.activeTintColor = .white
        view.prioritizesVideoDevices = false
        return view
    }
    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
#endif

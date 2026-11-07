import AVFoundation
import SwiftUI
import TVCore

/// The subtitle lines on screen now, which the app draws itself in the chosen `SubtitleStyle` (#547). Each item gets a
/// legible output that stops AVPlayer drawing them (its renderer keeps the system's box behind the letters whatever
/// the item's text style rules say) and hands over the text of the cues as they come and go. Nothing runs between
/// cues, and nothing at all while no subtitle is chosen.
@MainActor @Observable final class SubtitleCues: NSObject, AVPlayerItemLegibleOutputPushDelegate {
    private(set) var lines: [String] = []
    /// The picture's size, to place the lines on the picture rather than on the whole view.
    private(set) var pictureSize: CGSize = .zero
    private(set) var style = SubtitleStyle.load()
    /// How late the lines show (#599). 0 keeps AVPlayer's own timing.
    private(set) var delay = SubtitleDelay.load()
    /// What AVPlayer handed over, waiting for its turn while `delay` is on.
    @ObservationIgnored private var schedule = SubtitleSchedule()
    /// The playback time `advance(to:)` saw last: what is due there when the delay is turned off.
    @ObservationIgnored private var lastAdvanced: Double?
    /// A subtitle file the app shows itself (`ExternalSubtitles`, #576), at the player's clock: while there is one,
    /// what AVPlayer hands over is ignored (its own subtitles are off then).
    private(set) var document: SubtitleDocument?
    @ObservationIgnored var timing = SubtitleTiming() {
        didSet { if let lastAdvanced, document != nil { advance(to: lastAdvanced) } }
    }
    /// Runs when one of the item's own subtitles is chosen while a file shows: the file makes way.
    @ObservationIgnored var nativeChosen: () -> Void = {}
    /// ASS/SSA the app draws itself through libass (#576 M3): a chosen ASS file, or the item's own ASS track of a
    /// repackaged Matroska file. While it shows, `lines` stays empty.
    @ObservationIgnored let styled = StyledSubtitles()
    /// Whether the player's clock must tick for the subtitles (`advance`): a file or styled subtitles show.
    var needsClock: Bool { document != nil || styled.isActive }
    /// Runs when `needsClock` may have changed without a file being chosen (an ASS track came or went).
    @ObservationIgnored var clockChanged: () -> Void = {}
    /// Whether the item's ASS tracks were looked for since it began to play.
    @ObservationIgnored private var lookedForStyled = false
    /// AVPlayer draws the subtitles itself while the picture is somewhere the app's overlay isn't: Picture in Picture.
    var native = false {
        didSet {
            guard native != oldValue else { return }
            for output in outputs.allObjects { output.suppressesPlayerRendering = !native }
        }
    }
    @ObservationIgnored private let outputs = NSHashTable<AVPlayerItemLegibleOutput>.weakObjects()
    @ObservationIgnored private weak var item: AVPlayerItem?
    @ObservationIgnored private var sizeObservation: NSKeyValueObservation?

    override init() {
        super.init()
        schedule.delay = delay
        NotificationCenter.default.addObserver(self, selector: #selector(styleChanged), name: SubtitleStyle.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(delayChanged), name: SubtitleDelay.changed, object: nil)
    }

    /// Gives a new item its output; every item the queue may play needs one.
    func attach(_ item: AVPlayerItem) {
        let output = AVPlayerItemLegibleOutput()
        output.suppressesPlayerRendering = !native
        output.setDelegate(self, queue: .main)
        item.add(output)
        outputs.add(output)
    }

    /// The item now playing: its lines show, the last item's go.
    func follow(_ item: AVPlayerItem?) {
        guard item !== self.item else { return }
        // A file belongs to an episode; the session shows it again on the next one's item, if it is the same episode.
        if let old = self.item { NotificationCenter.default.removeObserver(self, name: AVPlayerItem.mediaSelectionDidChangeNotification, object: old) }
        self.item = item
        lines = []
        pictureSize = .zero
        lookedForStyled = false
        if styled.trackName != nil { styled.show(nil); clockChanged() }
        schedule.reset()
        lastAdvanced = nil
        sizeObservation = item?.observe(\.presentationSize, options: [.initial, .new]) { [weak self] item, _ in
            let size = item.presentationSize
            Task { @MainActor [weak self] in if self?.pictureSize != size { self?.pictureSize = size } }
        }
        // Subtitles turned off: the output says nothing more about the last lines.
        if let item { NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged), name: AVPlayerItem.mediaSelectionDidChangeNotification, object: item) }
        lookForStyledTrack()
    }

    /// The picture's whole rect in a view `bounds` big: fitted inside it, or filling it and running past its edges
    /// (cropped), which styled subtitles need to land where their script places them.
    func videoRect(in bounds: CGSize, fills: Bool) -> CGRect {
        let whole = CGRect(origin: .zero, size: bounds)
        guard pictureSize.width > 0, pictureSize.height > 0 else { return whole }
        let fit = AVMakeRect(aspectRatio: pictureSize, insideRect: whole)
        guard fills, fit.width > 0, fit.height > 0 else { return fit }
        let scale = max(bounds.width / fit.width, bounds.height / fit.height)
        let size = CGSize(width: fit.width * scale, height: fit.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    /// Where the picture is in a view `bounds` big: fitted inside it, or the whole view when it fills (and is cropped).
    func pictureRect(in bounds: CGSize, fills: Bool) -> CGRect {
        let whole = CGRect(origin: .zero, size: bounds)
        guard !fills, pictureSize.width > 0, pictureSize.height > 0 else { return whole }
        return AVMakeRect(aspectRatio: pictureSize, insideRect: whole)
    }

    nonisolated func legibleOutput(_ output: AVPlayerItemLegibleOutput, didOutputAttributedStrings strings: [NSAttributedString],
                                   nativeSampleBuffers nativeSamples: [Any], forItemTime itemTime: CMTime) {
        let lines = SubtitleStyle.lines(strings.map(\.string))
        // The delegate queue is the main queue (`attach`).
        MainActor.assumeIsolated {
            guard let item, item.outputs.contains(where: { $0 === output }), document == nil else { return }
            // An ASS track libass draws: its plain lines stay off screen. The first lines tell which track is on.
            if !lookedForStyled { lookedForStyled = true; lookForStyledTrack() }
            if styled.trackName != nil { if !self.lines.isEmpty { self.lines = [] }; return }
            if delay > 0 {
                // Held until its turn. AVPlayer repeats a cue it is still showing; `schedule` keeps the last word.
                schedule.enqueue(lines, at: itemTime.seconds)
            } else if self.lines != lines {
                self.lines = lines
            }
        }
    }

    /// Shows the lines whose delay has passed, at the player's own clock: a paused video holds them, and so does
    /// one still buffering. Call it while `delay` is on; at 0 the lines go up as AVPlayer hands them over.
    func advance(to time: Double) {
        if let document, time.isFinite {
            lastAdvanced = time
            if styled.isActive {
                styled.render(at: timing.source(at: time))
                return
            }
            let next = SubtitleStyle.lines(document.texts(at: timing.source(at: time)))
            if next != lines { lines = next }
            return
        }
        if styled.trackName != nil, time.isFinite {
            // The item's own ASS track: AVPlayer's clock, less the subtitle delay (#599).
            lastAdvanced = time
            styled.render(at: Int64(((time - delay) * 1_000_000).rounded()))
            return
        }
        guard delay > 0, time.isFinite else { return }
        // A seek is the schedule's to tell: it clears the line and what waited for the old place.
        lastAdvanced = time
        if let next = schedule.lines(at: time), next != lines { lines = next }
    }

    /// Shows `document` (nil: back to the item's own subtitles) from `time` on.
    func show(_ document: SubtitleDocument?, timing: SubtitleTiming, at time: Double?) {
        self.timing = timing
        guard document != self.document else { return }
        self.document = document
        schedule.reset()
        lines = []
        showStyled(document, at: time)
        if let time { advance(to: time) }
    }

    /// An ASS/SSA file is drawn by libass when it starts here; otherwise (or for any other format) as plain lines.
    /// The script is read off the main thread: a karaoke-heavy one runs to megabytes.
    private func showStyled(_ document: SubtitleDocument?, at time: Double?) {
        styled.show(nil)
        guard let document, let script = document.styledScript, ASSRenderer.isAvailable else {
            // A file put away: the item's own ASS track, if one is on, is drawn again.
            if document == nil { lookForStyledTrack() }
            return
        }
        Task { [weak self] in
            let renderer = await Task.detached(priority: .userInitiated) { ASSRenderer(script: script) }.value
            guard let self, self.document == document else { return }
            guard let renderer else {
                Diagnostics.shared.record(.warning, "subtitles", "libass refused file=\(document.format.rawValue)")
                if let time = self.lastAdvanced ?? time { self.advance(to: time) }
                return
            }
            self.styled.show(renderer)
            self.lines = []
            Diagnostics.shared.record(.info, "subtitles", "styled file events=\(renderer.eventCount)")
            if let time = self.lastAdvanced ?? time { self.advance(to: time) }
        }
    }

    /// Draws the item's chosen subtitle itself when it is one AVPlayer can't style or show: an ASS track (libass) or a
    /// bitmap track (PGS, VobSub) of a repackaged file. Stops when another (or none) is chosen.
    private func lookForStyledTrack() {
        guard let item, document == nil, let url = (item.asset as? AVURLAsset)?.url else { return }
        let tracks = Self.styledTracks(url)
        guard !tracks.isEmpty || styled.trackName != nil else { return }
        Task { [weak self, weak item] in
            guard let item, let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
                  let self, self.item === item, self.document == nil else { return }
            let option = item.currentMediaSelection.selectedMediaOption(in: group)
            let track = option.flatMap { Self.track(tracks, for: $0, in: group) }
            guard track?.name != self.styled.trackName else { return }
            if let track, let renderer = track.make() {
                self.styled.show(renderer, track: track.name)
                self.lines = []
                self.schedule.reset()
                Diagnostics.shared.record(.info, "subtitles", "styled track \(track.detail)")
            } else {
                self.styled.show(nil)
            }
            self.clockChanged()
            self.advance(to: self.lastAdvanced ?? item.currentTime().seconds)
        }
    }

    /// A subtitle track of a repackaged file that the app draws itself.
    private struct StyledTrack {
        let name: String
        let position: Int
        let detail: String
        let make: () -> (any StyledSubtitleSource)?
    }

    private static func styledTracks(_ url: URL) -> [StyledTrack] {
        let ass = ASSRenderer.isAvailable ? Remux.styledSubtitles(url).map { track in
            StyledTrack(name: track.name, position: track.position, detail: "ass fonts=\(track.fonts.count) events=\(track.count)") { ASSRenderer(track: track) }
        } : []
        let bitmaps = Remux.bitmapSubtitles(url).map { track in
            StyledTrack(name: track.name, position: track.position, detail: "bitmap cues=\(track.count)") { BitmapSubtitleRenderer(track: track) }
        }
        return ass + bitmaps
    }

    /// The track an option of the item's subtitles is: by its NAME in the master playlist (the option's title;
    /// its `displayName` is the language's name when it has one), else by its place among the subtitle renditions.
    private static func track(_ tracks: [StyledTrack], for option: AVMediaSelectionOption, in group: AVMediaSelectionGroup) -> StyledTrack? {
        let title = AVMetadataItem.metadataItems(from: option.commonMetadata, filteredByIdentifier: .commonIdentifierTitle).first?.stringValue
        if let title, let track = tracks.first(where: { $0.name == title }) { return track }
        guard let position = group.options.firstIndex(of: option) else { return nil }
        return tracks.first { $0.position == position && (title == nil || $0.name == title) }
    }

    @objc private func styleChanged() { style = SubtitleStyle.load() }

    @objc private func delayChanged() {
        let next = SubtitleDelay.load()
        guard next != delay else { return }
        delay = next
        schedule.delay = next
        guard next == 0 else { return }
        // Off again: what is up now is whatever the player's clock has due, not what was queued last.
        if let lastAdvanced, let now = schedule.lines(at: lastAdvanced) { lines = now }
        schedule.reset()
    }
    /// Clears the lines once no subtitle is chosen. A newly chosen one sends its own lines, sometimes before this.
    @objc private func selectionChanged() {
        guard let item else { return }
        Task { [weak self, weak item] in
            guard let item, let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
                  let self, self.item === item else { return }
            // A track change too: the old track's lines must not wait behind the new one's.
            self.schedule.reset()
            self.lookForStyledTrack()
            if let option = item.currentMediaSelection.selectedMediaOption(in: group) {
                if self.document != nil, !option.hasMediaCharacteristic(.containsOnlyForcedSubtitles) { self.nativeChosen() }
                return
            }
            guard self.document == nil else { return }
            self.lines = []
        }
    }
}

/// The playing video's subtitle lines over its picture, in the chosen style.
struct SubtitleOverlay: View {
    let cues: SubtitleCues
    /// The picture fills the view and is cropped, rather than fitting inside it.
    var fills = false
    var body: some View {
        GeometryReader { proxy in
            if !cues.native, cues.styled.isActive {
                StyledSubtitleCanvas(styled: cues.styled, picture: cues.videoRect(in: proxy.size, fills: fills), video: cues.pictureSize)
            }
            if !cues.native, !cues.lines.isEmpty {
                let picture = cues.pictureRect(in: proxy.size, fills: fills)
                let style = cues.style.clamped
                SubtitleLines(lines: cues.lines, style: style, letters: max(12, picture.height * style.size / 100))
                    .subtitlePlacement(style, in: picture)
            }
        }
        .allowsHitTesting(false)
    }
}

/// A subtitle's lines in `style`, the letters `letters` points tall, each line on its own box when the style has one.
struct SubtitleLines: View {
    let lines: [String]
    let style: SubtitleStyle
    let letters: CGFloat
    /// Keeps each line on one line, shrinking it to fit: the preview's sample.
    var oneLine = false

    var body: some View {
        VStack(spacing: letters * 0.15) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(font)
                    .foregroundStyle(swatch)
                    .subtitleEdge(style.edge, letters: letters)
                    .padding(.horizontal, style.backdrop == .none ? 0 : letters * 0.3)
                    .padding(.vertical, style.backdrop == .none ? 0 : letters * 0.06)
                    .background(Color.black.opacity(style.backdrop.opacity), in: RoundedRectangle(cornerRadius: letters * 0.12, style: .continuous))
            }
        }
        .multilineTextAlignment(.center)
        .lineLimit(oneLine ? 1 : nil)
        .minimumScaleFactor(oneLine ? 0.5 : 1)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var font: Font {
        var font = style.font.map { Font.custom($0, fixedSize: letters) } ?? .system(size: letters)
        if style.bold { font = font.bold() }
        if style.italic { font = font.italic() }
        return font
    }

    private var swatch: Color {
        let (red, green, blue) = style.color.rgb
        return Color(red: red, green: green, blue: blue)
    }
}

extension View {
    /// Places a subtitle on `picture` (a rect in the parent's space) where `style` says: its lines in a box
    /// `style.width` of the picture wide centred on `x`, and the point `y` of the way through its height `y` of the
    /// way down the picture.
    func subtitlePlacement(_ style: SubtitleStyle, in picture: CGRect) -> some View {
        frame(width: picture.width * style.width)
            .alignmentGuide(.leading) { d in d.width / 2 - picture.minX - picture.width * style.x }
            .alignmentGuide(.top) { d in d.height * style.y - picture.minY - picture.height * style.y }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The subtitle edge styles, near enough to how AVPlayer's renderer draws them.
    @ViewBuilder func subtitleEdge(_ edge: SubtitleStyle.Edge, letters: CGFloat) -> some View {
        let step = max(1, letters * 0.04)
        switch edge {
        case .none: self
        case .shadow: shadow(color: .black.opacity(0.85), radius: step, x: step * 0.6, y: step * 0.6)
        case .outline:
            shadow(color: .black, radius: 0, x: step, y: 0).shadow(color: .black, radius: 0, x: -step, y: 0)
                .shadow(color: .black, radius: 0, x: 0, y: step).shadow(color: .black, radius: 0, x: 0, y: -step)
        case .raised: shadow(color: .black.opacity(0.85), radius: 0, x: step, y: step)
        case .depressed: shadow(color: .black.opacity(0.85), radius: 0, x: -step, y: -step)
        }
    }
}

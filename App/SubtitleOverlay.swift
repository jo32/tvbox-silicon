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
        NotificationCenter.default.addObserver(self, selector: #selector(styleChanged), name: SubtitleStyle.changed, object: nil)
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
        if let old = self.item { NotificationCenter.default.removeObserver(self, name: AVPlayerItem.mediaSelectionDidChangeNotification, object: old) }
        self.item = item
        lines = []
        pictureSize = .zero
        sizeObservation = item?.observe(\.presentationSize, options: [.initial, .new]) { [weak self] item, _ in
            let size = item.presentationSize
            Task { @MainActor [weak self] in if self?.pictureSize != size { self?.pictureSize = size } }
        }
        // Subtitles turned off: the output says nothing more about the last lines.
        if let item { NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged), name: AVPlayerItem.mediaSelectionDidChangeNotification, object: item) }
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
            guard let item, item.outputs.contains(where: { $0 === output }), self.lines != lines else { return }
            self.lines = lines
        }
    }

    @objc private func styleChanged() { style = SubtitleStyle.load() }
    /// Clears the lines once no subtitle is chosen. A newly chosen one sends its own lines, sometimes before this.
    @objc private func selectionChanged() {
        guard let item else { return }
        Task { [weak self, weak item] in
            guard let item, let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
                  item.currentMediaSelection.selectedMediaOption(in: group) == nil, let self, self.item === item else { return }
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

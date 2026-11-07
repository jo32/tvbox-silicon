import AVFoundation
import SwiftUI
import TVCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Subtitles the app draws as pictures over the video (#576 M3): an ASS/SSA file or a Matroska ASS track through
/// libass, in the picture's own rect so the script's positions land where its author put them. The player's clock
/// asks for a moment (`render`); a serial queue draws it, only when something changed, and only the part of the
/// picture the subtitles cover. Nothing runs while none is chosen.
@MainActor @Observable final class StyledSubtitles {
    /// What shows now; nil before the first frame.
    private(set) var frame: StyledSubtitleFrame?
    /// What draws them; nil while none shows.
    private(set) var source: (any StyledSubtitleSource)?
    /// The Matroska track's name, when the source is one (the item's own subtitle option shows it).
    private(set) var trackName: String?
    var isActive: Bool { source != nil }
    /// The frame to draw in, in pixels: the picture's rect on screen. And the picture's own size, which a
    /// script's border and shadow sizes scale against.
    @ObservationIgnored private var canvas: CGSize = .zero
    @ObservationIgnored private var video: CGSize = .zero
    @ObservationIgnored private var time: Int64?
    @ObservationIgnored private let queue = DispatchQueue(label: "tvbox.subtitles.styled", qos: .userInteractive)
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var again = false
    @ObservationIgnored private var generation = 0

    /// Shows `source` from the next `render`; nil puts it away.
    func show(_ source: (any StyledSubtitleSource)?, track: String? = nil) {
        generation += 1
        self.source = source
        trackName = source == nil ? nil : track
        frame = nil
        time = nil
    }

    /// What shows at `time` (microseconds of the subtitle's clock).
    func render(at time: Int64) {
        guard source != nil, time != self.time else { return }
        self.time = time
        schedule()
    }

    /// The picture is `canvas` pixels on screen now, and `video` pixels itself.
    func resize(canvas: CGSize, video: CGSize) {
        let canvas = CGSize(width: canvas.width.rounded(), height: canvas.height.rounded())
        guard canvas != self.canvas || video != self.video else { return }
        self.canvas = canvas
        self.video = video
        if time != nil { schedule() }
    }

    /// One frame at a time: a request while one is drawn waits for it and then draws the latest moment.
    private func schedule() {
        guard let source, let time, canvas.width >= 2, canvas.height >= 2 else { return }
        if busy { again = true; return }
        busy = true
        let generation = generation, canvas = canvas, video = video.width > 0 && video.height > 0 ? video : canvas
        queue.async { [weak self] in
            let drawn = source.render(at: time, size: canvas, video: video)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.busy = false
                    if generation == self.generation, let drawn { self.frame = drawn }
                    if self.again { self.again = false; self.schedule() }
                }
            }
        }
    }
}

/// The styled subtitles over `picture`, a rect of the parent's space, as one layer whose image is replaced only when
/// the renderer drew something new.
struct StyledSubtitleCanvas: View {
    let styled: StyledSubtitles
    let picture: CGRect
    /// The picture's own size in pixels (`presentationSize`).
    let video: CGSize
    @Environment(\.displayScale) private var scale

    var body: some View {
        StyledSubtitleLayer(frame: styled.frame)
            .frame(width: picture.width, height: picture.height)
            .position(x: picture.midX, y: picture.midY)
            .onAppear { resize() }
            .onChange(of: picture.size) { resize() }
            .onChange(of: scale) { resize() }
            .onChange(of: video) { resize() }
            .allowsHitTesting(false)
    }

    private func resize() {
        styled.resize(canvas: CGSize(width: picture.width * scale, height: picture.height * scale), video: video)
    }
}

/// A view with one layer showing a styled subtitle frame's image where the frame puts it, scaled from the pixels it was
/// drawn at to the view's points.
private struct StyledSubtitleLayer {
    let frame: StyledSubtitleFrame?

    static func place(_ frame: StyledSubtitleFrame?, in layer: CALayer, bounds: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let frame, let image = frame.image, frame.size.width > 0, frame.size.height > 0 else {
            layer.contents = nil
            return
        }
        let x = bounds.width / frame.size.width, y = bounds.height / frame.size.height
        layer.contents = image
        layer.contentsGravity = .resize
        #if os(macOS)
        // AppKit's layers count from the bottom.
        let top = bounds.height - frame.rect.maxY * y
        #else
        let top = frame.rect.minY * y
        #endif
        layer.frame = CGRect(x: frame.rect.minX * x, y: top, width: frame.rect.width * x, height: frame.rect.height * y)
    }
}

#if os(macOS)
extension StyledSubtitleLayer: NSViewRepresentable {
    final class Host: NSView {
        let picture = CALayer()
        var frameToShow: StyledSubtitleFrame?
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.addSublayer(picture)
        }
        required init?(coder: NSCoder) { nil }
        override func layout() { super.layout(); StyledSubtitleLayer.place(frameToShow, in: picture, bounds: bounds) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ view: Host, context: Context) {
        view.frameToShow = frame
        Self.place(frame, in: view.picture, bounds: view.bounds)
    }
}
#else
extension StyledSubtitleLayer: UIViewRepresentable {
    final class Host: UIView {
        let picture = CALayer()
        var frameToShow: StyledSubtitleFrame?
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
            layer.addSublayer(picture)
        }
        required init?(coder: NSCoder) { nil }
        override func layoutSubviews() { super.layoutSubviews(); StyledSubtitleLayer.place(frameToShow, in: picture, bounds: bounds) }
    }
    func makeUIView(context: Context) -> Host { Host() }
    func updateUIView(_ view: Host, context: Context) {
        view.frameToShow = frame
        Self.place(frame, in: view.picture, bounds: view.bounds)
    }
}
#endif

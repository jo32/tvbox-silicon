import SwiftUI
import TVCore
@preconcurrency import AVFoundation

/// Public trailer catalog -> expiring MP4/HLS URL -> AVPlayerLayer. No web page,
/// embedded controls, or AVPlayerViewController participates in the home background.
actor DiscoverTrailerResolver {
    struct Stream: Sendable { let url: URL; let headers: [String: String] }
    static let shared = DiscoverTrailerResolver()
    private var cached: [String: (Date, Stream)] = [:]
    private var pending: [String: Task<Stream?, Never>] = [:]

    func resolve(_ trailer: TMDBMatch.Trailer) async -> Stream? {
        let identity = trailer.site + ":" + trailer.key
        if let value = cached[identity], Date().timeIntervalSince(value.0) < 900 { return value.1 }
        if let value = pending[identity] { return await value.value }
        let task = Task { await self.load(trailer) }
        pending[identity] = task
        let value = await task.value
        pending[identity] = nil
        if let value { cached[identity] = (Date(), value) }
        return value
    }

    private func load(_ trailer: TMDBMatch.Trailer) async -> Stream? {
        if trailer.site == "IMDb" { return await imdb(trailer.key) }
        return nil
    }

    private func imdb(_ id: String) async -> Stream? {
        guard id.range(of: #"^tt[0-9]{5,12}$"#, options: .regularExpression) != nil else { return nil }
        let query = "query { title(id: \"\(id)\") { primaryVideos(first: 5) { edges { node { id name { value } playbackURLs { url mimeType displayName { value } } } } } } }"
        var request = URLRequest(url: URL(string: "https://api.graphql.imdb.com/")!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.imdb.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.imdb.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query])
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONDecoder().decode(Catalog.self, from: data) else { return nil }
        let videos = body.data?.title?.primaryVideos.edges.map(\.node) ?? []
        let named = videos.filter { $0.name.value.localizedCaseInsensitiveContains("trailer") || $0.name.value.localizedCaseInsensitiveContains("teaser") }
        for video in named.isEmpty ? videos : named {
            let formats = (video.playbackURLs ?? []).filter { $0.mimeType == "video/mp4" || $0.mimeType == "application/x-mpegurl" }
            let ranked = formats.sorted { rank($0) > rank($1) }
            for format in ranked {
                guard let url = URL(string: format.url), url.scheme == "https", let host = url.host,
                      host.hasSuffix(".media-imdb.com") else { continue }
                return Stream(url: url, headers: ["Referer": "https://www.imdb.com/"])
            }
        }
        return nil
    }
    private func rank(_ format: Format) -> Int {
        switch format.displayName.value {
        case "720p": 5
        case "1080p": 4
        case "480p": 3
        case "AUTO": 2
        default: 1
        }
    }
    private struct Catalog: Decodable { let data: DataBody? }
    private struct DataBody: Decodable { let title: Title? }
    private struct Title: Decodable { let primaryVideos: Videos }
    private struct Videos: Decodable { let edges: [Edge] }
    private struct Edge: Decodable { let node: Video }
    private struct Video: Decodable { let name: Name; let playbackURLs: [Format]? }
    private struct Name: Decodable { let value: String }
    private struct Format: Decodable { let url: String; let mimeType: String; let displayName: Name }
}

/// The trailer's picture: its pixel size and the black bars baked into it. Trailers for scope films are often a
/// 16:9 file with letterbox bars, which a fill of the hero left as a black band across its top edge.
struct DiscoverTrailerFraming: Equatable {
    var size: CGSize
    /// The share of the height each bar takes, top and bottom alike.
    var bars: CGFloat

    /// Where the whole frame goes so its picture, without the bars, fills `rect`.
    func frame(filling rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let active = size.height * (1 - 2 * bars)
        let scale = max(rect.width / size.width, rect.height / max(active, 1))
        let width = size.width * scale, height = size.height * scale
        return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }

    /// Rows of black at the top and bottom of a frame, as a share of its height. Nil for a frame that is dark all
    /// over (a fade), which says nothing about bars.
    static func bars(in buffer: CVPixelBuffer) -> CGFloat? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 16, height > 16 else { return nil }
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        func dark(_ row: Int) -> Bool {
            let line = pixels + row * stride
            var x = 0
            while x < width {
                let pixel = line + x * 4
                if max(pixel[0], pixel[1], pixel[2]) > 30 { return false }
                x += 4
            }
            return true
        }
        var top = 0
        while top < height / 2, dark(top) { top += 1 }
        var bottom = 0
        while bottom < height / 2, dark(height - 1 - bottom) { bottom += 1 }
        guard top + bottom < height * 7 / 10 else { return nil }
        let share = CGFloat(min(top, bottom)) / CGFloat(height)
        return share < 0.01 ? 0 : min(share, 0.3)
    }
}

@MainActor @Observable private final class DiscoverTrailerPlayback {
    let player = AVQueuePlayer()
    var ready = false
    /// Nil until a frame has been looked at.
    var framing: DiscoverTrailerFraming?
    /// Bars known, or given up on after a few seconds of frames that couldn't be read: the video may show.
    var framed = false
    @ObservationIgnored private var ticks = 0
    @ObservationIgnored private var output: AVPlayerItemVideoOutput?
    @ObservationIgnored private var samples = 0
    private var looper: AVPlayerLooper?
    private var observer: Any?
    private var generation = 0

    init() {
        player.isMuted = true
        player.allowsExternalPlayback = false
        player.preventsDisplaySleepDuringVideoPlayback = false
    }
    func load(_ trailer: TMDBMatch.Trailer) async {
        stop()
        generation += 1
        let requestGeneration = generation
        report("resolving", trailer)
        guard let stream = await DiscoverTrailerResolver.shared.resolve(trailer), !Task.isCancelled,
              generation == requestGeneration else { report("unavailable", trailer); return }
        let asset = AVURLAsset(url: stream.url, options: ["AVURLAssetHTTPHeaderFieldsKey": stream.headers])
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 3
        looper = AVPlayerLooper(player: player, templateItem: item)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, self.generation == requestGeneration else { return }
                if time.seconds > 0.05, self.player.currentItem?.status == .readyToPlay {
                    self.measure()
                    self.ticks += 1
                    if !self.framed, self.framing != nil || self.ticks >= 6 { self.framed = true }
                    self.ready = true
                    self.report("playing:\(String(format: "%.1f", time.seconds))", trailer)
                }
            }
        }
        player.play()
    }
    /// Looks at a frame every half second for the first few seconds, keeping the thinnest bars seen: a dark scene
    /// can make a bar look taller than it is, never shorter.
    private func measure() {
        guard samples < 12, let item = player.currentItem else { return }
        if output == nil || !item.outputs.contains(where: { $0 === output }) {
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            item.add(output)
            self.output = output
            return
        }
        guard let output else { return }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
        samples += 1
        guard let bars = DiscoverTrailerFraming.bars(in: buffer) else { return }
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        let next = DiscoverTrailerFraming(size: size, bars: min(bars, framing?.bars ?? bars))
        if next != framing { framing = next }
    }
    func stop() {
        generation += 1
        ready = false
        framing = nil
        framed = false
        samples = 0
        ticks = 0
        if let output, let item = player.currentItem, item.outputs.contains(where: { $0 === output }) { item.remove(output) }
        output = nil
        player.pause()
        if let observer { player.removeTimeObserver(observer); self.observer = nil }
        looper?.disableLooping(); looper = nil
        player.removeAllItems()
    }
    private func report(_ value: String, _ trailer: TMDBMatch.Trailer) {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "qaKeepAwake") {
            UserDefaults.standard.set("\(trailer.site):\(trailer.key):\(value)", forKey: "qaDiscoverTrailer")
        }
        #endif
    }
}

struct DiscoverTrailer: View {
    let trailer: TMDBMatch.Trailer
    /// Mac: the leading part of the frame that lies under the floating sidebar. It shows a mirrored, blurred copy of
    /// the video, as `backgroundExtensionEffect()` does for SwiftUI content, which can't reach this layer.
    var mirrorWidth: CGFloat = 0
    var readyChanged: (Bool) -> Void = { _ in }
    @State private var playback = DiscoverTrailerPlayback()
    var body: some View {
        DiscoverTrailerLayer(player: playback.player, mirrorWidth: mirrorWidth, framing: playback.framing)
            // Shown once its bars are known, so a letterboxed trailer doesn't first appear with a black band.
            .opacity(playback.ready && playback.framed ? 1 : 0)
            .animation(.easeOut(duration: 0.4), value: playback.ready && playback.framed)
            .accessibilityHidden(true)
            .onChange(of: playback.ready && playback.framed) { _, ready in readyChanged(ready) }
            .task(id: trailer) { await playback.load(trailer) }
            .onDisappear { playback.stop() }
    }
}

#if os(macOS)
private struct DiscoverTrailerLayer: NSViewRepresentable {
    let player: AVPlayer
    let mirrorWidth: CGFloat
    let framing: DiscoverTrailerFraming?
    final class Host: NSView {
        let video = AVPlayerLayer()
        /// The same player again, flipped about the content's leading edge and blurred, under the sidebar.
        let mirror = AVPlayerLayer()
        private let videoClip = CALayer()
        private let mirrorClip = CALayer()
        var mirrorWidth: CGFloat = 0 { didSet { if mirrorWidth != oldValue { needsLayout = true } } }
        var framing: DiscoverTrailerFraming? {
            didSet {
                guard framing != oldValue else { return }
                // Placed by hand once the bars are known, so the layer must not fill again inside that frame.
                let gravity: AVLayerVideoGravity = framing == nil ? .resizeAspectFill : .resize
                video.videoGravity = gravity; mirror.videoGravity = gravity
                needsLayout = true
            }
        }
        let fade = CAGradientLayer()
        /// AppKit owns a layer-backed view's own layer and drops a mask set on it, so the video and its fade sit in
        /// a sublayer. The view is flipped to match UIKit, so the fade runs to the bottom as on iOS.
        private let clip = CALayer()
        override var isFlipped: Bool { true }
        override init(frame: NSRect) {
            super.init(frame: frame); wantsLayer = true; layerUsesCoreImageFilters = true; layer?.addSublayer(clip)
            clip.addSublayer(mirrorClip); clip.addSublayer(videoClip); videoClip.addSublayer(video); mirrorClip.addSublayer(mirror)
            video.videoGravity = .resizeAspectFill; mirror.videoGravity = .resizeAspectFill
            clip.masksToBounds = true; videoClip.masksToBounds = true; mirrorClip.masksToBounds = true
            mirror.transform = CATransform3DMakeScale(-1, 1, 1)
            mirror.filters = [CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 24])].compactMap { $0 }
            fade.startPoint = CGPoint(x: 0.5, y: 0); fade.endPoint = CGPoint(x: 0.5, y: 1)
            fade.colors = [1.0, 1.0, 0.85, 0.35, 0.0].map { NSColor.black.withAlphaComponent($0).cgColor }
            fade.locations = [0, 0.5, 0.7, 0.87, 1]; clip.mask = fade
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() {
            super.layout(); CATransaction.begin(); CATransaction.setDisableActions(true)
            clip.frame = bounds; fade.frame = bounds
            let edge = min(max(mirrorWidth, 0), bounds.width)
            let content = CGRect(x: edge, y: 0, width: bounds.width - edge, height: bounds.height)
            videoClip.frame = content
            var picture = CGRect(origin: .zero, size: content.size).insetBy(dx: -content.width * 0.1, dy: -content.height * 0.1)
            if let framing { picture = framing.frame(filling: picture) }
            video.frame = picture
            mirrorClip.frame = CGRect(x: 0, y: 0, width: edge, height: bounds.height)
            mirrorClip.isHidden = edge <= 0
            // Reflect the picture about the content's leading edge (x = edge in the mirror clip's space).
            mirror.bounds = CGRect(origin: .zero, size: picture.size)
            mirror.position = CGPoint(x: edge - picture.midX, y: picture.midY)
            CATransaction.commit()
        }
    }
    func makeNSView(context: Context) -> Host {
        let view = Host(); view.video.player = player; view.mirror.player = player; view.mirrorWidth = mirrorWidth; view.framing = framing
        return view
    }
    func updateNSView(_ view: Host, context: Context) {
        view.video.player = player; view.mirror.player = player; view.mirrorWidth = mirrorWidth; view.framing = framing
    }
    static func dismantleNSView(_ view: Host, coordinator: ()) { view.video.player = nil; view.mirror.player = nil }
}
#else
private struct DiscoverTrailerLayer: UIViewRepresentable {
    let player: AVPlayer
    var mirrorWidth: CGFloat = 0
    var framing: DiscoverTrailerFraming?
    final class Host: UIView {
        let video = AVPlayerLayer()
        let fade = CAGradientLayer()
        var framing: DiscoverTrailerFraming? {
            didSet {
                guard framing != oldValue else { return }
                video.videoGravity = framing == nil ? .resizeAspectFill : .resize
                setNeedsLayout()
            }
        }
        override init(frame: CGRect) {
            super.init(frame: frame); layer.addSublayer(video); video.videoGravity = .resizeAspectFill
            fade.startPoint = CGPoint(x: 0.5, y: 0); fade.endPoint = CGPoint(x: 0.5, y: 1)
            fade.colors = [1.0, 1.0, 0.85, 0.35, 0.0].map { UIColor.black.withAlphaComponent($0).cgColor }
            fade.locations = [0, 0.5, 0.7, 0.87, 1]; layer.mask = fade
        }
        required init?(coder: NSCoder) { nil }
        override func layoutSubviews() {
            super.layoutSubviews(); CATransaction.begin(); CATransaction.setDisableActions(true)
            let picture = bounds.insetBy(dx: -bounds.width * 0.1, dy: -bounds.height * 0.1)
            video.frame = framing?.frame(filling: picture) ?? picture; fade.frame = bounds
            CATransaction.commit()
        }
    }
    func makeUIView(context: Context) -> Host { let view = Host(); view.video.player = player; view.framing = framing; return view }
    func updateUIView(_ view: Host, context: Context) { view.video.player = player; view.framing = framing }
    static func dismantleUIView(_ view: Host, coordinator: ()) { view.video.player = nil }
}
#endif

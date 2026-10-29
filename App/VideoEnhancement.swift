import SwiftUI
import AVKit
import CoreMedia
import CoreVideo
import VideoToolbox
import Metal
import TVCore

/// Sharper and smoother video with Apple's own machine-learning frame processors (VideoToolbox, OS 26):
/// super resolution upscales a picture smaller than the screen, and frame interpolation lifts 24–30 fps
/// to 60. AVPlayer still decodes and keeps time. Frames come out of an AVPlayerItemVideoOutput, go
/// through the processors on a queue of their own, and are drawn by a sample-buffer layer above AVKit's
/// picture (under danmaku and the controls), on the item's own timebase so sound stays in sync. When
/// there is nothing to improve (HDR, AirPlay, a hot device, a picture already big and fast enough, an
/// older system) that layer steps aside and AVKit's own picture shows.
enum VideoEnhancement {
    static let upscaleKey = "videoUpscale"
    static let smoothKey = "videoSmoothMotion"

    static var upscaleNote: String { L10n.text("Upscales video smaller than your screen with on-device machine learning.") }
    static var smoothNote: String { L10n.text("Adds in-between frames so 24–30 fps video plays at 60 fps. Uses more battery, and films can look like TV soap operas.") }
    /// Both notes, for a settings group that explains its switches underneath.
    static var note: String { [canUpscale ? upscaleNote : nil, canSmooth ? smoothNote : nil].compactMap { $0 }.joined(separator: " ") }

    /// Whether this device can upscale: OS 26 on a real device (the Simulator has no processors).
    static let canUpscale: Bool = {
        #if targetEnvironment(simulator)
        return false
        #else
        if #available(macOS 26, iOS 26, tvOS 26, *) { return VTLowLatencySuperResolutionScalerConfiguration.isSupported }
        return false
        #endif
    }()

    static let canSmooth: Bool = {
        #if targetEnvironment(simulator)
        return false
        #else
        if #available(macOS 26, iOS 26, tvOS 26, *) { return VTLowLatencyFrameInterpolationConfiguration.isSupported }
        return false
        #endif
    }()
}

struct VideoEnhancementOptions: Equatable, Sendable {
    var upscale = false
    var smooth = false
    /// The picture's size on screen, in pixels.
    var target = CGSize.zero
    /// QA: a block stepping along the bottom once per drawn frame, proving the processed frames are on screen.
    var mark = false
    /// The grid smoothed frames are drawn on: the screen's refresh rate while smoothing.
    var outputRate = 60.0
}

/// A frame format handed from the pipeline's queue to the main actor; format descriptions are immutable.
struct VideoFormatBox: @unchecked Sendable { let format: CMFormatDescription }

struct VideoEnhancementStatus: Equatable, Sendable {
    var upscaling = false
    var smoothing = false
    /// The source's frames per second, to the hundredth; 0 until two frames have been seen.
    var sourceRate = 0.0
    var active: Bool { upscaling || smoothing }
}

private protocol EnhancementEngine: AnyObject, Sendable {
    func setOutput(_ output: AVPlayerItemVideoOutput?)
    func setOptions(_ options: VideoEnhancementOptions)
    func setTimebaseReady(_ ready: Bool)
    func discontinuity()
}

/// One per playback session: follows the player's item and owns the layer the surfaces show.
@MainActor @Observable final class VideoEnhancer {
    /// What is on screen now: processed frames drawn over AVKit's picture.
    private(set) var status = VideoEnhancementStatus()
    /// A line for logs and QA: the processors running, frame counts and timing.
    private(set) var summary = "off"
    @ObservationIgnored let layer = AVSampleBufferDisplayLayer()
    @ObservationIgnored private weak var player: AVPlayer?
    @ObservationIgnored private var engine: (any EnhancementEngine)?
    @ObservationIgnored private var item: AVPlayerItem?
    @ObservationIgnored private var output: AVPlayerItemVideoOutput?
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?
    @ObservationIgnored private var jumpObserver: NSObjectProtocol?
    @ObservationIgnored private var options = VideoEnhancementOptions()
    @ObservationIgnored private var displaySize = CGSize.zero
    /// The frames' format, for asking the TV for a display mode.
    @ObservationIgnored private var format: CMFormatDescription?
    @ObservationIgnored private var announced: String?
    @ObservationIgnored private var displayState = ""
    /// Called when what the screen should do changes: smoothing, its rate, or the first known format.
    @ObservationIgnored var onDisplayChange: (() -> Void)?

    /// Smoothed frames need the screen at `rate`; nil when the screen should follow the video as usual.
    var displayRequest: (rate: Double, format: CMFormatDescription)? {
        guard status.smoothing, let format else { return nil }
        return (options.outputRate, format)
    }

    /// The grid for smoothed frames. 25 fps doubles to 50 when the TV follows the video's rate (Match Frame
    /// Rate), so every new frame sits exactly halfway; otherwise 60 Hz (59.94 for the 1000/1001 rates), where
    /// 24 and 25 fps need uneven in-between positions.
    static func outputRate(source: Double, matching: Bool) -> Double {
        if matching, abs(source - 25) < 0.3 { return 50 }
        if abs(source - 30000 / 1001) < 0.02 || abs(source - 24000 / 1001) < 0.02 { return 60000 / 1001 }
        return 60
    }

    init(player: AVPlayer) {
        self.player = player
        layer.videoGravity = .resizeAspect
        layer.isHidden = true
        layer.backgroundColor = nil
        guard VideoEnhancement.canUpscale || VideoEnhancement.canSmooth else { return }
        #if !targetEnvironment(simulator)
        if #available(macOS 26, iOS 26, tvOS 26, *) {
            engine = EnhancementPipeline(renderer: layer.sampleBufferRenderer) { [weak self] status, summary, note, format in
                Task { @MainActor [weak self] in self?.apply(status, summary: summary, note: note, format: format) }
            }
        }
        #endif
        itemObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        // Settings, the device's temperature and AirPlay change while playing; so does the item's timebase.
        // (No strong reference across the sleep, or the session would never be released.)
        Task { [weak self] in
            while !Task.isCancelled, self != nil {
                self?.refresh()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// The surface's size in pixels, which decides how much to upscale.
    func setDisplaySize(_ size: CGSize) {
        guard size != displaySize else { return }
        displaySize = size
        refresh()
    }

    private func refresh() {
        guard let engine, let player else { return }
        let defaults = UserDefaults.standard
        var next = VideoEnhancementOptions(upscale: VideoEnhancement.canUpscale && defaults.bool(forKey: VideoEnhancement.upscaleKey),
                                           smooth: VideoEnhancement.canSmooth && defaults.bool(forKey: VideoEnhancement.smoothKey),
                                           target: displaySize)
        if !allowed(player) { next.upscale = false; next.smooth = false }
        #if DEBUG
        next.mark = defaults.bool(forKey: "qaEnhanceHUD")
        #endif
        let current = (next.upscale || next.smooth) ? player.currentItem : nil
        if current !== item || (current != nil && output == nil) {
            if let item, let output { item.remove(output) }
            if let jumpObserver { NotificationCenter.default.removeObserver(jumpObserver) }
            jumpObserver = nil
            item = current; output = nil
            layer.controlTimebase = nil
            engine.setTimebaseReady(false)
            if let current {
                let made = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
                    kCVPixelBufferMetalCompatibilityKey as String: true])
                current.add(made)
                output = made
                jumpObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.timeJumpedNotification, object: current, queue: .main) { [weak engine] _ in
                    engine?.discontinuity()
                }
            }
            engine.setOutput(output)
        }
        // Frames wait for their time on the item's own clock; until it exists they would show at once.
        if let item, layer.controlTimebase == nil, let timebase = item.timebase {
            layer.controlTimebase = timebase
            engine.setTimebaseReady(true)
        }
        #if os(tvOS)
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.windows.first }.first
        let matching = window?.avDisplayManager.isDisplayCriteriaMatchingEnabled ?? false
        displayState = window == nil ? "no window" : "match \(matching) switching \(window!.avDisplayManager.isDisplayModeSwitchInProgress)"
        #else
        let matching = false
        #endif
        next.outputRate = Self.outputRate(source: status.sourceRate, matching: matching)
        if next != options {
            options = next
            engine.setOptions(next)
        }
        announceDisplay()
    }

    private func announceDisplay() {
        let key = displayRequest.map { "\($0.rate)" }
        guard key != announced else { return }
        announced = key
        onDisplayChange?()
    }

    /// Not while AirPlay shows the video elsewhere, the device is hot, or it is saving power.
    private func allowed(_ player: AVPlayer) -> Bool {
        if player.isExternalPlaybackActive { return false }
        if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue { return false }
        #if !os(tvOS)
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return false }
        #endif
        return true
    }

    private func apply(_ status: VideoEnhancementStatus, summary: String, note: String?, format: VideoFormatBox?) {
        if let note { Diagnostics.shared.record(.info, "enhance", note) }
        if let format { self.format = format.format }
        defer { announceDisplay() }
        #if DEBUG
        let frame = layer.frame, host = layer.superlayer
        self.summary = summary + " · layer \(Int(frame.width))x\(Int(frame.height)) hidden \(layer.isHidden) hosted \(host != nil) timebase \(layer.controlTimebase != nil) · grid \(options.outputRate) \(displayState) request \(displayRequest.map { "\($0.rate)" } ?? "none")"
        #else
        self.summary = summary
        #endif
        guard status != self.status else { return }
        self.status = status
        layer.isHidden = !status.active
    }
}

#if os(tvOS)
/// In-between frames need the TV at 60 Hz, but AVKit's automatic display matching would switch it to the film's
/// own 24 Hz and drop them, and AVKit refuses to turn that off once playback has begun. So on an Apple TV that can
/// smooth, the player applies the display criteria itself: the video's own, as AVKit would, and while smoothing
/// none, which leaves the TV in the mode chosen in Settings (normally 60 Hz).
@MainActor final class DisplayCriteriaKeeper {
    private weak var controller: AVPlayerViewController?
    private weak var enhancer: VideoEnhancer?
    private var observation: NSKeyValueObservation?
    private var applying: Task<Void, Never>?

    init(controller: AVPlayerViewController, player: AVPlayer, enhancer: VideoEnhancer) {
        self.controller = controller
        self.enhancer = enhancer
        controller.appliesPreferredDisplayCriteriaAutomatically = false
        observation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.apply() }
        }
        enhancer.onDisplayChange = { [weak self] in self?.apply() }
    }

    /// Back to the TV's own mode when the player goes away, as AVKit does after full-screen playback.
    func reset() {
        applying?.cancel()
        observation = nil
        controller?.view.window?.avDisplayManager.preferredDisplayCriteria = nil
    }

    private func apply() {
        applying?.cancel()
        // Smoothing: the rate the frames are drawn at. Otherwise the video's own criteria, as AVKit would.
        let request = enhancer?.displayRequest
        let wanted = request.map { AVDisplayCriteria(refreshRate: Float($0.rate), formatDescription: $0.format) }
        let asset = request == nil ? controller?.player?.currentItem?.asset : nil
        applying = Task { [weak self] in
            var criteria = wanted
            if let asset { criteria = try? await asset.load(.preferredDisplayCriteria) }
            // The controller joins its window a moment after it is made.
            for _ in 0..<20 {
                guard !Task.isCancelled, let self else { return }
                if let manager = self.controller?.view.window?.avDisplayManager {
                    manager.preferredDisplayCriteria = criteria
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}
#endif

/// Where the enhanced picture is drawn: the session's layer, sized to the player's own picture.
struct EnhancedVideoSurface: View {
    let enhancer: VideoEnhancer
    var fills = false
    /// Whether AVKit's picture runs under the safe areas, as it does on a screen of its own. At the top of an iPhone
    /// watch page it keeps to its frame, so the enhanced picture must too.
    var bleeds = true
    var body: some View {
        if VideoEnhancement.canUpscale || VideoEnhancement.canSmooth {
            // The same area as AVKit's own picture: inside the safe area (under the Mac's title bar) the fitted
            // picture came out smaller than AVKit's, and under the status bar above a watch page's player it came out
            // taller and higher; either way AVKit's picture showed around its edges.
            Host(enhancer: enhancer, fills: fills).ignoresSafeArea(edges: bleeds ? .all : []).allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    #if os(macOS)
    private struct Host: NSViewRepresentable {
        let enhancer: VideoEnhancer
        let fills: Bool
        func makeNSView(context: Context) -> SurfaceView { SurfaceView(enhancer: enhancer) }
        func updateNSView(_ view: SurfaceView, context: Context) {
            enhancer.layer.videoGravity = fills ? .resizeAspectFill : .resizeAspect
        }
    }

    final class SurfaceView: NSView {
        private let enhancer: VideoEnhancer
        init(enhancer: VideoEnhancer) {
            self.enhancer = enhancer
            super.init(frame: .zero)
            wantsLayer = true
            layer?.addSublayer(enhancer.layer)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() {
            super.layout()
            place()
        }
        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            place()
        }
        private func place() {
            if enhancer.layer.superlayer !== layer { layer?.addSublayer(enhancer.layer) }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            enhancer.layer.frame = bounds
            CATransaction.commit()
            let scale = window?.backingScaleFactor ?? 2
            enhancer.setDisplaySize(CGSize(width: bounds.width * scale, height: bounds.height * scale))
        }
    }
    #else
    private struct Host: UIViewRepresentable {
        let enhancer: VideoEnhancer
        let fills: Bool
        func makeUIView(context: Context) -> SurfaceView { SurfaceView(enhancer: enhancer) }
        func updateUIView(_ view: SurfaceView, context: Context) {
            enhancer.layer.videoGravity = fills ? .resizeAspectFill : .resizeAspect
        }
    }

    final class SurfaceView: UIView {
        private let enhancer: VideoEnhancer
        init(enhancer: VideoEnhancer) {
            self.enhancer = enhancer
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = .clear
            layer.addSublayer(enhancer.layer)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layoutSubviews() {
            super.layoutSubviews()
            if enhancer.layer.superlayer !== layer { layer.addSublayer(enhancer.layer) }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            enhancer.layer.frame = bounds
            CATransaction.commit()
            let scale = traitCollection.displayScale
            enhancer.setDisplaySize(CGSize(width: bounds.width * scale, height: bounds.height * scale))
        }
    }
    #endif
}

#if !targetEnvironment(simulator)
/// The frame pipeline. Everything below runs on `queue`; session starts (which load ML models and can
/// take longer than a frame) run on `setup` so playback never waits for them.
@available(macOS 26, iOS 26, tvOS 26, *)
private final class EnhancementPipeline: EnhancementEngine, @unchecked Sendable {
    /// How far ahead of the clock frames are pulled, so processing finishes before they are due.
    private static let lookahead = 0.08

    private struct Frame {
        let buffer: CVPixelBuffer
        let time: CMTime
        /// A smaller copy for the interpolator, when the picture is bigger than it can keep up with.
        var work: CVPixelBuffer? = nil
        /// A frame of the video itself, not one made in between.
        var real = true
    }

    private let queue = DispatchQueue(label: "com.tvbox.video-enhancement", qos: .userInteractive)
    private let setup = DispatchQueue(label: "com.tvbox.video-enhancement.setup", qos: .userInitiated)
    private let renderer: AVSampleBufferVideoRenderer
    private let report: @Sendable (VideoEnhancementStatus, String, String?, VideoFormatBox?) -> Void

    private var timer: DispatchSourceTimer?
    private var output: AVPlayerItemVideoOutput?
    private var options = VideoEnhancementOptions()
    private var timebaseReady = false
    private var status = VideoEnhancementStatus()
    private var previous: Frame?
    /// Seconds between source frames.
    private var interval: Double?
    private var hdr = false
    private var scaler: Stage?
    private var interpolator: Stage?
    private var wanted: (scale: String?, smooth: String?) = (nil, nil)
    private var starting: Set<String> = []
    /// Configurations that failed or ran too slowly, not tried again for this item.
    private var refused: Set<String> = []
    private var slow = 0
    /// The most pixels interpolated per frame. 1080p takes about 90 ms a frame on an M1 Pro against 15 ms
    /// for 720p, so bigger pictures are interpolated from a 720p copy; 540p when even that is too slow.
    private var workBudget = 1280 * 720
    private var shrinker: VTPixelTransferSession?
    private var counts = (frames: 0, shown: 0, late: 0, failed: 0, busy: 0.0, lead: 0.0, cuts: 0)
    private var lastReport = 0.0
    /// Frames drawn per second over the last report, against the source's own rate.
    private var shownAtReport = 0
    private var drawnRate = 0.0
    private var lastFormat: CMVideoFormatDescription?
    /// Where the output grid starts: a source frame, so at 2x every other drawn frame is an original.
    private var gridOrigin = 0.0
    private var changeMax = (histogram: 0.0, difference: 0.0)
    /// QA (with `mark`): new pictures the layer actually showed per second, read back from the marker, and how
    /// far each in-between frame is from its two neighbours (a copy of either would read 0).
    private var probe = (slot: -1, changes: 0, since: 0.0, rate: 0.0)
    private var distance = (previous: 0.0, current: 0.0, between: 0.0, count: 0)
    private var brightness = (previous: 0.0, middle: 0.0, current: 0.0, range: "")
    private var inspection: (CVPixelBuffer, CVPixelBuffer, CVPixelBuffer)?
    /// Frames wait here and are handed to the layer one at a time, as each falls due, marked to display at
    /// once: given them ahead of time with their timestamps, the layer showed only about 25 of 60 a second.
    private let presenter = DispatchQueue(label: "com.tvbox.video-enhancement.present", qos: .userInteractive)
    private let pendingLock = NSLock()
    private var pending: [(sample: CMSampleBuffer, real: Bool)] = []
    /// Paused on an in-between frame, the picture would stay on it; the latest real frame replaces it.
    private var latestReal: CMSampleBuffer?
    private var showingReal = true
    private var presentTimer: DispatchSourceTimer?
    /// The marker is read on a queue of its own: `queue` is busy for most of each frame while processing.
    private let probeQueue = DispatchQueue(label: "com.tvbox.video-enhancement.probe", qos: .userInteractive)
    private var probeTimer: DispatchSourceTimer?

    /// Keeps still parts of in-between frames (subtitles, logos, background) at the video's own sharpness.
    private var stillRegions: StillRegions?
    /// Seconds spent per step since the item started (QA).
    private var timing = (shrink: 0.0, interpolate: 0.0, compose: 0.0, scale: 0.0)

    init(renderer: AVSampleBufferVideoRenderer, report: @escaping @Sendable (VideoEnhancementStatus, String, String?, VideoFormatBox?) -> Void) {
        self.renderer = renderer
        self.report = report
        // Compiling the shader takes a moment: off the frame queue.
        setup.async { [weak self] in
            let regions = StillRegions()
            self?.queue.async { [weak self] in self?.stillRegions = regions }
        }
    }

    deinit { timer?.cancel(); probeTimer?.cancel(); presentTimer?.cancel() }

    private func flush(removingImage: Bool = false) {
        pendingLock.lock(); pending.removeAll(); latestReal = nil; showingReal = true; pendingLock.unlock()
        if removingImage { renderer.flush(removingDisplayedImage: true, completionHandler: nil) } else { renderer.flush() }
    }

    /// Every 2 ms: the newest frame whose time has come (a few ms early, for the next refresh) goes to the layer.
    private func present() {
        let due = CMTimebaseGetTime(renderer.timebase).seconds + 0.004
        let paused = CMTimebaseGetRate(renderer.timebase) == 0
        pendingLock.lock()
        var ready: (sample: CMSampleBuffer, real: Bool)?
        var skipped = 0
        while let first = pending.first, CMSampleBufferGetPresentationTimeStamp(first.sample).seconds <= due {
            if ready != nil { skipped += 1 }
            ready = pending.removeFirst()
            if ready?.real == true { latestReal = ready?.sample }
        }
        if let ready { showingReal = ready.real }
        // Paused on an in-between frame: show the real one it came from instead (sharper, and what AVKit would show).
        var still: CMSampleBuffer?
        if ready == nil, paused, !showingReal, let latestReal { still = latestReal; showingReal = true }
        pendingLock.unlock()
        if skipped > 0 { queue.async { [self] in counts.late += skipped } }
        if let ready { renderer.enqueue(ready.sample) }
        if let still { renderer.enqueue(still) }
    }

    func setOutput(_ output: AVPlayerItemVideoOutput?) {
        queue.async { [self] in
            self.output = output
            timebaseReady = false
            previous = nil; interval = nil; hdr = false; slow = 0; workBudget = 1280 * 720
            scaler = nil; interpolator = nil; refused = []
            counts = (0, 0, 0, 0, 0, 0, 0); timing = (0, 0, 0, 0)
            flush(removingImage: true)
            update(VideoEnhancementStatus())
            if output == nil { presentTimer?.cancel(); presentTimer = nil }
            else if presentTimer == nil {
                let timer = DispatchSource.makeTimerSource(queue: presenter)
                timer.schedule(deadline: .now(), repeating: .milliseconds(2), leeway: .microseconds(500))
                timer.setEventHandler { [weak self] in self?.present() }
                timer.resume()
                presentTimer = timer
            }
            if output == nil { timer?.cancel(); timer = nil }
            else if timer == nil {
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
                timer.setEventHandler { [weak self] in self?.tick() }
                timer.resume()
                self.timer = timer
            }
        }
    }

    func setOptions(_ options: VideoEnhancementOptions) {
        queue.async { [self] in self.options = options }
    }

    func setTimebaseReady(_ ready: Bool) {
        queue.async { [self] in timebaseReady = ready }
    }

    /// A seek: frames already queued belong to the old position, and the next one has no neighbour.
    func discontinuity() {
        queue.async { [self] in
            previous = nil
            flush()
        }
    }

    // MARK: Frames

    private func tick() {
        guard let output else { return }
        if options.mark, probeTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: probeQueue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(3), leeway: .microseconds(500))
            timer.setEventHandler { [weak self] in self?.sampleDisplayed() }
            timer.resume()
            probeTimer = timer
        }
        if renderer.requiresFlushToResumeDecoding || renderer.status == .failed { flush() }
        let now = CACurrentMediaTime()
        let ahead = output.itemTime(forHostTime: now + Self.lookahead)
        guard ahead.isValid, output.hasNewPixelBuffer(forItemTime: ahead) else { return }
        let pulled = output.pixelBufferAndDisplayTime(forItemTime: ahead)
        guard let readOnly = pulled.pixelBuffer, pulled.itemTimeForDisplay.isValid else { return }
        // The processors take a CVPixelBuffer; this one is only read, by them and by the layer.
        nonisolated(unsafe) var pixels: CVPixelBuffer?
        readOnly.withUnsafeBuffer { pixels = $0 }
        guard let buffer = pixels else { return }
        handle(Frame(buffer: buffer, time: pulled.itemTimeForDisplay), output: output)
    }

    private func handle(_ frame: Frame, output: AVPlayerItemVideoOutput) {
        guard options.upscale || options.smooth else { return update(VideoEnhancementStatus()) }
        if Self.isHDR(frame.buffer) {
            // Processing is 8-bit SDR; HDR keeps AVKit's own picture and the TV's HDR mode.
            if !hdr { hdr = true; update(VideoEnhancementStatus(), note: "hdr source, left to AVKit") }
            return
        }
        counts.frames += 1
        let width = CVPixelBufferGetWidth(frame.buffer), height = CVPixelBufferGetHeight(frame.buffer)
        if let last = previous {
            let gap = frame.time.seconds - last.time.seconds
            if gap <= 0 || gap > 0.25 || CVPixelBufferGetWidth(last.buffer) != width || CVPixelBufferGetHeight(last.buffer) != height {
                previous = nil
                if gap <= 0 { flush() }
            } else if let known = interval, abs(gap - known) < known * 0.2 {
                interval = known * 0.9 + gap * 0.1
            } else {
                interval = gap
            }
        }
        let work = workSize(width: width, height: height)
        prepare(width: width, height: height, work: work, format: CVPixelBufferGetPixelFormatType(frame.buffer))
        if previous == nil { gridOrigin = frame.time.seconds }

        let started = CACurrentMediaTime()
        var current = frame
        // A big picture is interpolated from a smaller copy: only the in-between frames are drawn at that size.
        let shrinks = work != (width, height)
        let shrinking = CACurrentMediaTime()
        if shrinks, let interpolator { current.work = shrink(frame.buffer, with: interpolator) }
        timing.shrink += CACurrentMediaTime() - shrinking
        var frames = [current]
        let smoothing = interpolator != nil && smoothable
        if smoothing, let interpolator, let last = previous, !shrinks || (last.work != nil && current.work != nil) {
            // Across a cut the two frames show different shots, and morphing one into the other gives a
            // scrambled mix of both: hold each shot instead, as TVs do.
            let change = Self.sceneChange(last.work ?? last.buffer, current.work ?? current.buffer)
            let cut = change.cut
            if cut { counts.cuts += 1 }
            changeMax = (max(changeMax.histogram, change.histogram), max(changeMax.difference, change.difference))
            if let made = interpolate(from: last, to: current, with: interpolator, cut: cut) { frames = made }
            else { failed(interpolator) }
        }
        let upscaling = scaler != nil
        if let scaler {
            frames = frames.map { source in
                guard scaler.accepts(source.buffer) else { return source }
                if let scaled = scale(source, with: scaler) { return scaled }
                failed(scaler)
                return source
            }
        }
        let spent = CACurrentMediaTime() - started
        counts.busy += spent
        if counts.frames % 15 == 0 { inspect() } else { inspection = nil }
        previous = current
        update(VideoEnhancementStatus(upscaling: upscaling, smoothing: smoothing, sourceRate: interval.map { (100 / $0).rounded() / 100 } ?? 0))
        budget(spent)
        guard status.active, timebaseReady else { return }
        enqueue(frames, now: output.itemTime(forHostTime: CACurrentMediaTime()).seconds)
    }

    /// Whether the source is slow enough to gain from in-between frames (24–30 fps, up to 47).
    private var smoothable: Bool {
        guard let interval else { return false }
        return interval > 1 / 47.0 && interval < 1 / 18.0
    }

    private func enqueue(_ frames: [Frame], now: Double) {
        for (index, frame) in frames.enumerated() {
            // A frame already past its turn would only flash; the last one still shows the newest picture.
            if frame.time.seconds < now - 1 / options.outputRate, index < frames.count - 1 { counts.late += 1; continue }
            // isReadyForMoreMediaData is advice for a source that could run ahead; frames here arrive at
            // playback speed, at most a few dozen milliseconds early, so the queue stays short.
            var buffer = frame.buffer
            if options.mark {
                // A source frame is shared with AVKit's own picture, so it is marked on a copy.
                if !status.upscaling, let copy = markCopy(buffer) { buffer = copy }
                if status.upscaling || buffer !== frame.buffer { Self.mark(buffer, index: counts.shown) }
            }
            do {
                let format = try CMVideoFormatDescription(imageBuffer: buffer)
                let timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: frame.time, decodeTimeStamp: .invalid)
                let sample = try CMSampleBuffer(imageBuffer: buffer, formatDescription: format, sampleTiming: timing)
                if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
                    attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
                }
                pendingLock.lock(); pending.append((sample, frame.real)); pendingLock.unlock()
                lastFormat = format
                counts.shown += 1
                counts.lead += frame.time.seconds - now
            } catch { counts.failed += 1 }
        }
    }

    /// QA only: a private copy of a frame to draw the marker on.
    private func markCopy(_ buffer: CVPixelBuffer) -> CVPixelBuffer? {
        if shrinker == nil {
            var session: VTPixelTransferSession?
            VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session)
            shrinker = session
        }
        var copy: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), CVPixelBufferGetPixelFormatType(buffer),
                            [kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()] as CFDictionary, &copy)
        guard let shrinker, let copy, VTPixelTransferSessionTransferImage(shrinker, from: buffer, to: copy) == noErr else { return nil }
        CVBufferPropagateAttachments(buffer, copy)
        return copy
    }

    private func sampleDisplayed() {
        let now = CACurrentMediaTime()
        if let shown = renderer.displayedPixelBuffer(), let slot = Self.markSlot(shown), slot != probe.slot {
            probe.slot = slot; probe.changes += 1
        }
        if now - probe.since >= 1 {
            probe.rate = probe.since > 0 ? Double(probe.changes) / (now - probe.since) : 0
            probe.changes = 0; probe.since = now
        }
    }

    /// Which of the 60 marker positions the buffer shows, if any.
    private static func markSlot(_ buffer: CVPixelBuffer) -> Int? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let row = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let size = max(8, height / 24), step = (width - size) / 60
        let line = base + (height - size * 2 + size / 2) * row
        var x = 0
        while x + size <= width {
            if line[x] == 235, line[x + size - 1] == 235, line[x + size / 2] == 235 { return x / max(1, step) }
            x += 1
        }
        return nil
    }

    private static func meanLuma(_ buffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let p = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.assumingMemoryBound(to: UInt8.self) else { return -1 }
        let row = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        var total = 0, count = 0
        for y in stride(from: 0, to: height, by: 6) { for x in stride(from: 0, to: width, by: 6) { total += Int(p[y * row + x]); count += 1 } }
        return Double(total) / Double(max(1, count))
    }

    private static func fourCC(_ buffer: CVPixelBuffer) -> String {
        let code = CVPixelBufferGetPixelFormatType(buffer)
        return String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }, encoding: .ascii) ?? "\(code)"
    }

    /// A scene change between two frames of the same size: their brightness histograms differ a lot, or the
    /// pictures differ a lot and the histograms clearly. A pan or fast motion moves the picture but keeps
    /// its histogram, so it is still interpolated. Reads about 15,000 luma samples.
    private static func sceneChange(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> (cut: Bool, histogram: Double, difference: Double) {
        guard CVPixelBufferGetWidth(a) == CVPixelBufferGetWidth(b), CVPixelBufferGetHeight(a) == CVPixelBufferGetHeight(b) else { return (true, -1, -1) }
        CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        guard let pa = CVPixelBufferGetBaseAddressOfPlane(a, 0)?.assumingMemoryBound(to: UInt8.self),
              let pb = CVPixelBufferGetBaseAddressOfPlane(b, 0)?.assumingMemoryBound(to: UInt8.self) else { return (false, -2, -2) }
        let ra = CVPixelBufferGetBytesPerRowOfPlane(a, 0), rb = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
        let width = CVPixelBufferGetWidthOfPlane(a, 0), height = CVPixelBufferGetHeightOfPlane(a, 0)
        let step = max(4, Int((Double(width * height) / 15_000).squareRoot()))
        var ha = [Int](repeating: 0, count: 32), hb = [Int](repeating: 0, count: 32)
        var total = 0, count = 0
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let va = Int(pa[y * ra + x]), vb = Int(pb[y * rb + x])
                ha[va >> 3] += 1; hb[vb >> 3] += 1
                total += abs(va - vb); count += 1
            }
        }
        guard count > 0 else { return (false, -3, -3) }
        let histogram = Double(zip(ha, hb).reduce(0) { $0 + abs($1.0 - $1.1) }) / Double(count)   // 0...2
        let difference = Double(total) / Double(count)
        return (histogram > 0.5 || (difference > 30 && histogram > 0.25), histogram, difference)
    }

    /// Mean luma difference on a sparse grid.
    private static func difference(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        guard let pa = CVPixelBufferGetBaseAddressOfPlane(a, 0)?.assumingMemoryBound(to: UInt8.self),
              let pb = CVPixelBufferGetBaseAddressOfPlane(b, 0)?.assumingMemoryBound(to: UInt8.self) else { return -1 }
        let ra = CVPixelBufferGetBytesPerRowOfPlane(a, 0), rb = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
        let width = min(CVPixelBufferGetWidthOfPlane(a, 0), CVPixelBufferGetWidthOfPlane(b, 0))
        let height = min(CVPixelBufferGetHeightOfPlane(a, 0), CVPixelBufferGetHeightOfPlane(b, 0))
        var total = 0, count = 0
        for y in stride(from: 0, to: height, by: 5) { for x in stride(from: 0, to: width, by: 5) {
            total += abs(Int(pa[y * ra + x]) - Int(pb[y * rb + x])); count += 1
        } }
        return count > 0 ? Double(total) / Double(count) : -1
    }

    private static func mark(_ buffer: CVPixelBuffer, index: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return }
        let row = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let size = max(8, height / 24), slots = 60, step = (width - size) / slots
        let left = (index % slots) * step, top = height - size * 2
        for y in top..<(top + size) { memset(base + y * row + left, 235, size) }
    }

    /// The source frame's slots on the 60 Hz grid between the previous frame and this one, each the
    /// nearer source frame or an interpolated one: 30 fps gets one new frame between two, 24 fps
    /// alternates two and three.
    private func interpolate(from last: Frame, to frame: Frame, with stage: Stage, cut: Bool) -> [Frame]? {
        let start = last.time.seconds, end = frame.time.seconds, span = end - start
        var slots: [(time: CMTime, phase: Float)] = []
        let rate = options.outputRate, origin = gridOrigin
        var index = ((start - origin) * rate + 0.0005).rounded(.down) + 1
        while origin + index / rate <= end + 0.0005 {
            // The exact position: the processor takes any phase (it resolves about an eighth of a frame), and
            // rounding to quarters made 25 fps move in uneven steps on a 60 Hz screen.
            let raw = (origin + index / rate - start) / span
            let phase = Float(raw < 0.03 ? 0 : raw > 0.97 ? 1 : (raw * 1000).rounded() / 1000)
            slots.append((CMTime(seconds: origin + index / rate, preferredTimescale: 90_000), phase))
            index += 1
        }
        let phases = Array(Set(slots.map(\.phase).filter { $0 > 0 && $0 < 1 })).sorted()
        var made: [Float: CVPixelBuffer] = [:]
        if cut {
            return slots.map { Frame(buffer: $0.phase < 0.5 ? last.buffer : frame.buffer, time: $0.time) }
        }
        if !phases.isEmpty {
            guard let source = VTFrameProcessorFrame(buffer: frame.work ?? frame.buffer, presentationTimeStamp: frame.time),
                  let prior = VTFrameProcessorFrame(buffer: last.work ?? last.buffer, presentationTimeStamp: last.time) else { return nil }
            var buffers: [CVPixelBuffer] = [], destinations: [VTFrameProcessorFrame] = []
            for phase in phases {
                guard let buffer = stage.makeBuffer(),
                      let destination = VTFrameProcessorFrame(buffer: buffer, presentationTimeStamp: CMTime(seconds: start + Double(phase) * span, preferredTimescale: 90_000))
                else { return nil }
                buffers.append(buffer); destinations.append(destination)
            }
            guard let parameters = VTLowLatencyFrameInterpolationParameters(sourceFrame: source, previousFrame: prior, interpolationPhase: phases, destinationFrames: destinations),
                  timed(&timing.interpolate, { stage.run(parameters) }) else { return nil }
            // Made from a smaller copy, an in-between frame blurs subtitles and still detail (24 against 35 dB on
            // burned-in subtitles): where the two real frames agree, their own pixels are used instead.
            let composing = CACurrentMediaTime()
            #if DEBUG
            let still = UserDefaults.standard.bool(forKey: "qaNoStill") ? nil : stillRegions
            #else
            let still = stillRegions
            #endif
            let kept = still?.compose(previous: last.buffer, next: frame.buffer, made: buffers, phases: phases) ?? buffers
            timing.compose += CACurrentMediaTime() - composing
            for (phase, buffer) in zip(phases, kept) {
                CVBufferPropagateAttachments(frame.buffer, buffer)
                made[phase] = buffer
            }
            if options.mark, let middle = buffers.first {
                inspection = (last.work ?? last.buffer, middle, frame.work ?? frame.buffer)
            }
        }
        return slots.map { slot in
            let made = slot.phase <= 0 || slot.phase >= 1 ? nil : made[slot.phase]
            return Frame(buffer: made ?? (slot.phase < 0.5 ? last.buffer : frame.buffer), time: slot.time, real: made == nil)
        }
    }

    /// QA only, every 15th source frame and outside the time budget: how the in-between frame compares.
    private func inspect() {
        guard let (before, middle, after) = inspection else { return }
        inspection = nil
        distance.previous += Self.difference(middle, before); distance.current += Self.difference(middle, after)
        distance.between += Self.difference(before, after); distance.count += 1
        brightness = (Self.meanLuma(before), Self.meanLuma(middle), Self.meanLuma(after),
                      "\(Self.fourCC(before))/\(Self.fourCC(middle)) \((CVBufferCopyAttachments(middle, .shouldPropagate) as? [String: Any])?[kCVImageBufferYCbCrMatrixKey as String] as? String ?? "no-matrix")")
    }

    private func timed(_ total: inout Double, _ work: () -> Bool) -> Bool {
        let began = CACurrentMediaTime()
        defer { total += CACurrentMediaTime() - began }
        return work()
    }

    private func shrink(_ buffer: CVPixelBuffer, with stage: Stage) -> CVPixelBuffer? {
        if shrinker == nil {
            var session: VTPixelTransferSession?
            VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session)
            shrinker = session
        }
        guard let shrinker, let small = stage.makeBuffer(), VTPixelTransferSessionTransferImage(shrinker, from: buffer, to: small) == noErr else { return nil }
        CVBufferPropagateAttachments(buffer, small)
        return small
    }

    private func scale(_ frame: Frame, with stage: Stage) -> Frame? {
        guard let buffer = stage.makeBuffer(),
              let source = VTFrameProcessorFrame(buffer: frame.buffer, presentationTimeStamp: frame.time),
              let destination = VTFrameProcessorFrame(buffer: buffer, presentationTimeStamp: frame.time),
              stage.run(VTLowLatencySuperResolutionScalerParameters(sourceFrame: source, destinationFrame: destination)) else { return nil }
        CVBufferPropagateAttachments(frame.buffer, buffer)
        return Frame(buffer: buffer, time: frame.time, real: frame.real)
    }

    // MARK: Processors

    /// Starts the processors this source needs and drops the ones it no longer does.
    private func prepare(width: Int, height: Int, work: (width: Int, height: Int), format: OSType) {
        let factor = options.upscale ? Self.scaleFactor(width: width, height: height, target: options.target) : nil
        let scaleKey = factor.map { "scale \(width)x\(height) x\($0)" }
        let tooFast = interval.map { $0 <= 1 / 47.0 } ?? false
        let smoothKey = options.smooth && !tooFast && Self.interpolationFits(width: work.width, height: work.height)
            ? "smooth \(work.width)x\(work.height)\(work != (width, height) ? " from \(width)x\(height)" : "")" : nil
        wanted = (scaleKey, smoothKey)
        if scaler?.key != scaleKey { scaler = nil }
        if interpolator?.key != smoothKey { interpolator = nil }
        if let scaleKey, let factor, scaler == nil {
            start(scaleKey) {
                let configuration = VTLowLatencySuperResolutionScalerConfiguration(frameWidth: width, frameHeight: height, scaleFactor: factor)
                guard configuration.supportedPixelFormats.contains(format) else { throw StageError.format }
                return try Stage(key: scaleKey, configuration: configuration, destination: configuration.destinationPixelBufferAttributes, source: (width, height),
                                 width: Int((Float(width) * factor).rounded()), height: Int((Float(height) * factor).rounded()), format: format)
            }
        }
        if let smoothKey, interpolator == nil {
            start(smoothKey) {
                // Two: exact phases come back at about an eighth of a frame either way, and three cost ~5 ms more a frame (M1 Pro).
                guard let configuration = VTLowLatencyFrameInterpolationConfiguration(frameWidth: work.width, frameHeight: work.height, numberOfInterpolatedFrames: 2)
                else { throw StageError.unsupported }
                guard configuration.supportedPixelFormats.contains(format) else { throw StageError.format }
                return try Stage(key: smoothKey, configuration: configuration, destination: configuration.destinationPixelBufferAttributes, source: work,
                                 width: work.width, height: work.height, format: format)
            }
        }
    }

    private func start(_ key: String, make: @escaping @Sendable () throws -> Stage) {
        guard !refused.contains(key), !starting.contains(key) else { return }
        starting.insert(key)
        setup.async { [weak self] in
            let began = CACurrentMediaTime()
            let result = Result { try make() }
            let took = Int((CACurrentMediaTime() - began) * 1000)
            self?.queue.async { [weak self] in
                guard let self else { return }
                starting.remove(key)
                switch result {
                case .success(let stage):
                    if wanted.scale == key { scaler = stage }
                    else if wanted.smooth == key { interpolator = stage }
                    else { return }
                    note("\(key) started in \(took) ms")
                case .failure(let error):
                    refused.insert(key)
                    note("\(key) unavailable: \(Diagnostics.describe(error))")
                }
            }
        }
    }

    /// A processor that keeps failing (some systems accept a size at start and then refuse every frame) is dropped.
    private func failed(_ stage: Stage) {
        counts.failed += 1
        stage.failures += 1
        guard stage.failures >= 10 else { return }
        refused.insert(stage.key)
        if scaler === stage { scaler = nil }
        if interpolator === stage { interpolator = nil }
        note("\(stage.key) dropped after repeated failures")
    }

    /// When the work takes most of a frame's time, the device can't keep up: give up upscaling first, then smoothing.
    private func budget(_ spent: Double) {
        let allowance = (interval ?? 1 / 30.0) * 0.92
        slow = spent > allowance ? slow + 1 : max(0, slow - 1)
        guard slow > 45 else { return }
        slow = 0
        if let scaler {
            refused.insert(scaler.key); self.scaler = nil
            note("\(scaler.key) too slow (\(Int(spent * 1000)) ms a frame), dropped")
        } else if let interpolator {
            refused.insert(interpolator.key); self.interpolator = nil
            if workBudget > 960 * 540 {
                workBudget = 960 * 540
                note("\(interpolator.key) too slow (\(Int(spent * 1000)) ms a frame), trying 540p")
            } else {
                note("\(interpolator.key) too slow (\(Int(spent * 1000)) ms a frame), dropped")
            }
        }
    }

    /// The size the interpolator works at: the picture itself, or a copy within `workBudget`.
    private func workSize(width: Int, height: Int) -> (width: Int, height: Int) {
        guard width * height > workBudget else { return (width, height) }
        let scale = (Double(workBudget) / Double(width * height)).squareRoot()
        return (Int(Double(width) * scale) / 16 * 16, Int(Double(height) * scale) / 2 * 2)
    }

    /// Upscale any picture drawn larger than it is, by the processor's factor nearest the gap. Below 1.5x the
    /// layer shrinks the result to fit and keeps the detail: 720p in a 1613-pixel-wide window (a 1x monitor)
    /// needs only 1.1x, and a 1.4x floor left it unprocessed.
    private static func scaleFactor(width: Int, height: Int, target: CGSize) -> Float? {
        guard target.width > 0, target.height > 0, width > 0, height > 0 else { return nil }
        let need = Float(min(target.width / CGFloat(width), target.height / CGFloat(height)))
        guard need > 1.05 else { return nil }
        let factors = VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(frameWidth: width, frameHeight: height).filter { $0 > 1 }.sorted()
        return factors.min { abs($0 - need) < abs($1 - need) }
    }

    /// OS 27 reports the interpolator's size limit. OS 26 has no query, and above 1280×720 its sessions
    /// start and then fail every frame (reported by other developers), so stay within that there.
    private static func interpolationFits(width: Int, height: Int) -> Bool {
        if #available(macOS 27, iOS 27, tvOS 27, *) {
            guard let side = VTLowLatencyFrameInterpolationConfiguration.maximumDimension(forSpatialScaleFactor: 1),
                  let pixels = VTLowLatencyFrameInterpolationConfiguration.maximumPixelCount(forSpatialScaleFactor: 1) else { return false }
            return max(width, height) <= side && width * height <= pixels
        }
        return max(width, height) <= 1280 && width * height <= 1280 * 720
    }

    private static func isHDR(_ buffer: CVPixelBuffer) -> Bool {
        let attachments = CVBufferCopyAttachments(buffer, .shouldPropagate) as? [String: Any]
        guard let transfer = attachments?[kCVImageBufferTransferFunctionKey as String] as? String else { return false }
        return transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String || transfer == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String
    }

    // MARK: Reporting

    private func update(_ next: VideoEnhancementStatus, note: String? = nil) {
        let now = CACurrentMediaTime()
        guard next != status || note != nil || now - lastReport > 1 else { return }
        if next != status, !next.active { flush(removingImage: true) }
        if now - lastReport > 0.5 {
            drawnRate = lastReport > 0 ? Double(counts.shown - shownAtReport) / (now - lastReport) : 0
            shownAtReport = counts.shown
            lastReport = now
        }
        status = next
        report(next, summary, note, lastFormat.map(VideoFormatBox.init))
    }

    private func note(_ text: String) { update(status, note: text) }

    /// What the layer itself reports: its status, the frame it shows now, and its clock against the item's.
    private var rendererState: String {
        #if !DEBUG
        return ""
        #else
        var text = " · renderer \(renderer.status.rawValue)"
        if let error = renderer.error { text += " error \((error as NSError).code)" }
        if let shown = renderer.displayedPixelBuffer() { text += " showing \(CVPixelBufferGetWidth(shown))x\(CVPixelBufferGetHeight(shown))" }
        else { text += " showing nothing" }
        if let timebase = renderer.timebase as CMTimebase?, let output {
            let clock = CMTimebaseGetTime(timebase).seconds, item = output.itemTime(forHostTime: CACurrentMediaTime()).seconds
            text += String(format: " clock %.2f item %.2f rate %.1f", clock, item, CMTimebaseGetRate(timebase))
        }
        return text
        #endif
    }

    private var summary: String {
        let average = counts.frames > 0 ? counts.busy / Double(counts.frames) * 1000 : 0
        let parts = [scaler?.key, interpolator?.key, hdr ? "hdr" : nil].compactMap { $0 }
        return (parts.isEmpty ? "idle" : parts.joined(separator: ", "))
            + String(format: " · %.1f → %.1f fps", interval.map { 1 / $0 } ?? 0, drawnRate)
            + rendererState
            + (options.mark ? String(format: " · displayed %.1f fps · mid-prev %.1f mid-next %.1f prev-next %.1f", probe.rate,
                                     distance.previous / Double(max(1, distance.count)), distance.current / Double(max(1, distance.count)),
                                     distance.between / Double(max(1, distance.count)))
                           + String(format: " · luma prev %.1f mid %.1f next %.1f ", brightness.previous, brightness.middle, brightness.current) + brightness.range : "")
            + String(format: " · shrink %.1f interp %.1f compose %.1f ms", timing.shrink / Double(max(1, counts.frames)) * 1000,
                            timing.interpolate / Double(max(1, counts.frames)) * 1000, timing.compose / Double(max(1, counts.frames)) * 1000)
            + String(format: " · in %d shown %d late %d failed %d cuts %d (max %.2f/%.0f) · %.1f ms, lead %.0f ms", counts.frames, counts.shown, counts.late,
                            counts.failed, counts.cuts, changeMax.histogram, changeMax.difference, average, counts.shown > 0 ? counts.lead / Double(counts.shown) * 1000 : 0)
    }
}

private enum StageError: Error { case unsupported, format, pool }

/// Where the two real frames around an in-between one agree (subtitles, logos, a still background), the nearer real
/// frame's own full-resolution pixels; where they differ, the in-between frame (made from a smaller copy for big
/// pictures). Two Metal passes: a half-resolution map of what moves, once per interval, then a blend per frame.
@available(macOS 26, iOS 26, tvOS 26, *)
private final class StillRegions: @unchecked Sendable {
    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    // 1 where the two real frames differ (anything moving, with a margin), 0 where they agree.
    kernel void motion(texture2d<float, access::read> prev [[texture(0)]], texture2d<float, access::read> next [[texture(1)]],
                       texture2d<float, access::write> out [[texture(2)]], constant float &threshold [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
        int2 last = int2(prev.get_width(), prev.get_height()) - 1;
        float d = 0;
        for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) {
            uint2 p = uint2(clamp(int2(gid) * 2 + int2(dx, dy) * 2, int2(0), last));
            d = max(d, abs(prev.read(p).r - next.read(p).r));
        }
        out.write(float4(smoothstep(threshold, threshold * 2.5, d)), gid);
    }
    kernel void compose(texture2d<float, access::read> prev [[texture(0)]], texture2d<float, access::read> next [[texture(1)]],
                        texture2d<float, access::sample> made [[texture(2)]], texture2d<float, access::sample> moving [[texture(3)]],
                        texture2d<float, access::write> out [[texture(4)]], constant float &phase [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
        uint2 size = uint2(out.get_width(), out.get_height());
        if (gid.x >= size.x || gid.y >= size.y) return;
        constexpr sampler linear(filter::linear, coord::normalized, address::clamp_to_edge);
        float2 uv = (float2(gid) + 0.5) / float2(size);
        float4 real = phase < 0.5 ? prev.read(gid) : next.read(gid);
        out.write(mix(real, made.sample(linear, uv), moving.sample(linear, uv).r), gid);
    }
    """
    /// Below this difference (0...1) a pixel counts as still: above compression noise, below real motion.
    private static let threshold: Float = 0.04

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let motion: MTLComputePipelineState
    private let blend: MTLComputePipelineState
    private let cache: CVMetalTextureCache
    private var pool: (width: Int, height: Int, pool: CVPixelBufferPool)?
    private var map: MTLTexture?

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shader, options: nil),
              let motion = library.makeFunction(name: "motion").flatMap({ try? device.makeComputePipelineState(function: $0) }),
              let blend = library.makeFunction(name: "compose").flatMap({ try? device.makeComputePipelineState(function: $0) }) else { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess, let cache else { return nil }
        self.device = device; self.queue = queue; self.motion = motion; self.blend = blend; self.cache = cache
    }

    /// All the in-between frames of one interval in a single GPU submission; nil when any of it fails.
    func compose(previous: CVPixelBuffer, next: CVPixelBuffer, made: [CVPixelBuffer], phases: [Float]) -> [CVPixelBuffer]? {
        let width = CVPixelBufferGetWidth(previous), height = CVPixelBufferGetHeight(previous)
        guard CVPixelBufferGetPlaneCount(previous) == 2, CVPixelBufferGetWidth(next) == width, CVPixelBufferGetHeight(next) == height,
              let map = motionMap(width: (width + 1) / 2, height: (height + 1) / 2),
              let commands = queue.makeCommandBuffer() else { return nil }
        var textures: [CVMetalTexture] = []   // kept until the GPU is done
        var planes: [[MTLTexture]] = []
        for plane in 0...1 {
            guard let prev = texture(previous, plane, &textures), let nextTexture = texture(next, plane, &textures) else { return nil }
            planes.append([prev, nextTexture])
        }
        guard let encoder = commands.makeComputeCommandEncoder() else { return nil }
        encoder.setComputePipelineState(motion)
        encoder.setTexture(planes[0][0], index: 0); encoder.setTexture(planes[0][1], index: 1); encoder.setTexture(map, index: 2)
        var threshold = Self.threshold
        encoder.setBytes(&threshold, length: MemoryLayout<Float>.size, index: 0)
        encoder.dispatchThreads(MTLSize(width: map.width, height: map.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        var outputs: [CVPixelBuffer] = []
        encoder.setComputePipelineState(blend)
        for (buffer, phase) in zip(made, phases) {
            guard CVPixelBufferGetPlaneCount(buffer) == 2,
                  let out = makeBuffer(width: width, height: height, format: CVPixelBufferGetPixelFormatType(previous)) else { encoder.endEncoding(); return nil }
            for plane in 0...1 {
                guard let madeTexture = texture(buffer, plane, &textures), let target = texture(out, plane, &textures) else { encoder.endEncoding(); return nil }
                for (index, item) in [planes[plane][0], planes[plane][1], madeTexture, map, target].enumerated() { encoder.setTexture(item, index: index) }
                var value = phase
                encoder.setBytes(&value, length: MemoryLayout<Float>.size, index: 0)
                encoder.dispatchThreads(MTLSize(width: target.width, height: target.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            }
            CVBufferPropagateAttachments(previous, out)
            outputs.append(out)
        }
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        withExtendedLifetime(textures) {}
        return commands.status == .completed ? outputs : nil
    }

    private func motionMap(width: Int, height: Int) -> MTLTexture? {
        if let map, map.width == width, map.height == height { return map }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        map = device.makeTexture(descriptor: descriptor)
        return map
    }

    private func texture(_ buffer: CVPixelBuffer, _ plane: Int, _ keep: inout [CVMetalTexture]) -> MTLTexture? {
        var made: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer, nil, plane == 0 ? .r8Unorm : .rg8Unorm,
                                                  CVPixelBufferGetWidthOfPlane(buffer, plane), CVPixelBufferGetHeightOfPlane(buffer, plane), plane, &made)
        guard let made, let texture = CVMetalTextureGetTexture(made) else { return nil }
        keep.append(made)
        return texture
    }

    private func makeBuffer(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        if pool?.width != width || pool?.height != height {
            var made: CVPixelBufferPool?
            let attributes: [String: Any] = [kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                                             kCVPixelBufferPixelFormatTypeKey as String: format,
                                             kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
                                             kCVPixelBufferMetalCompatibilityKey as String: true]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &made)
            pool = made.map { (width, height, $0) }
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool.pool, &buffer)
        return buffer
    }
}

/// One running processor and the pool its output frames come from.
@available(macOS 26, iOS 26, tvOS 26, *)
private final class Stage: @unchecked Sendable {
    let key: String
    var failures = 0
    /// The size of the frames it takes.
    let source: (width: Int, height: Int)
    private let processor = VTFrameProcessor()
    private let pool: CVPixelBufferPool

    init(key: String, configuration: any VTFrameProcessorConfiguration, destination: [String: Any], source: (width: Int, height: Int),
         width: Int, height: Int, format: OSType) throws {
        self.key = key
        self.source = source
        var attributes = destination
        attributes[kCVPixelBufferWidthKey as String] = width
        attributes[kCVPixelBufferHeightKey as String] = height
        attributes[kCVPixelBufferPixelFormatTypeKey as String] = format
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess, let pool else { throw StageError.pool }
        self.pool = pool
        try processor.startSession(configuration: configuration)
    }

    deinit { processor.endSession() }

    func accepts(_ buffer: CVPixelBuffer) -> Bool {
        CVPixelBufferGetWidth(buffer) == source.width && CVPixelBufferGetHeight(buffer) == source.height
    }

    func makeBuffer() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }

    /// Runs one request and waits for it: this queue does nothing else meanwhile.
    func run(_ parameters: any VTFrameProcessorParameters) -> Bool {
        let done = DispatchSemaphore(value: 0)
        let outcome = Outcome()
        processor.process(parameters: parameters) { _, error in
            outcome.error = error
            done.signal()
        }
        guard done.wait(timeout: .now() + 0.5) == .success else { return false }
        return outcome.error == nil
    }

    private final class Outcome: @unchecked Sendable { var error: Error? }
}
#endif

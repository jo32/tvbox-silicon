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

@MainActor @Observable private final class DiscoverTrailerPlayback {
    let player = AVQueuePlayer()
    var ready = false
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
                    self.ready = true
                    self.report("playing:\(String(format: "%.1f", time.seconds))", trailer)
                }
            }
        }
        player.play()
    }
    func stop() {
        generation += 1
        ready = false
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
    var readyChanged: (Bool) -> Void = { _ in }
    @State private var playback = DiscoverTrailerPlayback()
    var body: some View {
        DiscoverTrailerLayer(player: playback.player)
            .opacity(playback.ready ? 1 : 0)
            .animation(.easeOut(duration: 0.4), value: playback.ready)
            .accessibilityHidden(true)
            .onChange(of: playback.ready) { _, ready in readyChanged(ready) }
            .task(id: trailer) { await playback.load(trailer) }
            .onDisappear { playback.stop() }
    }
}

#if os(macOS)
private struct DiscoverTrailerLayer: NSViewRepresentable {
    let player: AVPlayer
    final class Host: NSView {
        let video = AVPlayerLayer()
        let fade = CAGradientLayer()
        override init(frame: NSRect) {
            super.init(frame: frame); wantsLayer = true; layer?.addSublayer(video); video.videoGravity = .resizeAspectFill
            fade.startPoint = CGPoint(x: 0.5, y: 0); fade.endPoint = CGPoint(x: 0.5, y: 1)
            fade.colors = [1.0, 1.0, 0.85, 0.35, 0.0].map { NSColor.black.withAlphaComponent($0).cgColor }
            fade.locations = [0, 0.5, 0.7, 0.87, 1]; layer?.mask = fade
        }
        required init?(coder: NSCoder) { nil }
        override func layout() {
            super.layout(); CATransaction.begin(); CATransaction.setDisableActions(true)
            video.frame = bounds.insetBy(dx: -bounds.width * 0.1, dy: -bounds.height * 0.1); fade.frame = bounds
            CATransaction.commit()
        }
    }
    func makeNSView(context: Context) -> Host { let view = Host(); view.video.player = player; return view }
    func updateNSView(_ view: Host, context: Context) { view.video.player = player }
    static func dismantleNSView(_ view: Host, coordinator: ()) { view.video.player = nil }
}
#else
private struct DiscoverTrailerLayer: UIViewRepresentable {
    let player: AVPlayer
    final class Host: UIView {
        let video = AVPlayerLayer()
        let fade = CAGradientLayer()
        override init(frame: CGRect) {
            super.init(frame: frame); layer.addSublayer(video); video.videoGravity = .resizeAspectFill
            fade.startPoint = CGPoint(x: 0.5, y: 0); fade.endPoint = CGPoint(x: 0.5, y: 1)
            fade.colors = [1.0, 1.0, 0.85, 0.35, 0.0].map { UIColor.black.withAlphaComponent($0).cgColor }
            fade.locations = [0, 0.5, 0.7, 0.87, 1]; layer.mask = fade
        }
        required init?(coder: NSCoder) { nil }
        override func layoutSubviews() {
            super.layoutSubviews(); CATransaction.begin(); CATransaction.setDisableActions(true)
            video.frame = bounds.insetBy(dx: -bounds.width * 0.1, dy: -bounds.height * 0.1); fade.frame = bounds
            CATransaction.commit()
        }
    }
    func makeUIView(context: Context) -> Host { let view = Host(); view.video.player = player; return view }
    func updateUIView(_ view: Host, context: Context) { view.video.player = player }
    static func dismantleUIView(_ view: Host, coordinator: ()) { view.video.player = nil }
}
#endif

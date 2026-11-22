#if os(iOS) || os(macOS)
import AVFoundation
import SwiftUI
import TVCore
#if os(iOS)
import UIKit
#endif

/// Casting to a TV or box over DLNA (投屏, #749), from iPhone, iPad and Mac. AirPlay and Play On cover Apple devices;
/// this covers the TVs most homes have. The TV fetches the video itself: straight from the source when the address
/// needs nothing else, otherwise through `CastRelay` on this device. While the TV plays, the player here stays paused
/// and its panel drives the TV.
@MainActor @Observable final class CastController {
    static let shared = CastController()

    /// The renderers the last search found.
    private(set) var devices: [DLNADevice] = []
    private(set) var searching = false
    /// iOS without Apple's multicast entitlement: only TVs that answer a unicast search show up.
    private(set) var multicastBlocked = false
    @ObservationIgnored private var searchedAt: Date?
    @ObservationIgnored private var search: Task<Void, Never>?

    /// The TV playing what was sent, while a player here drives it.
    private(set) var device: DLNADevice?
    private(set) var position = 0.0
    private(set) var duration = 0.0
    private(set) var paused = false
    /// The TV fetches through this device, which must stay awake with Yingxia open.
    private(set) var relayed = false
    private(set) var volume: Int?
    var failure: String?
    @ObservationIgnored private var poll: Task<Void, Never>?
    /// A seek just sent: the TV's old position isn't shown meanwhile, so the bar doesn't jump back.
    @ObservationIgnored private var heldUntil = Date.distantPast
    #if os(iOS)
    @ObservationIgnored private var idleBefore: Bool?
    #endif

    /// Looks for TVs when the player opens: a few packets, at most every ten minutes unless asked again.
    func refresh(force: Bool = false) {
        guard search == nil else { return }
        if !force, let searchedAt, Date().timeIntervalSince(searchedAt) < 600 { return }
        searching = true
        var unicast = false
        #if DEBUG
        // `-qaCastUnicast 1`: searches as an iPhone without the multicast entitlement does.
        unicast = UserDefaults.standard.bool(forKey: "qaCastUnicast")
        #endif
        search = Task { [weak self] in
            let result = await DLNADiscovery.search(seconds: 3, forceUnicast: unicast)
            guard let self else { return }
            // Yingxia on a Mac or Apple TV also takes DLNA casts (for Bilibili), and Play On already lists it with more.
            devices = result.devices.filter { device in !["映匣 · ", "Yingxia · "].contains { device.name.hasPrefix($0) } }
            multicastBlocked = result.multicastBlocked
            searchedAt = .now
            searching = false
            search = nil
        }
    }

    /// Sends `channel` to the TV and starts it there, from `start` when the TV allows seeking.
    func cast(_ channel: Channel, title: String, from start: Double?, to target: DLNADevice) async throws {
        let stream = try await CastStream.resolve(channel)
        let address: URL
        if stream.direct {
            address = stream.url
        } else {
            await CastRelay.shared.reset()
            address = try await CastRelay.shared.address(for: stream.url, headers: stream.headers, playlist: stream.playlist,
                                                         towards: target.location.host())
        }
        let mime = stream.playlist ? DLNA.mime(for: URL(string: "x.m3u8")!) : DLNA.mime(for: stream.url)
        Diagnostics.shared.record(.info, "cast", "send model=\(target.model) relayed=\(!stream.direct) playlist=\(stream.playlist) host=\(stream.url.host() ?? "-")")
        try await DLNARenderer(target).load(address, title: title, mime: mime)
        poll?.cancel()
        device = target; relayed = !stream.direct; position = start ?? 0; duration = 0; paused = false; failure = nil; volume = nil
        #if os(iOS)
        if relayed, idleBefore == nil { idleBefore = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true }
        #endif
        follow(target, resumeAt: start ?? 0)
    }

    func togglePause() {
        guard let device else { return }
        let pausing = !paused
        paused = pausing
        act { pausing ? try await DLNARenderer(device).pause() : try await DLNARenderer(device).play() }
    }

    func skip(by seconds: Double) { seek(to: position + seconds) }

    func seek(to seconds: Double) {
        guard let device else { return }
        let target = max(0, duration > 0 ? min(seconds, duration - 1) : seconds)
        position = target
        heldUntil = Date().addingTimeInterval(3)
        act { try await DLNARenderer(device).seek(to: target) }
    }

    func changeVolume(by step: Int) {
        guard let device, let current = volume else { return }
        let next = min(100, max(0, current + step))
        volume = next
        act { try await DLNARenderer(device).setVolume(next) }
    }

    /// Stops the TV and gives back where it was, for the player here to carry on from.
    @discardableResult
    func stop() async -> Double? {
        guard let device else { return nil }
        let reached = position
        end()
        try? await DLNARenderer(device).stop()
        Diagnostics.shared.record(.info, "cast", "stopped at=\(Int(reached))")
        return reached
    }

    /// The player closed: the TV plays on by itself, and nothing here keeps asking it.
    func detach() { end() }

    private func end() {
        poll?.cancel(); poll = nil
        device = nil; relayed = false; failure = nil
        #if os(iOS)
        if let idleBefore { UIApplication.shared.isIdleTimerDisabled = idleBefore; self.idleBefore = nil }
        #endif
    }

    private func act(_ action: @escaping @Sendable () async throws -> Void) {
        Task {
            do { try await action(); failure = nil }
            catch { failure = error.localizedDescription }
        }
    }

    /// Asks the TV where it is every 1.5 s while it plays what was sent; seeks to `resumeAt` once it has started.
    private func follow(_ target: DLNADevice, resumeAt: Double) {
        let renderer = DLNARenderer(target)
        poll = Task { [weak self] in
            var started = false, misses = 0
            let deadline = Date().addingTimeInterval(20)
            if let level = try? await renderer.volume() { self?.volume = level }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1500))
                guard !Task.isCancelled, let self, self.device == target else { return }
                do {
                    let state = try await renderer.state()
                    let (position, duration) = try await renderer.position()
                    misses = 0
                    if Date() > heldUntil { self.position = position }
                    if duration > 0 { self.duration = duration }
                    if state == "PLAYING" || state == "PAUSED_PLAYBACK" { self.paused = state == "PAUSED_PLAYBACK" }
                    // Most TVs refuse a seek until they play; the place the viewer was at comes once they do.
                    if !started, state == "PLAYING" {
                        started = true
                        if resumeAt > 5, position < resumeAt - 5 {
                            self.heldUntil = Date().addingTimeInterval(3)
                            self.position = resumeAt
                            try? await renderer.seek(to: resumeAt)
                        }
                    } else if !started, Date() > deadline { started = true }
                } catch {
                    misses += 1
                    if misses == 4 { self.failure = error.localizedDescription }
                }
            }
        }
    }
}

/// What a TV is given for a channel: the stream behind a plugin's proxy or a drive link, and whether it needs the relay.
enum CastStream {
    struct Resolved {
        var url: URL
        var headers: [String: String]
        /// The TV can fetch it as it is: on the network, with no headers to send.
        var direct: Bool
        var playlist: Bool
    }

    static func resolve(_ channel: Channel) async throws -> Resolved {
        var address = try await EmbeddedJarHost.shared.recoverProxy(channel.url)
        var headers = channel.headers
        if CloudFiles.isFile(address) { address = try await CloudFiles.prepare(address) }
        // A drive file the plugin only proxies goes from the drive itself, as it plays here (PlaybackSession.prepare).
        if let media = await EmbeddedJarHost.shared.directMedia(address) {
            address = media.url; headers = media.headers
        } else if let media = await CatPawOpen.proxiedMedia(address, headers: headers) {
            let source = await CatPawOpen.directMedia(media) ?? media
            address = source.url; headers = source.headers
        }
        guard address.scheme == "http" || address.scheme == "https" else {
            throw TVError.unsupported(L10n.text("This video plays only on this device and can't be sent to a TV."))
        }
        let playlist = await isPlaylist(address, headers: headers)
        return Resolved(url: address, headers: headers, direct: headers.isEmpty && PlayOn.isPortable(address), playlist: playlist)
    }

    /// Whether the address is an HLS playlist: by its name, or by its first bytes for a plugin's route that names none.
    private static func isPlaylist(_ url: URL, headers: [String: String]) async -> Bool {
        let name = url.pathExtension.lowercased()
        if name == "m3u8" || name == "m3u" { return true }
        if ["mp4", "mkv", "flv", "ts", "mov", "avi", "webm", "m4v"].contains(name) { return false }
        var request = URLRequest(url: url, timeoutInterval: 8)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        request.setValue("bytes=0-15", forHTTPHeaderField: "Range")
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return false }
        if (response.mimeType ?? "").lowercased().contains("mpegurl") { return true }
        return data.prefix(16).starts(with: Data("#EXTM3U".utf8))
    }
}

/// Over the paused picture while a TV plays the video: where it plays, and the TV's controls.
struct CastPanel: View {
    let playHere: () -> Void
    @State private var scrub: Double?

    var body: some View {
        let cast = CastController.shared
        VStack(spacing: 14) {
            Image(systemName: "tv").font(.system(size: 44, weight: .light))
            Text(L10n.text("Playing on %@", cast.device?.name ?? "")).font(.callout)
            if cast.duration > 0 {
                VStack(spacing: 4) {
                    Slider(value: Binding(get: { min(scrub ?? cast.position, cast.duration) }, set: { scrub = $0 }), in: 0...cast.duration) { editing in
                        if !editing, let scrub { cast.seek(to: scrub); self.scrub = nil }
                    }
                    HStack {
                        Text(Self.time(scrub ?? cast.position))
                        Spacer()
                        Text(Self.time(cast.duration))
                    }
                    .font(.caption.monospacedDigit())
                }
                .frame(maxWidth: 360)
            }
            HStack(spacing: 26) {
                button("gobackward.10", L10n.text("Back 10 Seconds")) { cast.skip(by: -10) }
                button(cast.paused ? "play.fill" : "pause.fill", cast.paused ? L10n.text("Play") : L10n.text("Pause")) { cast.togglePause() }
                button("goforward.10", L10n.text("Forward 10 Seconds")) { cast.skip(by: 10) }
                if cast.volume != nil {
                    button("speaker.wave.1.fill", L10n.text("Volume Down")) { cast.changeVolume(by: -5) }
                    button("speaker.wave.3.fill", L10n.text("Volume Up")) { cast.changeVolume(by: 5) }
                }
            }
            .font(.title2)
            if cast.relayed {
                Text(L10n.text("Keep Yingxia open while the TV plays this video.")).font(.caption).opacity(0.7)
            }
            if let failure = cast.failure {
                Text(failure).font(.caption).foregroundStyle(.orange).lineLimit(3)
            }
            Button(L10n.text("Play Here"), action: playHere)
                .controlButton()
                .accessibilityIdentifier("player.playHere")
        }
        .foregroundStyle(.white.opacity(0.85))
        .multilineTextAlignment(.center)
        .padding(32)
        .accessibilityIdentifier("player.castPanel")
    }

    private func button(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 36, height: 36).contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
    }

    static func time(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds : 0))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}
#endif

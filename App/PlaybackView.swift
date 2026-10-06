import SwiftUI
import AVKit
import TVCore

@MainActor @Observable final class PlaybackSession {
    let player = AVPlayer()
    var error: String?
    var loading = true
    var looping = false
    var buffering = false
    /// Download state while connecting or buffering, sampled once a second from AVFoundation's logs.
    struct Transfer {
        var received: Int64 = 0
        /// Over the last few seconds; nil until two samples exist.
        var bytesPerSecond: Double?
        /// What the playing variant needs to play without stalling.
        var required: Double?
        var host: String?
        /// The latest failure while loading media: an HTTP status, or a network error description.
        var failure: String?
        var httpStatus: Int?
    }
    private(set) var transfer = Transfer()
    private var sampler: Task<Void, Never>?
    private var endObserver: NSObjectProtocol?
    private var timeObservation: NSKeyValueObservation?

    func togglePlayback() {
        if player.timeControlStatus == .paused {
            if let item = player.currentItem, item.duration.seconds.isFinite,
               player.currentTime().seconds >= item.duration.seconds - 0.1 {
                player.seek(to: .zero)
            }
            player.play()
        } else { player.pause() }
    }

    func skip(_ seconds: Double) {
        guard let item = player.currentItem, item.status == .readyToPlay else { return }
        let current = player.currentTime().seconds
        guard current.isFinite else { return }
        let ranges = item.seekableTimeRanges.map(\.timeRangeValue)
        guard let range = ranges.first(where: { CMTimeRangeContainsTime($0, time: player.currentTime()) }) ?? ranges.last else { return }
        let target = min(max(current + seconds, range.start.seconds), range.end.seconds)
        guard target.isFinite else { return }
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    func setSpeed(_ speed: Float) {
        player.defaultRate = speed
        if player.rate != 0 { player.rate = speed }
    }
    private var generation = UUID()
    private var observation: NSKeyValueObservation?
    private var failureObserver: NSObjectProtocol?
    private var preparation: Task<Void, Never>?
    #if os(macOS)
    private var proxy: HLSProxy?
    #endif
    func start(_ channel: Channel) {
        stop(); error = nil; loading = true
        let activeGeneration = generation
        preparation = Task { [weak self] in
            guard let self else { return }
            var address = channel.url
            #if os(macOS)
            if address.pathExtension.lowercased() == "m3u8" {
                let adapter = HLSProxy(headers: channel.headers)
                self.proxy = adapter
                do { address = try await adapter.start(url: address) }
                catch {
                    guard self.generation == activeGeneration, !Task.isCancelled else { return }
                    self.error = error.localizedDescription; self.loading = false; return
                }
            }
            #endif
            guard self.generation == activeGeneration, !Task.isCancelled else { return }
            self.configure(channel, url: address, generation: activeGeneration)
        }
    }
    private func configure(_ channel: Channel, url: URL, generation activeGeneration: UUID) {
        #if !os(macOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { self.error = error.localizedDescription }
        #endif
        // Some providers require request headers. AVURLAsset's HTTP-header option is
        // best-effort and is not a guarantee for every redirected HLS segment.
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": channel.headers])
        let item = AVPlayerItem(asset: asset)
        observation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let status = item.status
            let message = item.error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, self.generation == activeGeneration else { return }
                if status == .readyToPlay { self.loading = false }
                if status == .failed { self.loading = false; self.error = message ?? L10n.text("This media cannot be played. Try another channel or source.") }
            }
        }
        failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] notification in
            let message = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, self.generation == activeGeneration else { return }
                self.error = message ?? L10n.text("Playback was interrupted."); self.loading = false
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == activeGeneration, self.looping else { return }
                self.player.seek(to: .zero)
                self.player.play()
            }
        }
        timeObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            Task { @MainActor [weak self] in
                guard let self, self.generation == activeGeneration else { return }
                self.buffering = waiting
            }
        }
        player.preventsDisplaySleepDuringVideoPlayback = true
        player.replaceCurrentItem(with: item)
        player.play()
        let origin = channel.url.host()
        sampler = Task { [weak self] in
            var history: [(date: Date, bytes: Int64)] = []
            var tick = 0
            while !Task.isCancelled {
                guard self?.sample(&history, tick: tick, origin: origin, generation: activeGeneration) == true else { return }
                tick += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    private func sample(_ history: inout [(date: Date, bytes: Int64)], tick: Int, origin: String?, generation activeGeneration: UUID) -> Bool {
        guard generation == activeGeneration else { return false }
        guard let item = player.currentItem else { return true }
        let events = item.accessLog()?.events ?? []
        let now = Date()
        var next = Transfer(received: events.reduce(Int64(0)) { $0 + max(0, $1.numberOfBytesTransferred) })
        #if os(macOS)
        // HLS goes through the local proxy, which sees upstream bytes as they arrive.
        let upstream = proxy?.stats.snapshot
        if let upstream { next.received = max(next.received, upstream.received) }
        #endif
        history.append((now, next.received))
        history.removeAll { now.timeIntervalSince($0.date) > 5 }
        if let first = history.first, now.timeIntervalSince(first.date) >= 1 {
            next.bytesPerSecond = Double(next.received - first.bytes) / now.timeIntervalSince(first.date)
        }
        // Prefer the decoded media's own bitrate; single-variant playlists declare none. AVFoundation's
        // average counts a half-fetched segment's bytes against finished durations, so it runs high
        // mid-segment and settles at each boundary: keep the lowest value seen.
        if let last = events.last {
            let media = max(0, last.averageVideoBitrate) + max(0, last.averageAudioBitrate)
            let current = media > 0 ? media / 8 : (last.indicatedBitrate > 0 ? last.indicatedBitrate / 8 : nil)
            next.required = [current, transfer.required].compactMap { $0 }.min()
        }
        // The Mac plays HLS through a local proxy; name the real server instead.
        let segmentHost = events.last?.uri.flatMap { URL(string: $0)?.host() }
        next.host = segmentHost.flatMap { ["127.0.0.1", "localhost"].contains($0) ? nil : $0 } ?? origin
        #if os(macOS)
        if let upstream {
            next.host = upstream.host ?? next.host
            next.httpStatus = upstream.status.flatMap { (400..<600).contains($0) ? $0 : nil }
            next.failure = upstream.failure ?? upstream.status.map { "HTTP \($0)" }
        }
        #endif
        if next.failure == nil, let error = item.errorLog()?.events.last, let date = error.date, now.timeIntervalSince(date) < 30 {
            if (400..<600).contains(error.errorStatusCode) { next.httpStatus = error.errorStatusCode }
            next.failure = error.errorComment ?? "\(error.errorDomain) \(error.errorStatusCode)"
        }
        transfer = next
        if (loading || buffering) && tick % 5 == 0 {
            Diagnostics.shared.record(.debug, "player", "waiting host=\(next.host ?? "-") received=\(next.received) speed=\(Int(next.bytesPerSecond ?? -1)) required=\(Int(next.required ?? -1)) failure=\(next.failure ?? "-")")
        }
        return true
    }
    func stop() {
        generation = UUID()
        preparation?.cancel(); preparation = nil
        sampler?.cancel(); sampler = nil
        transfer = Transfer()
        #if os(macOS)
        if let proxy { Task { await proxy.stop() } }; proxy = nil
        #endif
        observation = nil
        timeObservation = nil
        buffering = false
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = nil
        player.pause(); player.replaceCurrentItem(with: nil)
    }
}

extension PlaybackSession {
    /// The player's wait, with download speed against what the video needs.
    var loadingProgress: LoadingProgress {
        let transfer = transfer
        // AVPlayer counts the first segment only once it finishes, so zero bytes means "not yet", not "stalled".
        let speed = transfer.received > 0 ? transfer.bytesPerSecond.map(Self.rate) : nil
        var progress = LoadingProgress(title: L10n.text(loading ? "Connecting…" : "Buffering…"))
        if let speed {
            progress.detail = transfer.required.map { L10n.text("%@ · needs %@", speed, Self.rate($0)) }
                ?? L10n.text("Downloading at %@", speed)
        } else if let host = transfer.host {
            progress.detail = L10n.text("Waiting for %@", host)
        }
        let server = transfer.host ?? L10n.text("The video server")
        if let status = transfer.httpStatus {
            progress.reason = L10n.text("%@ returned an error (%@). The link may have expired: go back and play the episode again, or choose another line.", server, "HTTP \(status)")
        } else if let failure = transfer.failure {
            progress.reason = L10n.text("Couldn't load video from %@ (%@). Check the connection, or choose another line.", server, failure)
        } else if transfer.received == 0 {
            progress.reason = L10n.text("%@ hasn't delivered the first part of the video yet. The server may be slow or down; try another line.", server)
        } else if let bytes = transfer.bytesPerSecond, let required = transfer.required, bytes < required {
            progress.reason = L10n.text("%@ sends %@, but this video needs about %@. Try another line, or wait without skipping.", server, Self.rate(bytes), Self.rate(required))
        } else {
            progress.reason = L10n.text("The player is filling its buffer before playback continues.")
        }
        return progress
    }
    private static func rate(_ bytesPerSecond: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false // "0 KB", not "Zero KB"
        return L10n.text("%@/s", formatter.string(fromByteCount: Int64(max(0, bytesPerSecond))))
    }
}

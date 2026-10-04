import SwiftUI
import AVKit
import TVCore

@MainActor @Observable final class PlaybackSession {
    let player = AVPlayer()
    var error: String?
    var loading = true
    var looping = false
    var buffering = false
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
    }
    func stop() {
        generation = UUID()
        preparation?.cancel(); preparation = nil
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

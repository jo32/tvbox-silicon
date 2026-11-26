import AVFoundation
import Foundation

/// A player's sleep fade owns only the item and volume with which it started.
@MainActor final class PlaybackSleepFade {
    private let duration: TimeInterval
    private let steps: Int
    private var task: Task<Void, Never>?
    private var restore: (() -> Void)?
    private var generation = UUID()
    private var rateObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    var isActive: Bool { task != nil }

    init(duration: TimeInterval = 6, steps: Int = 30) {
        self.duration = max(0, duration); self.steps = max(1, steps)
    }

    func start(_ player: AVPlayer, pause: @escaping @MainActor () -> Void) {
        cancel()
        guard let item = player.currentItem, player.rate != 0 else { pause(); return }
        start(volume: { [weak player] in player?.volume ?? 0 },
              isCurrent: { [weak player, weak item] in item != nil && player?.currentItem === item },
              shouldContinue: { [weak player] in player?.rate != 0 },
              setVolume: { [weak player] in player?.volume = $0 }, pause: pause)
        let run = generation
        // A pause followed immediately by Play still cancels this run, even between fade ticks.
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] _, change in
            guard change.newValue == 0 else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == run else { return }
                self.cancel()
            }
        }
        itemObservation = player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == run else { return }
                self.cancel()
            }
        }
    }

    func start(volume: @escaping @MainActor () -> Float,
               isCurrent: @escaping @MainActor () -> Bool,
               shouldContinue: @escaping @MainActor () -> Bool,
               setVolume: @escaping @MainActor (Float) -> Void,
               pause: @escaping @MainActor () -> Void) {
        cancel()
        // Read after cancellation restored the previous run, never from its half-faded volume.
        let initial = volume(), run = generation, steps = steps
        var lastVolume = initial
        restore = { if isCurrent(), volume() == lastVolume { setVolume(initial) } }
        task = Task { @MainActor [weak self] in
            for step in 1...steps {
                do { try await Task.sleep(for: .seconds(self?.duration ?? 0) / Double(steps)) }
                catch { return }
                guard let self, self.generation == run else { return }
                guard isCurrent(), shouldContinue(), volume() == lastVolume else { self.cancel(); return }
                lastVolume = initial * Float(steps - step) / Float(steps)
                setVolume(lastVolume)
            }
            guard let self, self.generation == run, isCurrent() else { return }
            let restoration = self.restore
            self.restore = nil; self.task = nil
            self.rateObservation = nil; self.itemObservation = nil
            pause()
            restoration?()
        }
    }

    func cancel() {
        generation = UUID()
        task?.cancel(); task = nil
        rateObservation = nil; itemObservation = nil
        let restoration = restore; restore = nil
        restoration?()
    }
}

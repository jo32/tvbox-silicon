import Foundation
@MainActor final class Player { var item = UUID(); var volume: Float = 0.8; var playing = true; var pauses = 0 }
@main struct Check {
    @MainActor static func main() async throws {
        let player = Player(), fade = PlaybackSleepFade(duration: 0.08, steps: 4)
        func start() {
            let item = player.item
            fade.start(volume: { player.volume }, isCurrent: { player.item == item }, shouldContinue: { player.playing }, setVolume: { player.volume = $0 }, pause: { player.pauses += 1; player.playing = false })
        }
        start()
        try await Task.sleep(for: .milliseconds(30))
        player.item = UUID(); player.volume = 0.6
        try await Task.sleep(for: .milliseconds(100))
        precondition(player.pauses == 0 && player.volume == 0.6, "old fade paused or changed a replacement item")
        start()
        try await Task.sleep(for: .milliseconds(30))
        fade.cancel(); player.playing = false; player.playing = true
        try await Task.sleep(for: .milliseconds(100))
        precondition(player.pauses == 0 && player.volume == 0.6, "pause/resume was overridden by old fade")
        start()
        try await Task.sleep(for: .milliseconds(30))
        player.volume = 0.9
        try await Task.sleep(for: .milliseconds(100))
        precondition(player.pauses == 0 && player.volume == 0.9, "external volume was overwritten")
        start(); start()
        try await Task.sleep(for: .milliseconds(120))
        precondition(player.pauses == 1 && player.volume == 0.9, "replacement fade lost starting volume or paused twice")
        var order: [String] = []
        let fired = NotificationCenter.default.addObserver(forName: SleepTimer.fired, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { order.append("fired") }
        }
        let changed = NotificationCenter.default.addObserver(forName: SleepTimer.changed, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { order.append("changed") }
        }
        SleepTimer.shared.stopAtEndOfItem()
        order.removeAll()
        precondition(SleepTimer.shared.itemEnded())
        precondition(order == ["fired", "changed"], "Off reenabled automatic advance before stop event")
        NotificationCenter.default.removeObserver(fired); NotificationCenter.default.removeObserver(changed)
        print("PASS: replacement identity, cancellation, pause/resume, user volume and restart")
    }
}

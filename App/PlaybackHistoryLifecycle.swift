#if os(iOS)
import UIKit
import TVCore

/// Saves the final sampled position and gives the utility writer time to finish before suspension.
@MainActor enum PlaybackHistoryLifecycle {
    static func enterBackground(history: PlaybackHistory) {
        let lease = BackgroundLease()
        lease.begin()
        let session = PlaybackSession.current
        session?.saveHistory()
        let playerHistory = session?.history
        Task { @MainActor in
            _ = await history.flushPersistence()
            if let playerHistory, playerHistory !== history { _ = await playerHistory.flushPersistence() }
            lease.end()
        }
    }

    @MainActor private final class BackgroundLease {
        private var identifier = UIBackgroundTaskIdentifier.invalid
        func begin() {
            identifier = UIApplication.shared.beginBackgroundTask(withName: "Playback history save") { [weak self] in
                Task { @MainActor [weak self] in self?.end() }
            }
        }
        func end() {
            guard identifier != .invalid else { return }
            let finished = identifier
            identifier = .invalid
            UIApplication.shared.endBackgroundTask(finished)
        }
    }
}
#endif

import TVCore
#if os(iOS) || os(tvOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Saves the final sampled position and lets the history's background writer finish: before an iPhone, iPad or
/// Apple TV app is suspended, and before a Mac app quits.
@MainActor enum PlaybackHistoryLifecycle {
    #if os(iOS) || os(tvOS)
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
    #endif

    #if os(macOS)
    private static var terminationObserver: NSObjectProtocol?
    /// A Mac app exits as soon as `willTerminate` returns, so this waits for the writes, blocking: a few milliseconds.
    /// `history` is read then, for the profile open at the time.
    static func saveOnTermination(_ history: @escaping @MainActor @Sendable () -> PlaybackHistory) {
        guard terminationObserver == nil else { return }
        // No queue: the observer runs on the posting (main) thread before the app exits.
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                     object: nil, queue: nil) { _ in
            MainActor.assumeIsolated {
                let history = history()
                let session = PlaybackSession.current
                session?.saveHistory()
                history.waitForPendingWrites()
                if let playerHistory = session?.history, playerHistory !== history { playerHistory.waitForPendingWrites() }
            }
        }
    }
    #endif
}

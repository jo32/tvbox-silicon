#if os(macOS)
import AppKit
import Sparkle
import TVCore

/// Installs Mac updates in place with Sparkle and relaunches. The release feed (`Updates`) still decides
/// what to announce and shows the sheet; this downloads, checks and swaps the app. Sparkle reads an appcast
/// made at release time from the notarized DMGs (Scripts/make-appcast.sh) and only installs an update
/// signed with the EdDSA key in Info.plist and by the same Developer ID as this app.
///
/// With automatic installs on (the default), Sparkle downloads new versions in the background and puts them
/// in place when the app quits; the sheet's button then just relaunches.
@MainActor final class MacUpdater: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        /// Bytes so far and in all; `expected` is 0 until the server says.
        case downloading(received: UInt64, expected: UInt64)
        case preparing
        /// Downloaded and checked: it goes in when the app quits, or now with `install()`.
        case ready
        case installing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// Downloads updates in the background and installs them on quit.
    @Published var automaticallyInstalls: Bool {
        didSet { if updater.automaticallyDownloadsUpdates != automaticallyInstalls { updater.automaticallyDownloadsUpdates = automaticallyInstalls } }
    }
    var canCancel: Bool { cancellation != nil }

    private var updater: SPUUpdater!
    private let feed: URL
    private let defaults: UserDefaults
    /// Someone pressed Install: say yes to each of Sparkle's questions until the app relaunches.
    private var installRequested = false
    private var cancellation: (() -> Void)?
    /// Installs an update Sparkle downloaded on its own, without asking again.
    private var installNow: (() -> Void)?
    /// Closes the release sheet: macOS doesn't quit an app while a sheet is open, so the relaunch waits for it.
    var closeSheet: (() -> Void)?
    private var terminationRetries = 0
    /// Sparkle has told the installer to relaunch: from here on, quitting the app installs the update and reopens it.
    private var relaunching = false
    private var relaunchWatchdog: Task<Void, Never>?
    private static let pendingKey = "pendingUpdateRelaunch"

    /// Nil in App Store builds, which the App Store updates, and in debug builds, whose update would replace
    /// the build in DerivedData (QA: `-qaAppcast <url>`).
    static func make(defaults: UserDefaults = .standard) -> MacUpdater? {
        guard !Distribution.isAppStore else { return nil }
        #if DEBUG
        guard let value = defaults.string(forKey: "qaAppcast"), let url = URL(string: value) else { return nil }
        let updater = MacUpdater(feed: url, defaults: defaults)
        // `-qaInstallUpdate 1` presses Install and Relaunch a few seconds after launch.
        if defaults.bool(forKey: "qaInstallUpdate") { Task { try? await Task.sleep(for: .seconds(4)); updater.install() } }
        return updater
        #else
        return MacUpdater(feed: ReleaseFeed.appcastAddress, defaults: defaults)
        #endif
    }

    private init(feed: URL, defaults: UserDefaults) {
        self.feed = feed
        self.defaults = defaults
        automaticallyInstalls = true
        super.init()
        reportLastRelaunch()
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        do { try updater.start() } catch {
            Diagnostics.shared.record(.warning, "updates", "Updater didn't start: \(error.localizedDescription)")
        }
        automaticallyInstalls = updater.automaticallyDownloadsUpdates
    }

    /// Downloads the newest version if needed, installs it and relaunches.
    func install() {
        Diagnostics.shared.record(.info, "updates", "Install pressed: phase=\(phase) downloaded=\(installNow != nil) canCheck=\(updater.canCheckForUpdates)")
        switch phase {
        case .checking, .downloading, .preparing, .installing: return
        case .idle, .ready, .failed: break
        }
        installRequested = true
        if let installNow {
            phase = .installing
            watchRelaunch()
            installNow()
            return
        }
        // A background download that is still running can't be shown or restarted; it installs as soon as it lands.
        guard updater.canCheckForUpdates else { phase = .preparing; return }
        phase = .checking
        updater.checkForUpdates()
    }

    func cancel() {
        let cancellation = cancellation
        self.cancellation = nil
        installRequested = false
        phase = .idle
        cancellation?()
    }

    /// Forgets a failure once its message has been seen.
    func clearFailure() { if case .failed = phase { phase = installNow == nil ? .idle : .ready } }

    private func fail(_ message: String, _ error: (any Error)? = nil) {
        installRequested = false
        cancellation = nil
        phase = .failed(message)
        Diagnostics.shared.record(.warning, "updates", "Update install failed: \(error.map(Self.detail) ?? message)")
    }

    /// The error with its code and causes: Sparkle's own messages are general ("An error occurred in retrieving
    /// update information"), the reason is underneath.
    private static func detail(_ error: any Error) -> String {
        var parts: [String] = []
        var next: NSError? = error as NSError
        while let error = next, parts.count < 4 {
            parts.append("\(error.domain) \(error.code): \(error.localizedDescription)")
            next = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return parts.joined(separator: " <- ")
    }

    /// Closes the release sheet, then any sheet still attached: macOS doesn't quit an app while one is open.
    private func closeSheets() async {
        closeSheet?()
        try? await Task.sleep(for: .milliseconds(400))
        for window in NSApp.windows { if let sheet = window.attachedSheet { window.endSheet(sheet) } }
    }

    /// What can keep the app from quitting, for the log.
    private static func blockers() -> String {
        let sheets = NSApp.windows.filter { $0.attachedSheet != nil }.count
        let modal = NSApp.modalWindow.map { String(describing: type(of: $0)) } ?? "none"
        return "windows=\(NSApp.windows.filter(\.isVisible).count) sheets=\(sheets) modal=\(modal)"
    }

    /// Sparkle asks the app to quit only once, and only its user-driver path says so (`showInstallingUpdate`); an
    /// update downloaded in the background relaunches without telling. Should the app still be open, close what may
    /// hold it and quit again; should it stay open, say so instead of leaving "Relaunching…" up for good (#122).
    private func watchRelaunch() {
        guard relaunchWatchdog == nil else { return }
        relaunchWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, phase == .installing else { self?.relaunchWatchdog = nil; return }
            Diagnostics.shared.record(.warning, "updates", "Still open 3 s after Relaunch: \(Self.blockers()) relaunching=\(relaunching)")
            if relaunching {
                await closeSheets()
                NSApp.terminate(nil)
            }
            try? await Task.sleep(for: .seconds(9))
            relaunchWatchdog = nil
            guard phase == .installing else { return }
            Diagnostics.shared.record(.error, "updates", "Relaunch to update stalled: still open 12 s after Relaunch: \(Self.blockers()) relaunching=\(relaunching)")
            fail(L10n.text("Yingxia couldn't relaunch to finish the update. Quit Yingxia and open it again."))
        }
    }

    /// Says how the last relaunch to update went, now that the app is open again: one that hung until someone
    /// force-quit shows up as slow, or as the old version.
    private func reportLastRelaunch() {
        guard let data = defaults.data(forKey: Self.pendingKey) else { return }
        defaults.removeObject(forKey: Self.pendingKey)
        guard let pending = try? JSONDecoder().decode(PendingRelaunch.self, from: data) else { return }
        let info = Bundle.main.infoDictionary
        let outcome = pending.outcome(version: info?["CFBundleShortVersionString"] as? String ?? "?",
                                      build: info?["CFBundleVersion"] as? String ?? "?")
        Diagnostics.shared.record(outcome.level, "updates", outcome.message)
    }
}

extension MacUpdater: SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Info.plist turns automatic checks on, so Sparkle shouldn't ask; if it does, the answer is yes.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        phase = .checking
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if installRequested { reply(.install); return }
        // A scheduled check with automatic installs off: the release sheet already tells people. A download
        // made earlier stays and goes in on quit.
        if state.stage != .notDownloaded { phase = .ready }
        reply(.dismiss)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        // The release feed announced a version this appcast doesn't have (yet), e.g. one built before Sparkle.
        if installRequested { fail(L10n.text("This update can't be installed from within Yingxia yet. Download it instead."), error) }
        else { phase = .idle }
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        if installRequested { fail(L10n.text("The update couldn't be installed: %@", error.localizedDescription), error) }
        else {
            Diagnostics.shared.record(.warning, "updates", "Background update failed: \(Self.detail(error))")
            if phase != .ready { phase = .idle }
        }
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        phase = .downloading(received: 0, expected: 0)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        phase = .downloading(received: 0, expected: expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        if case .downloading(let received, let expected) = phase { phase = .downloading(received: received + length, expected: expected) }
    }

    func showDownloadDidStartExtractingUpdate() {
        cancellation = nil
        phase = .preparing
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if installRequested {
            phase = .installing
            watchRelaunch()
            reply(.install)
        } else {
            // Installs on quit; Install later resumes it through checkForUpdates.
            phase = .ready
            reply(.dismiss)
        }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        phase = .installing
        Diagnostics.shared.record(.info, "updates", "Installing: terminated=\(applicationTerminated) \(Self.blockers())")
        // Sparkle has just sent the quit request, which the app refuses while a sheet is open (the release sheet,
        // where Install was pressed): close the sheets and ask again. Should something else keep it open, the
        // watchdog asks once more and then says so; the update still goes in on quit.
        guard !applicationTerminated, terminationRetries < 3 else { return }
        terminationRetries += 1
        Task {
            await closeSheets()
            retryTerminatingApplication()
        }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {
        cancellation = nil
        switch phase {
        case .checking, .downloading, .preparing, .installing:
            Diagnostics.shared.record(.info, "updates", "Sparkle ended the update session during \(phase)")
            installRequested = false
            phase = .idle
        case .idle, .ready, .failed: break
        }
    }
}

extension MacUpdater: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? { feed.absoluteString }

    /// A background download finished. Keep the handler so Install relaunches right away instead of
    /// waiting for the next quit.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        installNow = immediateInstallHandler
        cancellation = nil
        if installRequested {
            phase = .installing
            watchRelaunch()
            Task { immediateInstallHandler() }
        } else {
            phase = .ready
        }
        Diagnostics.shared.record(.info, "updates", "Update \(item.displayVersionString) downloaded; installs on quit")
        return true
    }

    /// Sparkle is about to ask the installer to relaunch, on both paths (Install and Relaunch, and Relaunch to Update
    /// after a background download). Close the sheets now, so the quit request that follows finds none, and note
    /// the update so the next launch can say how it went.
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        let info = Bundle.main.infoDictionary
        let pending = PendingRelaunch(from: info?["CFBundleShortVersionString"] as? String ?? "?", to: item.displayVersionString,
                                      build: item.versionString, requested: Date())
        defaults.set(try? JSONEncoder().encode(pending), forKey: Self.pendingKey)
        Diagnostics.shared.record(.info, "updates", "Relaunching to install \(item.displayVersionString): \(Self.blockers())")
        relaunching = true
        phase = .installing
        watchRelaunch()
        Task { await closeSheets() }
    }

    /// A check or download that ended without telling the user driver, such as the background download Install was
    /// waiting for (Sparkle doesn't start a second session while one runs).
    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        guard installRequested else {
            Diagnostics.shared.record(.info, "updates", "Update session ended: \(Self.detail(error))")
            return
        }
        fail(L10n.text("The update couldn't be installed: %@", error.localizedDescription), error)
    }
}
#endif

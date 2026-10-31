import Foundation
import os
#if canImport(UIKit)
import UIKit
#endif

/// Converts classes a subscription's JAR sources are likely to need while the app sits idle, so the first
/// visit to a source has less left to convert (issue #274). Conversion is heavy on the interpreted JVM, so
/// it runs only when nothing else wants the device: the app in front, no plugin request for a while, no
/// plugin proxy serving video, not in Low Power Mode, not hot, and memory to spare. It works a few classes
/// at a time on a utility-priority thread and checks again between batches. Each archive is prepared once
/// per app build, at most `limit` classes (see `ConvertAhead.java` for which ones).
///
/// iOS and tvOS only: the Mac's JVM has a JIT and converts a plugin in seconds.
public actor PluginConversionAhead {
    public static let shared = PluginConversionAhead()
    static let limit = 300
    static let batch = 8

    /// What the device is doing, sampled before each batch.
    struct Conditions: Equatable {
        var active: Bool
        var lowPower: Bool
        var thermal: ProcessInfo.ThermalState
        /// Bytes the process may still allocate (`os_proc_available_memory`).
        var availableMemory: Int
        /// Seconds since the last plugin request ended; 0 while one runs.
        var idle: TimeInterval

        var allowsWork: Bool {
            active && !lowPower && thermal.rawValue < ProcessInfo.ThermalState.serious.rawValue
                && availableMemory >= 600 * 1024 * 1024 && idle >= 30
        }
    }

    /// One archive to prepare: its address and the spider classes its sources use.
    struct Archive: Equatable {
        let url: URL
        var spiders: [String]
    }

    /// Plugin requests running now, and when the last one started or ended.
    private static let activity = OSAllocatedUnfairLock(initialState: (running: 0, last: ContinuousClock.now))
    private static let foreground = OSAllocatedUnfairLock(initialState: true)
    private var task: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private static let doneKey = "pluginConversionAheadDone"

    /// A plugin request started. Cheap: called on every request.
    static func requestStarted() { activity.withLock { $0 = ($0.running + 1, .now) } }
    static func requestEnded() { activity.withLock { $0 = (max(0, $0.running - 1), .now) } }

    /// Prepares the archives of these sources from now on, replacing earlier work.
    public func schedule(sites: [Site], origin: URL, spider: URL?) {
        task?.cancel()
        task = nil
        #if os(iOS) || os(tvOS)
        guard EmbeddedJarHost.available else { return }
        let archives = Self.archives(sites, origin: origin, spider: spider)
        guard !archives.isEmpty else { return }
        observeAppState()
        // Utility, not background: background-priority timers can lag by minutes on a busy device. The
        // conversion itself runs on its own utility thread and checks the device before every batch.
        task = Task(priority: .utility) { await self.run(archives) }
        #endif
    }

    /// The JAR sources a visit runs in the embedded JVM, grouped by archive in subscription order.
    /// Sources with a JavaScript port, native APIs, built-ins and sources TVBox hides are left out.
    static func archives(_ sites: [Site], origin: URL, spider: URL?) -> [Archive] {
        var archives: [Archive] = []
        for site in sites where site.runtime == .jar && !site.isBuiltIn && !site.native && !site.runsLitePort && !site.hidden && site.api.hasPrefix("csp_") {
            // Merged sources resolve against their own subscription, as PluginLocator does.
            guard let url = try? site.pluginURL(origin: site.origin(or: origin), fallback: site.spider(or: spider)) else { continue }
            let spiderClass = String(site.api.dropFirst("csp_".count))
            guard !spiderClass.isEmpty, spiderClass.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }) else { continue }
            if let index = archives.firstIndex(where: { $0.url == url }) {
                if !archives[index].spiders.contains(spiderClass) { archives[index].spiders.append(spiderClass) }
            } else {
                archives.append(Archive(url: url, spiders: [spiderClass]))
            }
        }
        return archives
    }

    private func run(_ archives: [Archive]) async {
        // Let launch and the first screens settle before anything else runs.
        guard (try? await Task.sleep(for: .seconds(60))) != nil else { return }
        let http = HTTPClient()
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        defer { Task { await EmbeddedJarHost.shared.releaseConversionAhead() } }
        for archive in archives {
            var from = 0
            while !Task.isCancelled {
                guard await Self.waitUntilAllowed() else { return }
                let batch: EmbeddedJarHost.ConversionBatch
                do {
                    batch = try await EmbeddedJarHost.shared.convertAhead(jarURL: archive.url, spiders: archive.spiders, from: from, limit: Self.limit,
                                                                          batch: Self.batch, http: http) { Self.done($0 + " " + build) }
                } catch {
                    // The source reports its own failures when someone opens it.
                    Diagnostics.shared.record(.info, "jar.ahead", "skipped an archive: \(error.localizedDescription)")
                    break
                }
                if batch.skipped { break }
                from = batch.next
                if batch.converted > 0 || batch.done {
                    Diagnostics.shared.record(.info, "jar.ahead", "archive=\(batch.digest.prefix(12)) converted=\(batch.converted) reused=\(batch.reused) next=\(batch.next)/\(batch.planned)\(batch.stopped.isEmpty ? "" : " stopped=" + batch.stopped)")
                }
                if batch.done { Self.markDone(batch.digest + " " + build); break }
                // Short of memory: leave the rest for another launch.
                if batch.stopped == "memory" { return }
                // Breathe between batches, longer when a request interrupted this one.
                let pause: Duration = batch.stopped == "busy" ? .seconds(30) : .seconds(2)
                guard (try? await Task.sleep(for: pause)) != nil else { return }
            }
        }
    }

    /// Waits (checking every 30 s) until the device is free for background work; false once cancelled.
    private static func waitUntilAllowed() async -> Bool {
        while !Task.isCancelled {
            if current().allowsWork { return true }
            guard (try? await Task.sleep(for: .seconds(30))) != nil else { return false }
        }
        return false
    }

    static func current() -> Conditions {
        let info = ProcessInfo.processInfo
        #if os(iOS) || os(tvOS)
        // 0 when the system sets no limit (the simulator); the host's heap check still applies.
        let left = os_proc_available_memory()
        let available = left > 0 ? Int(left) : Int.max
        #else
        let available = Int.max
        #endif
        let (running, last) = activity.withLock { $0 }
        let idle = running > 0 ? 0 : Double(last.duration(to: .now).components.seconds)
        return Conditions(active: foreground.withLock { $0 }, lowPower: info.isLowPowerModeEnabled, thermal: info.thermalState,
                          availableMemory: available, idle: idle)
    }

    private func observeAppState() {
        #if canImport(UIKit)
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: nil) { _ in
            Self.foreground.withLock { $0 = false }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
            Self.foreground.withLock { $0 = true }
        })
        #endif
    }

    /// Archives (SHA-256 and app build) already prepared, newest last.
    static func done(_ key: String) -> Bool { (UserDefaults.standard.stringArray(forKey: doneKey) ?? []).contains(key) }
    static func markDone(_ key: String) {
        var keys = UserDefaults.standard.stringArray(forKey: doneKey) ?? []
        keys.removeAll { $0 == key }
        keys.append(key)
        UserDefaults.standard.set(Array(keys.suffix(20)), forKey: doneKey)
    }
}

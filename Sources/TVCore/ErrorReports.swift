import Foundation
#if os(iOS) || os(tvOS)
import os
#endif

/// Sends the app's errors to the developer, so bugs nobody reports still get found
/// (Services/error-reports; read them with Scripts/error-reports.py). On unless turned off in Settings.
/// Only error-level diagnostics go out, after Diagnostics' credential redaction, with every URL cut to
/// its scheme and host, home folders and private IP addresses removed. Repeats are summed on the device
/// and sent at most every six hours, so an install costs about a request a day. The ID is random.
/// Crashes come from MetricKit on iPhone, iPad and Mac, and uncaught exceptions on every platform (CrashReports); on iPhone, iPad and Apple TV an
/// exit while on screen (a crash, or the system ending the app for memory) is noticed on the next launch,
/// with what that launch was doing (QuitContext).
/// Plays are counted too, for the play success rate: only how many started, failed or were left, split by
/// coarse fields (`PlayAttempt`), as `player.stats` items in the same upload.
public final class ErrorReports: @unchecked Sendable {
    public static let shared = ErrorReports()
    /// UserDefaults switch; missing means on.
    public static let key = "sendsErrorReports"
    static let endpoint = URL(string: "https://yingxia-reports.getmegaportal.com/v1/reports")!
    /// Play counters' category: each message is one counter, kept and sent exactly as written.
    static let statsCategory = "player.stats"
    /// At most this many play counters are kept, and sent in one upload ahead of the errors.
    static let statsLimit = 30

    struct Group: Codable, Equatable, Sendable {
        var category: String
        var message: String
        var count: Int
        var first: Int
        var last: Int
    }

    private let defaults: UserDefaults
    private let file: URL
    private let interval: TimeInterval
    private let lock = NSLock()
    // Guarded by `lock`.
    private var groups: [String: Group] = [:]
    private var started = false
    private var sending = false
    private var saveScheduled = false
    private var retryAfter = Date.distantPast
    /// The launch that was on screen when this one began, read before this launch marks itself.
    private let previousLaunch: String?
    /// What that launch, or a later one that left the screen normally, last saved about itself.
    private let previousContext: QuitContext?
    // Guarded by `lock`: this launch's context, saved while it is on screen.
    private var context: QuitContext
    private var sampler: DispatchSourceTimer?
    private var pressure: DispatchSourceMemoryPressure?
    /// Saves and clears that context in order, outside `lock`: a UserDefaults write can wait on
    /// SwiftUI, and the main thread waits on `lock` in `onScreen` during a scene update (8BADF00D).
    private let contextWriter = DispatchQueue(label: "tvbox.error-reports.context", qos: .utility)

    init(defaults: UserDefaults = .standard, directory: URL = Diagnostics.shared.directory, interval: TimeInterval = 6 * 3600) {
        self.defaults = defaults
        self.file = directory.appendingPathComponent("error-reports.json")
        self.interval = interval
        self.previousLaunch = defaults.string(forKey: Self.onScreenKey)
        self.previousContext = defaults.data(forKey: Self.contextKey).flatMap { try? JSONDecoder().decode(QuitContext.self, from: $0) }
        let now = Int(Date().timeIntervalSince1970)
        self.context = QuitContext(launch: Self.launch, started: now, saved: now)
    }

    public var enabled: Bool { defaults.object(forKey: Self.key) as? Bool ?? true }

    /// The app only: helper processes (TVBoxProbe, the source sweep) share the log folder and never report.
    public func start() async {
        let saved = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: Group].self, from: $0) } ?? [:]
        let first = lock.withLock {
            defer { started = true }
            if !started { groups.merge(saved) { current, old in Self.combine(old, current) } }
            return !started
        }
        guard first else { return }
        #if os(iOS) || os(tvOS)
        // Set by an earlier launch while it was on screen, and never cleared: it ended there.
        if let other = previousLaunch, other != Self.launch {
            if defaults.string(forKey: Self.onScreenKey) == other { defaults.removeObject(forKey: Self.onScreenKey) }
            if let report = QuitContext.report(previousContext?.launch == other ? previousContext : nil, bootTime: Self.bootTime) {
                Diagnostics.shared.record(.error, "app", report)
            } else {
                Diagnostics.shared.record(.info, "app", "The device restarted while the last launch was on screen")
            }
        }
        #endif
        CrashReports.shared.start()
        await sendIfDue()
    }

    private static let onScreenKey = "errorReportsOnScreen"
    private static let contextKey = "errorReportsOnScreenContext"
    private static let launch = UUID().uuidString

    /// The app's scene phase: whether this launch is on screen and active right now.
    public func onScreen(_ active: Bool) {
        #if os(iOS) || os(tvOS)
        if active { defaults.set(Self.launch, forKey: Self.onScreenKey); startSampling() } else { defaults.removeObject(forKey: Self.onScreenKey); stopSampling() }
        #endif
    }

    /// What the player shows, for a later "quit unexpectedly" report. No title or address: only its kind.
    public func playing(live: Bool, format: String, source: String?, danmaku: Bool, sharper: Bool) {
        let since = Int(Date().timeIntervalSince1970)
        note { $0.playback = QuitContext.Playback(live: live, format: format.isEmpty ? "-" : String(format.lowercased().prefix(5)),
                                                  source: source ?? "-", since: since, danmaku: danmaku, sharper: sharper) }
    }

    public func stoppedPlaying() { note { $0.playback = nil } }

    private func startSampling() {
        lock.lock(); defer { lock.unlock() }
        guard sampler == nil else { return }
        let queue = DispatchQueue.global(qos: .utility)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 30, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in self?.note { _ in } }
        let memory = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
        memory.setEventHandler { [weak self, weak memory] in
            let level = memory?.data.contains(.critical) == true ? "critical" : "warning"
            self?.note { $0.pressure = Int(Date().timeIntervalSince1970); $0.pressureLevel = level }
        }
        sampler = timer; pressure = memory
        timer.resume(); memory.resume()
    }

    private func stopSampling() {
        lock.withLock {
            sampler?.cancel(); sampler = nil
            pressure?.cancel(); pressure = nil
            contextWriter.async { self.defaults.removeObject(forKey: Self.contextKey) }
        }
    }

    /// Changes this launch's context and, while it is on screen, saves it with fresh memory figures.
    private func note(_ change: (inout QuitContext) -> Void) {
        let memory = Self.memory()
        lock.withLock {
            change(&context)
            guard sampler != nil else { return }
            context.footprint = memory.footprint; context.available = memory.available
            context.saved = Int(Date().timeIntervalSince1970)
            if let data = try? JSONEncoder().encode(context) { contextWriter.async { self.defaults.set(data, forKey: Self.contextKey) } }
        }
    }

    /// Megabytes: this process's footprint (what the system counts against it), and on iPhone, iPad and
    /// Apple TV how much more it may use before the system ends it.
    static func memory() -> (footprint: Int?, available: Int?) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        let footprint = result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : nil
        #if os(iOS) || os(tvOS)
        let left = os_proc_available_memory()
        return (footprint, left > 0 ? left / 1_048_576 : nil)
        #else
        return (footprint, nil)
        #endif
    }

    /// When the device last started up, in seconds since 1970.
    static var bootTime: Int {
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0 else { return 0 }
        return Int(time.tv_sec)
    }

    /// Called by Diagnostics with entries it has already redacted.
    func collect(_ entries: [LogEntry]) {
        let errors = entries.filter { $0.level == .error }
        guard !errors.isEmpty, enabled else { return }
        lock.lock()
        guard started else { lock.unlock(); return }
        for entry in errors {
            let message = Self.scrub(entry.message)
            let key = Self.groupKey(entry.category, message)
            let time = Int(entry.date.timeIntervalSince1970)
            if var group = groups[key] {
                group.count += 1; group.last = time; group.message = message
                groups[key] = group
            } else if size(stats: false) < 100 {
                groups[key] = Group(category: entry.category, message: message, count: 1, first: time, last: time)
            }
        }
        changed()
    }

    /// Adds one to a play counter (`PlayAttempt`). Its message is the counter: never grouped like an error's, so
    /// counters that differ only in a field stay apart.
    func count(_ message: String) {
        guard enabled else { return }
        let time = Int(Date().timeIntervalSince1970)
        lock.lock()
        guard started else { lock.unlock(); return }
        let key = Self.statsCategory + "\n" + message
        if var group = groups[key] {
            group.count += 1; group.last = time
            groups[key] = group
        } else if size(stats: true) < Self.statsLimit {
            groups[key] = Group(category: Self.statsCategory, message: message, count: 1, first: time, last: time)
        }
        changed()
    }

    private static func isStats(_ key: String) -> Bool { key.hasPrefix(statsCategory + "\n") }

    /// Guarded by `lock`: how many play counters, or error groups, are kept.
    private func size(stats: Bool) -> Int { groups.keys.reduce(0) { $0 + (Self.isStats($1) == stats ? 1 : 0) } }

    /// Called with `lock` held, which it releases: saves the file once for each burst and sends when due.
    private func changed() {
        let save = !saveScheduled
        saveScheduled = true
        lock.unlock()
        if save { DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { self.save() } }
        if due { Task { await sendIfDue() } }
    }

    /// Forgets everything not yet sent, for when reports are turned off.
    public func discard() {
        lock.lock(); groups.removeAll(); lock.unlock()
        try? FileManager.default.removeItem(at: file)
    }

    public func save() {
        lock.lock(); let snapshot = groups; saveScheduled = false; lock.unlock()
        if snapshot.isEmpty { try? FileManager.default.removeItem(at: file); return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
    }

    private var address: URL? {
        #if DEBUG
        // Debug builds and simulators only report with `-qaErrorReports <url>` (e.g. a local `wrangler dev`).
        return defaults.string(forKey: "qaErrorReports").flatMap(URL.init(string:))
        #else
        return Self.endpoint
        #endif
    }

    private var due: Bool {
        let last = defaults.double(forKey: "errorReportsSent")
        lock.lock(); defer { lock.unlock() }
        return !sending && !groups.isEmpty && Date() >= retryAfter && Date().timeIntervalSince1970 - last >= interval
    }

    public func sendIfDue() async {
        guard enabled else { discard(); return }
        guard let address, due else { return }
        let batch: [(String, Group)]? = lock.withLock {
            guard !sending else { return nil }
            sending = true
            // Play counters first (the server keeps 50 items an upload), then the most frequent errors.
            let sorted = groups.sorted { $0.value.count > $1.value.count }
            let stats = sorted.filter { Self.isStats($0.key) }.prefix(Self.statsLimit)
            return (stats + sorted.filter { !Self.isStats($0.key) }.prefix(50 - stats.count)).map { ($0.key, $0.value) }
        }
        guard let batch else { return }
        defer { lock.withLock { sending = false } }

        var request = URLRequest(url: address, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(Payload(install: install, app: Self.bundleValue("CFBundleShortVersionString"),
                                                             build: Self.bundleValue("CFBundleVersion"), platform: Self.platform,
                                                             os: Self.osVersion, model: Self.model, lang: L10n.resolvedLanguage(),
                                                             items: batch.map(\.1)))
        let status = (try? await URLSession.shared.data(for: request)).flatMap { ($0.1 as? HTTPURLResponse)?.statusCode } ?? 0
        // Accepted, or rejected for good (malformed, too large): either way these are done.
        guard (200..<300).contains(status) || status == 400 || status == 413 else {
            lock.withLock { retryAfter = Date().addingTimeInterval(1800) }
            return
        }
        lock.withLock {
            for (key, sent) in batch {
                guard var group = groups[key] else { continue }
                if group.count <= sent.count { groups[key] = nil }
                else { group.count -= sent.count; group.first = sent.last; groups[key] = group }
            }
        }
        defaults.set(Date().timeIntervalSince1970, forKey: "errorReportsSent")
        save()
    }

    private struct Payload: Encodable {
        let install, app, build, platform, os, model, lang: String
        let items: [Group]
    }

    /// Also sent with feedback, to the server only.
    var install: String {
        if let id = defaults.string(forKey: "errorReportsInstall") { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: "errorReportsInstall")
        return id
    }

    static func bundleValue(_ key: String) -> String { Bundle.main.infoDictionary?[key] as? String ?? "0" }

    static var platform: String {
        #if os(tvOS)
        "tvos"
        #elseif os(iOS)
        "ios"
        #else
        "macos"
        #endif
    }

    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// The hardware model ("AppleTV14,1", "iPhone16,2", "Mac15,6"): playback and memory bugs often
    /// depend on it. Simulators report the model they simulate.
    static var model: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        #if os(macOS)
        let name = "hw.model"
        #else
        let name = "hw.machine"
        #endif
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "-" }
        var value = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return "-" }
        return String(decoding: value.prefix { $0 != 0 }, as: UTF8.self)
    }

    private static func combine(_ old: Group, _ new: Group) -> Group {
        Group(category: new.category, message: new.message, count: old.count + new.count, first: min(old.first, new.first), last: max(old.last, new.last))
    }

    // Beyond Diagnostics' redaction: a URL keeps only its scheme and host (paths can carry tokens or
    // titles), home folders and app containers lose the user's name and ids, and private addresses go.
    private static let scrubbers: [(NSRegularExpression, String)] = [
        (#"(?i)\b([a-z][a-z0-9+.-]{1,15})://(?:[^\s/@]+@)?([^\s/?#"'<>]+)[^\s"'<>]*"#, "$1://$2"),
        (#"/(?:Users|home)/[^/\s]+"#, "~"),
        (#"/(?:private/)?var/mobile/Containers/(?:Data|Shared)/(?:Application|AppGroup)/[0-9A-Fa-f-]{36}"#, "~"),
        (#"\b(?:10(?:\.\d{1,3}){3}|192\.168(?:\.\d{1,3}){2}|172\.(?:1[6-9]|2\d|3[01])(?:\.\d{1,3}){2})\b"#, "<lan>")
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    static func scrub(_ text: String) -> String {
        let result = scrubbers.reduce(text) { result, rule in
            rule.0.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: rule.1)
        }
        return String(result.prefix(1000))
    }

    // The same rules as `normalize` in Services/error-reports/src/index.ts: keep them in step.
    private static let variables: [(NSRegularExpression, String)] = [
        (#"(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#, "<id>"),
        (#"(?i)\b[0-9a-f]{12,}\b"#, "<id>"),
        // A plugin request's trace (LocalJarHost): the first 8 characters of a UUID.
        (#"\brequest=[0-9A-F]{8}\b"#, "request=#"),
        (#"\b(offset|at|bytes|duration|length|chunk|aid|cid|room|id|page|elapsed|total|size|seconds)=-?[0-9.]+"#, "$1=#"),
        (#"\b\d+(?:\.\d+)? ?(?:seconds|sec|ms|s)\b"#, "#s"),
        (#"(?<![\w.-])\d{5,}\b"#, "#")
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    /// One bug, many messages: ids, offsets, sizes and durations differ between occurrences. Status and
    /// error codes stay, so an HTTP 403 and a 500, or a timeout (-1001) and no network (-1009), stay apart.
    static func groupKey(_ category: String, _ message: String) -> String {
        let line = String(message.prefix { $0 != "\n" })
        return category + "\n" + variables.reduce(line) { result, rule in
            rule.0.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: rule.1)
        }.trimmingCharacters(in: .whitespaces)
    }
}

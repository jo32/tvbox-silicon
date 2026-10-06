import Foundation

/// Request-scoped preparation state. The UI polls only while a source is loading.
/// Conversion is demand-driven, so class counts never masquerade as a percentage.
public final class PluginPreparation: @unchecked Sendable {
    public enum Stage: String, Sendable { case checking, downloading, verifying, reusing, queued, preparing, converting, loading }
    public struct Snapshot: Sendable {
        public let stage: Stage
        public let received: Int64
        public let expected: Int64?
        public let converted: Int
        public let reused: Int
        public let started: Date
        /// The server the plugin is waiting on right now, as reported by the Java runtime.
        public var host: String? = nil
        public var fraction: Double? {
            guard stage == .downloading, let expected, expected > 0 else { return nil }
            return min(1, max(0, Double(received) / Double(expected)))
        }
    }
    /// One in-flight plugin request, for views that show several at once (global search).
    public struct Activity: Identifiable, Sendable {
        public let id: UUID
        public let name: String
        public let snapshot: Snapshot
    }
    private struct Entry {
        let key: String
        let name: String
        var state: Snapshot
        var updated = Date()
    }
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var entries: [UUID: Entry] = [:]
    }
    private static let registry = Registry()
    private static let runtimeLock = NSLock()
    nonisolated(unsafe) private static var runtimeStarted = false
    /// Set once the embedded JVM has answered. Until then a queued request waits for its start-up.
    public static var runtimeReady: Bool {
        get { runtimeLock.withLock { runtimeStarted } }
        set { runtimeLock.withLock { runtimeStarted = newValue } }
    }
    private let id = UUID()
    private let started = Date()
    public init(site: Site, origin: URL) {
        Self.registry.lock.lock(); defer { Self.registry.lock.unlock() }
        Self.registry.entries[id] = Entry(key: Self.key(site, origin), name: site.name, state: Snapshot(stage: .checking, received: 0, expected: nil, converted: 0, reused: 0, started: started))
    }
    private static func key(_ site: Site, _ origin: URL) -> String {
        origin.absoluteString + "\n" + site.key + "\n" + site.api
    }
    public static func snapshot(site: Site, origin: URL) -> Snapshot? {
        registry.lock.lock(); defer { registry.lock.unlock() }
        return registry.entries.values.filter { $0.key == key(site, origin) }.max { $0.updated < $1.updated }?.state
    }
    /// Requests of this configuration still in flight, oldest first.
    public static func active(origin: URL) -> [Activity] {
        let prefix = origin.absoluteString + "\n"
        registry.lock.lock(); defer { registry.lock.unlock() }
        return registry.entries.filter { $0.value.key.hasPrefix(prefix) }
            .map { Activity(id: $0.key, name: $0.value.name, snapshot: $0.value.state) }
            .sorted { $0.snapshot.started < $1.snapshot.started }
    }
    public func report(_ stage: Stage, received: Int64 = 0, expected: Int64? = nil, converted: Int = 0, reused: Int = 0, host: String? = nil) {
        Self.registry.lock.lock(); defer { Self.registry.lock.unlock() }
        guard var entry = Self.registry.entries[id] else { return }
        entry.state = Snapshot(stage: stage, received: received, expected: expected, converted: converted, reused: reused, started: started, host: host)
        entry.updated = Date(); Self.registry.entries[id] = entry
    }
    public func finish() {
        Self.registry.lock.lock(); defer { Self.registry.lock.unlock() }
        Self.registry.entries[id] = nil
    }
    deinit { finish() }

    /// Each session owns this file. Atomic Java publication keeps reads consistent.
    func observe(_ url: URL) -> Task<Void, Never> {
        let began = Date()
        return Task { [weak self] in
            var previous: Data?
            while !Task.isCancelled {
                if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified >= began,
                   let data = try? Data(contentsOf: url), data != previous,
                   let value = try? JSONDecoder().decode(BuildProgress.self, from: data) {
                    previous = data
                    self?.report(Stage(rawValue: value.stage) ?? .preparing, converted: value.converted, reused: value.reused, host: value.host)
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }
    private struct BuildProgress: Decodable { let stage: String; let converted: Int; let reused: Int; let host: String? }
}

// Shared by the single-source preparation card and the global-search activity list.
extension PluginPreparation.Stage {
    public var title: String {
        switch self {
        case .checking: L10n.text("Checking saved plugin…")
        case .downloading: L10n.text("Downloading plugin…")
        case .verifying: L10n.text("Checking plugin content…")
        case .reusing: L10n.text("Reusing saved plugin…")
        case .queued: L10n.text("Waiting for the plugin runtime…")
        case .preparing: L10n.text("Preparing plugin…")
        case .converting: L10n.text("Building plugin components…")
        case .loading: L10n.text("Loading source content…")
        }
    }
}

extension PluginPreparation.Snapshot {
    /// Download size or component counts; nil when the stage title says everything.
    public var detail: String? {
        if stage == .downloading, received > 0 {
            let done = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
            guard let expected else { return done }
            return L10n.text("%@ of %@", done, ByteCountFormatter.string(fromByteCount: expected, countStyle: .file))
        }
        if let host { return L10n.text("Waiting for %@", host) }
        if converted > 0 || reused > 0 { return L10n.text("Components prepared: %lld · reused: %lld", converted, reused) }
        return nil
    }

    /// Why this stage is taking long, for views to show once loading passes a few seconds.
    public var reason: String? {
        if let host { return L10n.text("The plugin is waiting for %@ to respond. The source's server may be slow or busy.", host) }
        switch stage {
        case .downloading: return L10n.text("The plugin file is still downloading from the subscription server.")
        case .queued:
            return PluginPreparation.runtimeReady
                ? L10n.text("Other plugin requests are using every slot. This one starts as soon as one finishes.")
                : L10n.text("The plugin runtime is starting. This takes about half a minute after the app opens.")
        case .converting: return L10n.text("This plugin is running for the first time, so its code is being converted for this device. Next time is much faster.")
        case .preparing, .loading: return L10n.text("The plugin is still working. Plugins run much slower on this device than on Android.")
        case .checking, .verifying, .reusing: return nil
        }
    }
}

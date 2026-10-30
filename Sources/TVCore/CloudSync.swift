import Foundation

/// iCloud key-value storage, or a stand-in in tests. Without the iCloud entitlement (a sideloaded
/// build) the system store keeps values on this device only, so nothing breaks; it just doesn't sync.
@MainActor public protocol CloudValueStore: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: CloudValueStore {}

/// One synced item: its value, or nil once it was removed, and when that last changed on any device.
public struct CloudSyncRecord<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var value: Value?
    public var stamp: Date
    public init(value: Value?, stamp: Date) { self.value = value; self.stamp = stamp }
}

/// A live item after a merge, with when it last changed, for stores that order by it.
public struct CloudSyncItem<Value: Sendable>: Sendable {
    public let id: String
    public let value: Value
    public let stamp: Date
}

/// Every item a device knows, removed ones included, so a removal travels to other devices like an
/// addition does. Each item's newest change wins.
public struct CloudSyncLedger<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var records: [String: CloudSyncRecord<Value>] = [:]
    public init() {}

    /// Stamps what changed on this device since the ledger last saw it. A change is always stamped
    /// after the one it replaces, so a device whose clock runs behind still wins with its newer edit.
    @discardableResult public mutating func note(_ current: [String: Value], now: Date) -> Bool {
        var changed = false
        for (id, value) in current where records[id]?.value != value {
            records[id] = CloudSyncRecord(value: value, stamp: Self.after(records[id]?.stamp, now))
            changed = true
        }
        for (id, record) in records where record.value != nil && current[id] == nil {
            records[id] = CloudSyncRecord(value: nil, stamp: Self.after(record.stamp, now))
            changed = true
        }
        return changed
    }

    /// Takes each item's newer change from another device's ledger. True when a value changed here.
    @discardableResult public mutating func merge(_ other: Self) -> Bool {
        var changed = false
        for (id, theirs) in other.records {
            if let mine = records[id], mine.stamp >= theirs.stamp { continue }
            if records[id]?.value != theirs.value { changed = true }
            records[id] = theirs
        }
        return changed
    }

    /// Forgets removals older than `date`; every device has long since seen them.
    public mutating func prune(before date: Date) {
        records = records.filter { $0.value.value != nil || $0.value.stamp >= date }
    }

    public var live: [CloudSyncItem<Value>] {
        records.compactMap { id, record in record.value.map { CloudSyncItem(id: id, value: $0, stamp: record.stamp) } }
    }

    public var values: [String: Value] { records.compactMapValues(\.value) }

    private static func after(_ previous: Date?, _ now: Date) -> Date {
        guard let previous, previous >= now else { return now }
        return previous.addingTimeInterval(0.001)
    }
}

@MainActor private protocol CloudSyncChannel: AnyObject {
    var delay: Duration { get }
    func flush(_ cloud: any CloudValueStore, now: Date)
    func reset()
}

/// One kind of data (favorites, history, …): what it holds on this device, how to take what other
/// devices changed, and the ledger that tells the two apart. The ledger is kept in a file, since
/// tvOS aborts apps whose defaults grow large.
@MainActor private final class SyncChannel<Value: Codable & Equatable & Sendable>: CloudSyncChannel {
    let key: String
    let file: URL
    let delay: Duration
    let current: @MainActor () -> [String: Value]
    let apply: @MainActor ([CloudSyncItem<Value>]) -> Void
    var ledger: CloudSyncLedger<Value>

    init(key: String, file: URL, delay: Duration, current: @escaping @MainActor () -> [String: Value],
         apply: @escaping @MainActor ([CloudSyncItem<Value>]) -> Void) {
        self.key = key; self.file = file; self.delay = delay; self.current = current; self.apply = apply
        ledger = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(CloudSyncLedger<Value>.self, from: $0) } ?? CloudSyncLedger()
    }

    func flush(_ cloud: any CloudValueStore, now: Date) {
        let cutoff = now.addingTimeInterval(-CloudSync.removalLifetime)
        let noted = ledger.note(current(), now: now)
        var remote = cloud.data(forKey: key).flatMap { CloudSync.decode(CloudSyncLedger<Value>.self, from: $0) } ?? CloudSyncLedger()
        remote.prune(before: cutoff)
        let incoming = ledger.merge(remote)
        ledger.prune(before: cutoff)
        if noted || incoming { save() }
        if incoming { apply(ledger.live) }
        guard ledger != remote, let data = CloudSync.encode(ledger) else { return }
        guard data.count <= CloudSync.valueLimit else {
            Diagnostics.shared.record(.warning, "icloud", "\(key) is \(data.count) bytes, over the \(CloudSync.valueLimit) byte limit; not synced")
            return
        }
        cloud.set(data, forKey: key)
    }

    func reset() {
        ledger = CloudSyncLedger()
        try? FileManager.default.removeItem(at: file)
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(ledger).write(to: file, options: .atomic)
        } catch {
            Diagnostics.shared.failure("icloud", "save \(key)", error)
        }
    }
}

/// Keeps favorites, Continue Watching, subscriptions and source choices the same on every device signed
/// in to the same iCloud account, through iCloud key-value storage (1 MB in all, which works on Apple TV
/// too). Stores report changes with `changed(_:)`; a pause gathers a burst of them into one write.
@MainActor public final class CloudSync {
    nonisolated public static let enabledKey = "iCloudSync.enabled"
    /// iCloud allows 1 MB per app; every kind together has to fit.
    nonisolated static let valueLimit = 256 * 1024
    nonisolated static let removalLifetime: TimeInterval = 90 * 24 * 3600

    private let cloud: any CloudValueStore
    private let directory: URL
    private let defaults: UserDefaults
    private var channels: [String: any CloudSyncChannel] = [:]
    private var order: [String] = []
    private var pending: [String: Task<Void, Never>] = [:]
    private var observer: (any NSObjectProtocol)?

    public init(cloud: any CloudValueStore = NSUbiquitousKeyValueStore.default, directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.cloud = cloud; self.defaults = defaults
        #if os(tvOS)
        let base = URL.cachesDirectory
        #else
        let base = URL.applicationSupportDirectory
        #endif
        self.directory = directory ?? base.appending(path: "icloud-sync")
    }

    /// On unless the viewer turned it off in Settings.
    public var isEnabled: Bool { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }

    /// `current` is what this device holds now, by id; `apply` replaces it with the merged result.
    /// `delay` is how long a change waits for the next one before it goes up.
    public func register<Value: Codable & Equatable & Sendable>(_ key: String, delay: Duration = .seconds(3),
                                                                current: @escaping @MainActor () -> [String: Value],
                                                                apply: @escaping @MainActor ([CloudSyncItem<Value>]) -> Void) {
        let cloudKey = "sync." + key
        if channels[cloudKey] == nil { order.append(cloudKey) }
        channels[cloudKey] = SyncChannel(key: cloudKey, file: directory.appending(path: key + ".json"), delay: delay, current: current, apply: apply)
    }

    /// Listens for other devices' changes and merges everything once.
    public func start() {
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                                                              object: nil, queue: .main) { [weak self] note in
                let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
                let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
                MainActor.assumeIsolated { self?.receive(reason: reason, keys: keys) }
            }
        }
        guard isEnabled else { return }
        cloud.synchronize()
        flush()
    }

    /// Something changed on this device; it goes up after its kind's pause.
    public func changed(_ key: String) {
        let key = "sync." + key
        guard isEnabled, pending[key] == nil, let delay = channels[key]?.delay else { return }
        pending[key] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.pending[key] = nil
            self.flush([key])
        }
    }

    /// Sends what is waiting now, as the app goes to the background.
    public func flushPending() {
        let keys = Set(pending.keys)
        cancelPending()
        if !keys.isEmpty { flush(keys) }
    }

    private func cancelPending() {
        for task in pending.values { task.cancel() }
        pending = [:]
    }

    /// Merges the given cloud keys (every kind when nil) both ways.
    func flush(_ keys: Set<String>? = nil, now: Date = Date()) {
        guard isEnabled else { return }
        for key in order where keys?.contains(key) ?? true { channels[key]?.flush(cloud, now: now) }
    }

    /// Turned back on: whatever changed meanwhile on either side merges. Turned off: nothing more is sent.
    public func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled { start() } else { cancelPending() }
    }

    func receive(reason: Int?, keys: [String]?) {
        switch reason {
        case NSUbiquitousKeyValueStoreAccountChange:
            // Another iCloud account: its data is not this device's past, so nothing here counts as removed there.
            for channel in channels.values { channel.reset() }
            flush()
        case NSUbiquitousKeyValueStoreQuotaViolationChange:
            Diagnostics.shared.record(.warning, "icloud", "iCloud key-value storage is over its quota")
        default:
            flush(keys.map(Set.init))
        }
    }

    /// An ordered list as each item's place, so two devices' additions merge instead of one list replacing the other.
    nonisolated public static func ranks(_ keys: [String]) -> [String: Int] {
        Dictionary(keys.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
    }

    /// The list back from places; two items given the same place on different devices put the newer one first.
    nonisolated public static func ordered(_ items: [CloudSyncItem<Int>]) -> [String] {
        items.sorted { ($0.value, $1.stamp, $0.id) < ($1.value, $0.stamp, $1.id) }.map(\.id)
    }

    nonisolated static func encode<Value>(_ ledger: CloudSyncLedger<Value>) -> Data? {
        guard let json = try? JSONEncoder().encode(ledger) else { return nil }
        return try? (json as NSData).compressed(using: .lzfse) as Data
    }

    nonisolated static func decode<Value>(_ type: CloudSyncLedger<Value>.Type, from data: Data) -> CloudSyncLedger<Value>? {
        guard let json = try? (data as NSData).decompressed(using: .lzfse) as Data else { return nil }
        return try? JSONDecoder().decode(type, from: json)
    }
}

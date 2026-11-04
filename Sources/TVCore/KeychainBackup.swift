import Foundation
import Security

/// A complete backup that survives uninstall/reinstall by living in the keychain, which iOS keeps
/// after the app's own sandbox is deleted. This is the "local auto-backup" leg that works on a
/// sideloaded build — the iCloud key-value leg (`CloudBackupPayload`) needs the ubiquity-kvstore
/// entitlement the wildcard App ID does not carry, so this keychain leg is what actually restores
/// sign-in state and the rest after a reinstall without a manual backup file.
///
/// Why the keychain, and why sharded:
/// - The keychain persists across uninstall (unlike `UserDefaults` and the sandbox).
/// - A single keychain item should stay small; a full backup (history + favourites + accounts) can
///   be tens to hundreds of KB. Sharding into ~8 KB chunks keeps each item well under the limits
///   that older OS versions and device-restore paths still impose.
/// - `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` keeps it on this device and available after
///   the first unlock following a reboot, which is exactly when a reinstall restores.
///
/// The stored payload is the plain JSON encoding of `FullBackup` (the accounts slice already holds
/// sign-in files verbatim, and the vault is its own encrypted blob). Shards carry a leading marker
/// byte so a corrupt or truncated shard is detected instead of silently half-restored.
///
/// Not `@MainActor`: the keychain API is thread-safe and the store protocol is `Sendable`, so the
/// save/load path can run off the main thread (the debounced write in `Store` schedules it on a
/// background task). Callers hop back to the main actor before touching `Store` state.
public enum KeychainBackup {

    /// Service/account namespace. Stable across versions so a reinstall of a newer build finds it.
    nonisolated static let service = "com.jo32.yingxia.ios.backup"
    nonisolated static let accountPrefix = "shard"

    /// Each shard's target size in bytes. Small enough to be safe on old keychain limits, large
    /// enough that even a big backup only needs a handful of items.
    nonisolated static let shardSize = 8 * 1024

    /// One shard, plus the bookkeeping a reader needs to trust the whole chain.
    struct Shard: Codable, Equatable, Sendable {
        var index: Int
        var count: Int
        var createdAt: Date
        var bytes: Data
    }

    /// A decode-able whole backup read back from the keychain.
    public struct Result: Equatable, Sendable {
        public var backup: FullBackup
        public var createdAt: Date
        public var shardCount: Int
    }

    // MARK: - Keychain plumbing

    /// The four operations `KeychainBackup` needs, so a unit test can substitute an in-memory store.
    public protocol Store: Sendable {
        func data(forAccount account: String, service: String) -> Data?
        func set(_ data: Data?, forAccount account: String, service: String)
    }

    /// The real keychain, used by the app.
    public struct KeychainStore: Store {
        public init() {}
        public func data(forAccount account: String, service: String) -> Data? {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess, let data = result as? Data else { return nil }
            return data
        }
        public func set(_ data: Data?, forAccount account: String, service: String) {
            let base: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            guard let data else {
                SecItemDelete(base as CFDictionary)
                return
            }
            var update: [String: Any] = [kSecValueData as String: data]
            let status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
            if status == errSecItemNotFound {
                update.merge(base) { current, _ in current }
                SecItemAdd(update as CFDictionary, nil)
            }
        }
    }

    // MARK: - Save / load / clear

    /// Encodes `backup` and writes it into the keychain as shards, replacing anything already there.
    /// Returns the number of shards written, or nil when there is nothing to back up.
    @discardableResult
    public static func save(_ backup: FullBackup, to store: Store = KeychainStore()) -> Int? {
        guard !backup.isEmpty else { clear(in: store); return nil }
        guard let json = try? JSONEncoder().encode(backup) else { return nil }
        let shards = Self.shards(from: json)
        // Write every shard first, then clear any stale higher-indexed shards, so a crash mid-write
        // never leaves a new index 0 next to an old, longer chain.
        for shard in shards { store.set(shardData(shard), forAccount: account(shard.index), service: service) }
        let stale = storedCount(in: store)
        if stale > shards.count {
            for index in shards.count..<stale { store.set(nil, forAccount: account(index), service: service) }
        }
        return shards.count
    }

    /// Reads the shards back and reassembles the backup. Returns nil when nothing is stored, the
    /// chain is incomplete, or any shard is corrupt.
    public static func load(from store: Store = KeychainStore()) -> Result? {
        guard let first = store.data(forAccount: account(0), service: service),
              let head = decode(first), head.index == 0 else { return nil }
        guard head.count > 0 else { return nil }
        var parts: [Data?] = Array(repeating: nil, count: head.count)
        parts[0] = head.bytes
        for index in 1..<head.count {
            guard let raw = store.data(forAccount: account(index), service: service),
                  let shard = decode(raw), shard.index == index, shard.count == head.count else { return nil }
            parts[index] = shard.bytes
        }
        var joined = Data()
        for part in parts {
            guard let bytes = part else { return nil }
            joined.append(bytes)
        }
        guard let backup = try? JSONDecoder().decode(FullBackup.self, from: joined) else { return nil }
        return Result(backup: backup, createdAt: head.createdAt, shardCount: head.count)
    }

    /// Removes every shard, leaving the keychain clean.
    public static func clear(in store: Store = KeychainStore()) {
        let count = storedCount(in: store)
        for index in 0..<count { store.set(nil, forAccount: account(index), service: service) }
    }

    /// Whether any backup shards are currently stored.
    public static func hasBackup(in store: Store = KeychainStore()) -> Bool {
        storedCount(in: store) > 0
    }

    // MARK: - Internals

    static func account(_ index: Int) -> String { "\(accountPrefix)-\(index)" }

    /// How many shard accounts currently exist (read by walking from 0 until a gap, capped).
    static func storedCount(in store: Store) -> Int {
        var count = 0
        while count < 256, store.data(forAccount: account(count), service: service) != nil { count += 1 }
        return count
    }

    static func shards(from json: Data) -> [Shard] {
        let bytes = [UInt8](json)
        let count = max(1, (bytes.count + shardSize - 1) / shardSize)
        let createdAt = Date()
        return (0..<count).map { index in
            let start = index * shardSize
            let end = min(start + shardSize, bytes.count)
            return Shard(index: index, count: count, createdAt: createdAt, bytes: Data(bytes[start..<end]))
        }
    }

    static func shardData(_ shard: Shard) -> Data {
        (try? JSONEncoder().encode(shard)) ?? Data()
    }

    static func decode(_ data: Data) -> Shard? {
        try? JSONDecoder().decode(Shard.self, from: data)
    }
}

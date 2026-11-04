import Foundation
import Testing
@testable import TVCore

/// KeychainBackup 的分片写入/读回往返、空备份清理、以及损坏/不完整分片的防御，用内存 Store
/// 替代真实钥匙串，只锁「卸载后能从钥匙串重组出完整备份」这个核心契约。
@Suite struct KeychainBackupTests {

    /// 内存版 KeychainBackup.Store，模拟 SecItem 的按 service+account 存取。
    final class MemoryStore: KeychainBackup.Store, @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: Data] = [:]
        func data(forAccount account: String, service: String) -> Data? {
            lock.lock(); defer { lock.unlock() }
            return items[service + "." + account]
        }
        func set(_ data: Data?, forAccount account: String, service: String) {
            lock.lock(); defer { lock.unlock() }
            items[service + "." + account] = data
        }
    }

    private func sampleBackup() -> FullBackup {
        FullBackup(appName: "Mi3s", appVersion: "1.8.8",
                   accounts: ["douyin": Data("cookie=abc".utf8)],
                   history: try? JSONEncoder().encode([1, 2, 3]),
                   favorites: Data("fav".utf8),
                   vault: Data("vault".utf8),
                   preferences: ["sourceOrder.enabled": try! JSONEncoder().encode(true)])
    }

    @Test func saveThenLoadRoundTrips() {
        let store = MemoryStore()
        let backup = sampleBackup()

        let count = KeychainBackup.save(backup, to: store)
        #expect(count != nil)
        #expect(count! >= 1)

        let loaded = KeychainBackup.load(from: store)
        #expect(loaded != nil)
        #expect(loaded?.backup == backup)
        #expect(loaded?.shardCount == count)
    }

    @Test func emptyBackupClearsAndLoadsNil() {
        let store = MemoryStore()
        let backup = FullBackup(appName: "Mi3s", appVersion: "1.8.8")

        #expect(KeychainBackup.save(backup, to: store) == nil)
        #expect(!KeychainBackup.hasBackup(in: store))
        #expect(KeychainBackup.load(from: store) == nil)
    }

    @Test func largeBackupShardsAcrossMultipleItems() {
        let store = MemoryStore()
        // A history blob big enough to force multiple shards.
        let bigHistory = Data(repeating: 0xAB, count: KeychainBackup.shardSize * 3 + 123)
        let backup = FullBackup(appName: "Mi3s", appVersion: "1.8.8", history: bigHistory)

        let count = KeychainBackup.save(backup, to: store)
        #expect(count! > 1)

        let loaded = KeychainBackup.load(from: store)
        #expect(loaded?.backup.history == bigHistory)
        #expect(loaded?.shardCount == count)
    }

    @Test func missingShardFailsToLoad() {
        let store = MemoryStore()
        let backup = FullBackup(appName: "Mi3s", appVersion: "1.8.8",
                                history: Data(repeating: 0x01, count: KeychainBackup.shardSize * 2))
        _ = KeychainBackup.save(backup, to: store)!

        // Delete the middle shard, leaving a gap.
        store.set(nil, forAccount: KeychainBackup.account(1), service: KeychainBackup.service)

        #expect(KeychainBackup.load(from: store) == nil)
        // The head shard still exists, so hasBackup still reports true.
        #expect(KeychainBackup.hasBackup(in: store))
    }

    @Test func corruptShardFailsToLoad() {
        let store = MemoryStore()
        let backup = sampleBackup()
        _ = KeychainBackup.save(backup, to: store)

        // Corrupt shard 0 with garbage that decodes but with wrong index/count.
        store.set(Data("garbage".utf8), forAccount: KeychainBackup.account(0), service: KeychainBackup.service)

        #expect(KeychainBackup.load(from: store) == nil)
    }

    @Test func clearRemovesEverything() {
        let store = MemoryStore()
        let backup = sampleBackup()
        _ = KeychainBackup.save(backup, to: store)

        KeychainBackup.clear(in: store)
        #expect(!KeychainBackup.hasBackup(in: store))
        #expect(KeychainBackup.load(from: store) == nil)
    }

    @Test func overwriteShortensStaleChain() {
        let store = MemoryStore()
        // First a large backup (many shards), then a small one (fewer shards).
        let big = FullBackup(appName: "Mi3s", appVersion: "1.8.8",
                             history: Data(repeating: 0x02, count: KeychainBackup.shardSize * 3))
        _ = KeychainBackup.save(big, to: store)
        let small = sampleBackup()
        let smallCount = KeychainBackup.save(small, to: store)!

        // Stale higher-indexed shards must be gone so load reads exactly the new chain.
        #expect(KeychainBackup.storedCount(in: store) == smallCount)
        let loaded = KeychainBackup.load(from: store)
        #expect(loaded?.backup == small)
    }
}

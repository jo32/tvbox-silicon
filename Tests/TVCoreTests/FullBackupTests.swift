import Foundation
import Testing
@testable import TVCore

/// FullBackup 的编解码往返与类别位运算，以及 UserDefaults 白名单快照/恢复的纯逻辑。
/// 不启动 App、不碰真实账号文件，只锁「备份文件能无损往返」和「快照能还原」这两个核心契约。
@Suite struct FullBackupTests {

    // MARK: - FullBackup 编解码往返

    @Test func aBackupRoundTripsAllSlices() throws {
        let accounts: [String: Data] = ["douyin": Data("cookie=abc".utf8)]
        let history = try JSONEncoder().encode([1, 2, 3])
        let favorites = Data("fav-blob".utf8)
        let vault = Data("vault-blob".utf8)
        let proxies = try JSONEncoder().encode(ProxySnapshot(endpoints: [], routes: ["k": .direct]))
        let prefs = ["sourceOrder.enabled": try JSONEncoder().encode(true)]
        let subs = Data("subs-blob".utf8)

        let backup = FullBackup(appName: "Mi3s", appVersion: "1.8.8",
                                accounts: accounts, history: history, favorites: favorites,
                                vault: vault, proxies: proxies, preferences: prefs, subscriptions: subs)

        let data = try JSONEncoder().encode(backup)
        let decoded = try JSONDecoder().decode(FullBackup.self, from: data)

        #expect(decoded.schemaVersion == FullBackup.version)
        #expect(decoded.appName == "Mi3s")
        #expect(decoded.appVersion == "1.8.8")
        #expect(decoded.accounts == accounts)
        #expect(decoded.history == history)
        #expect(decoded.favorites == favorites)
        #expect(decoded.vault == vault)
        #expect(decoded.proxies == proxies)
        #expect(decoded.preferences == prefs)
        #expect(decoded.subscriptions == subs)
        #expect(!decoded.isEmpty)
    }

    @Test func anEmptyBackupReportsEmpty() {
        let backup = FullBackup(appName: "Mi3s", appVersion: "0")
        #expect(backup.isEmpty)
    }

    @Test func aBackupWithOneSliceIsNotEmpty() {
        let backup = FullBackup(appName: "Mi3s", appVersion: "0", history: Data("x".utf8))
        #expect(!backup.isEmpty)
    }

    // MARK: - BackupCategory 位运算

    @Test func categoriesComposeAndDecompose() {
        let set: BackupCategory = [.accounts, .history, .vault]
        #expect(set.contains(.accounts))
        #expect(set.contains(.history))
        #expect(set.contains(.vault))
        #expect(!set.contains(.favorites))
        #expect(!set.contains(.subscriptions))

        #expect(BackupCategory.all.contains(.accounts))
        #expect(BackupCategory.all.contains(.subscriptions))
        #expect(BackupCategory.all.rawValue == 0b1111111)
    }

    @Test func categoryRawValuesAreDistinctBits() {
        let all = [
            BackupCategory.accounts, .history, .favorites, .vault,
            .proxies, .preferences, .subscriptions,
        ]
        var seen = Set<Int>()
        for category in all {
            #expect(!seen.contains(category.rawValue))
            seen.insert(category.rawValue)
            // Each category is a single bit.
            #expect(category.rawValue & (category.rawValue - 1) == 0)
        }
    }

    // MARK: - 白名单快照 / 恢复（UserDefaults 注入）

    private func clean(_ name: String) -> (UserDefaults, UserDefaults) {
        let suite = "TVCoreTests.FullBackup." + name
        let box = UserDefaults(suiteName: suite)!
        box.removePersistentDomain(forName: suite)
        let playbackSuite = suite + ".player"
        let playback = UserDefaults(suiteName: playbackSuite)!
        playback.removePersistentDomain(forName: playbackSuite)
        return (box, playback)
    }

    @Test func snapshotCapturesWhitelistedDataKeysOnly() throws {
        let (defaults, playback) = clean(#function)
        defaults.set(Data("fav".utf8), forKey: "favorites")
        defaults.set(Data("route".utf8), forKey: "sourceRouting.v1")
        defaults.set("not-a-backup-key", forKey: "someSystemKey")   // must be ignored
        playback.set(Data("vault".utf8), forKey: "privacyVault")

        let snapshot = FullBackupPreferences.snapshot(defaults: defaults, playbackDefaults: playback)

        #expect(snapshot["favorites"] == Data("fav".utf8))
        #expect(snapshot["sourceRouting.v1"] == Data("route".utf8))
        #expect(snapshot["privacyVault"] == Data("vault".utf8))
        #expect(snapshot["someSystemKey"] == nil)   // non-whitelisted key excluded
    }

    @Test func snapshotAndRestoreRoundTripsScalars() {
        let (defaults, playback) = clean(#function)
        defaults.set(true, forKey: "iCloudSync.enabled")
        defaults.set(8090, forKey: "webCast.port")

        let snapshot = FullBackupPreferences.snapshot(defaults: defaults, playbackDefaults: playback)
        #expect(snapshot["iCloudSync.enabled"] != nil)
        #expect(snapshot["webCast.port"] != nil)

        // Wipe and restore into fresh suites.
        let (restored, restoredPlayback) = clean(#function + ".restore")
        FullBackupPreferences.restore(snapshot, defaults: restored, playbackDefaults: restoredPlayback)

        #expect(restored.bool(forKey: "iCloudSync.enabled") == true)
        #expect(restored.integer(forKey: "webCast.port") == 8090)
    }

    @Test func restoreWritesDataBlobsToBothSuites() {
        let (defaults, playback) = clean(#function)
        defaults.set(Data("fav".utf8), forKey: "favorites")

        let snapshot = FullBackupPreferences.snapshot(defaults: defaults, playbackDefaults: playback)

        let (restored, restoredPlayback) = clean(#function + ".restore")
        FullBackupPreferences.restore(snapshot, defaults: restored, playbackDefaults: restoredPlayback)

        #expect(restored.data(forKey: "favorites") == Data("fav".utf8))
        #expect(restoredPlayback.data(forKey: "favorites") == Data("fav".utf8))
    }

    // MARK: - ProxySnapshot 往返

    @Test func proxySnapshotRoundTrips() throws {
        let endpoint = CustomProxyEndpoint(name: "home", scheme: .socks5, host: "127.0.0.1", port: 1080,
                                           username: "u", password: "p")
        let snapshot = ProxySnapshot(endpoints: [endpoint], routes: ["a|b": .proxy(endpoint.id)])

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ProxySnapshot.self, from: data)

        #expect(decoded.endpoints.count == 1)
        #expect(decoded.endpoints[0].host == "127.0.0.1")
        #expect(decoded.endpoints[0].username == "u")
        #expect(decoded.routes["a|b"]?.proxyID == endpoint.id)
    }
}

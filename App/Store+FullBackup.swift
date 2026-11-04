import Foundation
import TVCore

// MARK: - 完整备份：导出 / 导入

/// The outcome of restoring a full backup, so the settings sheet can report exactly what came back
/// and what was skipped (a slice the user did not tick, or a slice the backup did not contain).
struct FullBackupRestoreResult {
    var restored: [BackupCategory] = []
    var skippedMissing: [BackupCategory] = []
    var skippedUnselected: [BackupCategory] = []
}

extension Store {

    /// A complete snapshot of the viewer's data, minus subscriptions (which `exportConfig()` already
    /// carries). Each ticked category is read from its live store and packed as raw bytes.
    ///
    /// The "accounts" slice pulls the on-disk sign-in files verbatim, so a cookie or token is
    /// restored byte-for-byte. The "preferences" slice copies a whitelist of UserDefaults keys.
    func exportFullBackup(categories: BackupCategory) -> FullBackup {
        var backup = FullBackup(appName: "Mi3s",
                                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")

        // Sign-in & accounts: read each store's own file, which is the source of truth on iOS.
        if categories.contains(.accounts) {
            let accounts = FullBackupAccountStore.collect()
            if !accounts.isEmpty { backup.accounts = accounts }
        }

        // Playback history (all environments): `entries` is unfiltered, unlike `entries(in:)`.
        if categories.contains(.history) {
            backup.history = try? JSONEncoder().encode(playbackHistory.entries)
        }

        // Favourites live in UserDefaults as a v2 document (all environments), so they ride the
        // preferences slice; expose them explicitly too for callers that restore favourites alone.
        if categories.contains(.favorites) {
            if let data = defaults.data(forKey: "favorites") { backup.favorites = data }
        }

        // Privacy vault: persisted beside the other playback defaults.
        if categories.contains(.vault) {
            if let data = playbackDefaults.data(forKey: "privacyVault") { backup.vault = data }
        }

        // Custom proxies: endpoints (credentials obfuscated) + routes.
        if categories.contains(.proxies) {
            let endpoints = customProxy.store.endpoints
            let routes = Self.proxyRoutesSnapshot()
            if !endpoints.isEmpty || !routes.isEmpty {
                backup.proxies = try? JSONEncoder().encode(ProxySnapshot(endpoints: endpoints, routes: routes))
            }
        }

        // Preferences: a whitelist of UserDefaults keys, copied as raw blobs.
        if categories.contains(.preferences) {
            backup.preferences = FullBackupPreferences.snapshot(defaults: defaults, playbackDefaults: playbackDefaults)
        }

        // Subscriptions: reuse the existing portable config payload.
        if categories.contains(.subscriptions) {
            backup.subscriptions = try? JSONEncoder().encode(exportConfig())
        }

        return backup
    }

    /// Restores a backup's ticked slices. Returns what came back and what was skipped.
    @discardableResult
    func importFullBackup(_ backup: FullBackup, categories: BackupCategory) -> FullBackupRestoreResult {
        guard backup.schemaVersion == FullBackup.version else {
            importError = "这份备份来自不兼容的版本，无法恢复。"
            return FullBackupRestoreResult()
        }
        var result = FullBackupRestoreResult()

        func restore(_ category: BackupCategory, present: Bool, _ apply: () -> Void) {
            guard categories.contains(category) else { result.skippedUnselected.append(category); return }
            guard present else { result.skippedMissing.append(category); return }
            apply()
            result.restored.append(category)
        }

        restore(.accounts, present: backup.accounts != nil) {
            guard let accounts = backup.accounts else { return }
            FullBackupAccountStore.restore(accounts)
        }

        restore(.history, present: backup.history != nil) {
            guard let data = backup.history,
                  let entries = try? JSONDecoder().decode([PlaybackHistoryEntry].self, from: data) else { return }
            playbackHistory.adopt(entries)
        }

        restore(.favorites, present: backup.favorites != nil) {
            guard let data = backup.favorites else { return }
            defaults.set(data, forKey: "favorites")
        }

        restore(.vault, present: backup.vault != nil) {
            guard let data = backup.vault else { return }
            playbackDefaults.set(data, forKey: "privacyVault")
            if let saved = try? JSONDecoder().decode(PrivacyVault.self, from: data) { vault = saved }
        }

        restore(.proxies, present: backup.proxies != nil) {
            guard let data = backup.proxies,
                  let snapshot = try? JSONDecoder().decode(ProxySnapshot.self, from: data) else { return }
            Self.restoreProxies(snapshot, defaults: defaults)
            customProxy.touch()
        }

        restore(.preferences, present: backup.preferences != nil) {
            guard let prefs = backup.preferences else { return }
            FullBackupPreferences.restore(prefs, defaults: defaults, playbackDefaults: playbackDefaults)
        }

        restore(.subscriptions, present: backup.subscriptions != nil) {
            guard let data = backup.subscriptions,
                  let config = try? JSONDecoder().decode(SubscriptionConfig.self, from: data) else { return }
            importConfig(config, overwrite: true)
        }

        return result
    }

    // MARK: - 快照 / 还原辅助

    /// Reads the current proxy routes out of the store's defaults (the store itself only exposes
    /// routes by key, not the whole table).
    static func proxyRoutesSnapshot() -> [String: CustomProxyRoute] {
        guard let data = UserDefaults.standard.data(forKey: "proxyRoutes.v1"),
              let routes = try? JSONDecoder().decode([String: CustomProxyRoute].self, from: data) else { return [:] }
        return routes
    }

    static func restoreProxies(_ snapshot: ProxySnapshot, defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(snapshot.endpoints) { defaults.set(data, forKey: "proxyEndpoints.v1") }
        if let data = try? JSONEncoder().encode(snapshot.routes) { defaults.set(data, forKey: "proxyRoutes.v1") }
    }
}

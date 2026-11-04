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

    // MARK: - iCloud 轻量同步

    /// The lightweight slice that follows the viewer through iCloud key-value storage, so a fresh
    /// install (after uninstall/reinstall) recovers sign-in state, the vault, proxies and preferences
    /// without a manual backup file. Subscriptions, history and favourites already have their own
    /// channels; this covers the rest.
    func cloudBackupPayload() -> CloudBackupPayload {
        var vaultValue: PrivacyVault?
        if let data = playbackDefaults.data(forKey: "privacyVault"),
           let decoded = try? JSONDecoder().decode(PrivacyVault.self, from: data), decoded.hasPasscode {
            vaultValue = decoded
        }
        let endpoints = customProxy.store.endpoints
        let routes = Self.proxyRoutesSnapshot()
        let proxies = (endpoints.isEmpty && routes.isEmpty) ? nil : ProxySnapshot(endpoints: endpoints, routes: routes)
        let prefs = FullBackupPreferences.snapshot(defaults: defaults, playbackDefaults: playbackDefaults)
        return CloudBackupPayload(accounts: FullBackupAccountStore.collect(),
                                  vault: vaultValue,
                                  proxies: proxies,
                                  preferences: prefs)
    }

    /// Applies a payload pulled from another device. Returns the slices that changed, so the caller
    /// can bump the relevant revision/touch.
    func applyCloudBackupPayload(_ payload: CloudBackupPayload) {
        if !payload.accounts.isEmpty { FullBackupAccountStore.restore(payload.accounts) }
        if let vaultValue = payload.vault {
            if let data = try? JSONEncoder().encode(vaultValue) {
                playbackDefaults.set(data, forKey: "privacyVault")
                vault = vaultValue
            }
        }
        if let proxies = payload.proxies {
            Self.restoreProxies(proxies, defaults: defaults)
            customProxy.touch()
        }
        if !payload.preferences.isEmpty {
            FullBackupPreferences.restore(payload.preferences, defaults: defaults, playbackDefaults: playbackDefaults)
        }
    }

    // MARK: - 云盘备份通道

    /// Writes the full backup into a signed-in cloud drive, so another device can restore it through
    /// the same drive. The JSON is the same payload `exportFullBackup` produces; `categories` picks
    /// which slices travel.
    func backupToCloudDrive(categories: BackupCategory, drive: CloudFilesDrive) async throws {
        let backup = exportFullBackup(categories: categories)
        let data = try JSONEncoder().encode(backup)
        try await CloudDriveBackup.upload(data, name: CloudDriveBackup.timestampedName(), to: drive)
        notice = L10n.text("Backed up to %@.", drive.name)
    }

    /// Pulls a backup file back from a cloud drive and restores it. `id` is the drive's identifier
    /// for the file and `name` its name; the caller (the settings sheet) passes the file the viewer
    /// picked from the drive's listing.
    func restoreFromCloudDrive(id: String, name: String, drive: CloudFilesDrive, categories: BackupCategory) async throws {
        let data = try await CloudDriveBackup.download(id: id, name: name, from: drive)
        guard let backup = try? JSONDecoder().decode(FullBackup.self, from: data) else {
            throw TVError.unsupported(L10n.text("This isn't a Mi3s backup file."))
        }
        importFullBackup(backup, categories: categories)
        notice = L10n.text("Restored from %@.", drive.name)
    }
}


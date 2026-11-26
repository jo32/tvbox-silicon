import Foundation
import Observation

/// Subscription-qualified hides. The same key scheme as `PinnedSources`.
@MainActor @Observable public final class HiddenSources {
    /// In the order they were hidden, as saved and synced.
    private var keys: [String] { didSet { lookup = Set(keys); sourceKeys = Set(keys.compactMap(Self.sourceComponent)) } }
    /// The same keys for `contains`, which runs for every source when the app starts and lists or searches its
    /// sources. Searching the list instead took seconds with thousands of sources hidden, long enough for iOS to
    /// kill the app as it started (report 39eb8ea19c38).
    private var lookup: Set<String>
    /// The `source` each saved key hides, for a history entry whose own key differs from the hide's
    /// (a Cloud Files folder, below). Rebuilt with `lookup`, so it costs nothing per entry.
    private var sourceKeys: Set<String>
    /// Bumps when a source is hidden or shown, so a cached source row can be reused until then.
    public private(set) var revision = 0
    private let defaults: UserDefaults
    /// Called after the list changes here (not after `adopt`), for iCloud sync.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?
    private static let storageKey = "hiddenSources.v1"
    private static let builtInRestoreKey = "hiddenSources.builtInRestore.v1"
    private static let autoRestoreKey = "hiddenSources.autoRestore.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.stringArray(forKey: Self.storageKey) ?? []
        keys = saved
        lookup = Set(saved)
        sourceKeys = Set(saved.compactMap(Self.sourceComponent))
    }

    public var isEmpty: Bool { lookup.isEmpty }

    private func key(origin: URL, sourceKey: String) -> String {
        EpisodeSkipSettings.scope(origin: origin, source: sourceKey, video: "")
    }

    private func key(_ site: Site, origin: URL) -> String {
        key(origin: site.origin(or: origin), sourceKey: site.sourceKey)
    }

    /// The `source` a saved scope key hides: a scope is `[origin, source, video]` as JSON.
    private static func sourceComponent(of scope: String) -> String? {
        guard let data = scope.data(using: .utf8),
              let parts = try? JSONDecoder().decode([String].self, from: data), parts.count == 3 else { return nil }
        return parts[1]
    }

    public func contains(_ site: Site, origin: URL) -> Bool {
        !lookup.isEmpty && lookup.contains(key(site, origin: origin))
    }

    public func contains(_ context: PlaybackHistoryContext) -> Bool {
        guard !lookup.isEmpty else { return false }
        if lookup.contains(key(origin: context.origin, sourceKey: context.sourceKey)) { return true }
        // Cloud Files history keeps one sourceKey for every drive, while each drive hides under its own site key,
        // so the exact match above never fires for a watched folder: match the entry to its drive's hide instead
        // (#2360). A drive's key is unique to it, so no other subscription's source can match by mistake.
        return context.sourceKey == CloudFiles.sourceKey &&
            sourceKeys.contains(CloudFilesSource.keyPrefix + context.episodeFlag)
    }

    public func toggle(_ site: Site, origin: URL) {
        let key = key(site, origin: origin)
        if lookup.contains(key) { keys.removeAll { $0 == key } } else { keys.append(key) }
        defaults.set(keys, forKey: Self.storageKey)
        revision += 1
        onChange?()
    }

    public func insert(_ site: Site, origin: URL) {
        let key = key(site, origin: origin)
        guard !lookup.contains(key) else { return }
        keys.append(key)
        defaults.set(keys, forKey: Self.storageKey)
        revision += 1
        onChange?()
    }

    /// Hides or shows many sources in one change: one save, one revision, one sync.
    public func setHidden(_ sites: [Site], origin: URL, hidden: Bool) {
        let changed = Set(sites.map { key($0, origin: origin) })
        var next = keys
        if hidden {
            var present = lookup
            for site in sites {
                let key = key(site, origin: origin)
                if present.insert(key).inserted { next.append(key) }
            }
        } else {
            next.removeAll { changed.contains($0) }
        }
        guard next != keys else { return }
        keys = next
        defaults.set(keys, forKey: Self.storageKey)
        revision += 1
        onChange?()
    }

    /// Keys saved under a subscription's old address, moved to its new one (#982).
    public func moveOrigin(from old: URL, to new: URL) {
        let next = EpisodeSkipSettings.rescope(keys, from: old, to: new)
        guard next != keys else { return }
        keys = next
        defaults.set(keys, forKey: Self.storageKey)
        revision += 1
        onChange?()
    }

    /// The saved keys, in order, as iCloud sync compares them.
    public var savedKeys: [String] { keys }
    /// The list merged with other devices'.
    public func adopt(_ keys: [String]) {
        guard keys != self.keys else { return }
        self.keys = keys
        defaults.set(keys, forKey: Self.storageKey)
        revision += 1
    }

    /// Built-in sources used to be hidden automatically like any other, so once, every hidden
    /// built-in shows again. One the viewer hides afterwards stays hidden.
    public func restoreBuiltIns(_ sites: [Site], origin: URL) {
        guard !defaults.bool(forKey: Self.builtInRestoreKey), !sites.isEmpty else { return }
        let restored = Set(sites.filter(\.isBuiltIn).map { key($0, origin: origin) })
        if keys.contains(where: restored.contains) {
            keys.removeAll { restored.contains($0) }
            defaults.set(keys, forKey: Self.storageKey)
            revision += 1
            onChange?()
        }
        defaults.set(true, forKey: Self.builtInRestoreKey)
    }

    /// 1.7.13 hid a source automatically once it went red, in the same list as the viewer's own hides,
    /// and nothing brought it back. Failing sources are now only paused in search (`SourceHealth.paused`),
    /// so once, every hidden source that failed repeatedly shows again. One hidden while it worked was
    /// the viewer's choice and stays hidden. An empty list waits for the real subscription.
    public func restoreAutoHidden(_ sites: [Site], origin: URL, health: SourceHealth) {
        guard !defaults.bool(forKey: Self.autoRestoreKey), !sites.isEmpty else { return }
        let restored = Set(sites.filter { health.failedRepeatedly($0, origin: origin) }.map { key($0, origin: origin) })
        if keys.contains(where: restored.contains) {
            keys.removeAll { restored.contains($0) }
            defaults.set(keys, forKey: Self.storageKey)
            revision += 1
            onChange?()
        }
        defaults.set(true, forKey: Self.autoRestoreKey)
    }
}

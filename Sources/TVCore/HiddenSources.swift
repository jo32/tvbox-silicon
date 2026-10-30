import Foundation
import Observation

/// Subscription-qualified hides. The same key scheme as `PinnedSources`.
@MainActor @Observable public final class HiddenSources {
    private var keys: [String]
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
        keys = defaults.stringArray(forKey: Self.storageKey) ?? []
    }

    private func key(_ site: Site, origin: URL) -> String {
        EpisodeSkipSettings.scope(origin: site.origin(or: origin), source: site.sourceKey, video: "")
    }

    public func contains(_ site: Site, origin: URL) -> Bool { keys.contains(key(site, origin: origin)) }

    public func toggle(_ site: Site, origin: URL) {
        let key = key(site, origin: origin)
        if keys.contains(key) { keys.removeAll { $0 == key } } else { keys.append(key) }
        defaults.set(keys, forKey: Self.storageKey)
        revision += 1
        onChange?()
    }

    public func insert(_ site: Site, origin: URL) {
        let key = key(site, origin: origin)
        guard !keys.contains(key) else { return }
        keys.append(key)
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

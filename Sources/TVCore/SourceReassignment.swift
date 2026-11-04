import Foundation
import Observation

/// Where a viewer moved one source, across subscriptions. The Sources page groups a source by its
/// subscription's `provenance.origin`; a source listed under one subscription can be dragged onto another
/// subscription's header to file it there instead. The choice survives re-imports (the key scheme matches
/// `PinnedSources`) and follows the viewer to their other devices through iCloud.
///
/// Only the *displayed* group changes: the source still resolves against its own subscription (its
/// `provenance.origin`), so its API, plugin and relative addresses keep working. `SourceGroups.make` applies
/// this map when it files each source into a group.
@MainActor @Observable public final class SourceReassignment {
    /// Source scope key -> destination subscription address.
    private var values: [String: String]
    /// Bumps when a choice changes, so a cached source list can be reused until then.
    public private(set) var revision = 0
    private let defaults: UserDefaults
    /// Called after the list changes here (not after `adopt`), for iCloud sync.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?
    private static let storageKey = "sourceReassignment.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        values = defaults.dictionary(forKey: Self.storageKey) as? [String: String] ?? [:]
    }

    private func key(_ site: Site, origin: URL) -> String {
        EpisodeSkipSettings.scope(origin: site.origin(or: origin), source: site.sourceKey, video: "")
    }

    /// The subscription address this source was filed under, or nil when it stays in its own subscription.
    public func destination(for site: Site, origin: URL) -> String? { values[key(site, origin: origin)] }

    /// Files the source under another subscription, or (when `address` is its own) clears the override.
    public func reassign(_ site: Site, origin: URL, to address: String?) {
        let k = key(site, origin: origin)
        if let address, address != site.origin(or: origin).absoluteString {
            values[k] = address
        } else {
            guard values.removeValue(forKey: k) != nil else { return }
        }
        persist()
    }

    public func clear(_ site: Site, origin: URL) {
        let k = key(site, origin: origin)
        guard values.removeValue(forKey: k) != nil else { return }
        persist()
    }

    /// The saved choices, as iCloud sync compares them.
    public var savedValues: [String: String] { values }
    /// The list merged with other devices'.
    public func adopt(_ raw: [String: String]) {
        guard raw != values else { return }
        values = raw
        persist()
    }

    private func persist() {
        defaults.set(values, forKey: Self.storageKey)
        revision += 1
        onChange?()
    }
}

extension Site {
    /// The subscription address this source files under: its own, or the one the viewer dragged it onto.
    public func groupAddress(fallback origin: URL, reassign: (Site, URL) -> String?) -> String {
        reassign(self, origin) ?? self.origin(or: origin).absoluteString
    }
}

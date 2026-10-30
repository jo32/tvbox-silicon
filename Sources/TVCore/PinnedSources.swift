import Foundation
import Observation

/// Subscription-qualified keys survive imports and cannot pin an unrelated site's reused key.
@MainActor @Observable public final class PinnedSources {
    private var keys: [String]
    /// Bumps when the pin list changes, so a cached source row can be reused until then.
    public private(set) var revision = 0
    private let defaults: UserDefaults
    /// Called after the list changes here (not after `adopt`), for iCloud sync.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        keys = defaults.stringArray(forKey: "pinnedSources.v1") ?? []
    }
    private func key(_ site: Site, origin: URL) -> String { EpisodeSkipSettings.scope(origin: site.origin(or: origin), source: site.sourceKey, video: "") }
    public func contains(_ site: Site, origin: URL) -> Bool { keys.contains(key(site, origin: origin)) }
    public var isEmpty: Bool { keys.isEmpty }
    public func toggle(_ site: Site, origin: URL) {
        let key = key(site, origin: origin)
        if keys.contains(key) { keys.removeAll { $0 == key } } else { keys.append(key) }
        defaults.set(keys, forKey: "pinnedSources.v1")
        revision += 1
        onChange?()
    }

    /// The saved keys, in order, as iCloud sync compares them.
    public var savedKeys: [String] { keys }
    /// The list merged with other devices'.
    public func adopt(_ keys: [String]) {
        guard keys != self.keys else { return }
        self.keys = keys
        defaults.set(keys, forKey: "pinnedSources.v1")
        revision += 1
    }
    public func arrange(_ sites: [Site], origin: URL) -> [Site] {
        let rank = Dictionary(keys.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        return sites.enumerated().sorted {
            let lhs = rank[key($0.element, origin: origin)] ?? Int.max
            let rhs = rank[key($1.element, origin: origin)] ?? Int.max
            return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
        }.map(\.element)
    }
}

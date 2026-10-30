import Foundation
import Observation

/// The viewer's own source order. While it is on, it replaces the automatic one (`SourceStrategy`):
/// the Sources page lists sources in it, and search asks sources and lists their matches in it, top first.
/// Keys are subscription-qualified like `PinnedSources`, so the order survives re-imports.
@MainActor @Observable public final class SourceOrder {
    public var enabled: Bool {
        didSet { defaults.set(enabled, forKey: "sourceOrder.enabled"); revision += 1; onChange?() }
    }
    private var keys: [String]
    /// Bumps when the saved order or its switch changes, so a cached source row can be reused until then.
    public private(set) var revision = 0
    private let defaults: UserDefaults
    /// Called after the list changes here (not after `adopt`), for iCloud sync.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: "sourceOrder.enabled")
        keys = defaults.stringArray(forKey: "sourceOrder.v1") ?? []
    }
    /// Nothing arranged yet: `arrange` keeps the order it is given.
    public var isEmpty: Bool { keys.isEmpty }
    private func key(_ site: Site, origin: URL) -> String { EpisodeSkipSettings.scope(origin: site.origin(or: origin), source: site.sourceKey, video: "") }

    /// `sites` in the saved order; sources it has not seen yet (a new subscription's) follow, in the order given.
    public func arrange(_ sites: [Site], origin: URL) -> [Site] {
        let rank = Dictionary(keys.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        return sites.enumerated().sorted {
            let lhs = rank[key($0.element, origin: origin)] ?? Int.max
            let rhs = rank[key($1.element, origin: origin)] ?? Int.max
            return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
        }.map(\.element)
    }

    /// Each group's sources in the saved order, so moving a source on the Sources page moves it inside its group.
    public func arrange(_ groups: [SourceGroup], origin: URL) -> [SourceGroup] {
        groups.map { group in
            var group = group
            group.sites = arrange(group.sites, origin: origin)
            return group
        }
    }

    /// Saves `sites` as the order. Saved sources not among them (a subscription that is turned off)
    /// keep their places after them, so turning it back on doesn't lose its order.
    public func save(_ sites: [Site], origin: URL) {
        let ordered = sites.map { key($0, origin: origin) }, listed = Set(ordered)
        keys = ordered + keys.filter { !listed.contains($0) }
        defaults.set(keys, forKey: "sourceOrder.v1")
        revision += 1
        onChange?()
    }

    /// The saved keys, in order, as iCloud sync compares them.
    public var savedKeys: [String] { keys }
    /// The list merged with other devices'.
    public func adopt(_ keys: [String]) {
        guard keys != self.keys else { return }
        self.keys = keys
        defaults.set(keys, forKey: "sourceOrder.v1")
        revision += 1
    }
}

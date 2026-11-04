import Foundation
import Observation

/// One source the viewer filed under another subscription.
///
/// The move is *display only*: the source keeps its own subscription's `provenance`, so its API,
/// plugin and relative addresses keep working exactly as before. Only the group it is listed in
/// changes, and only the Sources page reads it.
///
/// Its identity is the subscription the source came from — the address the viewer added, not the
/// URL that address finally landed on — plus the key the feed gave the source. A subscription that
/// redirects to a new mirror on refresh keeps the same address, so a move survives every update;
/// keyed by the final URL, it used to be dropped by the next refresh.
public struct SourceMove: Codable, Hashable, Sendable, Identifiable {
    /// The address of the subscription the source belongs to. Stable across refreshes.
    public var address: String
    /// The key the feed gave the source.
    public var sourceKey: String
    /// The subscription the viewer filed it under.
    public var target: String
    /// The name the source had when it was moved, for the maintenance list after a feed renames it.
    public var sourceName: String
    /// The subscription's origin at the time of the move, kept for the older key scheme.
    public var origin: String
    /// The name of the target subscription at the time of the move.
    public var targetName: String
    /// When the viewer moved it, newest first in the list.
    public var movedAt: Date

    public var id: String { Self.key(address: address, sourceKey: sourceKey) }

    public init(address: String, sourceKey: String, target: String, sourceName: String = "",
                origin: String = "", targetName: String = "", movedAt: Date = Date()) {
        self.address = address
        self.sourceKey = sourceKey
        self.target = target
        self.sourceName = sourceName
        self.origin = origin
        self.targetName = targetName
        self.movedAt = movedAt
    }

    /// The identity of one source inside one subscription. A unit separator keeps an address that
    /// happens to contain a delimiter from colliding with another source.
    public static func key(address: String, sourceKey: String) -> String {
        address + "\u{1F}" + sourceKey
    }

    public var title: String {
        let name = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? sourceKey : name
    }
}

/// Where a viewer moved sources, across subscriptions. The Sources page groups a source by its
/// subscription's `provenance.origin`; a source listed under one subscription can be dragged onto
/// another subscription's header to file it there instead. The choice survives re-imports and
/// follows the viewer to their other devices through iCloud.
///
/// Only the *displayed* group changes: the source still resolves against its own subscription (its
/// `provenance.origin`), so its API, plugin and relative addresses keep working. `SourceGroups.make`
/// applies this map when it files each source into a group.
@MainActor @Observable public final class SourceReassignment {
    /// One move per source identity.
    private var values: [String: SourceMove]
    /// Moves saved by builds that keyed by the subscription's origin. They still apply, matched by
    /// key and origin, so an update does not quietly move everything back.
    private var legacy: [String: String]
    /// Bumps when a choice changes, so a cached source list can be reused until then.
    public private(set) var revision = 0
    private let defaults: UserDefaults
    /// Called after the list changes here (not after `adopt`), for iCloud sync.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?
    private static let storageKey = "sourceReassignment.v2"
    private static let legacyStorageKey = "sourceReassignment.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([String: SourceMove].self, from: data) {
            values = saved
        } else {
            values = [:]
        }
        legacy = (defaults.dictionary(forKey: Self.legacyStorageKey) as? [String: String]) ?? [:]
    }

    /// The old identity: what `EpisodeSkipSettings.scope` writes, origin first.
    private static func legacyKey(origin: String, sourceKey: String) -> String {
        EpisodeSkipSettings.scope(origin: URL(string: origin) ?? URL(fileURLWithPath: "/"), source: sourceKey, video: "")
    }

    /// One move saved by a build that keyed by the subscription's origin rather than its address.
    public struct LegacyMove: Hashable, Sendable {
        public var origin: String
        public var sourceKey: String
        public var target: String
    }

    /// The moves older builds saved. They still apply, but the maintenance list cannot show or undo
    /// them until the app knows which address each origin belongs to, so it folds them in on launch.
    public var pendingLegacy: [LegacyMove] {
        legacy.compactMap { key, target in
            // The scope is a JSON array of three strings: origin, source, video.
            guard let data = key.data(using: .utf8),
                  let parts = try? JSONDecoder().decode([String].self, from: data), parts.count == 3
            else { return nil }
            return LegacyMove(origin: parts[0], sourceKey: parts[1], target: target)
        }
    }

    /// The subscription address this source was filed under, or nil when it stays where it belongs.
    ///
    /// `address` is the subscription's own address, which a refresh never changes; `origin` is only
    /// consulted for moves saved by an older build.
    public func destination(address: String, sourceKey: String, origin: URL? = nil) -> String? {
        if let move = values[SourceMove.key(address: address, sourceKey: sourceKey)], !move.target.isEmpty {
            return move.target
        }
        if let origin, let target = legacy[Self.legacyKey(origin: origin.absoluteString, sourceKey: sourceKey)] {
            return target
        }
        return nil
    }

    /// Files one source under another subscription, or (when `target` is its own address) moves it
    /// back. `targetName` is stored for the maintenance list, which outlives a rename.
    public func reassign(_ site: Site, address: String, origin: URL, sourceName: String = "",
                         to target: String?, targetName: String = "") {
        let key = SourceMove.key(address: address, sourceKey: site.sourceKey)
        legacy.removeValue(forKey: Self.legacyKey(origin: origin.absoluteString, sourceKey: site.sourceKey))
        guard let target, !target.isEmpty, target != address else {
            guard values.removeValue(forKey: key) != nil else { persist(); return }
            persist()
            return
        }
        let previous = values[key]
        values[key] = SourceMove(address: address,
                                  sourceKey: site.sourceKey,
                                  target: target,
                                  sourceName: sourceName.isEmpty ? (previous?.sourceName ?? site.name) : sourceName,
                                  origin: origin.absoluteString,
                                  targetName: targetName.isEmpty ? (previous?.targetName ?? "") : targetName,
                                  movedAt: previous?.movedAt ?? Date())
        persist()
    }

    /// Undoes one move, by its identity in the maintenance list.
    public func remove(_ id: String) {
        guard values.removeValue(forKey: id) != nil else { return }
        persist()
    }

    /// Undoes every move at once.
    public func removeAll() {
        guard !values.isEmpty || !legacy.isEmpty else { return }
        values.removeAll()
        legacy.removeAll()
        persist()
    }

    /// Every move, newest first, for the maintenance list.
    public var moves: [SourceMove] {
        values.values.sorted { ($0.movedAt, $0.id) > ($1.movedAt, $1.id) }
    }

    public var moveCount: Int { values.count }

    /// The saved moves, as iCloud sync compares them.
    public var savedValues: [String: SourceMove] { values }
    /// The list merged with other devices'.
    public func adopt(_ raw: [String: SourceMove]) {
        guard raw != values else { return }
        values = raw
        persist(notify: false)
    }

    private func persist(notify: Bool = true) {
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: Self.storageKey) }
        // The old map is kept for the sources that have not been moved again yet; `reassign` drops
        // one entry as soon as the same source is written in the new form.
        defaults.set(legacy, forKey: Self.legacyStorageKey)
        revision += 1
        if notify { onChange?() }
    }
}

extension Site {
    /// The subscription address this source files under: its own, or the one the viewer moved it to.
    public func groupAddress(fallback address: String, reassign: (Site, String) -> String?) -> String {
        reassign(self, address) ?? address
    }
}

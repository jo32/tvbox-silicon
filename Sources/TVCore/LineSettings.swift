import Foundation
import Observation

/// Per-line (per `Episode.flag`) settings, one level finer than `SourceRouting`/`CustomProxyRouter`:
/// a single line can be forced direct or through a custom proxy even when its source is on another
/// route, and a line can be hidden from the picker (with a small button to bring it back).
///
/// Keyed like `PinnedSources` / `HiddenSources` so choices survive re-imports and merges, and sync
/// through iCloud alongside the other source-level settings.
@MainActor @Observable public final class LineSettings {
    public struct Setting: Codable, Hashable, Sendable {
        /// A forced route for this line, or nil to follow the source's route.
        public var route: CustomProxyRoute?
        /// Whether this line is hidden from the picker and search. Hidden lines stay listed in the
        /// subscription's full detail, so a small button can restore them.
        public var hidden: Bool = false
        public init(route: CustomProxyRoute? = nil, hidden: Bool = false) {
            self.route = route; self.hidden = hidden
        }
    }

    /// The instance the app reads.
    ///
    /// Assignable so a Store built on its own defaults (QA's isolated data, tests) can point every
    /// reader at the same suite. `PlaybackSession` and the source editor have no `Store` to ask, and
    /// reading `.shared` there while the app wrote through `playbackDefaults` meant a line route set
    /// in one place was invisible in the other.
    @MainActor public static var shared = LineSettings()

    private var values: [String: Setting]
    public private(set) var revision = 0
    private let defaults: UserDefaults
    private static let storageKey = "lineSettings.v1"
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([String: Setting].self, from: data) { values = saved }
        else { values = [:] }
    }

    private func key(origin: URL, sourceKey: String, flag: String) -> String {
        EpisodeSkipSettings.scope(origin: origin, source: sourceKey, video: flag)
    }

    public func setting(origin: URL, sourceKey: String, flag: String) -> Setting? {
        values[key(origin: origin, sourceKey: sourceKey, flag: flag)]
    }

    /// The forced route for a line, or nil when it follows its source.
    public func route(origin: URL, sourceKey: String, flag: String) -> CustomProxyRoute? {
        values[key(origin: origin, sourceKey: sourceKey, flag: flag)]?.route
    }

    /// Whether a line is hidden from the picker.
    public func isHidden(origin: URL, sourceKey: String, flag: String) -> Bool {
        values[key(origin: origin, sourceKey: sourceKey, flag: flag)]?.hidden ?? false
    }

    public func setRoute(_ route: CustomProxyRoute?, origin: URL, sourceKey: String, flag: String) {
        mutate(origin: origin, sourceKey: sourceKey, flag: flag) { $0.route = route }
    }

    public func setHidden(_ hidden: Bool, origin: URL, sourceKey: String, flag: String) {
        mutate(origin: origin, sourceKey: sourceKey, flag: flag) { $0.hidden = hidden }
    }

    /// Toggles hiding, returning the new state for the button's label.
    @discardableResult
    public func toggleHidden(origin: URL, sourceKey: String, flag: String) -> Bool {
        let k = key(origin: origin, sourceKey: sourceKey, flag: flag)
        var current = values[k] ?? Setting()
        current.hidden.toggle()
        values[k] = current
        persist()
        return current.hidden
    }

    /// All flags hidden for a source, so a bulk "hide every dead line" can be offered.
    public func hiddenFlags(origin: URL, sourceKey: String) -> Set<String> {
        var found = Set<String>()
        for (k, v) in values where v.hidden {
            if let flag = flag(in: k, origin: origin, sourceKey: sourceKey) { found.insert(flag) }
        }
        return found
    }

    /// Restores every hidden line of a source at once.
    public func restoreAll(origin: URL, sourceKey: String) {
        for (k, var v) in values where v.hidden && flag(in: k, origin: origin, sourceKey: sourceKey) != nil {
            v.hidden = false
            values[k] = v
        }
        persist()
    }

    /// Extracts the flag from a stored key when it belongs to `origin`/`sourceKey`. The key is the
    /// JSON array `["origin","source","flag"]` produced by `EpisodeSkipSettings.scope`, so the flag is
    /// the last decoded element rather than a `|`-separated tail.
    private func flag(in key: String, origin: URL, sourceKey: String) -> String? {
        guard let parts = try? JSONDecoder().decode([String].self, from: Data(key.utf8)),
              parts.count == 3, parts[0] == origin.absoluteString, parts[1] == sourceKey else { return nil }
        return parts[2]
    }

    public var savedValues: [String: Setting] { values }
    public func adopt(_ synced: [String: Setting]) {
        guard synced != values else { return }
        values = synced
        persist()
    }

    private func mutate(origin: URL, sourceKey: String, flag: String, _ change: (inout Setting) -> Void) {
        let k = key(origin: origin, sourceKey: sourceKey, flag: flag)
        var current = values[k] ?? Setting()
        change(&current)
        if current.route == nil && !current.hidden { values.removeValue(forKey: k) } else { values[k] = current }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: Self.storageKey) }
        revision += 1
        onChange?()
    }
}

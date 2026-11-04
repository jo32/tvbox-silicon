import Foundation
import Observation

/// Local edits to a subscription sub-source: a new display name, or a replacement API address.
/// These override what the subscription file says, without rewriting the file, so the viewer's
/// changes survive a refresh. Keyed like `PinnedSources` / `HiddenSources` / `BlockedSources`.
///
/// Removal is `BlockedSources`'s job: a sub-source the viewer removes is blocked, which drops it
/// from every list and search. Keeping a separate `removed` flag here duplicated that and left
/// dead code, so this type only carries the two edits that have no other home.
@MainActor @Observable public final class SourceOverrides {
    public struct Override: Codable, Hashable, Sendable {
        public var name: String?
        public var api: String?
        public init(name: String? = nil, api: String? = nil) {
            self.name = name; self.api = api
        }
    }

    /// The instance the app reads.
    ///
    /// Assignable so a Store built on its own defaults (QA's isolated data, tests) can point every
    /// reader at the same suite. `PlaybackSession` and the source editor have no `Store` to ask, and
    /// reading `.shared` there while the app wrote through `playbackDefaults` meant a line route set
    /// in one place was invisible in the other.
    @MainActor public static var shared = SourceOverrides()

    private var overrides: [String: Override]
    public private(set) var revision = 0
    private let defaults: UserDefaults
    private static let storageKey = "sourceOverrides.v1"
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([String: Override].self, from: data) { overrides = saved }
        else { overrides = [:] }
    }

    private func key(_ site: Site, origin: URL) -> String {
        EpisodeSkipSettings.scope(origin: site.origin(or: origin), source: site.sourceKey, video: "")
    }

    public func override(for site: Site, origin: URL) -> Override? { overrides[key(site, origin: origin)] }

    public func rename(_ site: Site, origin: URL, to name: String) {
        let key = key(site, origin: origin)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var value = overrides[key] ?? Override()
        value.name = trimmed.isEmpty ? nil : trimmed
        if value.name == nil && value.api == nil { overrides.removeValue(forKey: key) } else { overrides[key] = value }
        persist(); revision += 1; onChange?()
    }

    public func setAPI(_ site: Site, origin: URL, to api: String) {
        let key = key(site, origin: origin)
        let trimmed = api.trimmingCharacters(in: .whitespacesAndNewlines)
        var value = overrides[key] ?? Override()
        value.api = trimmed.isEmpty ? nil : trimmed
        if value.name == nil && value.api == nil { overrides.removeValue(forKey: key) } else { overrides[key] = value }
        persist(); revision += 1; onChange?()
    }

    /// A copy of `site` with the viewer's name and address edits applied.
    public func apply(to site: Site, origin: URL) -> Site {
        guard let value = override(for: site, origin: origin) else { return site }
        return Site(key: site.key,
                    name: value.name ?? site.name,
                    type: site.type,
                    api: value.api ?? site.api,
                    raw: site.raw,
                    provenance: site.provenance,
                    detectedRuntime: site.detectedRuntime)
    }

    public var savedKeys: [String] { overrides.keys.sorted() }
    public var savedValues: [String: Override] { overrides }
    public func adopt(_ synced: [String: Override]) {
        guard synced != overrides else { return }
        overrides = synced
        persist(); revision += 1
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(overrides) { defaults.set(data, forKey: Self.storageKey) }
    }
}

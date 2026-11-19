import Foundation
import Observation

/// Live platforms and playlists the viewer turned off (#601, #783, #837). The built-in platforms come with the app and a
/// playlist comes with its subscription, so neither can be deleted on its own; hiding takes it out of Live TV, Watch Now
/// and live search, on every device. Known by address: a platform's `<scheme>://rooms`, a playlist's file.
@MainActor @Observable public final class HiddenLiveSources {
    /// In the order they were hidden, as saved and synced.
    private var keys: [String] { didSet { lookup = Set(keys) } }
    private var lookup: Set<String>
    private let defaults: UserDefaults
    /// Called after the list changes here (not after `adopt`), for iCloud sync.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?
    private static let storageKey = "hiddenLiveSources.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.stringArray(forKey: Self.storageKey) ?? []
        keys = saved
        lookup = Set(saved)
    }

    private static func key(_ source: LiveSource) -> String { source.url.absoluteString }

    public func contains(_ source: LiveSource) -> Bool { lookup.contains(Self.key(source)) }

    /// Hides or shows several in one change: one save, one sync.
    public func setHidden(_ sources: [LiveSource], hidden: Bool) {
        var next = keys
        if hidden {
            var present = lookup
            for source in sources where present.insert(Self.key(source)).inserted { next.append(Self.key(source)) }
        } else {
            let shown = Set(sources.map(Self.key))
            next.removeAll { shown.contains($0) }
        }
        guard next != keys else { return }
        keys = next
        defaults.set(keys, forKey: Self.storageKey)
        onChange?()
    }

    /// The saved keys, in order, as iCloud sync compares them.
    public var savedKeys: [String] { keys }
    /// The list merged with other devices'.
    public func adopt(_ keys: [String]) {
        guard keys != self.keys else { return }
        self.keys = keys
        defaults.set(keys, forKey: Self.storageKey)
    }
}

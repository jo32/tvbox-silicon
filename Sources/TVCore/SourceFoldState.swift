import Foundation

/// Remembers which source groups the viewer folded on the Sources page, so the page reopens as it was
/// left. Before anything was saved every group opens: a page that starts folded reads as a page with
/// no sources at all, which is the one thing this page must never look like.
public struct SourceFoldState {
    private let defaults: UserDefaults
    private static let storageKey = "sourceFoldState.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The group ids currently folded; nil when nothing was ever saved.
    public var collapsed: Set<String>? {
        guard let saved = defaults.stringArray(forKey: Self.storageKey) else { return nil }
        return Set(saved)
    }

    public func save(_ collapsed: Set<String>) {
        defaults.set(Array(collapsed).sorted(), forKey: Self.storageKey)
    }

    public func clear() {
        defaults.removeObject(forKey: Self.storageKey)
    }
}

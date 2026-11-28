import Foundation

/// The machine-learning processors behind Sharper Picture and Smooth Motion that this device starts and that then refuse
/// every frame. An iPad with an A13 (iPadOS 27) started both for every video and every picture size, loading their models
/// for up to three seconds each time, and each failed its first frames and was dropped, then the same again for the next
/// video and the next size (#2737). A size that failed before processing a single frame isn't started again; a kind that
/// did so at `limit` different sizes, and has never processed frames on this system version, is left off until the
/// system is updated. Sizes failing after frames went through (a hot or busy device) count for nothing here.
public struct EnhancementHealth: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case scale, smooth }

    /// Different sizes a kind may fail at straight away before it is left off.
    public static let limit = 3
    public static let defaultsKey = "videoEnhancementHealth"

    /// The system version these findings are for: an update can bring processors that work.
    public private(set) var system: String
    /// By kind, the sizes (`Stage` keys) that failed before processing a frame.
    private var failed: [String: Set<String>] = [:]
    /// Kinds that processed frames on this system version: their failures are a size's, not the device's.
    private var worked: Set<String> = []

    public init(system: String) { self.system = system }

    /// Whether the kind may run here at all.
    public func usable(_ kind: Kind) -> Bool {
        worked.contains(kind.rawValue) || (failed[kind.rawValue]?.count ?? 0) < Self.limit
    }

    /// Whether this size of this kind failed straight away before.
    public func refused(_ configuration: String, kind: Kind) -> Bool {
        failed[kind.rawValue]?.contains(configuration) == true
    }

    /// A size failed before processing a single frame. True when that leaves the kind unusable here.
    @discardableResult
    public mutating func failedAtOnce(_ configuration: String, kind: Kind) -> Bool {
        let before = usable(kind)
        failed[kind.rawValue, default: []].insert(configuration)
        return before && !usable(kind)
    }

    /// The kind processed frames: it works on this device.
    public mutating func worked(_ kind: Kind) {
        worked.insert(kind.rawValue)
    }

    public func hasWorked(_ kind: Kind) -> Bool { worked.contains(kind.rawValue) }

    /// The findings saved for this system version; none after a system update.
    public static func load(_ defaults: UserDefaults = .standard, system: String) -> EnhancementHealth {
        guard let data = defaults.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode(EnhancementHealth.self, from: data), saved.system == system else {
            return EnhancementHealth(system: system)
        }
        return saved
    }

    public func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

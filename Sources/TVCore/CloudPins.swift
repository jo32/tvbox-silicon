import Foundation
import Observation

/// Cloud files and folders kept at the top of their folder's list (#1715). Scoped by drive key and
/// file id, so an item of another drive with the same name stays on its own.
@MainActor @Observable public final class CloudPins {
    public static let shared = CloudPins()
    private var keys: Set<String>
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        keys = Set(defaults.stringArray(forKey: "cloudPins.v1") ?? [])
    }

    private func key(_ drive: CloudFilesDrive, _ file: CloudFile) -> String { drive.key + "|" + file.id }
    public func contains(drive: CloudFilesDrive, file: CloudFile) -> Bool { keys.contains(key(drive, file)) }

    public func toggle(drive: CloudFilesDrive, file: CloudFile) {
        let key = self.key(drive, file)
        if keys.contains(key) { keys.remove(key) } else { keys.insert(key) }
        defaults.set(Array(keys), forKey: "cloudPins.v1")
    }

    /// The pinned items first, the rest in the drive's own order.
    public func arrange(_ files: [CloudFile], drive: CloudFilesDrive) -> [CloudFile] {
        guard !keys.isEmpty else { return files }
        return files.filter { contains(drive: drive, file: $0) } + files.filter { !contains(drive: drive, file: $0) }
    }
}

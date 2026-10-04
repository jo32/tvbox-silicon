#if os(macOS)
import Foundation

/// Kept outside disposable plugin caches; never included in subscription exports.
public struct CloudDriveAccounts: Codable, Sendable {
    public var quarkCookie = ""
    public var ucCookie = ""
    public var ucToken = ""
    public var token = ""
    public init() {}
    public static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.tvbox.yingxia/CloudDrive/accounts.json")
    }
    public static func load() throws -> Self {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: fileURL))
    }
    public func save() throws {
        let folder = Self.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: Self.fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.fileURL.path)
    }
}
#endif

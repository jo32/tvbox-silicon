import Foundation

/// The "back up to a cloud drive" channel: it writes the app's full backup (a single JSON blob) into
/// a signed-in drive and reads it back later, so a fresh install on another device can restore
/// through whatever drive the viewer already has — Quark, UC, 115, an AList server or a WebDAV share.
///
/// Every drive already has read access (list/stream) for playing media; this adds the write side
/// (`upload`) and a whole-file `download`, and pins the backup to a fixed folder + name so a restore
/// can find it again.
public enum CloudDriveBackup {

    /// The folder (relative to the drive's root) backups live in.
    public static let folder = "Mi3sBackup"
    /// The file name a fresh backup is written under. `timestamped` variants keep every snapshot.
    public static let fileName = "mi3s-full-backup.json"

    /// A timestamped file name, so "back up" can keep history instead of overwriting the last one.
    public static func timestampedName(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "mi3s-backup-\(formatter.string(from: date)).json"
    }

    /// Writes `data` (the JSON-encoded `FullBackup`) into the drive. `folder` is the drive-rooted
    /// folder; the folder is created if it isn't there yet (best-effort — drives that refuse still
    /// succeed at the root).
    public static func upload(_ data: Data, name: String, to drive: CloudFilesDrive) async throws {
        switch drive {
        case .quark:
            try await QuarkFiles.quark.upload(await ensureFolder(in: drive), name: name, data: data)
        case .uc:
            try await QuarkFiles.uc.upload(await ensureFolder(in: drive), name: name, data: data)
        case .pan115:
            try await Pan115Files.shared.upload(await ensureFolder(in: drive), name: name, data: data)
        case .alist(let server):
            let target = try await ensureAlistFolder(server)
            try await uploadAlist(server, folder: target, name: name, data: data)
        }
    }

    /// Reads a backup file back from the drive. `id` is the drive's own identifier for the file
    /// (Quark/UC/115 fid/pick code, AList/WebDAV path) and `name` its name.
    public static func download(id: String, name: String, from drive: CloudFilesDrive) async throws -> Data {
        switch drive {
        case .quark: return try await QuarkFiles.quark.download(id, name: name)
        case .uc: return try await QuarkFiles.uc.download(id, name: name)
        case .pan115: return try await Pan115Files.shared.download(id)
        case .alist(let server):
            if server.isWebDAV { return try await WebDAV.shared.download(server, path: id) }
            return try await AList.shared.download(server, path: id)
        }
    }

    // MARK: - Folder handling

    /// Finds or creates the backup folder, returning its drive id. Quark/UC/115 folders are known by
    /// an id; listing the root finds the folder, else the drive's `mkdir` endpoint makes one.
    private static func ensureFolder(in drive: CloudFilesDrive) async throws -> String {
        let rootFiles = try await CloudFiles.list(drive, folder: drive.root)
        if let existing = rootFiles.first(where: { $0.isFolder && $0.name == folder }) { return existing.id }
        // The folder isn't there: create it. Each drive exposes its own mkdir; on failure the caller
        // still writes to the root (folder id "0"), which is a valid fallback.
        do { return try await mkdir(folder, in: drive) } catch {
            Diagnostics.shared.record(.warning, "backup", "couldn't create \(folder) folder on \(drive.key), falling back to root: \(error)")
            return "0"
        }
    }

    /// Creates a folder on a Quark/UC/115 drive, returning its id.
    private static func mkdir(_ name: String, in drive: CloudFilesDrive) async throws -> String {
        switch drive {
        case .quark: return try await QuarkFiles.quark.mkdir(name, parent: drive.root)
        case .uc: return try await QuarkFiles.uc.mkdir(name, parent: drive.root)
        case .pan115: return try await Pan115Files.shared.mkdir(name, parent: drive.root)
        case .alist: throw TVError.unsupported(L10n.text("Folders can't be created here."))
        }
    }

    /// For AList/WebDAV the "folder" is a path, not an id, and there is no need to pre-create it —
    /// the upload's `PUT` creates parent folders implicitly. Just ensure the target path.
    private static func ensureAlistFolder(_ server: AListServer) async throws -> String {
        let root = server.root
        return root == "/" ? "/\(folder)" : "\(root)/\(folder)"
    }

    private static func uploadAlist(_ server: AListServer, folder: String, name: String, data: Data) async throws {
        if server.isWebDAV { try await WebDAV.shared.upload(server, folder: folder, name: name, data: data) }
        else { try await AList.shared.upload(server, folder: folder, name: name, data: data) }
    }
}

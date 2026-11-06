import Foundation

/// Finished downloads handed to the share sheet (Save to Files, Save Video, AirDrop) under a readable name.
/// The share sheet gets a copy, never the download itself, so deleting or renaming what was saved in Files
/// can't take the episode away from the app. On APFS the copy is a clone: no extra space and no wait.
public enum DownloadExport {
    /// Where the copies wait for the share sheet. The system may clear it; each export empties it first.
    public static var folder: URL { FileManager.default.temporaryDirectory.appending(path: "Shared Downloads") }

    /// Copies `file` into `folder` as `name` plus the file's extension, replacing earlier copies.
    public static func copy(_ file: URL, named name: String, into folder: URL = folder) throws -> URL {
        let manager = FileManager.default
        try? manager.removeItem(at: folder)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appending(path: fileName(name, extension: file.pathExtension))
        try manager.copyItem(at: file, to: target)
        return target
    }

    /// Removes the copies once the share sheet is done with them.
    public static func clear(_ folder: URL = folder) { try? FileManager.default.removeItem(at: folder) }

    /// `name` as a file name: no path separators or characters Files and Windows refuse, at most 120 characters.
    static func fileName(_ name: String, extension ext: String) -> String {
        let refused = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        var base = name.unicodeScalars.map { refused.contains($0) ? " " : String($0) }.joined()
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        while base.hasPrefix(".") { base.removeFirst() }
        base = String(base.prefix(120)).trimmingCharacters(in: .whitespaces)
        if base.isEmpty { base = "Yingxia" }
        return ext.isEmpty ? base : base + "." + ext
    }
}

extension DownloadLibrary {
    /// A finished episode as one file to save or share. Nil for HLS downloads, which are many segments.
    /// Doesn't look at the disk: menus ask for it while they draw, and the copy finds out if the file is gone.
    public func exportableFile(for item: DownloadItem) -> URL? {
        guard let file = file(for: item), file.pathExtension.lowercased() != "m3u8" else { return nil }
        return file
    }

    /// "Show · Episode", the name a shared episode gets.
    public nonisolated static func exportName(for item: DownloadItem) -> String {
        item.episode.isEmpty || item.episode == item.title ? item.title : "\(item.title) · \(item.episode)"
    }
}

extension MusicDownloadLibrary {
    /// A saved song's audio file. Doesn't look at the disk, like `DownloadLibrary.exportableFile`.
    public func file(for track: MusicTrack) -> URL? {
        guard let item = item(for: track), item.status == .completed, let media = item.media else { return nil }
        return folder(item.id).appending(path: media)
    }

    /// "Artist - Title", the name a shared song gets.
    public nonisolated static func exportName(for track: MusicTrack) -> String {
        // Commas, not artistLine's " / ": a slash can't be in a file name.
        track.artists.isEmpty ? track.title : "\(track.artists.joined(separator: ", ")) - \(track.title)"
    }
}

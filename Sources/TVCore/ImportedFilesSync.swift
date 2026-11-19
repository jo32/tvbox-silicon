import Foundation

/// Files added as subscriptions, carried to the viewer's other devices with the subscription list (#1235). Apple TV has
/// no Files app, so a playlist or spider added from a file on an iPhone is the only way such a file reaches it.
/// iCloud key-value storage holds 1 MB for everything the app syncs, so only text files go, compressed, first come
/// first served up to `syncBudget`; a larger one stays on its device and says so where it is missing.
extension ImportedFiles {
    /// The compressed bytes all synced files may take together, leaving room for favorites, history and the rest.
    nonisolated static let syncBudget = 160 * 1024

    /// The files the given subscription addresses name, by file name, as text: the ones that fit, in list order.
    @MainActor public static func syncedTexts(for addresses: [String]) -> [String: String] {
        var texts: [String: String] = [:], used = 0
        for address in addresses {
            guard let url = URL(string: address), let file = file(for: url), texts[file.lastPathComponent] == nil,
                  let entry = syncEntry(file) else { continue }
            guard used + entry.compressed <= syncBudget else { continue }
            used += entry.compressed
            texts[file.lastPathComponent] = entry.text
        }
        return texts
    }

    /// Writes the files another device added that are missing or older here. Returns whether any was written.
    @discardableResult
    public static func adopt(_ texts: [String: String]) -> Bool {
        var wrote = false
        for (name, text) in texts {
            guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/") else { continue }
            let file = directory.appending(path: name), data = Data(text.utf8)
            guard (try? Data(contentsOf: file)) != data else { continue }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
                wrote = true
            } catch {
                Diagnostics.shared.failure("icloud", "write synced file", error)
            }
        }
        return wrote
    }

    /// A file's text and compressed size, read again only when the file changes: every flush of the subscription
    /// list asks for them, and compressing a large playlist each time would cost the main thread for nothing.
    @MainActor private static var syncEntries: [String: (stamp: String, entry: (text: String, compressed: Int)?)] = [:]

    @MainActor private static func syncEntry(_ file: URL) -> (text: String, compressed: Int)? {
        guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize else { return nil }
        let stamp = "\(size)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        if let cached = syncEntries[file.path], cached.stamp == stamp { return cached.entry }
        var entry: (text: String, compressed: Int)?
        // A file far past the budget can't compress into it; don't read it at all.
        if size <= syncBudget * 12, let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8),
           let packed = try? (data as NSData).compressed(using: .lzfse) {
            entry = (text, packed.length)
        }
        syncEntries[file.path] = (stamp, entry)
        return entry
    }
}

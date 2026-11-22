import Foundation

/// Pages two at a time when the reader is wider than tall (#1437, #1216), as Apple Books and printed comics show them:
/// a chapter's first page (the cover or title page) stands alone, then pages go in pairs. A page already as wide as a
/// spread stands alone too, and pairing starts again after it, so the pages that belong together stay together.
public enum MangaSpreads {
    /// Each spread's pages in reading order: one page or two.
    public static func spreads(count: Int, isWide: (Int) -> Bool) -> [[Int]] {
        var spreads: [[Int]] = [], page = 0
        while page < count {
            if page == 0 || page + 1 >= count || isWide(page) || isWide(page + 1) {
                spreads.append([page]); page += 1
            } else {
                spreads.append([page, page + 1]); page += 2
            }
        }
        return spreads
    }

    /// A page wider than tall is a spread already.
    public static func isWide(aspect: Double?) -> Bool { (aspect ?? 0) > 1 }

    /// Whether two pages fit side by side: a landscape view. A portrait page beside another takes the height either way,
    /// so two pages are each as large as one would be, and the dark bars beside a lone page go.
    public static func fitsTwo(width: Double, height: Double) -> Bool { height > 0 && width / height >= 1.2 }
}

/// New chapters of the comics the viewer follows (#1105): the chapter count the source shows now, against the count the
/// viewer last saw, on the comic's page or while reading. Both are kept by comic.
public struct MangaUpdates: Codable, Equatable, Sendable {
    /// Chapters the source listed at the last check.
    public var latest: [String: Int] = [:]
    /// Chapters there were when the viewer last saw the comic's list.
    public var seen: [String: Int] = [:]
    public var checked: Date?

    public init() {}

    /// How many chapters came out since the viewer last looked.
    public func newChapters(_ comic: String) -> Int {
        guard let latest = latest[comic], let seen = seen[comic] else { return 0 }
        return max(0, latest - seen)
    }

    /// A check found `count` chapters. The first count of a comic is what the viewer has seen: following a comic doesn't
    /// make all its chapters new.
    public mutating func found(_ count: Int, for comic: String) {
        guard count > 0 else { return }
        latest[comic] = count
        if seen[comic] == nil { seen[comic] = count }
    }

    /// The viewer saw the comic's `count` chapters.
    public mutating func saw(_ count: Int, of comic: String) {
        guard count > 0 else { return }
        seen[comic] = count
        if (latest[comic] ?? 0) < count { latest[comic] = count }
    }

    /// Keeps only the comics still followed.
    public mutating func keep(_ comics: Set<String>) {
        latest = latest.filter { comics.contains($0.key) }
        seen = seen.filter { comics.contains($0.key) }
    }

    /// Whether it is time to look again: at most every few hours, so sources aren't asked on every visit.
    public func due(now: Date = Date(), every interval: TimeInterval = 6 * 3600) -> Bool {
        guard let checked else { return true }
        return now.timeIntervalSince(checked) >= interval || now < checked
    }
}

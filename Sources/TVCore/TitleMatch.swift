import Foundation

/// Whether a search result's title is what was searched for (#374). Plenty of sources answer a search with loosely
/// related titles; the ones that match come first, and the search page keeps the rest behind one button (#770).
public enum TitleMatch {
    /// Lower case, half-width, simplified, with spaces and punctuation gone: "Mission: Impossible" and "MISSION IMPOSSIBLE"
    /// and "機動搜查隊" and "机动搜查队" compare equal.
    public static func normalize(_ text: String) -> String {
        var value = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        value = value.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? value
        return String(value.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// A season at the end of what was typed ("第二季", "s2", "season 2") doesn't have to be in the title.
    private static let season = try! NSRegularExpression(pattern: "(第[一二三四五六七八九十百零0-9]+[季部期]|s[0-9]+|season[0-9]+)$")

    /// The title holds the keyword, or, for a keyword of three characters or more, all of its characters in order
    /// (so "机动搜查队" finds "机动搜查队404" and "机动搜查队 劇場版"). An empty keyword matches everything.
    public static func matches(title: String, keyword: String) -> Bool {
        Wanted(keyword).map { $0.matches(title) } ?? true
    }

    /// The items whose title matches and the rest, each in the order they came. An empty keyword matches them all.
    public static func split<T>(_ items: [T], keyword: String, title: (T) -> String) -> (matching: [T], other: [T]) {
        // The keyword is the same for every title: normalized once, not once per result of the search.
        guard let wanted = Wanted(keyword) else { return (items, []) }
        var matching: [T] = [], other: [T] = []
        for item in items {
            if wanted.matches(title(item)) { matching.append(item) } else { other.append(item) }
        }
        return (matching, other)
    }

    /// The keyword, normalized, and without a season at its end; nil for an empty keyword.
    private struct Wanted {
        let full: String
        let core: String
        init?(_ keyword: String) {
            full = normalize(keyword)
            guard !full.isEmpty else { return nil }
            let range = NSRange(full.startIndex..., in: full)
            if let found = season.firstMatch(in: full, range: range), let cut = Range(found.range, in: full), cut.lowerBound != full.startIndex {
                core = String(full[..<cut.lowerBound])
            } else {
                core = full
            }
        }

        func matches(_ title: String) -> Bool {
            let name = normalize(title)
            if name.contains(full) || (core != full && name.contains(core)) { return true }
            guard core.count >= 3 else { return false }
            var remaining = core[...]
            for character in name {
                if character == remaining.first { remaining = remaining.dropFirst(); if remaining.isEmpty { return true } }
            }
            return false
        }
    }

    /// The items whose title matches first, then the rest, each in the order they came.
    public static func ordered<T>(_ items: [T], keyword: String, title: (T) -> String) -> [T] {
        let parts = split(items, keyword: keyword, title: title)
        return parts.matching + parts.other
    }
}

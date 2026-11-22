import Foundation

/// A long series' episodes in pages, as the 选集 tabs of video apps show them: 1–50, 51–100… (#1464). One tap reaches
/// episode 800 of a long anime, where the list was one grid to scroll through from the top. A list of 100 or fewer is
/// one page, with no tabs.
public enum EpisodePages {
    /// The pages of a list of `count` episodes, as index ranges: none for 100 or fewer, then 50 to a page, and 100 to a
    /// page past 500 so a very long series keeps a short row of tabs.
    public static func pages(count: Int) -> [Range<Int>] {
        guard count > 100 else { return [] }
        let size = count <= 500 ? 50 : 100
        return stride(from: 0, to: count, by: size).map { $0..<min($0 + size, count) }
    }

    /// The page holding the episode at `index`, else the first.
    public static func page(holding index: Int?, in pages: [Range<Int>]) -> Int {
        guard let index else { return 0 }
        return pages.firstIndex { $0.contains(index) } ?? 0
    }

    /// A tab's name: the episodes' numbers in the list, 1–50.
    public static func title(_ page: Range<Int>) -> String {
        "\(page.lowerBound + 1)–\(page.upperBound)"
    }
}

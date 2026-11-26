import Foundation

/// Pure ordering rules for the two-section tab bar editor (Tab Bar above, More below).
public enum TabBarReorder {
    /// Reconciles a drag result from the two sections against the bar's slot limit and minimum count.
    ///
    /// - Keeps at least one section in the tab bar (rejecting a move that would empty it).
    /// - When a move into a full tab bar exceeds `slots`, displaces the bar's previous last section
    ///   to the top of More rather than bouncing the newly dropped section back out, including when
    ///   dropped into the bar's last position.
    public static func reconcile<Item: Equatable>(
        previousBar: [Item],
        previousMore: [Item],
        proposedBar: [Item],
        proposedMore: [Item],
        slots: Int
    ) -> (bar: [Item], more: [Item]) {
        guard !proposedBar.isEmpty, slots > 0 else { return (previousBar, previousMore) }
        var bar = proposedBar
        var more = proposedMore
        var overflow: [Item] = []
        while bar.count > slots {
            let dropIndex = bar.lastIndex(where: previousBar.contains) ?? (bar.count - 1)
            overflow.insert(bar.remove(at: dropIndex), at: 0)
        }
        if !overflow.isEmpty {
            more.insert(contentsOf: overflow, at: 0)
        }
        return (bar, more)
    }
}

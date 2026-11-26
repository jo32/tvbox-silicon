import Testing
@testable import TVCore

@Test func moveFromMoreToLastSlotOfNonFullBarSucceeds() {
    let result = TabBarReorder.reconcile(
        previousBar: ["home", "discover", "music"],
        previousMore: ["novels", "sites", "manga"],
        proposedBar: ["home", "discover", "music", "novels"],
        proposedMore: ["sites", "manga"],
        slots: 4
    )
    #expect(result.bar == ["home", "discover", "music", "novels"])
    #expect(result.more == ["sites", "manga"])
}

@Test func moveFromBarToTopOfMoreSucceeds() {
    let result = TabBarReorder.reconcile(
        previousBar: ["home", "discover", "music"],
        previousMore: ["novels", "sites", "manga"],
        proposedBar: ["home", "discover"],
        proposedMore: ["music", "novels", "sites", "manga"],
        slots: 4
    )
    #expect(result.bar == ["home", "discover"])
    #expect(result.more == ["music", "novels", "sites", "manga"])
}

@Test func moveFromMoreToLastSlotOfFullBarDisplacesOldLastTab() {
    let firstFromMore = TabBarReorder.reconcile(
        previousBar: ["home", "discover", "live", "search"],
        previousMore: ["music", "manga", "novels"],
        proposedBar: ["home", "discover", "live", "search", "music"],
        proposedMore: ["manga", "novels"],
        slots: 4
    )
    #expect(firstFromMore.bar == ["home", "discover", "live", "music"])
    #expect(firstFromMore.more == ["search", "manga", "novels"])

    let laterFromMore = TabBarReorder.reconcile(
        previousBar: ["home", "discover", "live", "search"],
        previousMore: ["music", "manga", "novels"],
        proposedBar: ["home", "discover", "live", "search", "novels"],
        proposedMore: ["music", "manga"],
        slots: 4
    )
    #expect(laterFromMore.bar == ["home", "discover", "live", "novels"])
    #expect(laterFromMore.more == ["search", "music", "manga"])
}

@Test func moveFromMoreToEarlierSlotOfFullBarDisplacesOldLastTab() {
    let result = TabBarReorder.reconcile(
        previousBar: ["home", "discover", "live", "search"],
        previousMore: ["music", "manga"],
        proposedBar: ["home", "music", "discover", "live", "search"],
        proposedMore: ["manga"],
        slots: 4
    )
    #expect(result.bar == ["home", "music", "discover", "live"])
    #expect(result.more == ["search", "manga"])
}

@Test func moveCannotEmptyTheTabBar() {
    let result = TabBarReorder.reconcile(
        previousBar: ["home"],
        previousMore: ["discover", "music"],
        proposedBar: [],
        proposedMore: ["home", "discover", "music"],
        slots: 4
    )
    #expect(result.bar == ["home"])
    #expect(result.more == ["discover", "music"])
}

@Test func reorderWithinBarPreservesAllSlots() {
    let result = TabBarReorder.reconcile(
        previousBar: ["home", "discover", "live", "search"],
        previousMore: ["music", "manga"],
        proposedBar: ["search", "home", "discover", "live"],
        proposedMore: ["music", "manga"],
        slots: 4
    )
    #expect(result.bar == ["search", "home", "discover", "live"])
    #expect(result.more == ["music", "manga"])
}

@Test func wideBarSlotLimitWorksWhenDroppingAtEnd() {
    let result = TabBarReorder.reconcile(
        previousBar: ["1", "2", "3", "4", "5", "6", "7"],
        previousMore: ["8", "9"],
        proposedBar: ["1", "2", "3", "4", "5", "6", "7", "8"],
        proposedMore: ["9"],
        slots: 7
    )
    #expect(result.bar == ["1", "2", "3", "4", "5", "6", "8"])
    #expect(result.more == ["7", "9"])
}

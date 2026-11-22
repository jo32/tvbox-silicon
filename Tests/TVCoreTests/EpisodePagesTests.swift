import Testing
@testable import TVCore

@Suite struct EpisodePagesTests {
    @Test func shortListsHaveNoPages() {
        #expect(EpisodePages.pages(count: 0).isEmpty)
        #expect(EpisodePages.pages(count: 100).isEmpty)
    }

    @Test func longListsGoFiftyToAPage() {
        let pages = EpisodePages.pages(count: 123)
        #expect(pages == [0..<50, 50..<100, 100..<123])
        #expect(pages.map(EpisodePages.title) == ["1–50", "51–100", "101–123"])
    }

    @Test func veryLongListsGoAHundredToAPage() {
        let pages = EpisodePages.pages(count: 1_155)
        #expect(pages.count == 12)
        #expect(pages.last == 1_100..<1_155)
    }

    @Test func opensAtThePageOfTheEpisode() {
        let pages = EpisodePages.pages(count: 300)
        #expect(EpisodePages.page(holding: 0, in: pages) == 0)
        #expect(EpisodePages.page(holding: 149, in: pages) == 2)
        #expect(EpisodePages.page(holding: 150, in: pages) == 3)
        #expect(EpisodePages.page(holding: nil, in: pages) == 0)
        #expect(EpisodePages.page(holding: 999, in: pages) == 0)
    }
}

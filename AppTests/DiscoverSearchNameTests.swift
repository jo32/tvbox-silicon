import TVCore
import XCTest
@testable import PlaybackHistoryQA

/// A title page opened from a Douban card looks the title up on the viewer's sources by Douban's name (#2744):
/// sources list a title under the name it was released here under ("可能的爱"), which TMDB's zh-TW name for it
/// ("假如愛有如果") never matches. Every other card keeps the page on TMDB's name.
@MainActor final class DiscoverSearchNameTests: XCTestCase {
    private func item(name: String, originalName: String = "Possible Love") -> TMDBCatalog.Item {
        TMDBCatalog.Item(id: 1, mediaType: .movie, name: name, originalName: originalName, year: 2023, overview: "",
                         poster: nil, backdrop: nil, rating: nil, genreIDs: [])
    }

    func testDoubanCardSearchesByDoubanName() {
        let page = DiscoverDetailView(item: item(name: "假如愛有如果"), doubanName: "可能的爱")
        XCTAssertEqual(page.searchName, "可能的爱")
        // The page still shows TMDB's name; only the search uses Douban's.
        XCTAssertEqual(page.item.name, "假如愛有如果")
    }

    func testTMDBCardSearchesByTMDBName() {
        let page = DiscoverDetailView(item: item(name: "假如愛有如果"))
        XCTAssertEqual(page.searchName, "假如愛有如果")
    }

    /// The two ways into the same TMDB title search for it differently, so each keeps its own sources and search.
    func testEachNameGetsItsOwnSources() {
        let work = item(name: "假如愛有如果")
        let tmdb = DiscoverSources.of(work)
        let douban = DiscoverSources.of(work, name: "可能的爱")
        XCTAssertFalse(tmdb === douban)
        XCTAssertTrue(DiscoverSources.of(work) === tmdb)
        XCTAssertTrue(DiscoverSources.of(work, name: "可能的爱") === douban)
    }
}

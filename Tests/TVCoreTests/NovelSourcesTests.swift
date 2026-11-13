import Foundation
import Testing
@testable import TVCore

/// A Legado book source list is recognised as one (and only text sources are kept); other JSON is not.
@Test func novelSourceListIsRecognised() throws {
    let list = """
    [{"bookSourceUrl":"https://a.example","bookSourceName":"A","bookSourceGroup":"精品","searchUrl":"/s?q={{key}}","ruleSearch":{"bookList":"class.item"}},
     {"bookSourceUrl":"https://b.example","bookSourceName":"B","bookSourceType":1,"searchUrl":"/s","ruleSearch":{}},
     {"bookSourceUrl":"https://c.example","bookSourceName":"C","enabled":false,"exploreUrl":"玄幻::/c/1","ruleToc":{}},
     {"bookSourceUrl":"https://a.example","bookSourceName":"A again","searchUrl":"/s","ruleSearch":{}}]
    """
    let sources = try #require(NovelSource.list(from: Data(list.utf8)))
    #expect(sources.map(\.name) == ["A", "C"])
    #expect(sources[0].searchable && !sources[0].explorable && !sources[0].disabledByList)
    #expect(!sources[1].searchable && sources[1].explorable && sources[1].disabledByList)
    #expect(sources[0].group == "精品")
    // One source on its own counts too.
    #expect(NovelSource.list(from: Data(#"{"bookSourceUrl":"https://x","searchUrl":"/s"}"#.utf8))?.count == 1)
    // A TVBox subscription and a Venera index are not book source lists.
    #expect(NovelSource.list(from: Data(#"{"sites":[{"key":"a","api":"b"}]}"#.utf8)) == nil)
    #expect(NovelSource.list(from: Data(#"[{"name":"x","key":"x","fileName":"x.js"}]"#.utf8)) == nil)
}

@Test func novelImportLinksCarryTheListAddress() {
    let link = URL(string: "legado://import/bookSource?src=https%3A%2F%2Fexample.com%2Fsources.json")!
    #expect(NovelSources.importAddress(link)?.absoluteString == "https://example.com/sources.json")
    #expect(NovelSources.importAddress(URL(string: "https://example.com/sources.json")!) == nil)
}

/// Search joins the same title and author from several sources, and puts exact title matches first.
@Test func novelSearchMergesBooksAcrossSources() {
    var hits: [NovelSearchHit] = []
    NovelBooks.merge([NovelBook(sourceKey: "s1", url: "/1", name: "凡人修仙传之仙界篇", author: "忘语"),
                      NovelBook(sourceKey: "s1", url: "/2", name: "凡人修仙传", author: "忘语")], into: &hits, keyword: "凡人修仙传")
    NovelBooks.merge([NovelBook(sourceKey: "s2", url: "/x", name: "凡人修仙传 ", author: "忘语"),
                      NovelBook(sourceKey: "s2", url: "/y", name: "", author: "")], into: &hits, keyword: "凡人修仙传")
    #expect(hits.count == 2)
    #expect(hits[0].book.name == "凡人修仙传")
    #expect(hits[0].books.map(\.sourceKey) == ["s1", "s2"])
}

@Test func novelCoverCarriesItsHeaders() {
    let book = NovelBook(sourceKey: "s", url: "/b", name: "n", cover: #"https://img.example/c.jpg,{"headers":{"Referer":"https://example.com"}}"#)
    #expect(book.coverRequest?.url.absoluteString == "https://img.example/c.jpg")
    #expect(book.coverRequest?.headers["Referer"] == "https://example.com")
    #expect(NovelBook(sourceKey: "s", url: "/b", name: "n", cover: "//img.example/c.jpg").coverRequest?.url.scheme == "https")
}

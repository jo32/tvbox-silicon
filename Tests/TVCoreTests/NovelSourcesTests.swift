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

/// A Legado subscription source (订阅源) is not a book source list: it names the page it opens, and that page's
/// one-tap import links are the book source lists to offer, each named after the text before it.
@Test func novelSubscriptionSourceOpensItsPageOfLists() throws {
    let feed = """
    [{"articleStyle":0,"enableJs":true,"ruleArticles":"id.content@h3","ruleLink":"a@href","ruleTitle":"a@textNodes","singleUrl":true,
      "sortUrl":"首页::https://lists.example","sourceGroup":"书源","sourceName":"阅读APP源","sourceUrl":"https://lists.example"}]
    """
    #expect(NovelSourceIndex.pages(from: Data(feed.utf8)) == [URL(string: "https://lists.example")!])
    #expect(NovelSource.list(from: Data(feed.utf8)) == nil)
    // No sortUrl: the source's own address; a scripted one is skipped.
    #expect(NovelSourceIndex.pages(from: Data(#"{"sourceUrl":"https://b.example/x","ruleArticles":"a"}"#.utf8)) == [URL(string: "https://b.example/x")!])
    #expect(NovelSourceIndex.pages(from: Data(#"{"sourceUrl":"https://b.example","sortUrl":"@js:result"}"#.utf8)) == [])
    // Book sources and TVBox subscriptions are not subscription sources.
    #expect(NovelSourceIndex.pages(from: Data(#"[{"bookSourceUrl":"https://a","sourceUrl":"https://a","searchUrl":"/s"}]"#.utf8)) == nil)
    #expect(NovelSourceIndex.pages(from: Data(#"{"sites":[{"key":"a","api":"b"}]}"#.utf8)) == nil)

    let page = """
    <h2 id="id_0">书源</h2><p><details><summary>点击展开</summary></p>
    <ul><li><p>全量书源 </p><ul>
    <li><a href="https://lists.example/sources/b778.json">访问直链</a></li>
    <li><a href="legado://import/bookSource?src=https://lists.example/sources/b778.json">一键导入</a></li>
    <li>上一次同步状态: 同步成功, 共 3907 条</li></ul></li></ul><hr />
    <ul><li><p>XIU2精品书源 &amp; more 🔥</p><ul>
    <li><a href="legado://import/bookSource?src=https://lists.example/sources/71e5.json">一键导入</a></li></ul></li></ul>
    <ul><li><p>无名</p><ul><li><a href="yuedu://booksource/importonline?src=/sources/rel.json">x</a></li></ul></li></ul>
    <h2 id="id_1">订阅源</h2><ul><li><p>订阅</p><ul>
    <li><a href="legado://import/rssSource?src=https://lists.example/sources/c579.json">一键导入</a></li>
    <li><a href="legado://import/bookSource?src=https://lists.example/sources/b778.json">again</a></li></ul></li></ul>
    """
    let offers = NovelSourceIndex.offers(inPage: Data(page.utf8), origin: URL(string: "https://lists.example/")!)
    #expect(offers.map(\.name) == ["全量书源", "XIU2精品书源 & more 🔥", "无名"])
    #expect(offers.map(\.address.absoluteString) == ["https://lists.example/sources/b778.json", "https://lists.example/sources/71e5.json",
                                                     "https://lists.example/sources/rel.json"])
    #expect(NovelSourceIndex.offers(inPage: Data(#"{"sites":[]}"#.utf8), origin: URL(string: "https://x")!).isEmpty)
}

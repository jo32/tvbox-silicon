import Foundation
import Testing
@testable import TVCore

@Test func doubanListsGiveFilmsAndSeriesWithTheirCoversAndScores() throws {
    let data = Data(#"""
    {"start":0,"count":4,"total":4,"subject_collection_items":[
      {"id":"37446297","title":"逃出布迪秀","year":"2026","type":"movie","rating":{"value":7.4,"count":28478,"max":10},
       "cover":{"url":"https://img3.doubanio.com/view/photo/m_ratio_poster/public/p2934286660.jpg","width":1944},"card_subtitle":"2026 / 美国 / 惊悚"},
      {"id":"36675942","title":"小城良方","year":"2026","type":"tv","rating":{"value":8.0},
       "pic":{"large":"https://img2.doubanio.com/view/photo/m_ratio_poster/public/p2936709341.jpg","normal":"https://img2.doubanio.com/s.jpg"}},
      {"id":"37100984","title":"后会友期","year":"2026","type":"tv","rating":{"value":0},"pic":{"normal":"https://img3.doubanio.com/n.jpg"}},
      {"id":"1","title":"广告","type":"ad"},
      {"id":"36675942","title":"小城良方","year":"2026","type":"tv"}
    ]}
    """#.utf8)
    let items = try DoubanCatalog.parse(data)
    #expect(items.map(\.title) == ["逃出布迪秀", "小城良方", "后会友期"])
    #expect(items[0].mediaType == .movie && items[0].year == 2026 && items[0].rating == 7.4)
    #expect(items[0].cover?.absoluteString == "https://img3.doubanio.com/view/photo/m_ratio_poster/public/p2934286660.jpg")
    #expect(items[1].mediaType == .tv && items[1].cover?.lastPathComponent == "p2936709341.jpg")
    #expect(items[2].rating == nil)
    #expect(items[2].cover?.lastPathComponent == "n.jpg")
    #expect(throws: (any Error).self) { try DoubanCatalog.parse(Data(#"{"msg":"invalid_request_1284","code":1287}"#.utf8)) }
}

@Test func doubanTitlesOpenTheTMDBTitleOfTheSameKindNameAndYear() throws {
    func result(_ type: TMDBMatch.MediaType, _ id: Int, _ name: String, _ year: Int?, original: String? = nil) throws -> TMDBMatch.SearchResult {
        var row: [String: Any] = ["mediaType": type.rawValue, "id": id, "name": name, "sources": 0]
        if let year { row["year"] = year }
        if let original { row["originalName"] = original }
        return try JSONDecoder().decode(TMDBMatch.SearchResult.self, from: JSONSerialization.data(withJSONObject: row))
    }
    let birthday = DoubanCatalog.Item(id: "1", title: "生日快乐", year: 2025, rating: 8.9, cover: nil, mediaType: .movie)
    let results = [try result(.tv, 44218, "生日快乐", 2011), try result(.movie, 1142563, "一村之长之生日快乐", 2017), try result(.movie, 1303034, "生日快乐", 2025)]
    #expect(DoubanCatalog.match(birthday, in: results)?.id == 1303034)
    // A remake from another year is not the title.
    let old = DoubanCatalog.Item(id: "2", title: "生日快乐", year: 1990, rating: nil, cover: nil, mediaType: .movie)
    #expect(DoubanCatalog.match(old, in: results) == nil)
    // A later season matches the series, whatever year it began.
    let season = DoubanCatalog.Item(id: "3", title: "现在就出发 第四季", year: 2026, rating: nil, cover: nil, mediaType: .tv)
    #expect(DoubanCatalog.searchTitle(season) == "现在就出发")
    #expect(DoubanCatalog.match(season, in: [try result(.tv, 230000, "现在就出发", 2023)])?.id == 230000)
    let yearly = DoubanCatalog.Item(id: "5", title: "我家那闺女2026", year: 2026, rating: nil, cover: nil, mediaType: .tv)
    #expect(DoubanCatalog.match(yearly, in: [try result(.tv, 88000, "我家那闺女", 2019)])?.id == 88000)
    #expect(DoubanCatalog.searchTitle(DoubanCatalog.Item(id: "6", title: "银翼杀手2049", year: 2017, rating: nil, cover: nil, mediaType: .movie)) == "银翼杀手2049")
    #expect(DoubanCatalog.searchTitle(DoubanCatalog.Item(id: "7", title: "第一季", year: nil, rating: nil, cover: nil, mediaType: .tv)) == "第一季")
    // Spelled differently: the first result of that kind and year.
    let spelled = DoubanCatalog.Item(id: "4", title: "FX战士久留美", year: 2026, rating: nil, cover: nil, mediaType: .tv)
    #expect(DoubanCatalog.match(spelled, in: [try result(.movie, 9, "FX战士久留美", 2026), try result(.tv, 10, "FX 战士久留美", 2026)])?.id == 10)
    #expect(DoubanCatalog.match(spelled, in: [try result(.tv, 11, "别的剧", 2019)]) == nil)
}

@Test func doubanCoversAreAskedForWithADoubanReferer() {
    let cover = PosterResource(url: URL(string: "https://img3.doubanio.com/view/photo/m_ratio_poster/public/p1.jpg")!)
    #expect(cover.headers["Referer"] == "https://movie.douban.com/")
    // A source's own Referer is kept, and other hosts get none.
    #expect(PosterResource(url: cover.url, headers: ["referer": "https://example.com/"]).headers == ["referer": "https://example.com/"])
    #expect(PosterResource(url: URL(string: "https://image.tmdb.org/t/p/w342/a.jpg")!).headers.isEmpty)
}

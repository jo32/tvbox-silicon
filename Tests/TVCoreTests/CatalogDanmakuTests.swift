import Foundation
import Testing
@testable import TVCore

@Test func catalogAutomaticDanmakuRequiresOneUnambiguousTitleAndSeason() {
    let original = CatalogDanmakuAnime(id: "1", title: "葬送的芙莉莲", type: "TV")
    let otherSeason = CatalogDanmakuAnime(id: "2", title: "葬送的芙莉莲 第2季", type: "TV")
    #expect(CatalogDanmakuMatcher.anime(title: " 葬送的芙莉莲 ", in: [otherSeason, original])?.id == "1")
    #expect(CatalogDanmakuMatcher.anime(title: "不存在", in: [original]) == nil)
    #expect(CatalogDanmakuMatcher.anime(title: "葬送的芙莉莲", in: [original, CatalogDanmakuAnime(id: "3", title: original.title, type: "Movie")]) == nil)
}

@Test func catalogAutomaticDanmakuUnderstandsEpisodeNumbersWithoutGuessingSpecialsOrQuality() {
    for (name, expected) in [("1",1), ("第01集",1), ("第十二话",12), ("第两百零一集",201), ("EP. 02",2), ("Episode 3 - title",3)] {
        #expect(CatalogDanmakuMatcher.episodeNumber(name) == expected)
    }
    for name in ["1080P", "OVA1", "SP1", "S02E01", "正片", "0", "未知"] {
        #expect(CatalogDanmakuMatcher.episodeNumber(name) == nil)
    }
}

@Test func catalogAutomaticDanmakuMatchesCurrentEpisodeAndKeepsMissingTracksEmpty() {
    let episodes = [CatalogDanmakuEpisode(id: "1", title: "第1话 冒险结束"), CatalogDanmakuEpisode(id: "2", title: "第2话")]
    #expect(CatalogDanmakuMatcher.episode(name: "第 2 集", in: episodes)?.id == "2")
    #expect(CatalogDanmakuMatcher.episode(name: "3", in: episodes) == nil)
    #expect(CatalogDanmakuMatcher.episode(name: "正片", in: episodes) == nil)
    #expect(CatalogDanmakuMatcher.episode(name: "正片", in: [episodes[0]])?.id == "1")
    #expect(CatalogDanmakuMatcher.episode(name: "1", in: [episodes[0], CatalogDanmakuEpisode(id: "3", title: "第1话 其他版本")]) == nil)
}

@Test func catalogDanmakuRejectsMalformedRowsAndDoesNotConfuseColorWithFontSize() throws {
    let data = Data(#"""
    {"comments":[
      {"p":"2.52,5,16711680,user","m":"红色顶部"},
      {"p":"1.0,1,65280,user","m":"绿色滚动"},
      {"p":"1.0,1,65280,user","m":"绿色滚动"},
      {"p":"-1,1,0,user","m":"invalid"},
      {"p":"nan,1,0,user","m":"invalid"},
      {"p":"3,7,0,user","m":"unsupported advanced animation"},
      {"p":"3,4,255,user","m":"   "},
      {"p":"4,4,255,user","m":"蓝色底部"}]}
    """#.utf8)
    let comments = try CatalogDanmakuParser.parse(data)
    #expect(comments.count == 3)
    #expect(comments.map(\.time) == [1, 2.52, 4])
    #expect(comments.map(\.color) == [0x00ff00, 0xff0000, 0x0000ff])
    #expect(comments.map(\.mode) == [.scroll, .top, .bottom])
    #expect(throws: (any Error).self) { try CatalogDanmakuParser.parse(Data("<html>error</html>".utf8)) }
    #expect(throws: (any Error).self) { try CatalogDanmakuParser.parse(Data(repeating: 0, count: CatalogDanmakuParser.maximumBytes + 1)) }
}

/// A list longer than the limit keeps comments to the end of the episode, thinning only the busy stretches (#1061).
@Test func catalogDanmakuOverTheLimitStillReachesTheEnd() throws {
    // 40,000 comments over 40 minutes in posting order, then 10 in a quiet stretch at the end.
    let busy = (0..<40_000).map { (time: Double($0) * 0.06, text: "c\($0)") }
    let quiet = (0..<10).map { (time: 3_000 + Double($0) * 4.5, text: "q\($0)") }
    let rows = busy + quiet
    let json = Data(("{\"comments\":[" + rows.map { "{\"p\":\"\($0.time),1,16777215,u\",\"m\":\"\($0.text)\"}" }.joined(separator: ",") + "]}").utf8)
    let xml = Data(("<i>" + rows.map { "<d p=\"\($0.time),1,25,16777215\">\($0.text)</d>" }.joined() + "</i>").utf8)
    for data in [json, xml] {
        let comments = try CatalogDanmakuParser.parse(data)
        #expect(comments.count <= CatalogDanmakuParser.maximumComments)
        #expect(comments.count > CatalogDanmakuParser.maximumComments - 500)
        #expect(comments.map(\.time) == comments.map(\.time).sorted())
        // Every 5-second stretch of the busy part still has comments, up to its last minute.
        let stretches = Set(comments.filter { $0.time < 2_400 }.map { Int($0.time / 5) })
        #expect(stretches.count == 480)
        // The quiet stretch keeps all of its comments.
        #expect(comments.filter { $0.text.hasPrefix("q") }.count == 10)
    }
}

@Test func catalogDanmakuAcceptsSelfHostedPrefixWithoutDuplicatingAPIVersion() throws {
    let client = try CatalogDanmakuClient(address: "https://example.com/private-prefix/api/v2/")
    #expect(client.server.absoluteString == "https://example.com/private-prefix")
    #expect(throws: (any Error).self) { try CatalogDanmakuClient(address: "https://example.com/?token=example") }
    #expect(throws: (any Error).self) { try CatalogDanmakuClient(address: "https://name:password@example.com") }
}

@Test func catalogBilibiliXMLKeepsColorAndEscapedTextAndRejectsEntityDefinitions() throws {
    let data = Data(#"<?xml version="1.0"?><i><d p="2.5,1,25,16711680,0,0,user,1">A &amp; B</d><d p="4,4,25,255,0,0,u,2">底部</d></i>"#.utf8)
    let comments = try CatalogDanmakuParser.parse(data)
    #expect(comments.count == 2)
    #expect(comments.first?.color == 0xff0000)
    #expect(comments.first?.text == "A & B")
    #expect(comments.last?.mode == .bottom)
    #expect(throws: (any Error).self) { try CatalogDanmakuParser.parse(Data("<!DOCTYPE i [<!ENTITY x 'text'>]><i/>".utf8)) }
    #expect(throws: (any Error).self) { try CatalogDanmakuParser.parse(Data("<i><d>broken".utf8)) }
}

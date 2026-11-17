import Testing
@testable import TVCore

@Suite struct SeasonTitlesTests {
    @Test func parsesSeasons() {
        #expect(SeasonTitles.parse("聚宝仙盆之杂灵根才是真BOSS第十六季") == ("聚宝仙盆之杂灵根才是真BOSS", 16))
        #expect(SeasonTitles.parse("庆余年 第二季") == ("庆余年", 2))
        #expect(SeasonTitles.parse("庆余年第2季") == ("庆余年", 2))
        #expect(SeasonTitles.parse("永夜苟神：十万住户供我发育第四季") == ("永夜苟神：十万住户供我发育", 4))
        #expect(SeasonTitles.parse("嗜血法医：杀魔复生 第一季") == ("嗜血法医：杀魔复生", 1))
        #expect(SeasonTitles.parse("Wednesday Season 2") == ("Wednesday", 2))
        #expect(SeasonTitles.parse("The Bear S3") == ("The Bear", 3))
        #expect(SeasonTitles.parse("现在就出发（第二十三季）") == ("现在就出发", 23))
        #expect(SeasonTitles.parse("仙逆 [4K]") == ("仙逆", nil))
        #expect(SeasonTitles.parse("Mission S") == ("Mission S", nil))
    }

    @Test func chineseNumbers() {
        #expect(SeasonTitles.number(chinese: "十") == 10)
        #expect(SeasonTitles.number(chinese: "十六") == 16)
        #expect(SeasonTitles.number(chinese: "二十") == 20)
        #expect(SeasonTitles.number(chinese: "九十九") == 99)
        #expect(SeasonTitles.number(chinese: "两") == 2)
        #expect(SeasonTitles.number(chinese: "十十") == nil)
        for value in 1...99 { #expect(SeasonTitles.number(chinese: SeasonTitles.chinese(value)!) == value) }
    }

    @Test func renamesInTheSameStyle() {
        #expect(SeasonTitles.renamed("聚宝仙盆之杂灵根才是真BOSS第十六季", season: 17) == "聚宝仙盆之杂灵根才是真BOSS第十七季")
        #expect(SeasonTitles.renamed("庆余年 第2季", season: 3) == "庆余年 第3季")
        #expect(SeasonTitles.renamed("The Bear S3", season: 4) == "The Bear S4")
        #expect(SeasonTitles.renamed("Wednesday Season 2", season: 3) == "Wednesday Season 3")
        #expect(SeasonTitles.renamed("仙逆", season: 2) == nil)
    }

    @Test func findsTheOtherSeasonsInOrder() {
        let current = Video(id: "16", name: "聚宝仙盆第十六季")
        let results = [
            Video(id: "1", name: "聚宝仙盆"),
            Video(id: "x", name: "聚宝仙盆番外"),
            Video(id: "2", name: "聚宝仙盆 第二季"),
            Video(id: "2b", name: "聚宝仙盆第2季"),
            Video(id: "16", name: "聚宝仙盆第十六季"),
            Video(id: "3", name: "【短剧】聚宝仙盆 第三季"),
        ]
        let found = SeasonTitles.seasons(of: current, among: results)
        #expect(found.map(\.season) == [1, 2, 3, 16])
        #expect(found.map(\.video.id) == ["1", "2", "3", "16"])
    }

    @Test func aTitleWithoutASeasonIsTheFirst() {
        let current = Video(id: "a", name: "庆余年")
        let found = SeasonTitles.seasons(of: current, among: [Video(id: "b", name: "庆余年"), Video(id: "c", name: "庆余年第二季")])
        #expect(found.map(\.video.id) == ["a", "c"])
        #expect(SeasonTitles.seasons(of: current, among: []).map(\.season) == [1])
    }
}

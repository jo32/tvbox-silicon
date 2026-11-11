import Testing
@testable import TVCore

@Test func aTitleThatHoldsTheKeywordMatches() {
    #expect(TitleMatch.matches(title: "机动搜查队404", keyword: "机动搜查队"))
    #expect(TitleMatch.matches(title: "Mission: Impossible - Fallout", keyword: "mission impossible"))
    #expect(TitleMatch.matches(title: "ＡＢＣ　剧", keyword: "abc剧"))
}

@Test func traditionalAndSimplifiedAreTheSame() {
    #expect(TitleMatch.matches(title: "機動搜查隊404", keyword: "机动搜查队"))
    #expect(TitleMatch.matches(title: "机动搜查队", keyword: "機動搜查隊"))
}

@Test func aSeasonOnTheKeywordIsOptional() {
    #expect(TitleMatch.matches(title: "庆余年", keyword: "庆余年第二季"))
    #expect(TitleMatch.matches(title: "Severance", keyword: "Severance S2"))
    #expect(!TitleMatch.matches(title: "完全不同", keyword: "庆余年第二季"))
}

@Test func longKeywordsMayHaveLettersBetween() {
    #expect(TitleMatch.matches(title: "机动 搜查 特别 队", keyword: "机动搜查队"))
    // Two characters must be next to each other: the loose rule is for three or more.
    #expect(!TitleMatch.matches(title: "仁者医心", keyword: "仁医"))
    #expect(TitleMatch.matches(title: "仁医", keyword: "仁医"))
}

@Test func unrelatedTitlesDoNotMatch() {
    #expect(!TitleMatch.matches(title: "后会友期", keyword: "后会无期"))
    #expect(!TitleMatch.matches(title: "Spider-Man", keyword: "batman"))
}

@Test func anEmptyKeywordMatchesEverything() {
    #expect(TitleMatch.matches(title: "anything", keyword: "  "))
    #expect(TitleMatch.ordered(["b", "a"], keyword: "", title: { $0 }) == ["b", "a"])
}

@Test func matchesComeFirstInTheirOwnOrder() {
    let titles = ["别的剧", "仁医 第二季", "无关", "仁医"]
    #expect(TitleMatch.ordered(titles, keyword: "仁医", title: { $0 }) == ["仁医 第二季", "仁医", "别的剧", "无关"])
    // The search page shows the matching ones and keeps the rest behind a button (#770).
    let parts = TitleMatch.split(titles, keyword: "仁医", title: { $0 })
    #expect(parts.matching == ["仁医 第二季", "仁医"] && parts.other == ["别的剧", "无关"])
    // A search by an actor's name matches no title: nothing to lead with, so the page shows them all.
    #expect(TitleMatch.split(titles, keyword: "大泽隆夫", title: { $0 }).matching.isEmpty)
    #expect(TitleMatch.split(titles, keyword: " ", title: { $0 }).other.isEmpty)
}

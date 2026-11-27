import Testing
@testable import TVCore

private func site(_ key: String) -> Site { Site(key: key, name: key, type: 3, api: "csp_\(key)", raw: [:]) }
private func video(_ name: String, year: String? = nil, id: String? = nil) -> Video { Video(id: id ?? name, name: name, year: year) }

@Test func sourceTitleMatchKeepsOnlyTheWork() {
    let wanted = SourceTitleMatch.Wanted(names: ["绝命毒师", "Breaking Bad"], year: 2008)
    let videos = [video("絕命毒師"), video("绝命毒师 第二季"), video("绝命毒师电影版"), video("BREAKING BAD 【4K】"),
                  video("毒师"), Video(id: "f", name: "绝命毒师", category: "folder"), Video(id: "a", name: "绝命毒师", action: "LoginShow")]
    let found = SourceTitleMatch.candidates(videos, site: site("s"), wanted: wanted)
    #expect(found.map(\.video.name) == ["絕命毒師", "绝命毒师 第二季", "BREAKING BAD 【4K】"])
    #expect(found.map(\.laterSeason) == [nil, 2, nil])
}

@Test func sourceTitleMatchWidensToTMDBsOtherNames() {
    // TMDB lists the work as 龙珠超; the sources list it as 七龙珠超 (#2608).
    let wanted = SourceTitleMatch.Wanted(names: ["龙珠超", "Dragon Ball Super"], year: 2015)
    let videos = [video("七龙珠超", year: "2015")]
    #expect(SourceTitleMatch.candidates(videos, site: site("s"), wanted: wanted).isEmpty)
    let widened = wanted.widened(with: ["七龙珠超"])
    #expect(widened != nil)
    #expect(SourceTitleMatch.candidates(videos, site: site("s"), wanted: widened!).map(\.video.name) == ["七龙珠超"])
    #expect(wanted.widened(with: ["龙珠超"]) == nil)
}

@Test func sourceTitleMatchTreatsAFirstSeasonAsTheWork() {
    let wanted = SourceTitleMatch.Wanted(names: ["庆余年"], year: 2019)
    let found = SourceTitleMatch.candidates([video("庆余年 第一季", year: "2019")], site: site("s"), wanted: wanted)
    #expect(found.first?.laterSeason == nil)
    #expect(found.first?.decisive == true)
}

@Test func sourceTitleMatchReadsTheYear() {
    #expect(SourceTitleMatch.fit("2008", 2008) == .same)
    #expect(SourceTitleMatch.fit("2009-01-20", 2008) == .same)
    #expect(SourceTitleMatch.fit("2012年", 2008) == .other)
    #expect(SourceTitleMatch.fit("", 2008) == .unknown)
    #expect(SourceTitleMatch.fit("未知", 2008) == .unknown)
    #expect(SourceTitleMatch.fit("2008", nil) == .unknown)
}

@Test func sourceTitleMatchRanksYearThenSourceOrder() {
    let wanted = SourceTitleMatch.Wanted(names: ["流浪地球"], year: 2019)
    let first = site("first"), second = site("second"), third = site("third"), unlisted = site("unlisted")
    let all = SourceTitleMatch.candidates([video("流浪地球", year: "1999")], site: first, wanted: wanted)
        + SourceTitleMatch.candidates([video("流浪地球")], site: second, wanted: wanted)
        + SourceTitleMatch.candidates([video("流浪地球 第二部", year: "2023"), video("流浪地球", year: "2019", id: "x")], site: third, wanted: wanted)
        + SourceTitleMatch.candidates([video("流浪地球", year: "2019")], site: unlisted, wanted: wanted)
    let ranked = SourceTitleMatch.ranked(all, sourceOrder: ["first": 0, "second": 1, "third": 2])
    // The right year first (the listed source before the unlisted one), then no year, then another year, then the
    // later season.
    #expect(ranked.map(\.site.key) == ["third", "unlisted", "second", "first", "third"])
    #expect(ranked.first?.video.id == "x")
    #expect(ranked.last?.laterSeason == 2)
}

@Test func sourceTitleMatchWithoutAYearKeepsTheSourceOrder() {
    let wanted = SourceTitleMatch.Wanted(names: ["Severance"], year: nil)
    let all = SourceTitleMatch.candidates([video("Severance")], site: site("b"), wanted: wanted)
        + SourceTitleMatch.candidates([video("severance")], site: site("a"), wanted: wanted)
    let ranked = SourceTitleMatch.ranked(all, sourceOrder: ["a": 0, "b": 1])
    #expect(ranked.map(\.site.key) == ["a", "b"])
    #expect(ranked.allSatisfy { !$0.decisive })
}

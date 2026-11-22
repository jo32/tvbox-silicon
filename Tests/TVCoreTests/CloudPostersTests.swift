import Foundation
import Testing
@testable import TVCore

@Suite struct CloudPostersTests {
    private func results(_ items: [(String, String, String?, Int?, Int)]) -> [TMDBMatch.SearchResult] {
        let json = items.map { type, name, original, year, id in
            """
            {"mediaType":"\(type)","id":\(id),"name":"\(name)","originalName":\(original.map { "\"\($0)\"" } ?? "null"),\
            "year":\(year.map(String.init) ?? "null"),"poster":"https://images.tmdb.org/t/p/w342/\(id).jpg","sources":0}
            """
        }
        return try! JSONDecoder().decode([TMDBMatch.SearchResult].self, from: Data("[\(json.joined(separator: ","))]".utf8))
    }

    @Test func picksTheTitleInAYearThatFits() {
        let found = results([("movie", "小城良方外传", nil, 2026, 1), ("tv", "小城良方", "小城良方", 2026, 2)])
        #expect(CloudPosters.best(found, for: MediaName("小城良方（2026）", isFile: false))?.id == 2)
        // Another year is another work.
        #expect(CloudPosters.best(results([("movie", "Dune", "Dune", 1984, 3)]), for: MediaName("Dune.2021.2160p", isFile: false)) == nil)
        #expect(CloudPosters.best(results([("movie", "Dune", "Dune", 1984, 3), ("movie", "沙丘", "Dune", 2021, 4)]),
                                  for: MediaName("Dune.2021.2160p", isFile: false))?.id == 4)
    }

    @Test func seriesPreferShowsAndTraditionalMatchesSimplified() {
        let found = results([("movie", "三体", "三体", 2024, 5), ("tv", "三体", "三体", 2023, 6)])
        #expect(CloudPosters.best(found, for: MediaName("三體 S01", isFile: false))?.id == 6)
        #expect(CloudPosters.best(found, for: MediaName("三体", isFile: false))?.id == 5)
    }

    @Test func aNameThatIsOnlyAPrefixNeedsItsYear() {
        let found = results([("tv", "庆余年 第二季花絮", nil, 2024, 7)])
        #expect(CloudPosters.best(found, for: MediaName("庆余年", isFile: false)) == nil)
        #expect(CloudPosters.best(found, for: MediaName("庆余年 2024", isFile: false))?.id == 7)
    }

    @Test func aLatinNameTakesTheFirstResultWhenTheYearAgrees() {
        let found = results([("tv", "葬送的芙莉莲", "葬送のフリーレン", 2023, 8), ("movie", "Other", nil, 2020, 9)])
        #expect(CloudPosters.best(found, for: MediaName("Sousou no Frieren (2023)", isFile: false))?.id == 8)
        #expect(CloudPosters.best(found, for: MediaName("Sousou no Frieren", isFile: false)) == nil)
        // A Chinese name never falls back on a result that isn't it.
        #expect(CloudPosters.best(results([("tv", "别的", nil, 2023, 10)]), for: MediaName("葬送 (2023)", isFile: false)) == nil)
    }

    @Test func asksOncePerNameAndKeepsTheAnswer() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let calls = Counter()
        let found = results([("tv", "小城良方", nil, 2026, 2)])
        let posters = CloudPosters(cacheURL: folder.appending(path: "posters.json"), spacing: .milliseconds(1)) { _ in
            await calls.add(); try await Task.sleep(for: .milliseconds(50)); return found
        }
        let name = MediaName("小城良方（2026）", isFile: false)
        async let first = posters.work(for: name)
        async let second = posters.work(for: name)
        let (a, b) = await (first, second)
        #expect(a?.id == 2 && b?.id == 2)
        #expect(await posters.work(for: name)?.id == 2)
        #expect(await calls.value == 1)
        // Nothing found is kept too, so the wall doesn't ask again on every visit.
        let missing = MediaName("没有这部片", isFile: false)
        #expect(await posters.work(for: missing) == nil)
        if case .some(.none) = await posters.kept(missing) {} else { Issue.record("nothing found isn't kept") }
        // Category and season folders never ask.
        #expect(await posters.work(for: MediaName("电影", isFile: false)) == nil)
        #expect(await posters.work(for: MediaName("Season 1", isFile: false)) == nil)
        #expect(await calls.value == 2)
    }

    @Test func aCardThatLeavesGivesUpItsTurnAndFailuresAreNotKept() async {
        let calls = Counter()
        let posters = CloudPosters(cacheURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json"),
                                   spacing: .seconds(30)) { _ in await calls.add(); throw URLError(.notConnectedToInternet) }
        // The first search starts at once and fails: nothing is kept for it.
        #expect(await posters.work(for: MediaName("三体", isFile: false)) == nil)
        #expect(await posters.kept(MediaName("三体", isFile: false)) == nil)
        // The next waits its turn; cancelled meanwhile, it never asks.
        let waiting = Task { await posters.work(for: MediaName("繁花", isFile: false)) }
        try? await Task.sleep(for: .milliseconds(50))
        waiting.cancel()
        #expect(await waiting.value == nil)
        #expect(await calls.value == 1)
    }
}

private actor Counter {
    private(set) var value = 0
    func add() { value += 1 }
}

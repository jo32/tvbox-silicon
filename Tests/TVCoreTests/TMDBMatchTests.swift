import Foundation
import Testing
@testable import TVCore

struct TMDBMatchTests {
    @Test func episodeNumbersFromSourceNames() {
        #expect(TMDBMatch.episodeNumber("第05集") == 5)
        #expect(TMDBMatch.episodeNumber("EP12") == 12)
        #expect(TMDBMatch.episodeNumber("[1.18GB] S01E41.mkv") == 41)
        #expect(TMDBMatch.episodeNumber("07") == 7)
        #expect(TMDBMatch.episodeNumber("1080P") == nil)
        #expect(TMDBMatch.episodeNumber("HD中字") == nil)
        #expect(TMDBMatch.episodeNumber("20251220主题纯享") == nil)
        #expect(TMDBMatch.episodeNumber("第20251220期") == nil)
        #expect(TMDBMatch.episodeNumber("2024 第3集") == 3)
        #expect(TMDBMatch.episodeNumber("4K 第2集") == 2)
    }

    private func details(season: Int, episodes: Int, seasons: [(Int, Int)]) throws -> TMDBMatch.Details {
        let list = (1...episodes).map { #"{"number":\#($0),"name":"E\#($0)","overview":"","still":null,"airDate":null,"runtime":45,"rating":null}"# }
        let summaries = seasons.map { #"{"number":\#($0.0),"name":"S\#($0.0)","episodeCount":\#($0.1),"year":null,"poster":null}"# }
        let json = #"""
        {"mediaType":"tv","id":1,"name":"X","originalName":"X","tagline":"","overview":"","year":2020,"date":"2020-01-01","genres":[],
         "runtime":45,"rating":null,"voteCount":0,"countries":[],"status":null,"poster":null,"backdrop":null,"logo":null,"cast":[],"crew":[],
         "networks":[],"seasons":[\#(summaries.joined(separator: ","))],
         "season":{"number":\#(season),"name":"S","overview":"","poster":null,"year":null,"episodes":[\#(list.joined(separator: ","))]},
         "link":"https://www.themoviedb.org/tv/1"}
        """#
        return try JSONDecoder().decode(TMDBMatch.Details.self, from: Data(json.utf8))
    }

    @Test func episodesLineUpByNumberOrPosition() throws {
        let value = try details(season: 2, episodes: 10, seasons: [(1, 12), (2, 10)])
        // Numbered names, with a trailer that has none.
        #expect(value.episodes(for: ["第01集", "第02集", "预告", "第03集"], numbering: .season).map { $0?.number } == [1, 2, nil, 3])
        // No numbers: by position.
        #expect(value.episodes(for: ["HD中字", "HD国语"], numbering: .season).map { $0?.number } == [1, 2])
        // Counting on from season 1 (12 episodes): 第13集 is season 2's first.
        #expect(value.episodes(for: ["第13集", "第14集"], numbering: .absolute).map { $0?.number } == [1, 2])
        // Numbers past the season that fit once season 1 is taken off.
        #expect(value.episodes(for: ["第13集", "第22集"], numbering: .season).map { $0?.number } == [1, 10])
        // TMDB's season holds two of the source's: 第01集 is its 6th episode. 第08集 doesn't fit after the offset (13 > 10),
        // so it is TMDB's own number.
        #expect(value.episodes(for: ["第01集", "第05集", "第08集"], numbering: .season, offset: 5).map { $0?.number } == [6, 10, 8])
    }

    @Test func storeKeepsChoicesAndExpiresAnswers() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = TMDBMatchStore(cacheURL: folder.appending(path: "c.json"), choicesURL: folder.appending(path: "p.json"))
        let answer = TMDBMatch.Answer(status: .notFound, match: nil, season: nil, numbering: .season, unmatched: "", candidates: [], details: nil)
        let now = Date()
        await store.save(answer, for: "a|1", now: now)
        #expect(await store.answer(for: "a|1", now: now.addingTimeInterval(3600)) == answer)
        #expect(await store.answer(for: "a|1", now: now.addingTimeInterval(2 * 86400)) == nil)
        // Newer details for a match replace the old ones but keep when the match was saved.
        let matched = TMDBMatch.Answer(status: .matched, match: nil, season: 2, numbering: .season, unmatched: "", candidates: [],
                                       details: try details(season: 2, episodes: 8, seasons: [(2, 10)]))
        await store.save(matched, for: "b|1", now: now)
        let updated = await store.update(try details(season: 2, episodes: 9, seasons: [(2, 10)]), for: "b|1")
        #expect(updated?.details?.season?.episodes.count == 9)
        #expect(await store.answer(for: "b|1", now: now.addingTimeInterval(3600))?.details?.season?.episodes.count == 9)
        #expect(await store.answer(for: "b|1", now: now.addingTimeInterval(8 * 86400)) == nil)
        #expect(await store.update(try details(season: 2, episodes: 9, seasons: [(2, 10)]), for: "a|1") == nil)
        await store.choose(.work(.tv, 7, season: 2), for: "a|1")
        let reopened = TMDBMatchStore(cacheURL: folder.appending(path: "c.json"), choicesURL: folder.appending(path: "p.json"))
        #expect(await reopened.choice(for: "a|1") == .work(.tv, 7, season: 2))
    }

    @Test func labeledAIAndShortDramasAreSkipped() {
        func request(_ title: String, remarks: String = "", category: String?) -> TMDBMatch.Request {
            var value = TMDBMatch.Request(video: Video(id: "1", name: title, remarks: remarks, category: category))
            value.category = category
            return value
        }
        #expect(TMDBMatch.labeledNotOnTMDB(request("x", category: "漫剧")))
        #expect(TMDBMatch.labeledNotOnTMDB(request("x", category: "爽文短剧")))
        #expect(TMDBMatch.labeledNotOnTMDB(request("x", category: "动作片,AI")))
        #expect(TMDBMatch.labeledNotOnTMDB(request("x", category: "AI短剧")))
        #expect(TMDBMatch.labeledNotOnTMDB(request("异变", remarks: "AI生成", category: "动作片")))
        #expect(!TMDBMatch.labeledNotOnTMDB(request("AI创世者", category: "科幻片")))
        #expect(!TMDBMatch.labeledNotOnTMDB(request("异变：辐射", remarks: "更新HD", category: "动作片")))
        #expect(!TMDBMatch.labeledNotOnTMDB(request("x", category: "Mountain,Drama")))
    }

    @Test func musicAndBuiltInSourcesAreSkipped() {
        #expect(TMDBMatch.skipsSource(key: "builtin.bilibili", api: ""))
        #expect(TMDBMatch.skipsSource(key: "MTV1", api: "csp_MusicGuard"))
        #expect(TMDBMatch.skipsSource(key: "q", api: "https://x/music.js"))
        #expect(!TMDBMatch.skipsSource(key: "Bili", api: "csp_BiliGuard"))
        #expect(!TMDBMatch.skipsSource(key: "光影", api: "csp_T4Guard"))
    }

    @Test func progressLinesDecode() throws {
        let decode = { (line: String) in try JSONDecoder().decode(TMDBMatch.Event.self, from: Data(line.utf8)).step }
        #expect(try decode(#"{"type":"progress","step":"search","query":"庆余年"}"#) == .searching("庆余年"))
        #expect(try decode(#"{"type":"progress","step":"details","name":"庆余年","year":2019}"#) == .checking("庆余年", 2019))
        #expect(try decode(#"{"type":"progress","step":"novel"}"#) == nil)
    }
}

import Foundation
import Testing
@testable import TVCore

private let origin = URL(string: "https://sub.example/")!

private func site(_ name: String, _ api: String) -> Site { Site(key: api + name, name: name, type: 3, api: api, raw: [:]) }

private func book(chapters: Int, lines: [String] = ["线路1"]) -> Video {
    let episodes = lines.enumerated().flatMap { line, flag in
        (0..<chapters).map { Episode(id: "\(line)-\($0)", name: "第\($0 + 1)集", address: "https://media.example/\(flag)/\($0).mp3", flag: flag, videoID: "b1") }
    }
    return Video(id: "b1", name: "三体", poster: URL(string: "https://img.example/b1.jpg"), episodes: episodes)
}

// The reporter's subscription (#289): listening sources by name; video ones beside them stay video.
@Test func audioSourcesAreRecognizedByName() {
    for (name, api) in [("🎃‍小红┃听书🎃", "csp_BookHongGuoGuard"), ("🎼蜻蜓┃电台🎼", "csp_MusicAiQingTingGuard"),
                        ("🎼易听┃音乐🎼", "csp_MusicAi163Guard"),
                        ("🎼轮回┃舞曲🎼", "csp_MusicAiLunHuiGuard"), ("喜马拉雅", "csp_XiMaLaYa"), ("懒人", "csp_LanRenTingShu")] {
        #expect(AudioSources.isCandidate(site(name, api)), "\(name)")
    }
    for (name, api) in [("💃跳舞┃教学💃", "csp_MusicAiTangDouGuard"), ("🎎戏曲┃秒播🎎", "csp_MusicAiLiYuanGuard"),
                        ("🎼KTV┃音乐🎼", "csp_MusicAiIKtvGuard"), ("🅱‍哔哩┃歌曲🅱‍", "csp_BiliGuard"),
                        ("💓玩偶┃4K💓", "csp_AiNewWoggGuard"), ("🍉短剧┃好看🍉", "csp_DuanJuAiHaoKanGuard"),
                        // Its children's songs are cartoon videos.
                        ("👼宝宝┃儿歌👼", "csp_ChildrenAiBaoBaoGuard")] {
        #expect(!AudioSources.isCandidate(site(name, api)), "\(name)")
    }
}

@Test func aBookQueuesItsLineFromTheChosenChapter() throws {
    let video = book(chapters: 5, lines: ["线路1", "线路2"])
    let chosen = video.episodes.first { $0.flag == "线路2" && $0.name == "第3集" }!
    let queue = AudioSources.queue(video: video, from: chosen, site: site("听书", "csp_Book"), origin: origin)
    #expect(queue.tracks.map(\.title) == ["第1集", "第2集", "第3集", "第4集", "第5集"])
    #expect(queue.index == 2)
    let current = try #require(queue.current)
    #expect(current.artists == ["三体"])
    #expect(current.artwork == video.poster)
    #expect(current.source?.episode == chosen)
    #expect(current.source?.context.episodeFlag == "线路2")
    // Every chapter saves under the one book, as a series' episodes do.
    #expect(Set(queue.tracks.compactMap { $0.source?.context.id }).count == 1)
    #expect(Set(queue.tracks.map(\.id)).count == 5)
}

@Test func aLongBookQueuesAWindowAroundTheChapter() {
    let video = book(chapters: 1000)
    let queue = AudioSources.queue(video: video, from: video.episodes[500], site: site("听书", "csp_Book"), origin: origin)
    #expect(queue.tracks.count == AudioSources.queueLimit)
    #expect(queue.current?.title == "第501集")
    #expect(queue.hasPrevious)
    let end = AudioSources.queue(video: video, from: video.episodes[998], site: site("听书", "csp_Book"), origin: origin)
    #expect(end.tracks.count == AudioSources.queueLimit)
    #expect(end.tracks.last?.title == "第1000集")
    #expect(end.current?.title == "第999集")
    let start = AudioSources.queue(video: video, from: video.episodes[0], site: site("听书", "csp_Book"), origin: origin)
    #expect(start.index == 0)
    #expect(start.tracks.count == AudioSources.queueLimit)
}

// Continue Playing keeps a book's queue; songs saved before #289 still load.
@Test func sourceTracksSurviveTheResumePoint() throws {
    let video = book(chapters: 3)
    let queue = AudioSources.queue(video: video, from: video.episodes[1], site: site("听书", "csp_Book"), origin: origin)
    let saved = try JSONEncoder().encode(MusicResumePoint(queue: queue, position: 42))
    let loaded = try JSONDecoder().decode(MusicResumePoint.self, from: saved)
    #expect(loaded.queue == queue)
    #expect(loaded.queue.current?.source?.address == "https://media.example/线路1/1.mp3")

    let song = MusicTrack(platform: .qq, songID: "1", title: "晴天", artists: ["周杰伦"])
    var old = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(song)) as? [String: Any])
    old["source"] = nil
    let decoded = try JSONDecoder().decode(MusicTrack.self, from: JSONSerialization.data(withJSONObject: old))
    #expect(decoded == song)
    #expect(decoded.source == nil)
}

@Test func aSourceWithPicturesIsRemembered() throws {
    let defaults = try #require(UserDefaults(suiteName: "AudioSourcesTests-\(UUID().uuidString)"))
    let verdicts = AudioSourceVerdicts(defaults: defaults)
    let video = book(chapters: 2)
    let songs = PlaybackHistoryContext(origin: origin, site: site("儿歌", "csp_Children"), video: video, episode: video.episodes[0])
    let other = PlaybackHistoryContext(origin: origin, site: site("听书", "csp_Book"), video: video, episode: video.episodes[0])
    #expect(!verdicts.showsVideo(songs))
    verdicts.recordVideo(songs)
    verdicts.recordVideo(songs)
    #expect(verdicts.showsVideo(songs))
    #expect(!verdicts.showsVideo(other))
    #expect(defaults.stringArray(forKey: AudioSourceVerdicts.key)?.count == 1)
}

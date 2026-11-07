import Foundation
import Testing
@testable import TVCore

/// #256: credits and their links, Bilibili's ids, subtitles and skip segments.
@Suite struct BilibiliAPITests {
    private let origin = URL(string: "https://example.invalid/")!

    @Test func creditLinksOpenTheirCategory() throws {
        let json: [String: JSONValue] = [
            "vod_id": .string("BV1"), "vod_name": .string("T"),
            "vod_director": .string(#"[a=cr:{"id":"up_546195","name":"老番茄"}/]老番茄[/a]"#),
            "vod_actor": .string(#"张三 李四,[a=cr:{"id":"王五/{pg}","name":"王五"}/]王五[/a], Tom Hanks / 张三"#),
        ]
        let video = try #require(Video(json: json, origin: origin))
        #expect(video.credits == [
            VideoCredit(name: "老番茄", role: .director, category: "up_546195"),
            VideoCredit(name: "张三", role: .actor), VideoCredit(name: "李四", role: .actor),
            VideoCredit(name: "王五", role: .actor, category: "王五/{pg}"),
            VideoCredit(name: "Tom Hanks", role: .actor),
        ])
        // Kept with the poster, and absent when the source credits no one.
        #expect(video.keepingPoster(URL(string: "https://p.invalid/a.jpg")).credits == video.credits)
        #expect(Video(json: ["vod_id": .string("x")], origin: origin)?.credits == nil)
    }

    @Test func creditsSurviveOldSavedVideos() throws {
        // A video saved before credits existed (history, favourites) still decodes.
        let saved = #"{"id":"a","name":"A","posterHeaders":{},"remarks":"","synopsis":"","episodes":[]}"#
        let video = try JSONDecoder().decode(Video.self, from: Data(saved.utf8))
        #expect(video.credits == nil)
    }

    @Test func spaceCategoriesNameTheirUP() {
        #expect(BilibiliAPI.creator(category: "up_546195") == 546195)
        #expect(BilibiliAPI.creator(category: "up_546195_click") == nil)
        #expect(BilibiliAPI.creator(category: "rank_0") == nil)
        #expect(BilibiliAPI.spaceOwner(category: "up_546195_season_7") == 546195)
        #expect(BilibiliAPI.spaceOwner(category: "up_9") == 9)
        #expect(BilibiliAPI.spaceOwner(category: "up_x") == nil)
        #expect(BilibiliAPI.isVideo("BV1GJ411x7h7"))
        #expect(!BilibiliAPI.isVideo("season_33378"))
    }

    @Test func partsComeFromEpisodeAddresses() {
        #expect(BilibiliAPI.Part(address: "80433022_137649199") == BilibiliAPI.Part(address: "80433022_137649199"))
        let pgc = BilibiliAPI.Part(address: "1_2_3")
        #expect(pgc?.aid == 1 && pgc?.cid == 2 && pgc?.episode == 3)
        #expect(BilibiliAPI.Part(address: "80433022_137649199")?.episode == nil)
        #expect(BilibiliAPI.Part(address: "https://example.invalid/a.mp4") == nil)
        #expect(BilibiliAPI.Part(address: "1_2_x") == nil)
        #expect(BilibiliAPI.Part(address: "0_2") == nil)
    }

    @Test func countsReadAsBilibiliWritesThem() {
        #expect(BilibiliAPI.count(683) == "683")
        #expect(BilibiliAPI.count(10_000) == "1万")
        #expect(BilibiliAPI.count(20_872_039) == "2087.2万")
        #expect(BilibiliAPI.count(130_000_000) == "1.3亿")
    }

    @Test func csrfComesFromTheAccountCookie() {
        #expect(BilibiliAPI.csrf("SESSDATA=a; bili_jct=token; DedeUserID=1") == "token")
        #expect(BilibiliAPI.csrf("SESSDATA=a") == nil)
        #expect(BilibiliAPI.language("ai-zh") == "zh")
        #expect(BilibiliAPI.language("en-US") == "en-US")
    }

    @Test func bilibiliSubtitlesAreRead() throws {
        let bcc = #"{"font_size":0.4,"body":[{"from":1.5,"to":3,"location":2,"content":"你好 <世界> & 朋友"},{"from":0.2,"to":1,"content":"第一句"},{"from":4,"to":5,"content":""}]}"#
        let document = try SubtitleDocument(id: "a", name: "中文（自动生成）", data: Data(bcc.utf8), format: "application/json")
        #expect(document.cues.map(\.text) == ["第一句", "你好 <世界> & 朋友"])
        #expect(document.cues.first?.start == 200_000)
        #expect(document.texts(at: 2_000_000) == ["你好 <世界> & 朋友"])
        // Not every JSON file is BCC.
        #expect(SubtitleFile.bccCues(#"{"a":1}"#) == nil)
        #expect(SubtitleFile.bccCues("1\n00:00:01,000 --> 00:00:02,000\nhi") == nil)
    }

    @Test func skipSegmentsComeFromThePlayResult() {
        let value: JSONValue = .array([
            .object(["start": .number(89), "end": .number(179), "type": .string("intro")]),
            .object(["start": .number(1294), "end": .number(1385), "type": .string("outro")]),
            .object(["start": .number(5), "end": .number(5), "type": .string("intro")]),
            .object(["start": .number(1), "end": .number(2), "type": .string("recap")]),
        ])
        let skips = PlaybackSkip.parse(value)
        #expect(skips == [PlaybackSkip(start: 89, end: 179, kind: .intro), PlaybackSkip(start: 1294, end: 1385, kind: .outro)])
        #expect(PlaybackSkip.current(skips, at: 88) == nil)
        #expect(PlaybackSkip.current(skips, at: 100)?.kind == .intro)
        // Not in its last second, where skipping would only stutter.
        #expect(PlaybackSkip.current(skips, at: 178.5) == nil)
        #expect(PlaybackSkip.current(skips, at: 1300)?.kind == .outro)
        #expect(PlaybackSkip.parse(nil).isEmpty)
    }
}

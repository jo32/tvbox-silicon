import Foundation
import Testing
@testable import TVCore

private let origin = URL(string: "https://cdn.film.example/v/abc/index.m3u8")!

/// `count` ten-second segments named `prefix`0000.ts, from `base`.
private func run(_ base: String, prefix: String, count: Int, seconds: Double = 10, discontinuity: Bool = false, extra: [String] = []) -> [String] {
    var lines = discontinuity ? ["#EXT-X-DISCONTINUITY"] : []
    lines += extra
    for index in 0..<count {
        lines += ["#EXTINF:\(seconds),", "\(base)\(prefix)\(String(format: "%04d", index)).ts"]
    }
    return lines
}

private func playlist(_ parts: [[String]], ended: Bool = true) -> String {
    (["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:10", "#EXT-X-MEDIA-SEQUENCE:0"] + parts.flatMap { $0 } + (ended ? ["#EXT-X-ENDLIST"] : [])).joined(separator: "\n")
}

private let film = "https://cdn.film.example/v/abc/"
private let ad = "https://ads.other.example/a/"

@Test func anAdRunFromAnotherHostAtTheStartGoesAway() throws {
    let text = playlist([run(ad, prefix: "ad", count: 2, discontinuity: false), run(film, prefix: "seg", count: 60, discontinuity: true)])
    let result = try #require(AdSkip.clean(text, origin: origin))
    #expect(result.runs == 1)
    #expect(result.seconds == 20)
    #expect(result.host == "ads.other.example")
    #expect(!result.text.contains("ads.other.example"))
    #expect(result.text.components(separatedBy: "seg").count - 1 == 60)
    // The discontinuity that was before the film's first segment, now first of all, is gone.
    #expect(!result.text.contains("#EXT-X-DISCONTINUITY"))
    #expect(result.text.contains("#EXT-X-ENDLIST"))
}

@Test func anAdRunInTheMiddleGoesAndTheFilmKeepsItsJoin() throws {
    let text = playlist([run(film, prefix: "seg", count: 30), run(ad, prefix: "ad", count: 1, seconds: 15, discontinuity: true),
                         run(film, prefix: "seg", count: 30, discontinuity: true)])
    let result = try #require(AdSkip.clean(text, origin: origin))
    #expect(result.runs == 1 && result.seconds == 15)
    #expect(result.text.components(separatedBy: "#EXT-X-DISCONTINUITY").count - 1 == 1)
    #expect(!result.text.contains("/a/ad"))
}

@Test func anotherFolderOnTheSameHostCounts() throws {
    let text = playlist([run(film, prefix: "seg", count: 40), run("https://cdn.film.example/promo/", prefix: "p", count: 2, discontinuity: true),
                         run(film, prefix: "seg", count: 20, discontinuity: true)])
    #expect(AdSkip.clean(text, origin: origin)?.runs == 1)
}

@Test func relativeAddressesAreJudgedWhereTheyPointTo() throws {
    let text = playlist([run("", prefix: "seg", count: 50), run("../promo/", prefix: "p", count: 2, discontinuity: true), run("", prefix: "seg", count: 20, discontinuity: true)])
    #expect(AdSkip.clean(text, origin: origin)?.runs == 1)
}

@Test func aPlaylistWithoutDiscontinuitiesIsLeftAlone() {
    #expect(AdSkip.clean(playlist([run(film, prefix: "seg", count: 40), run(ad, prefix: "ad", count: 2)]), origin: origin) == nil)
}

@Test func aLivePlaylistIsLeftAlone() {
    let text = playlist([run(ad, prefix: "ad", count: 2), run(film, prefix: "seg", count: 40, discontinuity: true)], ended: false)
    #expect(AdSkip.clean(text, origin: origin) == nil)
}

@Test func aMasterPlaylistIsLeftAlone() {
    #expect(AdSkip.clean("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nlow.m3u8\n#EXT-X-ENDLIST\n", origin: origin) == nil)
}

@Test func aLongForeignRunIsPartOfTheFilm() {
    // Ten minutes from elsewhere is not an ad.
    let text = playlist([run(film, prefix: "seg", count: 100), run(ad, prefix: "ad", count: 70, discontinuity: true), run(film, prefix: "seg", count: 100, discontinuity: true)])
    #expect(AdSkip.clean(text, origin: origin) == nil)
}

@Test func removingTooMuchLeavesTheWholePlaylist() {
    // Short runs, but together a fifth of the video.
    let text = playlist([run(film, prefix: "seg", count: 20), run(ad, prefix: "ad", count: 2, discontinuity: true),
                         run(film, prefix: "seg", count: 20, discontinuity: true), run(ad, prefix: "ad", count: 3, discontinuity: true),
                         run(film, prefix: "seg", count: 20, discontinuity: true)])
    #expect(AdSkip.clean(text, origin: origin) != nil) // 50 s of 260 s: under the share.
    let heavy = playlist([run(film, prefix: "seg", count: 12), run(ad, prefix: "ad", count: 3, discontinuity: true), run(film, prefix: "seg", count: 12, discontinuity: true), run(ad, prefix: "ad", count: 3, discontinuity: true)])
    #expect(AdSkip.clean(heavy, origin: origin) == nil) // 60 s of 300 s is a fifth.
}

@Test func aShortVideoIsLeftAlone() {
    let text = playlist([run(ad, prefix: "ad", count: 1), run(film, prefix: "seg", count: 10, discontinuity: true)])
    #expect(AdSkip.clean(text, origin: origin) == nil)
}

@Test func aRunWithItsOwnKeyIsNotCut() {
    let key = "#EXT-X-KEY:METHOD=AES-128,URI=\"https://ads.other.example/k\""
    let text = playlist([run(film, prefix: "seg", count: 50), run(ad, prefix: "ad", count: 1, discontinuity: true, extra: [key]), run(film, prefix: "seg", count: 20, discontinuity: true)])
    #expect(AdSkip.clean(text, origin: origin) == nil)
}

@Test func hashNamedSegmentsOfOneFolderAreOneFamily() throws {
    func hashed(_ count: Int, _ discontinuity: Bool) -> [String] {
        var lines = discontinuity ? ["#EXT-X-DISCONTINUITY"] : []
        for index in 0..<count { lines += ["#EXTINF:10,", "\(film)\(String(index * 7919 + 1048576, radix: 16)).ts"] }
        return lines
    }
    let text = playlist([hashed(30, false), run(ad, prefix: "ad", count: 1, discontinuity: true), hashed(30, true)])
    #expect(try #require(AdSkip.clean(text, origin: origin)).runs == 1)
}

@Test func theCleanedPlaylistKeepsItsHeaderAndSegmentOrder() throws {
    let text = playlist([run(ad, prefix: "ad", count: 1), run(film, prefix: "seg", count: 30, discontinuity: true)])
    let result = try #require(AdSkip.clean(text, origin: origin))
    let lines = result.text.components(separatedBy: "\n")
    #expect(lines.prefix(4) == ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:10", "#EXT-X-MEDIA-SEQUENCE:0"])
    let segments = lines.filter { $0.hasSuffix(".ts") }
    #expect(segments == segments.sorted() && segments.count == 30)
}

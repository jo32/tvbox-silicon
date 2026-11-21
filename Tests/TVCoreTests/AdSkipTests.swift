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

/// Playlists that are not cut, each for its own reason.
@Test(arguments: [
    ("no discontinuities", playlist([run(film, prefix: "seg", count: 40), run(ad, prefix: "ad", count: 2)])),
    ("live", playlist([run(ad, prefix: "ad", count: 2), run(film, prefix: "seg", count: 40, discontinuity: true)], ended: false)),
    ("master", "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nlow.m3u8\n#EXT-X-ENDLIST\n"),
    // Ten minutes from elsewhere is not an ad.
    ("long foreign run", playlist([run(film, prefix: "seg", count: 100), run(ad, prefix: "ad", count: 70, discontinuity: true),
                                   run(film, prefix: "seg", count: 100, discontinuity: true)])),
    ("short video", playlist([run(ad, prefix: "ad", count: 1), run(film, prefix: "seg", count: 10, discontinuity: true)])),
    ("run with its own key", playlist([run(film, prefix: "seg", count: 50),
                                       run(ad, prefix: "ad", count: 1, discontinuity: true, extra: ["#EXT-X-KEY:METHOD=AES-128,URI=\"https://ads.other.example/k\""]),
                                       run(film, prefix: "seg", count: 20, discontinuity: true)])),
])
func playlistsLeftAlone(_ reason: String, _ text: String) {
    #expect(AdSkip.clean(text, origin: origin) == nil, "\(reason)")
}

/// Another folder on the film's host, and a relative address pointing there, are a run of their own.
@Test(arguments: ["https://cdn.film.example/promo/", "../promo/"])
func anotherFolderIsARunWhereverItIsNamed(_ promo: String) {
    let base = promo.hasPrefix("..") ? "" : film
    let text = playlist([run(base, prefix: "seg", count: 50), run(promo, prefix: "p", count: 2, discontinuity: true), run(base, prefix: "seg", count: 20, discontinuity: true)])
    #expect(AdSkip.clean(text, origin: origin)?.runs == 1)
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

// The shapes of four playlists captured from live sources (#1394): the film from one folder, the same short ad from
// another at the start and at every break, each part after a discontinuity.
private let aes = "#EXT-X-KEY:METHOD=AES-128,URI=\"https://cdn.film.example/v/abc/key.key\",IV=0x00000000000000000000000000000000"
private let plain = "#EXT-X-KEY:METHOD=NONE"
private let intro = "https://cdn.film.example/20261116/df50c5905e2cbc7e/"
private let breakAd = "https://cdn.film.example/20261116/625264b24905f8e9/"

/// A film part of `count` segments that is split by discontinuities of its own every `piece` segments, its key set once.
private func part(_ count: Int, seconds: Double, key: String?, piece: Int = .max) -> [String] {
    var lines: [String] = []
    var left = count
    while left > 0 {
        let size = min(piece, left)
        lines += run(film, prefix: "seg", count: size, seconds: seconds, discontinuity: true, extra: left == count ? (key.map { [$0] } ?? []) : [])
        left -= size
    }
    return lines
}

private func cut(_ text: String) throws -> (result: AdSkip.Result, segments: Int) {
    let result = try #require(AdSkip.clean(text, origin: origin))
    let before = text.components(separatedBy: "\n").filter { !$0.hasPrefix("#") }.count
    let after = result.text.components(separatedBy: "\n").filter { !$0.isEmpty && !$0.hasPrefix("#") }.count
    return (result, before - after)
}

@Test func theSameUnencryptedAdAtEveryBreakOfAnEncryptedFilmGoes() throws {
    // "A": an intro, then six breaks of one ad, each marked METHOD=NONE; the film sets its AES key again after each.
    var parts = [run(intro, prefix: "seg_k8bord_", count: 4, seconds: 3.7575, extra: [plain]), part(154, seconds: 6, key: aes)]
    for count in [195, 153, 161, 194, 161, 160] {
        parts += [run(breakAd, prefix: "seg_t7_", count: 4, seconds: 3.7425, discontinuity: true, extra: [plain]), part(count, seconds: 6, key: aes)]
    }
    let text = playlist(parts)
    let (result, segments) = try cut(text)
    #expect(segments == 28 && result.runs == 7)
    #expect(abs(result.seconds - 104.85) < 0.01)
    #expect(!result.text.contains("/20261116/"))
    // The film's own key is there before every part of it, as it was.
    #expect(result.text.components(separatedBy: aes).count == text.components(separatedBy: aes).count)
    #expect(result.text.components(separatedBy: plain).count - 1 == 1) // the header's, before the first film key
}

@Test func aFilmSplitByItsOwnDiscontinuitiesLosesOnlyItsAds() throws {
    // "X1": 131 discontinuities, most of them inside the film; five ads.
    var parts = [run(intro, prefix: "seg_k8bord_", count: 4, seconds: 3.7575, extra: [plain]), part(250, seconds: 3, key: aes, piece: 10)]
    for count in [256, 212, 255, 249] {
        parts += [run(breakAd, prefix: "seg_t7_", count: 4, seconds: 3.7425, discontinuity: true, extra: [plain]), part(count, seconds: 3, key: aes, piece: 10)]
    }
    let (result, segments) = try cut(playlist(parts))
    #expect(segments == 20 && result.runs == 5)
    #expect(abs(result.seconds - 74.91) < 0.01)
}

@Test func anUnencryptedIntroAndBreakGoFromAPlainFilm() throws {
    // "Y2": one intro and no keys after the header's.
    let y2 = playlist([run("https://cdn.film.example/20261117/5jnnmlLG/870kb/hls/", prefix: "a", count: 9, seconds: 2.8967, extra: [plain]),
                       run(film, prefix: "seg", count: 119, seconds: 2.9866, discontinuity: true)])
    let first = try cut(y2)
    #expect(first.segments == 9 && abs(first.result.seconds - 26.07) < 0.01)
    // "Z2": the same ad at the start and in the middle, METHOD=NONE set again on every part.
    let ad = "https://cdn.film.example/20261009/RCP0FQBQ/9622kb/hls/"
    let z2 = playlist([run(ad, prefix: "a", count: 9, seconds: 2.8622, extra: [plain]), part(2053, seconds: 3, key: plain),
                       run(ad, prefix: "a", count: 9, seconds: 2.8622, discontinuity: true, extra: [plain]), part(913, seconds: 3, key: plain)])
    let second = try cut(z2)
    #expect(second.segments == 18 && second.result.runs == 2)
    #expect(!second.result.text.contains("RCP0FQBQ"))
}

@Test func anAdsKeyStaysWhenTheFilmAfterItReliesOnIt() {
    // The film after the ad doesn't set its key again, so it plays with the ad's: cutting the ad would change it.
    let text = playlist([part(60, seconds: 6, key: aes), run(ad, prefix: "ad", count: 2, discontinuity: true, extra: [plain]), part(60, seconds: 6, key: nil)])
    #expect(AdSkip.clean(text, origin: origin) == nil)
}

@Test func manyDifferentShortRunsAreNotAds() {
    // Five different short runs, each from its own folder, look more like clips of the video than like an ad.
    var parts = [run(film, prefix: "seg", count: 40)]
    for index in 0..<5 {
        parts += [run("https://cdn.film.example/clip\(index)/", prefix: "c", count: 1, discontinuity: true), run(film, prefix: "seg", count: 40, discontinuity: true)]
    }
    #expect(AdSkip.clean(playlist(parts), origin: origin) == nil)
    // The same ad five times is one ad.
    var repeated = [run(film, prefix: "seg", count: 40)]
    for _ in 0..<5 { repeated += [run(ad, prefix: "ad", count: 1, discontinuity: true), run(film, prefix: "seg", count: 40, discontinuity: true)] }
    #expect(AdSkip.clean(playlist(repeated), origin: origin)?.runs == 5)
}

import Foundation
import Testing
@testable import TVCore

/// What a subtitle search knows about the playing video beyond its name (#576 M2): the file's OpenSubtitles hash and
/// the catalog's TMDB match; and the subtitle files beside a video in Cloud Files (#576 M1).
@Suite struct SubtitleHintTests {
    /// 200,000 bytes, zero but for a 1 in the first word and a 2 in the last: the hash is 200000 + 1 + 2.
    private func file() -> Data {
        var data = Data(repeating: 0, count: 200_000)
        data[0] = 1
        data[200_000 - 8] = 2
        return data
    }

    @Test func theHashAddsTheSizeAndTheWordsAtBothEnds() {
        #expect(SubtitleFileHash.hash(size: 131_072, head: Data(count: 65_536), tail: Data(count: 65_536)) == "0000000000020000")
        let data = file()
        #expect(SubtitleFileHash.hash(size: 200_000, head: data.prefix(65_536), tail: data.suffix(65_536)) == String(format: "%016llx", 200_003))
        // The sum wraps around 64 bits.
        let ones = Data(repeating: 0xFF, count: 8)
        #expect(SubtitleFileHash.hash(size: 2, head: ones, tail: ones) == "0000000000000000")
    }

    @Test func theHashIsTheSameFromDiskARemuxSourceAndRangeRequests() async throws {
        let data = file(), expected = String(format: "%016llx", 200_003)
        let local = FileManager.default.temporaryDirectory.appending(path: "hash-\(UUID().uuidString).mkv")
        try data.write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        #expect(await SubtitleFileHash.compute(local) == SubtitleFileHash(hash: expected, size: 200_000))
        #expect(await SubtitleFileHash.read(try Remux.fileSource(local))?.hash == expected)
        let name = "hash-\(UUID().uuidString).mp4"
        let remote = RangeServer.add(name, data)
        #expect(await SubtitleFileHash.compute(remote, session: RangeServer.session)?.hash == expected)
        // Two ranges of 64 KiB, never the whole file.
        #expect(RangeServer.requests(name) == 2)
        // A stream has no file to hash; a server without ranges is left at once.
        #expect(await SubtitleFileHash.compute(URL(string: "https://cloud.test/live.m3u8")!, session: RangeServer.session) == nil)
        #expect(await SubtitleFileHash.compute(URL(string: "https://cloud.test/gone.mp4")!, session: RangeServer.session) == nil)
    }

    @Test func theHintTakesTheTMDBMatch() {
        let hint = SubtitleHint(title: "庆余年", season: 1, episode: 3, languages: ["zh-Hans"])
        let series = TMDBMatch.Match(mediaType: .tv, id: 1_234, season: 2, numbering: .season, offset: 12, confidence: 0.9, unmatched: "")
        let matched = hint.matched(series)
        #expect(matched.tmdbID == 1_234 && matched.season == 2 && matched.episode == 15 && matched.title == "庆余年")
        let absolute = TMDBMatch.Match(mediaType: .tv, id: 7, season: nil, numbering: .absolute, offset: nil, confidence: 1, unmatched: "")
        #expect(hint.matched(absolute).season == 1 && hint.matched(absolute).episode == 3)
        let film = TMDBMatch.Match(mediaType: .movie, id: 99, season: nil, numbering: .season, offset: nil, confidence: 1, unmatched: "")
        #expect(hint.matched(film).tmdbID == 99 && hint.matched(film).episode == nil && hint.matched(film).season == nil)
        let hashed = hint.hashed(SubtitleFileHash(hash: "0123456789abcdef", size: 42))
        #expect(hashed.movieHash == "0123456789abcdef" && hashed.fileSize == 42 && hint.hashed(nil) == hint)
        // Sources get both in the hint they are handed.
        let json = SubtitleScriptProvider.json(hashed.matched(series))
        #expect(json.contains(#""movieHash":"0123456789abcdef""#) && json.contains(#""tmdbID":1234"#))
    }

    @Test func aCloudFilesFolderOffersItsSubtitleFiles() throws {
        let files = [CloudFile(id: "f1", name: "Show.S01E01.mkv", isFolder: false), CloudFile(id: "f2", name: "Show.S01E02.mkv", isFolder: false),
                     CloudFile(id: "s1", name: "Show.S01E01.chs.srt", isFolder: false), CloudFile(id: "s2", name: "Show.S01E02.chs.ass", isFolder: false),
                     CloudFile(id: "s3", name: "Show.S01E02.eng.vtt", isFolder: false), CloudFile(id: "z", name: "Show.S01.subs.zip", isFolder: false),
                     CloudFile(id: "x", name: "Show.S01E02.idx", isFolder: false), CloudFile(id: "v", name: "Show.S01E02.sub", isFolder: false),
                     CloudFile(id: "d", name: "Subs.srt", isFolder: true)]
        let subtitles = CloudFiles.subtitles(files, in: .quark)
        #expect(subtitles.map(\.name) == ["Show.S01E01.chs.srt", "Show.S01E02.chs.ass", "Show.S01E02.eng.vtt", "Show.S01.subs.zip"])
        let address = try #require(URLComponents(url: subtitles[1].url, resolvingAgainstBaseURL: false))
        #expect(CloudFiles.isFile(subtitles[1].url) && address.queryItems?.first { $0.name == "id" }?.value == "s2")
        #expect(address.queryItems?.first { $0.name == "drive" }?.value == "quark")
        // The episode's own come first; the season's archive stays (it names no episode); the other episode's goes.
        #expect(SubtitleMatch.candidates(subtitles, video: "Show.S01E02.mkv").map(\.name) == ["Show.S01E02.chs.ass", "Show.S01E02.eng.vtt", "Show.S01.subs.zip"])
        // The channel that plays a file carries them.
        let channel = CloudFiles.channel(files[1], in: .quark, folder: "0", folderName: "Show", subtitles: subtitles)
        #expect(channel.subtitles == subtitles)
    }
}

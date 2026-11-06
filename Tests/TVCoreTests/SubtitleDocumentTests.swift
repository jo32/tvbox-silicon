import Foundation
import Testing
@testable import TVCore

@Suite struct SubtitleDocumentTests {
    private func document(_ text: String, name: String = "a.srt") throws -> SubtitleDocument {
        try SubtitleDocument(id: name, name: name, data: Data(text.utf8))
    }

    @Test func findsOverlappingAndLongCues() throws {
        let srt = """
        1
        00:00:01,000 --> 00:00:20,000
        <i>Long</i> line & more

        2
        00:00:02,000 --> 00:00:03,000
        Short

        3
        00:00:10,000 --> 00:00:11,000
        Later
        """
        let doc = try document(srt)
        #expect(doc.format == .srt)
        #expect(doc.texts(at: 500_000).isEmpty)
        #expect(doc.texts(at: 2_500_000) == ["Long line & more", "Short"])
        // A seek into the middle of the long cue still finds it, behind a later one.
        #expect(doc.texts(at: 10_500_000) == ["Long line & more", "Later"])
        #expect(doc.texts(at: 15_000_000) == ["Long line & more"])
        #expect(doc.texts(at: 20_000_000).isEmpty)
    }

    @Test func readsAssAsPlainText() throws {
        let ass = """
        [Script Info]
        PlayResX: 1920

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:02.50,Default,,0,0,0,,{\\an8}Top\\Nline
        Dialogue: 0,0:00:03.00,0:00:04.00,Default,,0,0,0,,{\\p1}m 0 0 l 10 10{\\p0}
        """
        let doc = try document(ass, name: "a.ass")
        #expect(doc.format == .ass && doc.format.isStyled)
        #expect(doc.cues.count == 1)
        #expect(doc.texts(at: 2_000_000) == ["Top\nline"])
    }

    @Test func rejectsEmptyAndHugeFiles() {
        #expect(throws: SubtitleLoadError.empty) { try document("no cues here") }
        #expect(throws: SubtitleLoadError.tooLarge) {
            try SubtitleDocument(id: "x", name: "x.srt", data: Data(count: SubtitleFile.largest + 1))
        }
    }

    @Test func encodings() throws {
        let line = "1\n00:00:01,000 --> 00:00:02,000\n"
        // Japanese in Shift-JIS is told from Chinese by its kana.
        let japanese = try #require((line + "こんにちは、世界。元気ですか？").data(using: .shiftJIS))
        #expect(try SubtitleDocument(id: "j", name: "j.srt", data: japanese).cues.first?.text == "こんにちは、世界。元気ですか？")
        let gb = try #require((line + "你好，世界。今天天气很好。").data(using: SubtitleEncoding.gb18030.foundation!))
        #expect(try SubtitleDocument(id: "g", name: "g.srt", data: gb).cues.first?.text == "你好，世界。今天天气很好。")
        let big5 = try #require((line + "你好，世界。").data(using: SubtitleEncoding.big5.foundation!))
        // Read as GB 18030 by guess; the viewer picks Big5 and gets the words.
        let guessed = try SubtitleDocument(id: "b", name: "b.srt", data: big5)
        #expect(try guessed.reading(as: .big5).cues.first?.text == "你好，世界。")
        // UTF-8 forced on bytes that aren't is an error the menu can explain.
        #expect(throws: SubtitleLoadError.undecodable) { try guessed.reading(as: .utf8) }
    }

    @Test func timing() {
        #expect(SubtitleTiming().source(at: 12.5) == 12_500_000)
        // Two seconds later: what the file has at 10 s shows at 12 s.
        #expect(SubtitleTiming(delay: 2).source(at: 12) == 10_000_000)
        #expect(SubtitleTiming(delay: -1.5).source(at: 10) == 11_500_000)
        #expect(SubtitleTiming(delay: 99).delay == 30)
        // A file for the 25 fps cut against a 23.976 video: frame 25 000 is at 1000 s in the file and 1042.708 s here.
        let pal = SubtitleTiming.rates.first { $0.from == "25" && $0.to == "23.976" }!
        let timing = SubtitleTiming(scale: pal.scale)
        #expect(abs(Double(timing.source(at: 25_000.0 * 1001 / 24000)) - 1_000_000_000) < 2)
        #expect(timing.rate == pal)
        // Delay and rate don't mix: the delay is in the video's seconds.
        #expect(abs(Double(SubtitleTiming(delay: 1, scale: pal.scale).source(at: 1 + 25_000.0 * 1001 / 24000)) - 1_000_000_000) < 2)
    }

    @Test func timingIsRememberedPerShow() throws {
        let defaults = try #require(UserDefaults(suiteName: "SubtitleTimingTests"))
        defaults.removePersistentDomain(forName: "SubtitleTimingTests")
        SubtitleTimingStore.save(SubtitleTiming(delay: 1.5), scope: "show", defaults)
        #expect(SubtitleTimingStore.load(scope: "show", defaults).delay == 1.5)
        #expect(SubtitleTimingStore.load(scope: "other", defaults).isIdentity)
        SubtitleTimingStore.save(SubtitleTiming(), scope: "show", defaults)
        #expect(SubtitleTimingStore.load(scope: "show", defaults).isIdentity)
    }

    @Test func episodes() {
        let e = { (s: Int, n: Int) in SubtitleMatch.Episode(s, n) }
        #expect(SubtitleMatch.episode("Show.S02E05.1080p.WEB-DL.x264.mkv") == e(2, 5))
        #expect(SubtitleMatch.episode("show.2x05.srt") == e(2, 5))
        #expect(SubtitleMatch.episode("庆余年 第12集.mp4") == e(1, 12))
        #expect(SubtitleMatch.episode("[Group] Title - 07 [1080p].mkv") == e(1, 7))
        #expect(SubtitleMatch.episode("EP03.chs.ass") == e(1, 3))
        #expect(SubtitleMatch.episode("05.mp4") == e(1, 5))
        #expect(SubtitleMatch.episode("Movie.2019.1080p.DDP5.1.H.264.mkv") == nil)
    }

    @Test func leavesOtherEpisodesOut() {
        let subs = ["Show.S01E01.chs.srt", "Show.S01E02.chs.srt", "Show.S01E02.eng.srt", "Show.S01E03.chs.srt", "notes.srt"]
            .map { ExternalSubtitle(name: $0, url: URL(string: "https://drive.example/\($0)")!) }
        let picked = SubtitleMatch.candidates(subs, video: "Show.S01E02.1080p.mkv").map(\.name)
        #expect(picked == ["Show.S01E02.chs.srt", "Show.S01E02.eng.srt", "notes.srt"])
        // A film keeps all of them, closest name first.
        let film = ["other.srt", "Movie.2019.chs.srt"].map { ExternalSubtitle(name: $0, url: URL(string: "https://drive.example/\($0)")!) }
        #expect(SubtitleMatch.candidates(film, video: "Movie.2019.mkv").map(\.name) == ["Movie.2019.chs.srt", "other.srt"])
        #expect(SubtitleMatch.language("Movie.2019.chs.srt") == "zh-Hans" && SubtitleMatch.language("Movie.英文.srt") == "en")
    }

    @Test func downloadStopsAtTheLimit() async throws {
        let big = Data(repeating: 0x41, count: 300_000)
        let session = StubSession.make { _ in (200, big, [:]) }
        await #expect(throws: SubtitleLoadError.tooLarge) {
            try await SubtitleFile.download(URL(string: "https://subs.example/a.srt")!, headers: [:], session: session, limit: 100_000)
        }
        let declared = StubSession.make { _ in (200, Data("x".utf8), ["Content-Length": "999999999"]) }
        await #expect(throws: SubtitleLoadError.tooLarge) {
            try await SubtitleFile.download(URL(string: "https://subs.example/b.srt")!, headers: [:], session: declared, limit: 100_000)
        }
        let missing = StubSession.make { _ in (404, Data(), [:]) }
        await #expect(throws: SubtitleLoadError.http(404)) {
            try await SubtitleFile.download(URL(string: "https://subs.example/c.srt")!, headers: [:], session: missing)
        }
        let fine = StubSession.make { _ in (200, big, [:]) }
        #expect(try await SubtitleFile.download(URL(string: "https://subs.example/d.srt")!, headers: [:], session: fine).count == big.count)
    }
}

/// A URLSession whose every request gets the handler's answer.
private final class StubSession: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Int, Data, [String: String])
    nonisolated(unsafe) static var handlers: [String: Handler] = [:]
    static let lock = NSLock()

    static func make(_ handler: @escaping Handler) -> URLSession {
        let id = UUID().uuidString
        lock.withLock { handlers[id] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubSession.self]
        configuration.httpAdditionalHeaders = ["X-Stub": id]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let id = request.value(forHTTPHeaderField: "X-Stub") ?? ""
        guard let handler = Self.lock.withLock({ Self.handlers[id] }), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let (status, data, headers) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // In pieces, as a network would.
        var offset = 0
        while offset < data.count {
            let end = min(offset + 16_384, data.count)
            client?.urlProtocol(self, didLoad: data.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

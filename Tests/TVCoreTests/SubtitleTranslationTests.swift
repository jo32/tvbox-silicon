import Foundation
import Testing
@testable import TVCore

/// Stands in for Apple's Translation: marks each line, fails, or never answers.
struct FakeTranslator: SubtitleTranslating {
    enum Mode { case mark, fail, hang }
    var target = Locale.Language(identifier: "zh-Hans")
    var mode = Mode.mark
    var unsupported: Set<String> = []
    func supports(_ source: Locale.Language) async -> Bool { !unsupported.contains(source.languageCode?.identifier ?? "") }
    func translate(_ lines: [String], from source: Locale.Language) async throws -> [String] {
        switch mode {
        case .mark: return lines.map { "译<\($0)>" }
        case .fail: throw TVError.unsupported("no model")
        case .hang: try await Task.sleep(for: .seconds(60)); return lines
        }
    }
}

private typealias Stream = RemuxPlan.Stream

private func subtitle(_ index: Int, _ language: String, title: String = "", default isDefault: Bool = false, forced: Bool = false) -> RemuxPlan.Track {
    RemuxPlan.Track(stream: Stream(index: index, kind: .subtitle, codec: "subrip", language: language, title: title,
                                   isDefault: isDefault, isForced: forced, isText: true))
}

@Test func subtitleTwinsTranslateEachForeignLanguageOnce() {
    let tracks = [RemuxPlan.Track(stream: Stream(index: 0, kind: .video, codec: "h264")),
                  subtitle(1, "eng", title: "SDH"), subtitle(2, "eng", default: true), subtitle(3, "chi"), subtitle(4, "jpn", forced: true),
                  subtitle(5, "kor"), subtitle(-1, ""), subtitle(6, "fre")]
    let chinese = SubtitleTranslation.sources(tracks, detected: [6: Locale.Language(identifier: "en")], target: .init(identifier: "zh-Hans"))
    // English from its default track, then Korean: Chinese is the app's own, forced Japanese only translates speech,
    // the untagged file is English by its words, and French is one more than two.
    #expect(chinese.map(\.track) == [2, 5])
    #expect(chinese.map { $0.language.languageCode?.identifier } == ["en", "ko"])
    // An English app translates the Chinese track; a file whose language isn't known gets none.
    #expect(SubtitleTranslation.sources(tracks, detected: [:], target: .init(identifier: "en")).map(\.track) == [3, 5])
    // Twins aren't translated again.
    var plan = RemuxPlan(tracks: tracks, bounds: [0, 4_000_000])
    _ = plan.addTranslations(chinese, target: .init(identifier: "zh-Hans"))
    #expect(SubtitleTranslation.sources(plan.tracks, detected: [:], target: .init(identifier: "ja")).map(\.track) == [2, 3])
}

@Test func untaggedSubtitleFilesAreKnownByTheirWords() {
    let lines = ["Where are you going tonight?", "<i>I told you already.</i>", "We have to leave before dawn.", "Nobody knows the way.",
                 "Then we find it ourselves.", "Fine, let's go."]
    let english = lines.enumerated().map { RemuxPlan.Cue(start: Int64($0.offset) * 1_000_000, end: Int64($0.offset) * 1_000_000 + 900_000, text: $0.element) }
    #expect(SubtitleTranslation.detect(english)?.languageCode?.identifier == "en")
    #expect(SubtitleTranslation.detect([.init(start: 0, end: 1, text: "Hi")]) == nil)
}

@Test func translatedCuesKeepTheirTimes() async {
    let cues = [RemuxPlan.Cue(start: 500_000, end: 2_000_000, text: "<i>Hello</i> &amp; welcome"), .init(start: 3_000_000, end: 4_000_000, text: "Second\nline")]
    let english = Locale.Language(identifier: "en")
    let done = await SubtitleTranslation.translate(cues, from: english, with: FakeTranslator())
    #expect(done.translated && done.error == nil)
    #expect(done.cues == [.init(start: 500_000, end: 2_000_000, text: "译&lt;Hello &amp; welcome&gt;"), .init(start: 3_000_000, end: 4_000_000, text: "译&lt;Second\nline&gt;")])
    // A translator that fails, or doesn't answer in time, leaves the words as they were.
    let failed = await SubtitleTranslation.translate(cues, from: english, with: FakeTranslator(mode: .fail))
    #expect(!failed.translated && failed.cues == cues && failed.error != nil)
    let slow = await SubtitleTranslation.translate(cues, from: english, with: FakeTranslator(mode: .hang), patience: .milliseconds(100))
    #expect(!slow.translated && slow.cues == cues)
    #expect(SubtitleTranslation.cueText("a --> b\n\n\nc") == "a --&gt; b\nc" && SubtitleTranslation.cueText(" \n") == nil)
}

@Test func translatedTwinsAreListedButNeverChosenByThemselves() {
    var plan = RemuxPlan(tracks: [RemuxPlan.Track(stream: Stream(index: 0, kind: .video, codec: "h264", width: 640, height: 360)),
                                  subtitle(1, "eng", default: true)], bounds: [0, 4_000_000, 8_000_000])
    #expect(plan.addTranslations([(1, .init(identifier: "en"))], target: .init(identifier: "zh-Hans")) == [2])
    let lines = plan.masterPlaylist(codecs: [0: "avc1.4d400a"]).components(separatedBy: "\n")
    let twin = lines.first { $0.contains(#"URI="2.m3u8""#) } ?? ""
    #expect(twin.contains("TYPE=SUBTITLES") && twin.contains("DEFAULT=NO,AUTOSELECT=NO") && twin.contains(#"LANGUAGE="zh"#))
    #expect(twin.contains("NAME=\"\(SubtitleTranslation.name(target: .init(identifier: "zh-Hans"), source: .init(identifier: "en")))\""))
    #expect(lines.contains { $0.contains(#"URI="1.m3u8""#) && $0.contains("AUTOSELECT=YES") })
    #expect(plan.mediaPlaylist(track: 2).contains("\n2-1.vtt\n"))
}

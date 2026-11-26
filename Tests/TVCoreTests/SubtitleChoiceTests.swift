import Foundation
import Testing
@testable import TVCore

struct SubtitleChoiceTests {
    @Test func thePickedTrackIsFoundAgainInTheNextEpisode() {
        let chinese = SubtitleChoice(scope: "show", name: "简体中文", language: "zh")
        // The same name and language, wherever it stands in the list.
        #expect(chinese.index(among: [("English", "en"), ("繁體中文", "zh"), ("简体中文", "zh")]) == 2)
        // Named differently in this episode: the first track in its language.
        #expect(chinese.index(among: [("English", "en"), ("Chinese", "zh")]) == 1)
        // None like it: nothing is picked.
        #expect(chinese.index(among: [("English", "en")]) == nil)
        #expect(chinese.index(among: []) == nil)
        // A track without a language is only found by its name.
        let untagged = SubtitleChoice(scope: "show", name: "Track 3", language: nil)
        #expect(untagged.index(among: [("Track 2", nil), ("Track 3", nil)]) == 1)
        #expect(untagged.index(among: [("Track 2", nil), ("English", "en")]) == nil)
    }

    @Test func anotherTitleGetsATrackInTheSameLanguage() {
        let chinese = SubtitleChoice(scope: "show", name: "简体中文", language: "zh")
        #expect(chinese.index(among: [("English", "en"), ("Chinese", "zh")], in: "other") == 1)
        #expect(chinese.index(among: [("English", "en")], in: "other") == nil)
        // A track without a language is picked again only in its own title.
        let untagged = SubtitleChoice(scope: "show", name: "Track 3", language: nil)
        #expect(untagged.index(among: [("Track 3", nil)], in: "show") == 0)
        #expect(untagged.index(among: [("Track 3", nil)], in: "other") == nil)
        #expect(untagged.index(among: [("Track 3", nil)], in: nil) == nil)
    }

    @Test func perSeriesChoicesSurviveReorderingMissingTracksAndOff() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        typealias Track = TrackLabel.Option
        let pgs = Track(displayName: "中文", language: "zh", title: "Bilingual", format: "PGS")
        let ass = Track(displayName: "中文", language: "zh", title: "Bilingual", format: "ASS")
        let srt = Track(displayName: "中文", language: "zh", title: "简体", format: "SRT")
        let old = SubtitleChoice(scope: "old", name: "中文", language: "zh")
        defaults.set(Data(#"{"scope":"old","name":"中文","language":"zh"}"#.utf8), forKey: SubtitleChoice.key)
        SubtitleChoice.remember(ass, for: "A", in: defaults)
        SubtitleChoice.remember(srt, for: "B", in: defaults)
        #expect(SubtitleChoice.preference(for: "old", in: defaults) == .track(old))
        guard case let .track(a) = SubtitleChoice.preference(for: "A", in: defaults) else {
            Issue.record("Expected A's choice"); return
        }
        #expect(a.match([srt, ass, pgs], in: "A") == 1)
        #expect(a.match([pgs], in: "A") == 0)
        #expect(a.match([pgs, srt, ass], in: "A") == 2)
        var commentary = ass
        commentary.rendition = "Bilingual (2)"
        SubtitleChoice.remember(commentary, for: "duplicates", in: defaults)
        guard case let .track(duplicate) = SubtitleChoice.preference(for: "duplicates", in: defaults) else {
            Issue.record("Expected saved rendition"); return
        }
        #expect(duplicate.match([ass, commentary], in: "duplicates") == 1)
        SubtitleChoice.remember(nil, for: "B", in: defaults)
        #expect(SubtitleChoice.preference(for: "B", in: defaults) == .off)
        #expect(SubtitleChoice.preference(for: "A", in: defaults) == .track(a))
        guard case let .track(global) = SubtitleChoice.preference(for: "new", in: defaults) else {
            Issue.record("Expected language fallback"); return
        }
        #expect(global.match([pgs, ass, srt], in: "new") == 0)
    }

    @Test func theChoiceIsKeptAcrossLaunches() throws {
        let defaults = try #require(UserDefaults(suiteName: "SubtitleChoiceTests"))
        defaults.removePersistentDomain(forName: "SubtitleChoiceTests")
        #expect(SubtitleChoice.saved(in: defaults) == nil)
        let chinese = SubtitleChoice(scope: "show", name: "简体中文", language: "zh")
        SubtitleChoice.save(chinese, in: defaults)
        #expect(SubtitleChoice.saved(in: defaults) == chinese)
        // Off forgets it.
        SubtitleChoice.save(nil, in: defaults)
        #expect(SubtitleChoice.saved(in: defaults) == nil)
        defaults.removePersistentDomain(forName: "SubtitleChoiceTests")
    }
}

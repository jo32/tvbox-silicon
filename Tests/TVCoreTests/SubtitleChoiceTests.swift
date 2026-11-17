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

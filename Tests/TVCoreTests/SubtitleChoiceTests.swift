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
}

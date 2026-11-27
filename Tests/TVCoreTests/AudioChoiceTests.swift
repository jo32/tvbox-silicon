import Foundation
import Testing
@testable import TVCore

struct AudioChoiceTests {
    @Test func thePickedTrackIsFoundAgainInTheNextEpisode() {
        let italian = AudioChoice(scope: "show", name: "Italiano", language: "it")
        // The same name and language, wherever it stands in the list.
        #expect(italian.index(among: [("English", "en"), ("Français", "fr"), ("Italiano", "it")]) == 2)
        // Named differently in this episode: the first track in its language.
        #expect(italian.index(among: [("English", "en"), ("Italian", "it")]) == 1)
        // None like it: nothing is picked.
        #expect(italian.index(among: [("English", "en")]) == nil)
        #expect(italian.index(among: []) == nil)
        // A track without a language is only found by its name.
        let untagged = AudioChoice(scope: "show", name: "Track 3", language: nil)
        #expect(untagged.index(among: [("Track 2", nil), ("Track 3", nil)]) == 1)
        #expect(untagged.index(among: [("Track 2", nil), ("English", "en")]) == nil)
    }

    @Test func anotherTitleGetsATrackInTheSameLanguage() {
        let italian = AudioChoice(scope: "show", name: "Italiano", language: "it")
        #expect(italian.index(among: [("English", "en"), ("Italian", "it")], in: "other") == 1)
        #expect(italian.index(among: [("English", "en")], in: "other") == nil)
        // A track without a language is picked again only in its own title.
        let untagged = AudioChoice(scope: "show", name: "Track 3", language: nil)
        #expect(untagged.index(among: [("Track 3", nil)], in: "show") == 0)
        #expect(untagged.index(among: [("Track 3", nil)], in: "other") == nil)
        #expect(untagged.index(among: [("Track 3", nil)], in: nil) == nil)
    }

    @Test func anUngroupedDubIsFoundByNameThenLanguage() {
        let italian = AudioChoice(scope: "show", name: "Italiano", language: "it")
        let choices = [UngroupedAudio.Choice(id: 1, name: "English", language: "en"),
                       UngroupedAudio.Choice(id: 2, name: "Italiano", language: "it")]
        #expect(italian.match(choices, in: "show") == 2)
        // Named differently in this episode: the first track in its language.
        let renamed = [UngroupedAudio.Choice(id: 1, name: "English", language: "en"),
                       UngroupedAudio.Choice(id: 2, name: "Italian", language: "it")]
        #expect(italian.match(renamed, in: "other") == 2)
        // None like it: nothing is picked.
        #expect(italian.match([UngroupedAudio.Choice(id: 1, name: "English", language: "en")], in: "other") == nil)
        // A track without a language is picked again only in its own title.
        let untagged = AudioChoice(scope: "show", name: "Audio 2", language: nil)
        #expect(untagged.match([UngroupedAudio.Choice(id: 2, name: "Audio 2", language: nil)], in: "show") == 2)
        #expect(untagged.match([UngroupedAudio.Choice(id: 2, name: "Audio 2", language: nil)], in: "other") == nil)
    }

    @Test func perSeriesChoicesSurviveReorderingAndMissingTracks() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        typealias Track = TrackLabel.Option
        let italian = Track(displayName: "Italiano", language: "it", title: "Italian", format: "AAC")
        let english = Track(displayName: "English", language: "en", title: "English", format: "AAC")
        AudioChoice.remember(italian, for: "A", in: defaults)
        AudioChoice.remember(english, for: "B", in: defaults)
        #expect(AudioChoice.preference(for: "A", in: defaults)?.match([english, italian], in: "A") == 1)
        #expect(AudioChoice.preference(for: "A", in: defaults)?.match([italian], in: "A") == 0)
        #expect(AudioChoice.preference(for: "B", in: defaults)?.match([italian, english], in: "B") == 1)
        // A new series gets a track in the last language.
        guard let global = AudioChoice.preference(for: "new", in: defaults) else {
            Issue.record("Expected language fallback"); return
        }
        #expect(global.match([italian, english], in: "new") == 1)
        // An ungrouped pick is remembered the same way.
        AudioChoice.remember(UngroupedAudio.Choice(id: 3, name: "Italiano", language: "it"), for: "C", in: defaults)
        #expect(AudioChoice.preference(for: "C", in: defaults)?.match(
            [UngroupedAudio.Choice(id: 1, name: "English", language: "en"),
             UngroupedAudio.Choice(id: 3, name: "Italiano", language: "it")], in: "C") == 3)
    }

    @Test func theChoiceIsKeptAcrossLaunches() throws {
        let defaults = try #require(UserDefaults(suiteName: "AudioChoiceTests"))
        defaults.removePersistentDomain(forName: "AudioChoiceTests")
        #expect(AudioChoice.saved(in: defaults) == nil)
        let italian = AudioChoice(scope: "show", name: "Italiano", language: "it")
        AudioChoice.save(italian, in: defaults)
        #expect(AudioChoice.saved(in: defaults) == italian)
        AudioChoice.save(nil, in: defaults)
        #expect(AudioChoice.saved(in: defaults) == nil)
        defaults.removePersistentDomain(forName: "AudioChoiceTests")
    }
}

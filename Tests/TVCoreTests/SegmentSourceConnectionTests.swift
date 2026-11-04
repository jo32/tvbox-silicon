import Foundation
import Testing
@testable import TVCore

@Test func segmentSourceSaysWhetherItCanBeAskedAtAll() {
    // The settings page greys out a source on this, and the player only consults the same ones, so
    // the two cannot drift: a source that reports `false` here is one nothing reads.
    #expect(SkipSegmentSources.Source.manual.isConnected)
    #expect(SkipSegmentSources.Source.mediaServer.isConnected)
    for unconnected in [SkipSegmentSources.Source.theIntroDB, .introDB, .publicMetaDB] {
        #expect(!unconnected.isConnected)
        #expect(!unconnected.isFileLevel)
    }
}

@Test func viewerMarkersBecomeIntroAndCreditsSegments() throws {
    // What the player builds from the episode skip page: intro from the start, credits from the end.
    let settings = EpisodeSkipSettings(enabled: false, introEnd: 90, outroLength: 120)
    let duration = 2700.0
    #expect(settings.validationError(duration: duration) == nil)

    let sources = SkipSegmentSources()
    let intro = SkipSegmentSources.Segment(kind: .intro, start: 0, end: settings.introEnd)
    let credits = SkipSegmentSources.Segment(kind: .credits, start: duration - settings.outroLength, end: duration)
    #expect(sources.choose(kind: .intro, duration: duration, reported: [.manual: intro])?.source == .manual)
    #expect(sources.choose(kind: .credits, duration: duration, reported: [.manual: credits])?.segment == credits)

    // Switched off, the marker is ignored: the button must not appear for a source the viewer
    // turned off on the settings page.
    let disabled = SkipSegmentSources(disabled: [.manual])
    #expect(disabled.choose(kind: .intro, duration: duration, reported: [.manual: intro]) == nil)
}

@Test func speechPreferencePutsTheChosenLanguageFirst() {
    let candidates = SpeechSubtitlePreference.candidates(stored: "ja-JP")
    #expect(candidates.first == "ja-JP")
    #expect(candidates.count > 1)
    // An empty choice must not push a blank string at the recogniser.
    #expect(SpeechSubtitlePreference.candidates(stored: "").first != "")
    // The phone's own languages and the app's list overlap; the page must not show a code twice.
    let all = SpeechSubtitlePreference.candidates(stored: "en-US")
    #expect(Set(all).count == all.count)
}

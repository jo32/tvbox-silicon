import Foundation
import Testing
@testable import TVCore

@Test func episodeSkipRejectsInvalidAndExcessivePositions() {
    for text in ["-1", "nan", "1:60", "1::20", "1.5", "9999999999999999999999", "24:00:01"] {
        #expect(EpisodeSkipSettings.parseTime(text) == nil)
    }
    #expect(EpisodeSkipSettings.parseTime(" 01:30 ") == 90)
    #expect(EpisodeSkipSettings.parseTime("1:02:03") == 3723)
    let valid = EpisodeSkipSettings(enabled: true, introEnd: 90, outroLength: 120)
    #expect(valid.validationError(duration: 2700) == nil)
    for length in [0.0, .infinity, .nan] {
        #expect(valid.validationError(duration: length) != nil)
    }
    // No limits on their length (#1003): a short anime episode's long opening, a long intro, a short video.
    #expect(EpisodeSkipSettings(enabled: true, introEnd: 90, outroLength: 90).validationError(duration: 720) == nil)
    #expect(EpisodeSkipSettings(enabled: true, introEnd: 301).validationError(duration: 2700) == nil)
    #expect(EpisodeSkipSettings(enabled: true, introEnd: 20, outroLength: 30).validationError(duration: 90) == nil)
    // Only an intro that runs into the outro is refused.
    #expect(EpisodeSkipSettings(enabled: true, introEnd: 60, outroLength: 30).validationError(duration: 90) != nil)
    // Apple TV sets them at the place playing (#808), which also switches skipping on; a place the rules refuse is nil.
    let marked = EpisodeSkipSettings().marking(intro: true, at: 90.6, duration: 2700)?.marking(intro: false, at: 2580, duration: 2700)
    #expect(marked == EpisodeSkipSettings(enabled: true, introEnd: 90, outroLength: 120))
    #expect(EpisodeSkipSettings().marking(intro: true, at: 301, duration: 2700) == EpisodeSkipSettings(enabled: true, introEnd: 301))
    #expect(EpisodeSkipSettings(introEnd: 1200).marking(intro: false, at: 1000, duration: 2700) == nil)
    #expect(EpisodeSkipSettings().marking(intro: true, at: 10, duration: .nan) == nil)
    #expect(EpisodeSkipSettings(enabled: true, outroLength: 601).validationError(duration: 2700) == nil)
    #expect(EpisodeSkipSettings(enabled: true, introEnd: 120, outroLength: 120).validationError(duration: 480) == nil)
    #expect(EpisodeSkipSettings(enabled: true, introEnd: .nan).validationError(duration: 2700) != nil)
}

@Test func episodeSkipRunsOnceAndAllowsManualRewind() {
    let settings = EpisodeSkipSettings(enabled: true, introEnd: 90, outroLength: 120)
    var pass = EpisodeSkipPass()
    #expect(pass.target(time: 0, duration: 2700, playing: false, settings: settings) == nil)
    #expect(pass.target(time: 0, duration: 2700, playing: true, settings: settings) == 90)
    #expect(pass.target(time: 10, duration: 2700, playing: true, settings: settings) == nil)
    #expect(pass.target(time: 2579, duration: 2700, playing: true, settings: settings) == nil)
    #expect(pass.target(time: 2580, duration: 2700, playing: true, settings: settings) == 2699.95)
    #expect(pass.target(time: 2600, duration: 2700, playing: true, settings: settings) == nil)
    var disabled = EpisodeSkipPass()
    #expect(disabled.target(time: 0, duration: 2700, playing: true, settings: EpisodeSkipSettings()) == nil)
}

@Test func episodeSkipPersistsPerTitleAndPreservesOldChannelData() throws {
    let suite = "episode-skip-tests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let origin = URL(string: "https://example.com/config.json")!
    let scope = EpisodeSkipSettings.scope(origin: origin, source: "source", video: "series-1")
    let settings = EpisodeSkipSettings(enabled: true, introEnd: 90, outroLength: 120)
    settings.save(scope: scope, defaults: defaults)
    #expect(EpisodeSkipSettings.load(scope: scope, defaults: defaults) == settings)
    #expect(EpisodeSkipSettings.load(scope: EpisodeSkipSettings.scope(origin: origin, source: "source", video: "series-2"), defaults: defaults) == EpisodeSkipSettings(enabled: true))
    // The ending follows each episode's duration instead of retaining the first episode's absolute timestamp.
    var pass = EpisodeSkipPass()
    #expect(pass.target(time: 2880, duration: 3000, playing: true, settings: settings) == 2999.95)
    let legacy = Data(#"{"name":"Live","group":"TV","url":"https://example.com/live.m3u8","headers":{}}"#.utf8)
    #expect(try JSONDecoder().decode(Channel.self, from: legacy).skipScope == nil)
}

@Test func globalLegacyTimesAreNotCopiedToOtherSeriesAndTheSwitchIsShared() throws {
    let suite = "global-skip-tests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let legacy = EpisodeSkipSettings(enabled: true, introEnd: 30)
    legacy.save(scope: "old-film", defaults: defaults)
    #expect(EpisodeSkipSettings.loadGlobal(defaults: defaults) == EpisodeSkipSettings())
    let settings = EpisodeSkipSettings(enabled: true, introEnd: 90, outroLength: 120)
    settings.saveGlobal(defaults: defaults)
    let loaded = EpisodeSkipSettings.loadGlobal(defaults: defaults)
    #expect(loaded == settings)
    #expect(EpisodeSkipSettings.load(scope: "old-film", defaults: defaults) == legacy)
    #expect(EpisodeSkipSettings.load(scope: "new-film", defaults: defaults) == EpisodeSkipSettings(enabled: true))
    EpisodeSkipSettings(enabled: false, introEnd: 60, outroLength: 80).save(scope: "new-film", defaults: defaults)
    #expect(EpisodeSkipSettings.load(scope: "old-film", defaults: defaults) == EpisodeSkipSettings(enabled: false, introEnd: 30))
    for duration in [2700.0, 3000.0] {
        var pass = EpisodeSkipPass()
        #expect(pass.target(time: 0, duration: duration, playing: true, settings: loaded) == 90)
        #expect(pass.target(time: duration - 120, duration: duration, playing: true, settings: loaded) == duration - 0.05)
    }
}

@Test func enabledGlobalSkippingWithoutTimesRemainsEnabledButDoesNotSeek() throws {
    let suite = "empty-global-skip-tests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    EpisodeSkipSettings(enabled: true).saveGlobal(defaults: defaults)
    let settings = EpisodeSkipSettings.loadGlobal(defaults: defaults)
    #expect(settings.enabled)
    for duration in [300.0, 2700.0] {
        var pass = EpisodeSkipPass()
        #expect(pass.target(time: 0, duration: duration, playing: true, settings: settings) == nil)
        #expect(pass.target(time: duration - 1, duration: duration, playing: true, settings: settings) == nil)
    }
}

@Test func theOutroCountsDownAndCanBeKept() {
    let settings = EpisodeSkipSettings(enabled: true, introEnd: 90, outroLength: 120)
    var pass = EpisodeSkipPass()
    // Five seconds before the outro starts at 2580, the countdown shows; it is gone once skipped.
    #expect(pass.outroCountdown(time: 2570, duration: 2700, settings: settings) == nil)
    #expect(pass.outroCountdown(time: 2576, duration: 2700, settings: settings) == 4)
    #expect(pass.target(time: 2580, duration: 2700, playing: true, settings: settings) == 2699.95)
    #expect(pass.outroCountdown(time: 2579, duration: 2700, settings: settings) == nil)
    // Kept: no countdown and no skip this time through.
    var kept = EpisodeSkipPass()
    kept.keepOutro()
    #expect(kept.outroCountdown(time: 2576, duration: 2700, settings: settings) == nil)
    #expect(kept.target(time: 0, duration: 2700, playing: true, settings: settings) == 90)
    #expect(kept.target(time: 2590, duration: 2700, playing: true, settings: settings) == nil)
    // Off, or without an outro time, nothing counts down.
    #expect(EpisodeSkipPass().outroCountdown(time: 2576, duration: 2700, settings: EpisodeSkipSettings(introEnd: 90, outroLength: 120)) == nil)
    #expect(EpisodeSkipPass().outroCountdown(time: 2696, duration: 2700, settings: EpisodeSkipSettings(enabled: true, introEnd: 90)) == nil)
}

@Test func theMenuSaysWhatIsSkipped() {
    // Switched on without times skips nothing, and the menu says so rather than "On" (#1405).
    #expect(EpisodeSkipSettings(enabled: true).summary == L10n.text("Not set"))
    #expect(!EpisodeSkipSettings(enabled: true).hasTimes)
    #expect(EpisodeSkipSettings(enabled: false, introEnd: 90, outroLength: 120).summary == L10n.text("Off"))
    let both = EpisodeSkipSettings(enabled: true, introEnd: 90, outroLength: 120)
    #expect(both.hasTimes)
    #expect(both.summary == L10n.text("Intro %@", "01:30") + " · " + L10n.text("Outro %@", "−02:00"))
    #expect(EpisodeSkipSettings(enabled: true, outroLength: 45).summary == L10n.text("Outro %@", "−00:45"))
}

/// Times saved before the intro had a start and the outro an end still load, as an intro from the start and an outro
/// to the end (#2653).
@Test func episodeSkipSettingsDecodeWithoutRanges() throws {
    let old = try JSONDecoder().decode(EpisodeSkipSettings.self, from: Data(#"{"enabled":true,"introEnd":90,"outroLength":120}"#.utf8))
    #expect(old == EpisodeSkipSettings(enabled: true, introEnd: 90, outroLength: 120))
    #expect(old.introStart == 0 && old.outroTail == 0)
    let saved = EpisodeSkipSettings(enabled: true, introEnd: 224, outroLength: 1_200, introStart: 135, outroTail: 30)
    #expect(try JSONDecoder().decode(EpisodeSkipSettings.self, from: JSONEncoder().encode(saved)) == saved)
}

/// An intro after a cold open waits for play to reach it, then skips once; the cold open plays.
@Test func episodeSkipIntroAfterAColdOpen() {
    let settings = EpisodeSkipSettings(enabled: true, introEnd: 224, introStart: 135)
    var pass = EpisodeSkipPass()
    #expect(pass.target(time: 0, duration: 1_420, playing: true, settings: settings) == nil)
    #expect(pass.target(time: 100, duration: 1_420, playing: true, settings: settings) == nil)
    #expect(pass.target(time: 135.5, duration: 1_420, playing: true, settings: settings) == 224)
    #expect(pass.target(time: 150, duration: 1_420, playing: true, settings: settings) == nil)
    // Play that begins past it never jumps back into it.
    var late = EpisodeSkipPass()
    #expect(late.target(time: 300, duration: 1_420, playing: true, settings: settings) == nil)
    #expect(late.target(time: 140, duration: 1_420, playing: true, settings: settings) == nil)
}

/// An outro with a scene after it skips to the scene, which plays, and no countdown runs during it.
@Test func episodeSkipOutroBeforeAScene() {
    // 23:40 long: the outro 21:40–23:10, then 30 s of scene.
    let settings = EpisodeSkipSettings(enabled: true, outroLength: 120, outroTail: 30)
    #expect(settings.outro(in: 1_420) == 1_300...1_390)
    var pass = EpisodeSkipPass()
    #expect(pass.outroCountdown(time: 1_297, duration: 1_420, settings: settings) == 3)
    #expect(pass.target(time: 1_300, duration: 1_420, playing: true, settings: settings) == 1_390)
    #expect(pass.target(time: 1_395, duration: 1_420, playing: true, settings: settings) == nil)
    #expect(EpisodeSkipPass().outroCountdown(time: 1_400, duration: 1_420, settings: settings) == nil)
    // Reached only inside the scene: nothing to skip back over.
    var late = EpisodeSkipPass()
    #expect(late.target(time: 1_400, duration: 1_420, playing: true, settings: settings) == nil)
}

@Test func episodeSkipRangesMustRunForwards() {
    #expect(EpisodeSkipSettings(introEnd: 100, introStart: 120).validationError(duration: 1_420) != nil)
    #expect(EpisodeSkipSettings(outroLength: 100, outroTail: 120).validationError(duration: 1_420) != nil)
    #expect(EpisodeSkipSettings(introEnd: 224, outroLength: 120, introStart: 135, outroTail: 30).validationError(duration: 1_420) == nil)
    // Marking an intro's end before its start drops the start.
    let marked = EpisodeSkipSettings(introEnd: 224, introStart: 135).marking(intro: true, at: 100, duration: 1_420)
    #expect(marked?.introEnd == 100 && marked?.introStart == 0)
}

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
    for length in [0.0, .infinity, .nan, 119] {
        #expect(valid.validationError(duration: length) != nil)
    }
    #expect(EpisodeSkipSettings(enabled: true, introEnd: 301).validationError(duration: 2700) != nil)
    // Apple TV sets them at the place playing (#808), which also switches skipping on; a place the rules refuse is nil.
    let marked = EpisodeSkipSettings().marking(intro: true, at: 90.6, duration: 2700)?.marking(intro: false, at: 2580, duration: 2700)
    #expect(marked == EpisodeSkipSettings(enabled: true, introEnd: 90, outroLength: 120))
    #expect(EpisodeSkipSettings().marking(intro: true, at: 301, duration: 2700) == nil)
    #expect(EpisodeSkipSettings().marking(intro: false, at: 1000, duration: 2700) == nil)
    #expect(EpisodeSkipSettings().marking(intro: true, at: 10, duration: .nan) == nil)
    #expect(EpisodeSkipSettings(enabled: true, outroLength: 601).validationError(duration: 2700) != nil)
    #expect(EpisodeSkipSettings(enabled: true, introEnd: 120, outroLength: 120).validationError(duration: 480) != nil)
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

import Foundation
import Testing
@testable import TVCore

@Test func playbackSpeedDefaultsToOneWhenUnset() throws {
    let suite = "playback-speed-tests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(PlaybackSpeed.load(defaults: defaults) == PlaybackSpeed.standard)
}

@Test func playbackSpeedPersistsAndIsValidated() throws {
    let suite = "playback-speed-tests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    PlaybackSpeed.save(2, defaults: defaults)
    #expect(PlaybackSpeed.load(defaults: defaults) == 2)
    PlaybackSpeed.save(1.5, defaults: defaults)
    #expect(PlaybackSpeed.load(defaults: defaults) == 1.5)
}

@Test func playbackSpeedRejectsValuesOutsideTheMenu() throws {
    let suite = "playback-speed-tests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    // A speed the menus never offer is not stored.
    PlaybackSpeed.save(1.4, defaults: defaults)
    #expect(PlaybackSpeed.load(defaults: defaults) == PlaybackSpeed.standard)
    PlaybackSpeed.save(.infinity, defaults: defaults)
    #expect(PlaybackSpeed.load(defaults: defaults) == PlaybackSpeed.standard)
}

@Test func playbackSpeedIsChosenOnlyOnceSet() throws {
    let suite = "playback-speed-tests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    // Never set: the player keeps its speed, as before the setting existed.
    #expect(PlaybackSpeed.chosen(defaults: defaults) == nil)
    PlaybackSpeed.save(1, defaults: defaults)
    #expect(PlaybackSpeed.chosen(defaults: defaults) == 1)
    PlaybackSpeed.save(1.5, defaults: defaults)
    #expect(PlaybackSpeed.chosen(defaults: defaults) == 1.5)
    defaults.set(Float(1.4), forKey: PlaybackSpeed.key)
    #expect(PlaybackSpeed.chosen(defaults: defaults) == nil)
}

@Test func playbackSpeedLabelsTheMenuOptions() {
    #expect(PlaybackSpeed.speedLabel(1) == "1×")
    #expect(PlaybackSpeed.speedLabel(1.5) == "1.5×")
    #expect(PlaybackSpeed.speedLabel(2) == "2×")
    #expect(PlaybackSpeed.speeds.contains(PlaybackSpeed.standard))
}

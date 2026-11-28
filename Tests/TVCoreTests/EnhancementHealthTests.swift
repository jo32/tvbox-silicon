import Foundation
import Testing
@testable import TVCore

@Suite struct EnhancementHealthTests {
    /// The A13 iPad of #2737: both processors failed at once for every size they were started at.
    @Test func aKindThatFailsAtEverySizeIsLeftOff() {
        var health = EnhancementHealth(system: "27.0")
        #expect(health.usable(.scale) && health.usable(.smooth))
        let first = health.failedAtOnce("scale 1280x720 x1.5", kind: .scale)
        #expect(!first)
        #expect(health.refused("scale 1280x720 x1.5", kind: .scale))
        #expect(!health.refused("scale 1280x640 x1.5", kind: .scale))
        // The same size again is no new finding.
        let again = health.failedAtOnce("scale 1280x720 x1.5", kind: .scale)
        let second = health.failedAtOnce("scale 1280x640 x1.5", kind: .scale)
        #expect(!again && !second)
        #expect(health.usable(.scale))
        let third = health.failedAtOnce("scale 1920x800 x1.5", kind: .scale)
        #expect(third)
        #expect(!health.usable(.scale))
        // The other kind keeps its own record.
        #expect(health.usable(.smooth))
    }

    /// An iPhone 17 Pro refused upscaling a few small sizes while others upscaled fine: a kind that worked stays on.
    @Test func aKindThatWorkedStaysOn() {
        var health = EnhancementHealth(system: "27.2")
        health.worked(.scale)
        for size in ["406x720", "720x406", "480x270", "360x640"] { health.failedAtOnce("scale \(size) x2.0", kind: .scale) }
        #expect(health.usable(.scale))
        // Those sizes are still not started again.
        #expect(health.refused("scale 480x270 x2.0", kind: .scale))
    }

    @Test func findingsLastUntilTheSystemIsUpdated() throws {
        let defaults = try #require(UserDefaults(suiteName: "EnhancementHealthTests-\(UUID().uuidString)"))
        var health = EnhancementHealth(system: "27.0")
        for size in ["a", "b", "c"] { health.failedAtOnce("smooth \(size)", kind: .smooth) }
        health.save(defaults)
        #expect(EnhancementHealth.load(defaults, system: "27.0") == health)
        #expect(!EnhancementHealth.load(defaults, system: "27.0").usable(.smooth))
        #expect(EnhancementHealth.load(defaults, system: "27.1").usable(.smooth))
        #expect(EnhancementHealth.load(UserDefaults(suiteName: "EnhancementHealthTests-empty-\(UUID().uuidString)")!, system: "27.0") == EnhancementHealth(system: "27.0"))
    }
}

import Foundation
import Testing
@testable import TVCore

/// #2691: the Apple TV kept the video's frame rate after the player closed.
struct DisplayModeRequestsTests {
    final class Display {}
    final class Owner {}

    @Test func closingGivesBackEveryDisplayAskedOnAndTheWindowsShowing() {
        var requests = DisplayModeRequests<Display>()
        let first = Display(), second = Display(), showing = Display()
        let hdr = ObjectIdentifier(Owner()), player = ObjectIdentifier(Owner())
        // The HDR switch asked on the key window, the player view on its own window: two managers.
        requests.record(first, by: hdr, asking: true)
        requests.record(second, by: player, asking: true)
        let released = requests.release(showing: [first, showing])
        #expect(released.count == 3)
        #expect(released[0] === first && released[1] === second && released[2] === showing)
        // All forgotten: nothing left to give back the next time.
        #expect(requests.displays.isEmpty)
        #expect(requests.release(showing: []).isEmpty)
    }

    @Test func aPlayerViewTakesBackOnlyItsOwnMode() {
        var requests = DisplayModeRequests<Display>()
        let display = Display()
        let old = Owner(), new = Owner()
        requests.record(display, by: ObjectIdentifier(old), asking: true)
        #expect(requests.owns(display, ObjectIdentifier(old)))
        // A new player view asked on the same display before the old one went away.
        requests.record(display, by: ObjectIdentifier(new), asking: true)
        #expect(!requests.owns(display, ObjectIdentifier(old)))
        #expect(requests.owns(display, ObjectIdentifier(new)))
        #expect(requests.displays.count == 1)
        // Taking a mode back forgets the display.
        requests.record(display, by: ObjectIdentifier(new), asking: false)
        #expect(requests.displays.isEmpty)
        #expect(!requests.owns(display, ObjectIdentifier(new)))
    }
}

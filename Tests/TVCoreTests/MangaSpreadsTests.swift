import Foundation
import Testing
@testable import TVCore

struct MangaSpreadsTests {
    @Test func theFirstPageStandsAloneThenPagesPair() {
        #expect(MangaSpreads.spreads(count: 6) { _ in false } == [[0], [1, 2], [3, 4], [5]])
        #expect(MangaSpreads.spreads(count: 5) { _ in false } == [[0], [1, 2], [3, 4]])
        #expect(MangaSpreads.spreads(count: 1) { _ in false } == [[0]])
        #expect(MangaSpreads.spreads(count: 0) { _ in false }.isEmpty)
    }

    @Test func aWidePageStandsAloneAndPairingStartsAgainAfterIt() {
        // Page 3 is a double-page picture already.
        #expect(MangaSpreads.spreads(count: 8) { $0 == 3 } == [[0], [1, 2], [3], [4, 5], [6, 7]])
        #expect(MangaSpreads.spreads(count: 6) { $0 == 2 } == [[0], [1], [2], [3, 4], [5]])
        #expect(MangaSpreads.isWide(aspect: 1.4))
        #expect(!MangaSpreads.isWide(aspect: 0.7))
        #expect(!MangaSpreads.isWide(aspect: nil))
    }

    @Test func twoPagesOnlyInALandscapeView() {
        #expect(MangaSpreads.fitsTwo(width: 1920, height: 1080))
        #expect(MangaSpreads.fitsTwo(width: 1194, height: 834))
        #expect(!MangaSpreads.fitsTwo(width: 834, height: 1194))
        #expect(!MangaSpreads.fitsTwo(width: 1000, height: 900))
        #expect(!MangaSpreads.fitsTwo(width: 100, height: 0))
    }

    @Test func newChaptersCountFromWhatTheViewerSaw() {
        var updates = MangaUpdates()
        // Following a comic doesn't make its chapters new.
        updates.found(20, for: "a")
        #expect(updates.newChapters("a") == 0)
        updates.found(23, for: "a")
        #expect(updates.newChapters("a") == 3)
        // Opening its page or reading it sees them.
        updates.saw(23, of: "a")
        #expect(updates.newChapters("a") == 0)
        // A source that lists fewer chapters, or an empty answer, never goes negative or forgets.
        updates.found(0, for: "a")
        updates.found(22, for: "a")
        #expect(updates.newChapters("a") == 0)
        #expect(updates.newChapters("unknown") == 0)
        updates.found(5, for: "b")
        updates.keep(["b"])
        #expect(updates.latest["a"] == nil && updates.seen["a"] == nil && updates.latest["b"] == 5)
    }

    @Test func checksAtMostEverySixHours() {
        var updates = MangaUpdates()
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(updates.due(now: now))
        updates.checked = now
        #expect(!updates.due(now: now.addingTimeInterval(3600)))
        #expect(updates.due(now: now.addingTimeInterval(6 * 3600)))
        // A clock set back doesn't stop checks for good.
        #expect(updates.due(now: now.addingTimeInterval(-60)))
    }

    @Test func updatesSurviveAReload() throws {
        var updates = MangaUpdates()
        updates.found(7, for: "x"); updates.found(9, for: "x"); updates.checked = Date(timeIntervalSince1970: 5)
        let decoded = try JSONDecoder().decode(MangaUpdates.self, from: JSONEncoder().encode(updates))
        #expect(decoded == updates)
        #expect(decoded.newChapters("x") == 2)
    }
}

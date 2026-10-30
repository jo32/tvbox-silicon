import CoreMedia
import Testing
@testable import TVCore

struct LiveEdgeTests {
    func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }
    func range(_ start: Double, _ end: Double) -> CMTimeRange { CMTimeRange(start: time(start), end: time(end)) }

    /// Measured on a Huya room through the Mac's HLS adapter after 30 s of failed requests: playing at 38 s with
    /// the playlist's window at 64 s, and no new frame for the next 26 s.
    @Test func aStreamResumedBehindItsPlaylistJumpsToTheLiveEdge() {
        #expect(LiveEdge.target(position: time(38.2), seekable: [range(64, 64)]) == time(64))
        #expect(LiveEdge.target(position: time(10), seekable: [range(40, 52), range(60, 70)]) == time(70))
    }

    @Test func aStreamPlayingNearItsEdgeStays() {
        // Huya plays a little either side of its one-point window, Douyu up to 9 s behind it.
        #expect(LiveEdge.target(position: time(41.2), seekable: [range(40, 40)]) == nil)
        #expect(LiveEdge.target(position: time(29.6), seekable: [range(26, 26)]) == nil)
        #expect(LiveEdge.target(position: time(72.4), seekable: [range(81, 81)]) == nil)
        // A stream that keeps hours to rewind through plays from inside them.
        #expect(LiveEdge.target(position: time(100), seekable: [range(0, 3600)]) == nil)
    }

    @Test func unknownTimesChangeNothing() {
        #expect(LiveEdge.target(position: time(10), seekable: []) == nil)
        #expect(LiveEdge.target(position: .invalid, seekable: [range(64, 64)]) == nil)
        #expect(LiveEdge.target(position: time(10), seekable: [CMTimeRange(start: .invalid, duration: .invalid)]) == nil)
    }
}

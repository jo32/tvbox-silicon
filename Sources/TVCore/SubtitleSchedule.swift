import Foundation

/// The subtitle lines a delayed player shows, by the time AVPlayer handed each over (#599). A line waits
/// `delay` seconds past that time, so a subtitle file running ahead of the picture is pulled back; a cue's end
/// (empty lines) waits like its start, so a line stays up as long as it did. The lines alone are kept: AVPlayer
/// has already decided which cue is showing, and this only moves when it reaches the screen.
public struct SubtitleSchedule: Sendable {
    /// What AVPlayer handed over and when, oldest first.
    public private(set) var pending: [(time: Double, lines: [String])] = []
    public var delay: Double
    /// The playback time `lines(at:)` saw last, to tell a seek from the clock moving on.
    private var lastTime: Double?
    /// A step longer than this between two looks at the clock is a seek, not playback moving on.
    static let seekStep: Double = 2

    public init(delay: Double = 0) {
        self.delay = delay
    }

    /// Adds the lines AVPlayer handed over for `time`. AVPlayer repeats a cue it is still showing, so a later
    /// hand-over for the same time replaces the earlier one.
    public mutating func enqueue(_ lines: [String], at time: Double) {
        guard time.isFinite else { return }
        pending.removeAll { $0.time == time }
        pending.append((time, lines))
        pending.sort { $0.time < $1.time }
        // A queue this long means nothing was ever taken: keep the newest, which is what a seek needs.
        if pending.count > 64 { pending.removeFirst(pending.count - 64) }
    }

    /// The lines due at `time`, or nil while the lines on screen are still the latest. Everything that has come
    /// due is dropped, so the next call only reports a later change.
    ///
    /// After a seek, what waited belonged to where the video was, and so does the line on screen: both go (an empty
    /// result clears it). Lines AVPlayer already handed over for the new place stay, since they can arrive before the
    /// clock reports the jump.
    public mutating func lines(at time: Double) -> [String]? {
        guard time.isFinite else { return nil }
        defer { lastTime = time }
        let seeked = lastTime.map { abs(time - $0) > Self.seekStep } ?? false
        if seeked { pending.removeAll { $0.time > time + Self.seekStep || $0.time < time - delay - Self.seekStep } }
        let due = pending.filter { $0.time + delay <= time }
        pending.removeAll { $0.time + delay <= time }
        return due.last?.lines ?? (seeked ? [] : nil)
    }

    /// Forgets what was waiting, for a new item or another track: its times are no longer this playback's.
    public mutating func reset() { pending.removeAll(); lastTime = nil }
}

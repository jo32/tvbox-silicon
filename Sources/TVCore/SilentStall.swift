import Foundation

/// A player waiting for bytes that stopped coming, with nothing failing to say so (#2109). A 4–7 GB drive file showed
/// 努力加载 at 0 bytes/s for 35–80 s at a time on a working network: no chunk finished, retried, timed out or was
/// refused, so neither the stream's own retries nor the failure chain (`PlaybackDropRecovery`, `PlaybackRescue`)
/// ran, and only closing the player and opening the episode again played on. Fed once a second, this says when the
/// wait has gone on `limit` seconds with next to nothing arriving (less than `progress`, so a connection that
/// trickles a byte now and then counts too): the player then opens the episode again where it was.
public struct SilentStall: Sendable, Equatable {
    /// Long enough for a drive that pauses between connections (the stream's request timeout is 20 s, its retries
    /// a few seconds), short of the minute viewers waited before giving up.
    public static let limit: TimeInterval = 25
    /// Bytes that count as coming in again: a fraction of a second of any video worth waiting for.
    public static let progress: Int64 = 64 * 1024

    private var since: TimeInterval?
    private var bytes: Int64 = -1

    public init() {}

    /// Whether the player has waited `limit` seconds for data with almost no bytes arriving: `waiting` while it waits to play
    /// (not paused, not seeking), `received` the bytes the stream has received so far, `now` a monotonic clock in
    /// seconds. True once per stall: the count starts again after it.
    public mutating func update(waiting: Bool, received: Int64, now: TimeInterval) -> Bool {
        guard waiting else { since = nil; bytes = received; return false }
        guard let start = since, received - bytes < Self.progress else {
            since = now; bytes = received
            return false
        }
        guard now - start >= Self.limit else { return false }
        since = nil
        return true
    }

    /// Forgets the wait (a new item, a reopening).
    public mutating func reset() { since = nil; bytes = -1 }
}

import Foundation

/// When an on-demand episode whose connection dropped opens again where it was. A Wi-Fi hand-over or a server that
/// resets the connection ends the item with NSURL -1005, and a few seconds with no segment arriving end it with
/// Core Media -15628 ("No response for media file", -12889). AVPlayer doesn't ask again by itself, where Android
/// players reconnect. The episode opens again a few times, a little later each time, before the error shows.
public struct PlaybackDropRecovery: Sendable {
    /// The waits before each reopening; once they're used up the error shows.
    public static let delays: [Duration] = [.seconds(1), .seconds(3), .seconds(8)]
    /// Playing this many seconds away from the last reopening means the connection came back: a later drop starts
    /// the count again.
    public static let recovered: Double = 60

    public private(set) var attempts = 0
    private var reopenedAt: Double?

    public init() {}

    /// The wait before the episode opens again at `position` after `failure`, or nil when the error should show.
    public mutating func delay(after failure: Error?, position: Double) -> Duration? {
        guard Self.isDrop(failure), position.isFinite else { return nil }
        if let reopenedAt, abs(position - reopenedAt) >= Self.recovered { attempts = 0 }
        guard attempts < Self.delays.count else { return nil }
        reopenedAt = position
        attempts += 1
        return Self.delays[attempts - 1]
    }

    /// The connection dropped, timed out or couldn't be made again, as opposed to a server that refused the link
    /// (HTTP 403/404, which an expired link answers) or media the player can't read.
    public static func isDrop(_ error: Error?) -> Bool {
        var current = error as NSError?
        var dropped = false
        while let error = current {
            switch error.domain {
            case NSURLErrorDomain:
                guard droppedConnection.contains(error.code) else { return false }
                dropped = true
            case "CoreMediaErrorDomain":
                guard stalledMedia.contains(error.code) else { return false }
                dropped = true
            default: break
            }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return dropped
    }

    /// Connection lost, timed out, offline, host unreachable or not found, and a TLS handshake that failed: the
    /// stream had already played over the same connection, so a broken network is the likely cause.
    static let droppedConnection: Set<Int> = [
        NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut, NSURLErrorNotConnectedToInternet,
        NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed,
        NSURLErrorSecureConnectionFailed,
    ]
    /// Core Media's "media load failed" (-15628) and "no response for media file" (-12889).
    static let stalledMedia: Set<Int> = [-15628, -12889]
}

/// Tracks whether playback was already paused when a loopback relisten or drop reconnect started, so reopening the
/// stream restores its position without unpausing a paused player (such as a paused PiP window tucked to the edge of
/// the screen, #1641).
public struct PlaybackRecoveryPause: Sendable, Equatable {
    /// How long playback must have been paused before an error notification to count as paused by the viewer rather
    /// than paused by the error itself: AVPlayer transitions `timeControlStatus` to `.paused` right as it posts
    /// `AVPlayerItemFailedToPlayToEndTime`.
    public static let failureGrace: TimeInterval = 0.5

    /// Whether the current reconnect should leave the player paused once it has restored its position.
    public private(set) var stayPaused = false
    /// Monotonic uptime when `timeControlStatus` last became `.paused`, or nil while playing or buffering.
    private var pausedSince: TimeInterval?

    public init() {}

    /// Records whether `player.timeControlStatus == .paused` at `now` (monotonic uptime in seconds).
    public mutating func update(paused: Bool, at now: TimeInterval) {
        if paused {
            if pausedSince == nil { pausedSince = now }
        } else {
            pausedSince = nil
        }
    }

    /// Call before reopening after a loopback loss or connection drop.
    /// `fromFailure`: true when called from a failure callback (`AVPlayerItemFailedToPlayToEndTime` or item `.failed`),
    /// false when called from `sample()` on a still-live item's error log.
    public mutating func noteReconnect(currentlyPaused: Bool, fromFailure: Bool, at now: TimeInterval) {
        if stayPaused { return }
        guard currentlyPaused else { return }
        if !fromFailure {
            stayPaused = true
        } else if let pausedSince, now - pausedSince >= Self.failureGrace {
            stayPaused = true
        }
    }

    /// Consumes `stayPaused` once the reopened item is ready to play (or stay paused). Returns true when playback
    /// should remain paused instead of calling `player.play()`.
    public mutating func consumeStayPaused() -> Bool {
        defer { stayPaused = false }
        return stayPaused
    }

    /// The viewer explicitly asked to play, or a new playback/stop reset the session.
    public mutating func clear() {
        stayPaused = false
        pausedSince = nil
    }
}

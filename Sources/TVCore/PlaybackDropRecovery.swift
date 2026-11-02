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

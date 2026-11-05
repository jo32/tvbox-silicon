import Foundation

/// When a live room that stopped opens again with a fresh stream address, as the viewer's Try Again would.
///
/// A room's address runs out: Huya's edge servers refuse it with HTTP 403 about two minutes in (error reports put
/// the stop at 124–141 s on every platform), and Douyu's playlists sometimes contradict themselves (CoreMedia
/// -12312) long into a broadcast. A room that played a while before it stopped asks its platform for a new address
/// each time (#488). One that fails sooner gets one new address for a contradicting playlist, which an edge server
/// can send while it starts serving the room, and otherwise shows the error, so a room that can't play doesn't loop.
public struct LiveReopen: Sendable {
    /// Playing this long since the room last opened means its address worked: a failure after it is the address
    /// running out, or the connection dropping, rather than a room that can't play.
    public static let played: Duration = .seconds(20)

    private var contradictionRetried = false

    public init() {}

    /// Whether the room opens again after `failure`, having played for `playedFor` since it last opened (nil: it
    /// never became ready).
    public mutating func shouldReopen(after failure: Error?, playedFor: Duration?) -> Bool {
        if let playedFor, playedFor >= Self.played { return true }
        guard !contradictionRetried, Self.contradicted(failure) else { return false }
        contradictionRetried = true
        return true
    }

    /// A playlist that contradicted an earlier reload of it.
    static func contradicted(_ failure: Error?) -> Bool {
        guard let failure = failure as NSError? else { return false }
        return failure.domain == "CoreMediaErrorDomain" && failure.code == -12312
    }
}

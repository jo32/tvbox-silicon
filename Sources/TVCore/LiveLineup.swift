import Foundation

/// Live channels in the order they were listed (a playlist, or the favorites), to switch between them in the player
/// (#1010).
public struct LiveLineup: Sendable {
    public let title: String
    public let channels: [Channel]
    private let positions: [String: Int]
    public init(title: String, channels: [Channel]) {
        self.title = title
        self.channels = channels
        var positions: [String: Int] = [:]
        for (index, channel) in channels.enumerated() where positions[channel.id] == nil { positions[channel.id] = index }
        self.positions = positions
    }
    public func position(of channel: Channel) -> Int? { positions[channel.id] }
    /// The first of `lists` (a title and its channels) that holds the channel: the playlist a channel found by search
    /// came from, to switch through in the player (#1172).
    public static func first(holding channel: Channel, in lists: [(title: String, channels: [Channel])]) -> LiveLineup? {
        lists.first { $0.channels.contains { $0.id == channel.id } }.map { LiveLineup(title: $0.title, channels: $0.channels) }
    }
    /// The channel before or after, round from the end to the start as a TV's channel buttons go.
    public func neighbor(of channel: Channel, back: Bool) -> Channel? {
        guard channels.count > 1, let at = position(of: channel) else { return nil }
        return channels[(at + (back ? channels.count - 1 : 1)) % channels.count]
    }
}

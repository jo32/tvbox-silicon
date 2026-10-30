import CoreMedia

/// Where a live stream that fell behind its playlist plays from. Huya's and Douyu's playlists list only the last
/// few seconds. A stall longer than that (the connection drops for half a minute, say) resumes where it stopped,
/// before every segment still listed: AVPlayer then reports playing while the picture stays frozen until its clock
/// reaches the segments it fetched after the stall, and from then on it plays that far behind the broadcast.
public enum LiveEdge {
    /// How far before the oldest point it can seek to a live stream may play. AVPlayer itself keeps up to three
    /// target durations from the edge (12 s on Douyu's 4-second segments), which a position this close still is.
    public static let tolerance: Double = 15

    /// The live edge to jump to when `position` lies more than `tolerance` before every seekable range; nil while
    /// the stream plays where it should, or when the ranges don't say.
    public static func target(position: CMTime, seekable: [CMTimeRange]) -> CMTime? {
        guard position.isNumeric, let first = seekable.first, let last = seekable.last,
              first.start.isNumeric, last.end.isNumeric, first.start.seconds - position.seconds > tolerance else { return nil }
        return last.end
    }
}

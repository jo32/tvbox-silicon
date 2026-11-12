import Foundation

/// Which way a scroll over the Mac player goes. Up and down sets the volume (#680); sideways stays with AVKit,
/// which scrubs the video (#874). A trackpad gesture keeps the way it started, through its momentum too, so a
/// swipe that drifts doesn't change the volume halfway.
public struct ScrollAxisLock: Sendable {
    public enum Axis: Sendable { case vertical, horizontal }
    private var locked: Axis?

    public init() {}

    /// `tracked`: the event is part of a trackpad gesture (it has a phase; a mouse wheel's has none), and `starts`
    /// is that gesture's first event. nil while a gesture hasn't moved yet.
    public mutating func axis(dx: Double, dy: Double, starts: Bool, tracked: Bool) -> Axis? {
        if starts || !tracked { locked = nil }
        if let locked { return locked }
        guard dx != 0 || dy != 0 else { return nil }
        let axis: Axis = abs(dx) > abs(dy) ? .horizontal : .vertical
        if tracked { locked = axis }
        return axis
    }
}

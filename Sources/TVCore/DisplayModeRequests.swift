import Foundation

/// The displays a player asked for a mode on, and who asked last on each (an Apple TV's `AVDisplayManager`, one per
/// window), so that leaving the video gives every one of them back (#2691). The TV stayed at the film's 24 or 25 Hz
/// after the player closed, and the app's pages stuttered: the mode was taken back on the window the closing player
/// was in, which it had already left, so on none.
public struct DisplayModeRequests<Display: AnyObject> {
    private var asked: [(display: Display, owner: ObjectIdentifier)] = []

    public init() {}

    /// The displays with a mode asked for.
    public var displays: [Display] { asked.map(\.display) }

    /// `owner` asked for a mode on `display`, or (`nil` mode) took it back.
    public mutating func record(_ display: Display, by owner: ObjectIdentifier, asking: Bool) {
        asked.removeAll { $0.display === display }
        if asking { asked.append((display, owner)) }
    }

    /// Whether `owner` asked last on `display`: a player view that goes away takes back only its own mode, not one a
    /// newer player view (or the HDR switch) asked for since.
    public func owns(_ display: Display, _ owner: ObjectIdentifier) -> Bool {
        asked.contains { $0.display === display && $0.owner == owner }
    }

    /// The player closed: every display a mode was asked for on, then those `showing` now (where AVKit may have asked
    /// by itself), each once. They are all forgotten.
    public mutating func release(showing: [Display]) -> [Display] {
        var all = asked.map(\.display)
        for display in showing where !all.contains(where: { $0 === display }) { all.append(display) }
        asked = []
        return all
    }
}

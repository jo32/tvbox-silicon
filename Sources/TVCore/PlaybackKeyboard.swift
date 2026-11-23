/// The iPad player's hardware keys. Keep key repeats and the right-arrow hold independent of UI focus and timers.
public struct PlaybackKeyboard: Sendable {
    public enum Key: Hashable, Sendable { case space, left, right, up, down, mute }
    public enum Phase: Equatable, Sendable { case down, repeated, up }
    public enum Action: Equatable, Sendable {
        case playPause, seek(Double), volume(Double), mute, waitForHold, beginBoost, endBoost
    }

    private var pressed: Set<Key> = []
    private var arrow = KeyHold()
    private var shiftedRight = false

    public init() {}

    public mutating func handle(_ key: Key, phase: Phase, shift: Bool = false) -> [Action] {
        if phase == .up {
            guard pressed.remove(key) != nil, key == .right else { return [] }
            shiftedRight = false
            switch arrow.release() {
            case .tap: return [.seek(10)]
            case .held: return [.endBoost]
            case .stray: return []
            }
        }
        if phase == .down {
            guard pressed.insert(key).inserted else { return [] }
        } else if !pressed.contains(key) {
            // Focus may have arrived while the key was already held elsewhere.
            return []
        }
        switch key {
        case .space: return phase == .down ? [.playPause] : []
        case .mute: return phase == .down ? [.mute] : []
        case .left: return [.seek(shift ? -60 : -10)]
        case .up: return [.volume(0.05)]
        case .down: return [.volume(-0.05)]
        case .right:
            if phase == .down { shiftedRight = shift }
            if shiftedRight { return [.seek(60)] }
            return arrow.press(repeated: phase == .repeated) ? [.waitForHold] : []
        }
    }

    public mutating func held() -> [Action] { arrow.wait() ? [.beginBoost] : [] }

    /// Losing focus, opening a sheet, locking, pausing or replacing the video must never leave a boost running or seek.
    public mutating func cancel() -> [Action] {
        pressed.removeAll()
        shiftedRight = false
        return arrow.release() == .held ? [.endBoost] : []
    }
}

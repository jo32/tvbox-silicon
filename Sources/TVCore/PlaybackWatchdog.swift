import Foundation

/// Detects a stalled player and reports it in time to switch lines, plus records the four
/// timestamps that make "why was it slow" answerable.
///
/// Both come from One (`com.ios151.one`), which keeps `stallWatchdog`, `hlsWatchdog`, `playToken`,
/// `epoch`, `advancingEpoch` and the four marks `tStart` / `tResolved` / `tReady` / `tFirst`.
/// The two ideas are worth copying separately from One's closed API:
///
/// * A player that stops making progress is not the same as one that failed. Without a watchdog it
///   just sits there, and the user blames the app rather than the line. A watchdog turns silence
///   into a decision.
/// * Four timestamps split one number the user feels ("it takes ages") into three the code can act
///   on: resolution, buffering, and start-up.
///
/// Framework-free, so it works with AVPlayer, an HLS proxy, or a bare byte stream.

// MARK: - 时间戳

/// The four marks of one playback attempt. `nil` means that stage has not happened yet, which is
/// itself information: a session with `resolved` but no `ready` timed out while buffering.
public struct PlaybackMarks: Codable, Equatable, Sendable {
    /// The user asked to play.
    public var started: Date?
    /// The URL (or manifest) came back from the source.
    public var resolved: Date?
    /// The player reports it is ready to play.
    public var ready: Date?
    /// The first frame was actually shown — the only mark the user cares about.
    public var firstFrame: Date?

    public init(started: Date? = nil, resolved: Date? = nil, ready: Date? = nil, firstFrame: Date? = nil) {
        self.started = started; self.resolved = resolved; self.ready = ready; self.firstFrame = firstFrame
    }

    /// Click → first frame. The headline number.
    public var timeToFirstFrame: TimeInterval? { span(from: started, to: firstFrame) }
    /// Time the source took to produce a playable URL.
    public var resolutionLatency: TimeInterval? { span(from: started, to: resolved) }
    /// Time spent buffering after a URL existed.
    public var bufferingLatency: TimeInterval? { span(from: resolved, to: firstFrame) }
    /// Time from "player ready" to "picture".
    public var startLatency: TimeInterval? { span(from: ready, to: firstFrame) }

    /// Which stage the attempt stopped at, when it never reached a first frame.
    public var stalledAt: Stage? {
        if firstFrame != nil { return nil }
        if ready != nil { return .firstFrame }
        if resolved != nil { return .ready }
        if started != nil { return .resolution }
        return .start
    }

    public enum Stage: String, Codable, Sendable {
        case start, resolution, ready, firstFrame
    }

    private func span(from: Date?, to: Date?) -> TimeInterval? {
        guard let from, let to else { return nil }
        return max(0, to.timeIntervalSince(from))
    }
}

// MARK: - 卡顿看门狗

/// Watches for absence of progress, not for errors.
///
/// The distinction matters: `AVPlayer` reports `.waitingToPlayAtSpecifiedRate` and then nothing at
/// all, so an app that only handles `failed` never learns the stream died. This watchdog is driven
/// by whatever the app already observes — a periodic time observer, a byte counter, a manifest
/// reload — and asks one question: has the position moved within the allowance?
public final class StallWatchdog: @unchecked Sendable {
    public struct Policy: Sendable {
        /// How long the position may stay put before a stall is declared.
        public var allowance: TimeInterval
        /// Give up after this many declared stalls and report the line as bad.
        public var strikes: Int
        public init(allowance: TimeInterval = 6, strikes: Int = 2) {
            self.allowance = allowance; self.strikes = strikes
        }
    }

    public enum Judgement: Equatable, Sendable {
        /// Position moved; nothing to do.
        case fine
        /// No movement yet, but still inside the allowance.
        case quiet(remaining: TimeInterval)
        /// No movement for longer than the allowance. The caller should nudge or switch.
        case stalled(seconds: TimeInterval)
        /// The policy's strike count is used up. The caller should treat the line as unusable.
        case exhausted(seconds: TimeInterval)
    }

    public private(set) var policy: Policy
    private let lock = NSLock()
    private var lastPosition: Double = -1
    private var lastProgressAt: Date
    private var strikeCount = 0
    private var suspended = false

    public init(policy: Policy = Policy(), now: Date = Date()) {
        self.policy = policy
        self.lastProgressAt = now
    }

    /// Reports the current playback position. Call it from the player's periodic observer — once a
    /// second is generous; the watchdog measures elapsed silence, not call frequency.
    public func report(position: Double, now: Date = Date()) -> Judgement {
        lock.lock(); defer { lock.unlock() }
        guard !suspended else { return .fine }
        // A seek backwards is progress too; any change counts.
        if abs(position - lastPosition) > 0.001 {
            lastPosition = position
            lastProgressAt = now
            strikeCount = 0
            return .fine
        }
        let silent = now.timeIntervalSince(lastProgressAt)
        if silent < policy.allowance { return .quiet(remaining: policy.allowance - silent) }
        strikeCount += 1
        // Reset the clock so the next judgement needs another full allowance, not an immediate one.
        lastProgressAt = now
        if strikeCount >= policy.strikes { return .exhausted(seconds: silent) }
        return .stalled(seconds: silent)
    }

    /// Pauses the countdown, for a user-initiated pause where silence is expected.
    public func suspend(now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        suspended = true
        lastProgressAt = now
    }

    /// Resumes after `suspend`, without counting the paused span as a stall.
    public func resume(now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        suspended = false
        lastProgressAt = now
        strikeCount = 0
    }

    /// Restarts for a new attempt on the same or another line.
    public func reset(now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        lastPosition = -1
        lastProgressAt = now
        strikeCount = 0
        suspended = false
    }

    public var strikes: Int { lock.lock(); defer { lock.unlock() }; return strikeCount }
}

// MARK: - 世代号

/// A two-number generation, so a late callback from an abandoned line cannot touch the live one.
///
/// One keeps `epoch` and `advancingEpoch` separately, and the split is the point: `epoch` names the
/// session a callback belongs to, `advancingEpoch` names the one being set up. A result tagged with
/// the previous `epoch` is dropped; a result tagged with `advancingEpoch` is accepted only once the
/// switch completes. A single counter cannot express "in transition", which is exactly when stale
/// callbacks arrive.
public struct PlaybackEpoch: Equatable, Sendable {
    /// The line currently on screen.
    public private(set) var current: Int
    /// The line being prepared, when a switch is in flight.
    public private(set) var advancing: Int?

    public init(current: Int = 0) { self.current = current }

    /// Begins a switch. Returns the token the new attempt must carry.
    @discardableResult
    public mutating func beginAdvance() -> Int {
        let next = (advancing ?? current) + 1
        advancing = next
        return next
    }

    /// Completes the switch. Returns false when `token` is no longer the one being advanced, which
    /// means another switch started in between and this result is stale.
    @discardableResult
    public mutating func commit(token: Int) -> Bool {
        guard advancing == token else { return false }
        current = token
        advancing = nil
        return true
    }

    /// Abandons the in-flight switch and keeps the current line.
    public mutating func cancelAdvance() { advancing = nil }

    /// Whether a result carrying `token` may be applied to what is on screen.
    public func accepts(token: Int) -> Bool { token == current }

    /// Whether a result carrying `token` belongs to the switch in progress.
    public func isAdvancing(token: Int) -> Bool { token == advancing }
}

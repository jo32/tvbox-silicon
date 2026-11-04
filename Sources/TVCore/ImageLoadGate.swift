import Foundation

/// Decides which image requests may proceed while a list is moving.
///
/// The problem this solves is specific and easy to observe: a scrolling list asks for every poster
/// that crosses the viewport, and each request decodes a full image. Decoding competes with the
/// scroll itself, so a fast fling stutters — not because the images are big, but because too many
/// of them decode at once. One (`com.ios151.one`) caps this with `smoothScrollMaxImages`; this type
/// is the same idea with the policy exposed.
///
/// Two budgets, not one:
///
/// * While the list is still, everything requested may load. A still screen has nothing to
///   compete with.
/// * While it moves, only a few decodes run at once, and requests beyond that wait rather than
///   being dropped. Dropping would leave holes; waiting costs nothing because the user is moving
///   past them anyway.
///
/// Framework-free: no SwiftUI, no UIKit. A view reports whether it is scrolling and asks for a
/// slot; the gate answers and later learns how the request turned out.
public final class ImageLoadGate: @unchecked Sendable {

    public struct Policy: Sendable {
        /// Decodes allowed at once while the list is still.
        public var idleLimit: Int
        /// Decodes allowed at once while the list is moving. Keep it small: this is the number that
        /// decides whether a fling is smooth.
        public var scrollingLimit: Int
        public init(idleLimit: Int = 8, scrollingLimit: Int = 2) {
            self.idleLimit = max(1, idleLimit)
            self.scrollingLimit = max(1, scrollingLimit)
        }
    }

    private let lock = NSLock()
    private var policy: Policy
    private var scrolling = false
    private var inFlight = 0
    /// Requests waiting for a slot, oldest first. Waiting is bounded by `maxWaiters`; past that a
    /// caller is told to skip rather than queue, because an unbounded queue turns a fast fling into
    /// a long tail of work for images already off screen.
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public var maxWaiters = 48

    /// Counters, for a diagnostics panel.
    public private(set) var admitted = 0
    public private(set) var skipped = 0
    public private(set) var queued = 0

    public init(policy: Policy = Policy()) { self.policy = policy }

    /// The budget in force right now.
    public var currentLimit: Int {
        lock.lock(); defer { lock.unlock() }
        return scrolling ? policy.scrollingLimit : policy.idleLimit
    }

    public var isScrolling: Bool { lock.lock(); defer { lock.unlock() }; return scrolling }

    /// How many decodes are running.
    public var running: Int { lock.lock(); defer { lock.unlock() }; return inFlight }

    /// Reports whether a list is moving. Raising the limit when the list stops releases waiters, so
    /// the images the user is now looking at load immediately.
    public func setScrolling(_ value: Bool) {
        lock.lock()
        let was = scrolling
        scrolling = value
        let limit = value ? policy.scrollingLimit : policy.idleLimit
        // Stopping frees budget for everyone queued.
        if !value && !was { lock.unlock(); return }
        var granted: [CheckedContinuation<Void, Never>] = []
        while inFlight < limit, !waiters.isEmpty {
            granted.append(waiters.removeFirst())
            inFlight += 1
        }
        lock.unlock()
        for continuation in granted { continuation.resume() }
    }

    /// Asks for permission to decode one image.
    ///
    /// - Returns: `true` when the caller may decode now and must call `finish()` when done.
    ///   `false` when the gate is at capacity and its queue is full — the caller should not load
    ///   this image at all; it will be asked again if it scrolls back into view.
    public func begin() async -> Bool {
        switch claim() {
        case .granted:
            return true
        case .refused:
            return false
        case .queue:
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                enqueue(continuation)
            }
            return true
        }
    }

    private enum Claim { case granted, refused, queue }

    /// Synchronous half of `begin()`: the lock never crosses an `await`.
    private func claim() -> Claim {
        lock.lock(); defer { lock.unlock() }
        let limit = scrolling ? policy.scrollingLimit : policy.idleLimit
        if inFlight < limit {
            inFlight += 1
            admitted += 1
            return .granted
        }
        if waiters.count >= maxWaiters {
            skipped += 1
            return .refused
        }
        queued += 1
        return .queue
    }

    /// Second half: either takes a slot that opened in the meantime, or parks the continuation.
    private func enqueue(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        let limit = scrolling ? policy.scrollingLimit : policy.idleLimit
        if inFlight < limit {
            inFlight += 1
            admitted += 1
            lock.unlock()
            continuation.resume()
            return
        }
        waiters.append(continuation)
        lock.unlock()
    }

    /// Releases the slot taken by `begin()`. Every `true` from `begin()` needs exactly one call.
    public func finish() {
        lock.lock()
        inFlight = max(0, inFlight - 1)
        let limit = scrolling ? policy.scrollingLimit : policy.idleLimit
        if inFlight < limit, !waiters.isEmpty {
            let continuation = waiters.removeFirst()
            inFlight += 1
            lock.unlock()
            continuation.resume()
            return
        }
        lock.unlock()
    }

    /// Drops every waiter, for a list that went away. Callers already waiting are resumed and will
    /// find the gate open; they may then load an image nobody needs, so use it only when the list is
    /// being torn down.
    public func cancelAll() {
        lock.lock()
        let dropped = waiters
        waiters.removeAll()
        lock.unlock()
        for continuation in dropped { continuation.resume() }
    }

    /// Resets the counters, for a diagnostics panel opening fresh.
    public func resetCounters() {
        lock.lock()
        admitted = 0; skipped = 0; queued = 0
        lock.unlock()
    }

    public func update(policy newPolicy: Policy) {
        lock.lock()
        policy = newPolicy
        let limit = scrolling ? newPolicy.scrollingLimit : newPolicy.idleLimit
        var granted: [CheckedContinuation<Void, Never>] = []
        while inFlight < limit, !waiters.isEmpty {
            granted.append(waiters.removeFirst())
            inFlight += 1
        }
        lock.unlock()
        for continuation in granted { continuation.resume() }
    }
}

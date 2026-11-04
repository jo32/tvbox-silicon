import Foundation

/// A host pool that rotates with backoff, learns which hosts actually work, and caps how many
/// probes may run at once.
///
/// This is the part of One (`com.ios151.one`) worth copying. One keeps five pieces of state around
/// its host lists — a preferred index, an `avoidUntil` deadline per base, the last attempt and the
/// last self-heal time, and an in-flight counter — and the effect is that a line which just failed
/// is skipped rather than retried, while a line that has been working keeps being preferred. It
/// also remembers which image hosts answered (`learnedImageHosts`), so a CDN that worked once is
/// tried first next time.
///
/// Deliberately framework-free: no 映匣 types, no URLSession, no UI. A caller supplies whatever
/// clock and jitter it wants, so this can be dropped into a probe runner, a downloader, or a
/// server-side job without dragging an app along.
public struct HostRotation: Sendable {

    /// What the rotator remembers about one host.
    public struct HostState: Codable, Equatable, Sendable {
        /// How many times in a row this host failed. Reset to 0 on success.
        public var consecutiveFailures = 0
        /// Do not try this host again before this instant.
        public var avoidUntil: Date?
        /// Last time this host was tried at all.
        public var lastAttempt: Date?
        /// Last time a failure on this host was followed by a success elsewhere, i.e. the rotator
        /// healed itself rather than the host coming back on its own.
        public var lastHeal: Date?
        /// Requests currently in flight to this host.
        public var inflight = 0
        /// Observed successful uses, used as a tie-breaker when two hosts look equally good.
        public var successes = 0
        public init() {}
    }

    /// Backoff policy. `base` is the first delay; each further consecutive failure doubles it up to
    /// `cap`. Jitter is a fraction of the computed delay, spread either way, so a fleet of clients
    /// that all failed at once does not retry in lockstep.
    public struct Backoff: Sendable {
        public var base: TimeInterval = 5
        public var cap: TimeInterval = 300
        public var jitter: Double = 0.25
        public init(base: TimeInterval = 5, cap: TimeInterval = 300, jitter: Double = 0.25) {
            self.base = base; self.cap = cap; self.jitter = jitter
        }
        /// The delay before attempt number `failures` (1-based) may be retried.
        public func delay(afterFailures failures: Int, random: inout some RandomNumberGenerator) -> TimeInterval {
            guard failures > 0 else { return 0 }
            let exponent = min(failures - 1, 20)
            let raw = min(cap, base * pow(2, Double(exponent)))
            guard jitter > 0 else { return raw }
            let spread = raw * jitter
            return max(0, raw + Double.random(in: -spread...spread, using: &random))
        }
        /// Deterministic variant, for tests and for callers that keep their own seed.
        public func delay(afterFailures failures: Int) -> TimeInterval {
            guard failures > 0 else { return 0 }
            let exponent = min(failures - 1, 20)
            return min(cap, base * pow(2, Double(exponent)))
        }
    }

    /// How many probes may be in flight at once. One caps this itself; exceeding it is what makes a
    /// slow line look unreachable, because every probe times out behind a queue.
    public var maxConcurrent: Int
    public var backoff: Backoff
    private(set) public var hosts: [String]
    private(set) public var states: [String: HostState]
    /// The host a caller should try first, before any health signal exists.
    private(set) public var preferred: String?

    public init(hosts: [String] = [], preferred: String? = nil,
                maxConcurrent: Int = 4, backoff: Backoff = Backoff()) {
        self.hosts = hosts
        self.preferred = preferred
        self.maxConcurrent = max(1, maxConcurrent)
        self.backoff = backoff
        self.states = Dictionary(uniqueKeysWithValues: hosts.map { ($0, HostState()) })
    }

    // MARK: - 查询

    /// Hosts that may be tried right now: not in an avoid window, and not saturated.
    /// The preferred host is hoisted to the front when it qualifies.
    public func available(now: Date = Date()) -> [String] {
        let eligible = hosts.filter { host in
            guard let state = states[host] else { return true }
            if let until = state.avoidUntil, until > now { return false }
            return state.inflight < maxConcurrent
        }
        guard let preferred, eligible.contains(preferred) else { return eligible }
        return [preferred] + eligible.filter { $0 != preferred }
    }

    /// Hosts sorted by observed health: fewer failures first, then more successes, then the
    /// caller's original order. Unavailable hosts are still listed, at the end.
    public func ranked(now: Date = Date()) -> [String] {
        let order = Dictionary(uniqueKeysWithValues: hosts.enumerated().map { ($1, $0) })
        let usable = Set(available(now: now))
        return hosts.sorted { left, right in
            let l = states[left] ?? HostState(), r = states[right] ?? HostState()
            let lUsable = usable.contains(left), rUsable = usable.contains(right)
            if lUsable != rUsable { return lUsable }
            if l.consecutiveFailures != r.consecutiveFailures { return l.consecutiveFailures < r.consecutiveFailures }
            if l.successes != r.successes { return l.successes > r.successes }
            return (order[left] ?? 0) < (order[right] ?? 0)
        }
    }

    /// Whether every host is currently in an avoid window — the state that should surface to a user
    /// as "all lines are cooling down" rather than "no playable address".
    public func allCoolingDown(now: Date = Date()) -> Bool {
        !hosts.isEmpty && hosts.allSatisfy { host in
            guard let until = states[host]?.avoidUntil else { return false }
            return until > now
        }
    }

    // MARK: - 状态迁移

    /// Claims a host for one attempt. Returns nil when nothing is available, which a caller must
    /// treat as "back off", not "not found".
    public mutating func begin(_ host: String, now: Date = Date()) -> Bool {
        guard hosts.contains(host) else { return false }
        var state = states[host] ?? HostState()
        if let until = state.avoidUntil, until > now { return false }
        guard state.inflight < maxConcurrent else { return false }
        state.inflight += 1
        state.lastAttempt = now
        states[host] = state
        return true
    }

    /// Records a success: clears the failure streak and the avoid window, and promotes the host.
    public mutating func succeed(_ host: String, now: Date = Date()) {
        guard var state = states[host] else { return }
        state.inflight = max(0, state.inflight - 1)
        if state.consecutiveFailures > 0 { state.lastHeal = now }
        state.consecutiveFailures = 0
        state.avoidUntil = nil
        state.successes += 1
        states[host] = state
        preferred = host
    }

    /// Records a failure and schedules the next attempt. Returns the instant the host becomes
    /// available again, for logging or for a UI countdown.
    @discardableResult
    public mutating func fail(_ host: String, now: Date = Date(),
                             random: inout some RandomNumberGenerator) -> Date? {
        guard var state = states[host] else { return nil }
        state.inflight = max(0, state.inflight - 1)
        state.consecutiveFailures += 1
        let delay = backoff.delay(afterFailures: state.consecutiveFailures, random: &random)
        let until = now.addingTimeInterval(delay)
        state.avoidUntil = until
        states[host] = state
        if preferred == host { preferred = nil }
        return until
    }

    /// Deterministic `fail`, for callers without a generator handy.
    @discardableResult
    public mutating func fail(_ host: String, now: Date) -> Date? {
        var generator = SystemRandomNumberGenerator()
        return fail(host, now: now, random: &generator)
    }

    /// Releases an in-flight slot without recording success or failure, for a cancelled attempt.
    public mutating func cancel(_ host: String) {
        guard var state = states[host] else { return }
        state.inflight = max(0, state.inflight - 1)
        states[host] = state
    }

    /// Replaces the host list, keeping the state of hosts that survive the change.
    public mutating func replace(hosts newHosts: [String], preferred newPreferred: String? = nil) {
        let carried = states
        hosts = newHosts
        states = Dictionary(uniqueKeysWithValues: newHosts.map { ($0, carried[$0] ?? HostState()) })
        preferred = newPreferred.flatMap { newHosts.contains($0) ? $0 : nil }
    }
}

extension HostRotation: Codable {
    private enum CodingKeys: String, CodingKey { case maxConcurrent, hosts, states, preferred, backoffBase, backoffCap, backoffJitter }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = try c.decodeIfPresent(TimeInterval.self, forKey: .backoffBase) ?? 5
        let cap = try c.decodeIfPresent(TimeInterval.self, forKey: .backoffCap) ?? 300
        let jitter = try c.decodeIfPresent(Double.self, forKey: .backoffJitter) ?? 0.25
        self.init(hosts: try c.decodeIfPresent([String].self, forKey: .hosts) ?? [],
                  preferred: try c.decodeIfPresent(String.self, forKey: .preferred),
                  maxConcurrent: try c.decodeIfPresent(Int.self, forKey: .maxConcurrent) ?? 4,
                  backoff: Backoff(base: base, cap: cap, jitter: jitter))
        if let decoded = try c.decodeIfPresent([String: HostState].self, forKey: .states) {
            states = Dictionary(uniqueKeysWithValues: hosts.map { ($0, decoded[$0] ?? HostState()) })
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(maxConcurrent, forKey: .maxConcurrent)
        try c.encode(hosts, forKey: .hosts)
        try c.encode(states, forKey: .states)
        try c.encodeIfPresent(preferred, forKey: .preferred)
        try c.encode(backoff.base, forKey: .backoffBase)
        try c.encode(backoff.cap, forKey: .backoffCap)
        try c.encode(backoff.jitter, forKey: .backoffJitter)
    }
}

/// Remembers which hosts answered, so a host that worked once is tried before one that never did.
/// One keeps this as `learnedImageHosts` / `preferredImageHost` / `imageHostCache`; the mechanism is
/// general, so it is exposed on its own rather than folded into `HostRotation`.
public struct HostLearning: Codable, Equatable, Sendable {
    /// Hosts that have answered at least once, with the last time they did.
    public private(set) var learned: [String: Date] = [:]
    /// The host to try first.
    public private(set) var preferred: String?
    /// Hosts that have never answered, with the reason they were rejected.
    public private(set) var rejected: [String: String] = [:]
    /// How long a learned host stays preferred after its last success.
    public var trustWindow: TimeInterval = 3600

    public init() {}

    /// Records a host that answered.
    public mutating func learn(_ host: String, at date: Date = Date()) {
        learned[host] = date
        rejected[host] = nil
        preferred = host
    }

    /// Records a host that did not answer, with a short reason for diagnostics.
    public mutating func reject(_ host: String, reason: String, at date: Date = Date()) {
        learned[host] = nil
        rejected[host] = reason
        if preferred == host { preferred = nil }
    }

    /// The host to try first, when the remembered one is still inside its trust window.
    public func firstChoice(now: Date = Date()) -> String? {
        guard let preferred, let at = learned[preferred] else { return nil }
        return now.timeIntervalSince(at) <= trustWindow ? preferred : nil
    }

    /// Reorders `hosts` so learned-good ones come first, keeping the caller's order inside each tier.
    public func prefer(_ hosts: [String], now: Date = Date()) -> [String] {
        let first = firstChoice(now: now)
        let good = hosts.filter { $0 != first && learned[$0] != nil }
        let unknown = hosts.filter { learned[$0] == nil && rejected[$0] == nil }
        let bad = hosts.filter { rejected[$0] != nil }
        return (first.map { [$0] } ?? []) + good + unknown + bad
    }
}

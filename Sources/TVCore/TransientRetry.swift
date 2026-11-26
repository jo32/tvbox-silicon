import Foundation

/// How the readers behind the player (`CloudByteStream`, `StreamingRemuxSource`, `RemuxSession`) treat a failed
/// request: a dropped or timed-out connection and a server's passing error are tried again a little later, a refused
/// link is resolved again, and anything else fails at once. Retries back off and stop after a few, so a dead link
/// costs seconds, not a storm of requests: one install asked a dead loopback proxy for the same bytes ~100 times a
/// minute (`read offset=… error=-1004`, 3,928 reports in a week).
public enum TransientRetry {
    /// URL errors that a moment later may not happen again.
    static let transientURLCodes: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet, .dnsLookupFailed,
        .cannotFindHost, .resourceUnavailable, .internationalRoamingOff, .callIsActive, .dataNotAllowed,
        .secureConnectionFailed, .badServerResponse,
    ]
    /// HTTP answers a server gives while it is busy or a gateway behind it is.
    static let transientStatuses: Set<Int> = [408, 425, 429, 500, 502, 503, 504, 520, 521, 522, 523, 524]
    /// HTTP answers to a link that expired or that the drive no longer serves.
    static let expiredStatuses: Set<Int> = [401, 403, 404, 410]

    /// Whether `error`, or the error under it, is worth trying again later as it is.
    public static func isTransient(_ error: Error) -> Bool {
        if let status = status(error) { return transientStatuses.contains(status) }
        if let code = urlCode(error) { return transientURLCodes.contains(code) }
        return false
    }

    /// Whether `error` says the link itself is refused: only a fresh one helps.
    public static func isExpired(_ error: Error) -> Bool { status(error).map(expiredStatuses.contains) ?? false }

    /// The HTTP status a `TVError.http` carries.
    static func status(_ error: Error) -> Int? {
        if case .http(let status)? = error as? TVError { return status }
        return nil
    }

    /// The URL error code of `error` or of an error under it.
    static func urlCode(_ error: Error) -> URLError.Code? {
        if let error = error as? URLError { return error.code }
        var current: NSError? = error as NSError
        while let error = current {
            if error.domain == NSURLErrorDomain { return URLError.Code(rawValue: error.code) }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return nil
    }

    /// Whether `error` is the reader giving up on purpose (a seek, a closed player).
    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || urlCode(error) == .cancelled
    }
}

/// Waits that grow with each failure in a row: `base`, twice that, and so on up to `ceiling`; nil once `attempts`
/// failures have happened. A success starts it over.
public struct Backoff: Sendable, Equatable {
    public var base: Double
    public var ceiling: Double
    public var attempts: Int
    public private(set) var failures = 0

    public init(base: Double, ceiling: Double, attempts: Int) {
        self.base = base; self.ceiling = ceiling; self.attempts = attempts
    }

    /// The wait before trying again after one more failure, or nil when no more tries are left.
    public mutating func next() -> Double? {
        failures += 1
        guard failures <= attempts else { return nil }
        return min(ceiling, base * pow(2, Double(failures - 1)))
    }

    /// The wait the next failure would get, without counting it.
    public var upcoming: Double { min(ceiling, base * pow(2, Double(failures))) }

    public mutating func reset() { failures = 0 }
}

/// A run of failures of the same reader, so a failing stream is reported once with how often it failed, rather than
/// once per failed read; and so the reader waits before asking again once it failed several times in a row
/// (`cooldown`), instead of letting the player ask for the same bytes as fast as it can.
public struct FailureStreak: Sendable {
    /// Failures in a row after which a failed read waits before the next one.
    public let threshold: Int
    public private(set) var count = 0
    public private(set) var reported = 0
    private var backoff: Backoff

    public init(threshold: Int = 3, base: Double = 1, ceiling: Double = 15) {
        self.threshold = threshold
        backoff = Backoff(base: base, ceiling: ceiling, attempts: .max)
    }

    /// Counts a failure. `report` says whether to log it: the first of a run, then the 10th, 100th...
    /// `wait` is how long to hold the next read off.
    public mutating func fail() -> (report: Bool, wait: Double) {
        count += 1
        let report = count == 1 || count == 10 || count == 100 || count % 1000 == 0
        if report { reported = count }
        guard count >= threshold, let wait = backoff.next() else { return (report, 0) }
        return (report, wait)
    }

    /// A read succeeded: the run is over. Returns its length when it was longer than one.
    public mutating func succeed() -> Int? {
        defer { count = 0; reported = 0; backoff.reset() }
        return count > 1 ? count : nil
    }
}

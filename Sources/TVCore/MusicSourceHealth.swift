import Foundation

/// How each music channel has been answering, by provider, catalog and operation, so a search
/// failing says nothing about playback. A channel that fails for its own reasons cools down,
/// starting at a minute; a song a channel simply lacks, the viewer cancelling, or this device
/// being offline never count. Also keeps each service's request budget (GD Studio allows 50
/// requests per 5 minutes) across search and resolution.
public actor MusicHealth {
    public static let shared = MusicHealth(file: URL.cachesDirectory.appending(path: "music-health.json"))

    public enum Operation: String, Codable, Sendable { case search, resolve, play }

    struct Record: Codable, Equatable {
        var failures = 0
        var lastSuccess: Date?
        var lastFailure: Date?
        var cooldownUntil: Date?
    }
    struct Saved: Codable {
        var records: [String: Record]
        var requests: [String: [Date]]
    }

    /// The first cooldown; each further failure doubles it, up to `longestCooldown`.
    static let firstCooldown: TimeInterval = 60
    static let longestCooldown: TimeInterval = 30 * 60
    /// Risk control on the provider's upstream account rarely clears within minutes.
    static let riskCooldown: TimeInterval = 10 * 60
    /// Requests allowed per service in `window`; services not listed are unlimited here.
    /// Xinghai sets no number, only an overall limit and a request not to overuse it.
    /// LX Music sources are third-party scripts with services of their own: at most one lookup every few seconds.
    static let budgets: [String: Int] = ["gdstudio": 50, "xinghai": 30, "lx": 60]
    static let window: TimeInterval = 5 * 60

    private var records: [String: Record] = [:]
    private var requests: [String: [Date]] = [:]
    private let file: URL?
    private var saveTask: Task<Void, Never>?

    public init(file: URL?) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            records = saved.records; requests = saved.requests
        }
    }

    public static func key(_ provider: String, _ platform: MusicPlatform, _ operation: Operation) -> String {
        provider + "|" + platform.rawValue + "|" + operation.rawValue
    }

    /// When the channel may be asked again; nil when it may now. After a cooldown one request
    /// probes it, and a failure starts a longer cooldown.
    public func coolingUntil(_ key: String, now: Date = Date()) -> Date? {
        guard let until = records[key]?.cooldownUntil, until > now else { return nil }
        return until
    }

    public func failing(_ key: String, now: Date = Date()) -> Bool { coolingUntil(key, now: now) != nil }

    /// Records an answer: `error` nil for success.
    public func record(_ key: String, error: MusicProviderError?, now: Date = Date()) {
        var record = records[key] ?? Record()
        guard let error else {
            record.failures = 0; record.cooldownUntil = nil; record.lastSuccess = now
            records[key] = record; scheduleSave(); return
        }
        guard error.countsAgainstChannel else { return }
        record.failures += 1; record.lastFailure = now
        let doubling = min(Self.longestCooldown, Self.firstCooldown * pow(2, Double(record.failures - 1)))
        switch error {
        case .rateLimited(let until):
            record.cooldownUntil = max(until ?? now.addingTimeInterval(doubling), now.addingTimeInterval(Self.firstCooldown))
        case .upstreamRisk:
            record.cooldownUntil = now.addingTimeInterval(max(Self.riskCooldown, doubling))
        default:
            // A single timeout or bad answer is noted; the second in a row starts the cooldown.
            if record.failures >= 2 { record.cooldownUntil = now.addingTimeInterval(doubling) }
        }
        records[key] = record
        scheduleSave()
    }

    /// Takes one request from a service's budget, or throws `rateLimited` with when the oldest
    /// request in the window leaves it. Counted before sending, so a burst cannot overshoot.
    public func admit(_ service: String, now: Date = Date()) throws(MusicProviderError) {
        guard let limit = Self.budgets[service] else { return }
        var recent = (requests[service] ?? []).filter { now.timeIntervalSince($0) < Self.window }
        guard recent.count < limit else {
            requests[service] = recent
            throw .rateLimited(until: recent.min().map { $0.addingTimeInterval(Self.window) })
        }
        recent.append(now)
        requests[service] = recent
        scheduleSave()
    }

    /// Requests left in a service's window, for diagnostics.
    public func remaining(_ service: String, now: Date = Date()) -> Int? {
        guard let limit = Self.budgets[service] else { return nil }
        return limit - (requests[service] ?? []).filter { now.timeIntervalSince($0) < Self.window }.count
    }

    private func scheduleSave() {
        guard let file, saveTask == nil else { return }
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            self.save(to: file)
        }
    }

    private func save(to file: URL) {
        saveTask = nil
        let now = Date()
        let kept = records.filter { _, record in
            [record.lastSuccess, record.lastFailure, record.cooldownUntil].contains { now.timeIntervalSince($0 ?? .distantPast) < 86400 }
        }
        let recent = requests.mapValues { $0.filter { now.timeIntervalSince($0) < Self.window } }
        guard let data = try? JSONEncoder().encode(Saved(records: kept, requests: recent)) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

import Foundation
import Observation

/// How each source has been answering lately. Search leaves a failing source out, and the source
/// lists mark it, until it answers again or its cooldown ends; it stays listed and opens as usual.
/// A source is identified by its subscription and original key, so its record survives re-imports and merges.
@MainActor @Observable public final class SourceHealth {
    public static let shared = SourceHealth(file: URL.cachesDirectory.appending(path: "source-health.json"))

    public enum Status: Sendable {
        /// Not asked yet, or not since its record expired.
        case unknown
        case healthy
        /// Slow on average, or failed lately without reaching a cooldown.
        case unstable
        /// Failed repeatedly; left out of search until the cooldown ends or it answers.
        case failing
    }

    struct Record: Codable, Equatable {
        var failures = 0
        var lastSuccess: Date?
        var lastFailure: Date?
        var cooldownUntil: Date?
        /// Seconds per answer, smoothed.
        var latency: Double?
    }

    /// Two failures in a row start a cooldown of 30 minutes; each further failure doubles it, up to 6 hours.
    static let firstCooldown: TimeInterval = 30 * 60
    static let longestCooldown: TimeInterval = 6 * 3600
    /// Answers slower than this on average mark a source unstable.
    static let slowAnswer: Double = 8
    /// A record nobody updated for a week says nothing about the source today.
    static let expiry: TimeInterval = 7 * 86400

    private(set) var records: [String: Record] = [:]
    private let file: URL?
    private var saveTask: Task<Void, Never>?

    public init(file: URL?) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([String: Record].self, from: data) {
            // A cooldown is a wall-clock deadline for *this* run: persisting it across a restart left a
            // source silently excluded long after it recovered. Drop the deadline on load, so a restart
            // retries the source; the failure count stays, so it still reads as unstable.
            var loaded = saved
            for key in loaded.keys { loaded[key]?.cooldownUntil = nil }
            records = loaded
        }
    }

    public nonisolated static func key(origin: URL, sourceKey: String) -> String { origin.absoluteString + "|" + sourceKey }
    nonisolated static func key(_ site: Site, origin: URL) -> String { key(origin: site.origin(or: origin), sourceKey: site.sourceKey) }

    public func status(_ site: Site, origin: URL, now: Date = Date()) -> Status {
        guard let record = records[Self.key(site, origin: origin)] else { return .unknown }
        if let until = record.cooldownUntil, until > now { return .failing }
        if let last = [record.lastSuccess, record.lastFailure].compactMap({ $0 }).max(), now.timeIntervalSince(last) > Self.expiry { return .unknown }
        if record.failures > 0 || (record.latency ?? 0) > Self.slowAnswer { return .unstable }
        return record.lastSuccess == nil ? .unknown : .healthy
    }

    /// Whether search leaves this source out for now. A retry of the unavailable sources still asks it.
    public func paused(_ site: Site, origin: URL, now: Date = Date()) -> Bool {
        pausedUntil(site, origin: origin, now: now) != nil
    }

    /// When a paused source joins search again; nil when it is not paused.
    public func pausedUntil(_ site: Site, origin: URL, now: Date = Date()) -> Date? {
        records[Self.key(site, origin: origin)]?.cooldownUntil.flatMap { $0 > now ? $0 : nil }
    }

    /// Whether the source's latest answers were failures, at least two in a row, cooldown over or not.
    public func failedRepeatedly(_ site: Site, origin: URL) -> Bool {
        (records[Self.key(site, origin: origin)]?.failures ?? 0) >= 2
    }

    /// Records one answer from a source: `error` nil for success. Cancellations, and failures that
    /// are this device's rather than the source's, change nothing.
    public func record(_ site: Site, origin: URL, seconds: Double, error: Error?, now: Date = Date()) {
        let key = Self.key(site, origin: origin)
        guard let error else {
            update(key) { record in
                record.failures = 0; record.cooldownUntil = nil; record.lastSuccess = now
                // A plugin's first answer includes preparing its runtime, minutes on a cold JVM:
                // it counts as merely slow, and no single answer outweighs the history.
                record.latency = record.latency.map { $0 * 0.7 + min(seconds, 2 * Self.slowAnswer) * 0.3 } ?? min(seconds, Self.slowAnswer)
            }
            return
        }
        guard Self.counts(error) else { return }
        recordFailure(key: key, now: now)
    }

    /// A failure found after the source answered, such as a stream that will not play.
    public func recordFailure(key: String, now: Date = Date()) {
        update(key) { record in
            record.failures += 1; record.lastFailure = now
            if record.failures >= 2 {
                let delay = min(Self.longestCooldown, Self.firstCooldown * pow(2, Double(record.failures - 2)))
                record.cooldownUntil = now.addingTimeInterval(delay)
            }
        }
    }

    nonisolated static func counts(_ error: Error) -> Bool {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return false }
        // The plugin runtime turning a caller away is this device's queue, not the source.
        return !error.localizedDescription.hasPrefix("The plugin runtime is busy")
    }

    private func update(_ key: String, _ change: (inout Record) -> Void) {
        var record = records[key] ?? Record()
        change(&record)
        records[key] = record
        scheduleSave()
    }

    /// Writes after a short pause, so a search across many sources saves once.
    private func scheduleSave() {
        guard let file, saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            self.saveTask = nil
            let cutoff = Date().addingTimeInterval(-Self.expiry)
            let kept = self.records.filter { _, record in
                [record.lastSuccess, record.lastFailure, record.cooldownUntil].contains { ($0 ?? .distantPast) > cutoff }
            }
            guard let data = try? JSONEncoder().encode(kept) else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

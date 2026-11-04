//
//  SourceProbe.swift
//  TVCore
//
//  Lazy health probing for the play lines of one video, plus the score used to
//  order them in the picker.
//
//  What the codebase already had
//  -----------------------------
//  `PlaybackHistoryContext` already carries `sourceKey`, `videoID` and
//  `episodeFlag`, and `EpisodePlaylist.episodes(for:)` resolves a line from that
//  flag. So "reopen on the source and line I last used" needs no new storage —
//  it needs the player to consult the saved context instead of always starting at
//  the first line. That lives in PlaybackResume.swift.
//
//  What was missing is this file: nothing measured a line before the player
//  committed to it, so the picker could not show which line was alive, how fast
//  it was, or what resolution it offered. Everything here is opt-in and lazy:
//  the picker probes only the lines it is about to draw, one at a time, and a
//  reading is reused until it goes stale.
//

import Foundation

// MARK: - Probe result

/// What one line told us when we last looked.
public struct SourceProbeResult: Codable, Hashable, Sendable {
    public enum Reachability: String, Codable, Sendable {
        case unknown
        case reachable
        case slow
        case unreachable
    }

    public var reachability: Reachability
    /// Round-trip to the first response byte. `nil` when the probe never connected.
    public var latencyMilliseconds: Int?
    /// Throughput measured over a short ranged read, in KB/s.
    public var kilobytesPerSecond: Int?
    /// Height the source itself declares (1080, 720, …). `nil` when it does not say.
    public var resolutionHeight: Int?
    /// Short label for the picker: "1080P", or nil when unknown.
    public var resolutionLabel: String?
    public var measuredAt: Date

    public init(
        reachability: Reachability = .unknown,
        latencyMilliseconds: Int? = nil,
        kilobytesPerSecond: Int? = nil,
        resolutionHeight: Int? = nil,
        resolutionLabel: String? = nil,
        measuredAt: Date = .distantPast
    ) {
        self.reachability = reachability
        self.latencyMilliseconds = latencyMilliseconds
        self.kilobytesPerSecond = kilobytesPerSecond
        self.resolutionHeight = resolutionHeight
        self.resolutionLabel = resolutionLabel
        self.measuredAt = measuredAt
    }

    public static let unknown = SourceProbeResult()

    public func isStale(now: Date = Date(), tolerance: TimeInterval = 300) -> Bool {
        now.timeIntervalSince(measuredAt) > tolerance
    }

    /// Higher sorts first: reachable > slow > unreachable, then faster wins,
    /// then the higher resolution breaks a tie.
    public var sortScore: Int {
        var score: Int
        switch reachability {
        case .reachable: score = 1_000_000
        case .slow: score = 500_000
        case .unknown: score = 250_000
        case .unreachable: score = 0
        }
        if let latency = latencyMilliseconds {
            score += max(0, 300_000 - min(latency, 3_000) * 100)
        }
        if let speed = kilobytesPerSecond {
            score += min(speed, 5_000) * 10
        }
        if let height = resolutionHeight {
            score += min(height, 2_160)
        }
        return score
    }

    /// Compact line for the picker's subtitle, e.g. "1080P · 320 ms · 2.4 MB/s".
    public func summary() -> String {
        var parts: [String] = []
        if let label = resolutionLabel { parts.append(label) }
        if let latency = latencyMilliseconds, reachability != .unreachable {
            parts.append(String(format: "%d ms", latency))
        }
        if let speed = kilobytesPerSecond, reachability != .unreachable {
            parts.append(String(format: "%.1f MB/s", Double(speed) / 1024))
        }
        if parts.isEmpty {
            switch reachability {
            case .unreachable: return L10n.text("Unreachable")
            case .slow: return L10n.text("Slow")
            case .reachable: return L10n.text("Reachable")
            case .unknown: return L10n.text("Not checked")
            }
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Store

/// Caches probe readings per (source, video, line). Bounded, and least-recently
/// measured rows are evicted first so a long-lived install stays small.
@MainActor
public final class SourceProbeStore {
    public static let shared = SourceProbeStore()

    private static let probeKey = "player.playLine.probes"
    private static let orderKey = "player.playLine.probes.order"
    private static let limit = 800

    private static let rotationKey = "player.playLine.rotation"
    private static let learningKey = "player.playLine.learning"

    private let defaults: UserDefaults
    private var probes: [String: SourceProbeResult]
    private var order: [String]
    /// Per-base backoff and concurrency, keyed by base rather than by the full URL: a line that
    /// failed once will fail for every episode on that host, so the avoidance belongs to the host.
    /// This mirrors what One keeps as `avoidUntil` / `inflight` / `lastHeal`.
    private var rotation: HostRotation
    /// Which bases have actually answered, so a working CDN is tried before an unknown one.
    private var learning: HostLearning

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let blob = defaults.data(forKey: Self.probeKey),
           let decoded = try? JSONDecoder().decode([String: SourceProbeResult].self, from: blob) {
            self.probes = decoded
        } else {
            self.probes = [:]
        }
        self.order = defaults.stringArray(forKey: Self.orderKey) ?? []
        for key in probes.keys where !order.contains(key) { order.append(key) }
        if let blob = defaults.data(forKey: Self.rotationKey),
           let decoded = try? JSONDecoder().decode(HostRotation.self, from: blob) {
            self.rotation = decoded
        } else {
            self.rotation = HostRotation()
        }
        if let blob = defaults.data(forKey: Self.learningKey),
           let decoded = try? JSONDecoder().decode(HostLearning.self, from: blob) {
            self.learning = decoded
        } else {
            self.learning = HostLearning()
        }
    }

    // MARK: - Base rotation（对应 One 的 avoidUntil / lastHeal / inflight）

    private func persistRotation() {
        if let encoded = try? JSONEncoder().encode(rotation) { defaults.set(encoded, forKey: Self.rotationKey) }
        if let encoded = try? JSONEncoder().encode(learning) { defaults.set(encoded, forKey: Self.learningKey) }
    }

    /// Declares the bases a video offers, so the rotator knows the pool. Call this before probing.
    public func declareBases(_ bases: [String], preferred: String? = nil) {
        rotation.replace(hosts: bases, preferred: preferred)
        persistRotation()
    }

    /// Bases that may be probed right now: not cooling down, not saturated. One skips a base in its
    /// `avoidUntil` window rather than retrying it; this is that behaviour.
    public func availableBases(now: Date = Date()) -> [String] { rotation.available(now: now) }

    /// Bases ordered by observed health, with learned-good ones first.
    public func rankedBases(_ bases: [String]? = nil, now: Date = Date()) -> [String] {
        let pool = bases ?? rotation.hosts
        return learning.prefer(rotation.ranked(now: now).filter { pool.contains($0) }, now: now)
    }

    /// True when every base is cooling down. A caller should show "所有线路都在冷却" rather than
    /// "没有可播放的地址", because the two have different fixes.
    public func allBasesCoolingDown(now: Date = Date()) -> Bool { rotation.allCoolingDown(now: now) }

    /// Registers a base in the pool on first sight, so `HostRotation.begin` does not drop it
    /// (it only claims hosts that are already known). Surviving hosts keep their state.
    private func ensureBase(_ base: String) {
        guard !rotation.hosts.contains(base) else { return }
        var hosts = rotation.hosts
        hosts.append(base)
        rotation.replace(hosts: hosts, preferred: rotation.preferred)
    }

    /// Claims a base for one probe. Returns false when it is cooling down or saturated, which means
    /// "skip this round", not "this base is dead".
    public func beginBase(_ base: String, now: Date = Date()) -> Bool {
        ensureBase(base)
        let claimed = rotation.begin(base, now: now)
        if claimed { persistRotation() }
        return claimed
    }

    /// Records that a base answered. Promotes it and clears its backoff.
    public func succeedBase(_ base: String, now: Date = Date()) {
        rotation.succeed(base, now: now)
        learning.learn(base, at: now)
        persistRotation()
    }

    /// Records that a base failed, scheduling the next attempt. Returns when it becomes available.
    @discardableResult
    public func failBase(_ base: String, reason: String = "", now: Date = Date()) -> Date? {
        let until = rotation.fail(base, now: now)
        if !reason.isEmpty { learning.reject(base, reason: reason, at: now) }
        persistRotation()
        return until
    }

    /// Releases a slot for a cancelled probe without judging the base.
    public func cancelBase(_ base: String) {
        rotation.cancel(base)
        persistRotation()
    }

    /// Current backoff deadline for a base, for a UI countdown.
    public func baseAvoidUntil(_ base: String) -> Date? { rotation.states[base]?.avoidUntil }

    /// How long `base` stays out of rotation, in seconds, or nil when it is usable now.
    ///
    /// The UI asks this per chip. Exposing seconds rather than a date keeps the view from having to
    /// reason about clock changes, and lets it show a countdown without its own timer.
    public func cooldownRemaining(for base: String, now: Date = Date()) -> TimeInterval? {
        guard let until = baseAvoidUntil(base), until > now else { return nil }
        return until.timeIntervalSince(now)
    }

    /// The soonest a cooling base becomes usable, in seconds, or nil when at least one is usable.
    ///
    /// Used for the "every line is cooling down" notice: when this is non-nil, every chip on screen
    /// is disabled, and a list of greyed-out buttons with no explanation reads as a bug.
    public func soonestCooldown(now: Date = Date()) -> TimeInterval? {
        guard allBasesCoolingDown(now: now) else { return nil }
        return rotation.states.values
            .compactMap { $0.avoidUntil }
            .filter { $0 > now }
            .map { $0.timeIntervalSince(now) }
            .min()
    }

    /// How many consecutive failures a base has, for a UI badge.
    public func baseFailures(_ base: String) -> Int { rotation.states[base]?.consecutiveFailures ?? 0 }


    private func storageKey(sourceKey: String, videoID: String, lineFlag: String) -> String {
        "\(sourceKey)|\(videoID)|\(lineFlag)"
    }

    public func probe(sourceKey: String, videoID: String, lineFlag: String) -> SourceProbeResult? {
        probes[storageKey(sourceKey: sourceKey, videoID: videoID, lineFlag: lineFlag)]
    }

    /// The freshest reading for one source, whatever video or line it was measured on.
    ///
    /// Ranking sources needs one number per source, and a probe measures a sample video inside one
    /// source: the newest reading is the best guess at what that source serves now. A source that
    /// has never been probed answers nil, which ranks it as unknown rather than as bad.
    public func latest(sourceKey: String) -> SourceProbeResult? {
        let prefix = sourceKey + "|"
        var newest: SourceProbeResult?
        for (key, value) in probes where key.hasPrefix(prefix) {
            guard let found = newest else { newest = value; continue }
            if value.measuredAt > found.measuredAt { newest = value }
        }
        return newest
    }

    /// Every reading known for one video, keyed by line flag.
    public func probes(sourceKey: String, videoID: String) -> [String: SourceProbeResult] {
        let prefix = "\(sourceKey)|\(videoID)|"
        var found: [String: SourceProbeResult] = [:]
        for (key, value) in probes where key.hasPrefix(prefix) {
            found[String(key.dropFirst(prefix.count))] = value
        }
        return found
    }

    /// One row per dead line, whatever video it was measured on.
    ///
    /// Fixing a dead line needs the source and the flag — the route is stored per (origin, source,
    /// flag), not per episode — so the reader gets exactly those two, de-duplicated across every
    /// video the sweep happened to probe.
    ///
    /// The newest reading decides, reachable or not: a line that failed on Monday and was measured
    /// again as reachable on Tuesday is not dead, and filtering before taking the newest would have
    /// kept it in the list forever, since the two readings live under different video ids.
    public func unreadableLines() -> [(sourceKey: String, lineFlag: String)] {
        var best: [String: (sourceKey: String, lineFlag: String, at: Date, dead: Bool)] = [:]
        for (key, value) in probes {
            // key = "sourceKey|videoID|lineFlag"; a source key never contains a bar, a video id is
            // the feed's own id, and a flag is the feed's line name.
            let parts = key.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { continue }
            let flag = String(parts[parts.count - 1])
            guard !flag.isEmpty else { continue }
            let sourceKey = parts.dropLast(2).joined(separator: "|")
            let id = "\(sourceKey)|\(flag)"
            if let seen = best[id], seen.at >= value.measuredAt { continue }
            best[id] = (sourceKey, flag, value.measuredAt, value.reachability == .unreachable)
        }
        return best.values
            .filter(\.dead)
            .sorted { $0.at > $1.at }
            .map { (sourceKey: $0.sourceKey, lineFlag: $0.lineFlag) }
    }

    public func record(_ result: SourceProbeResult, sourceKey: String, videoID: String, lineFlag: String) {
        guard !lineFlag.isEmpty else { return }
        let key = storageKey(sourceKey: sourceKey, videoID: videoID, lineFlag: lineFlag)
        probes[key] = result
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > Self.limit {
            probes.removeValue(forKey: order.removeFirst())
        }
        if let encoded = try? JSONEncoder().encode(probes) {
            defaults.set(encoded, forKey: Self.probeKey)
        }
        defaults.set(order, forKey: Self.orderKey)
    }

    /// Records a whole source's lines in one go.
    ///
    /// `record` re-encodes every saved reading and writes the defaults file, which is the right cost
    /// for one line and the wrong one for a sweep of hundreds: a bulk probe used to spend its time
    /// re-serialising the same dictionary on the main actor, which is what made the app look stuck.
    public func record(_ rows: [(result: SourceProbeResult, lineFlag: String)], sourceKey: String, videoID: String) {
        guard !rows.isEmpty else { return }
        for row in rows where !row.lineFlag.isEmpty {
            let key = storageKey(sourceKey: sourceKey, videoID: videoID, lineFlag: row.lineFlag)
            probes[key] = row.result
            order.removeAll { $0 == key }
            order.append(key)
        }
        while order.count > Self.limit {
            probes.removeValue(forKey: order.removeFirst())
        }
        persist()
    }

    /// Writes the readings once, after a batch.
    private func persist() {
        if let encoded = try? JSONEncoder().encode(probes) {
            defaults.set(encoded, forKey: Self.probeKey)
        }
        defaults.set(order, forKey: Self.orderKey)
    }

    public func clear(sourceKey: String, videoID: String) {
        let prefix = "\(sourceKey)|\(videoID)|"
        for key in probes.keys where key.hasPrefix(prefix) {
            probes.removeValue(forKey: key)
            order.removeAll { $0 == key }
        }
        if let encoded = try? JSONEncoder().encode(probes) {
            defaults.set(encoded, forKey: Self.probeKey)
        }
        defaults.set(order, forKey: Self.orderKey)
    }
}

// MARK: - Runner

/// Probes one line with a single ranged GET: enough to learn whether it answers,
/// how fast, and what the manifest declares — without pulling a whole segment.
public enum SourceProbeRunner {
    /// Bytes to pull when measuring throughput. Large enough to separate a
    /// healthy CDN from a stalled one, small enough to stay harmless on cellular.
    public static let sampleBytes = 256 * 1024

    public static func probe(url: URL, headers: [String: String] = [:], session: URLSession = .shared) async -> SourceProbeResult {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("bytes=0-\(sampleBytes - 1)", forHTTPHeaderField: "Range")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }

        let started = Date()
        do {
            let (data, response) = try await session.data(for: request)
            let elapsed = max(Date().timeIntervalSince(started), 0.001)
            let http = response as? HTTPURLResponse

            let head = String(data: data.prefix(4_096), encoding: .utf8) ?? ""
            let height = declaredHeight(in: head, url: url)

            // A server that ignores Range and returns 200 sends the whole object;
            // charge only the sample we asked for so figures stay comparable.
            let charged = http?.statusCode == 200 ? min(data.count, sampleBytes) : data.count
            let kBps = Int(Double(charged) / 1024 / elapsed)
            let latency = Int(elapsed * 1_000)

            let reachability: SourceProbeResult.Reachability
            if let code = http?.statusCode, !(200..<400).contains(code) {
                reachability = .unreachable
            } else if elapsed > 3 || kBps < 64 {
                reachability = .slow
            } else {
                reachability = .reachable
            }

            return SourceProbeResult(
                reachability: reachability,
                latencyMilliseconds: latency,
                kilobytesPerSecond: kBps,
                resolutionHeight: height,
                resolutionLabel: height.map { "\($0)P" },
                measuredAt: Date()
            )
        } catch {
            // A cancelled probe (line switch / sheet closed) is not a verdict: recording it as
            // unreachable would poison the 5-minute cache with a lie.
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                return SourceProbeResult(reachability: .unknown)
            }
            return SourceProbeResult(reachability: .unreachable, measuredAt: Date())
        }
    }

    /// Reads a declared height from an m3u8 (`RESOLUTION=1920x1080`) or from a
    /// height token in the path. Returns nil rather than guessing — an invented
    /// number in the picker is worse than an empty slot.
    static func declaredHeight(in head: String, url: URL) -> Int? {
        if let range = head.range(of: #"RESOLUTION=\d+x(\d+)"#, options: .regularExpression) {
            let matched = String(head[range])
            if let x = matched.lastIndex(of: "x"), let height = Int(matched[matched.index(after: x)...]) {
                return height
            }
        }
        let name = url.lastPathComponent.lowercased()
        for height in [2160, 1440, 1080, 720, 480, 360] where name.contains("\(height)p") || name.contains("x\(height)") {
            return height
        }
        return nil
    }
}

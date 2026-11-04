import Foundation
import Testing
@testable import TVCore

/// Ranking sources by what a sweep measured rests on one reading per source: the newest one. These
/// pin that, and that a source nobody probed is unknown rather than bad.
@Suite struct SourceProbeRankingTests {

    @MainActor
    private func store() -> SourceProbeStore {
        // A suite of its own, so a reading recorded here cannot leak into the app's own list.
        SourceProbeStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    @MainActor
    @Test func theNewestReadingIsWhatASourceIsJudgedBy() {
        let probes = store()
        let now = Date()
        probes.record(SourceProbeResult(reachability: .reachable, resolutionHeight: 720, measuredAt: now.addingTimeInterval(-600)),
                      sourceKey: "alpha", videoID: "first", lineFlag: "l1")
        probes.record(SourceProbeResult(reachability: .reachable, resolutionHeight: 1080, measuredAt: now),
                      sourceKey: "alpha", videoID: "second", lineFlag: "l1")
        #expect(probes.latest(sourceKey: "alpha")?.resolutionHeight == 1080)
        // A different source's readings are not this one's.
        #expect(probes.latest(sourceKey: "beta") == nil)
        // A source key that merely starts the same is not a prefix match: "alpha|" is the boundary.
        #expect(probes.latest(sourceKey: "alph") == nil)
    }

    @MainActor
    @Test func aSharperSourceSortsFirstAndAnUnprobedOneSortsLast() {
        let probes = store()
        let now = Date()
        probes.record(SourceProbeResult(reachability: .reachable, resolutionHeight: 720, measuredAt: now), sourceKey: "low", videoID: "v", lineFlag: "l1")
        probes.record(SourceProbeResult(reachability: .reachable, resolutionHeight: 2160, measuredAt: now), sourceKey: "high", videoID: "v", lineFlag: "l1")
        probes.record(SourceProbeResult(reachability: .reachable, resolutionHeight: 1080, measuredAt: now), sourceKey: "mid", videoID: "v", lineFlag: "l1")

        let ranked = ResourceRanking.standard.sort(["low", "never", "high", "mid"]) { key in
            guard let reading = probes.latest(sourceKey: key) else { return ResourceRanking.Candidate() }
            return ResourceRanking.Candidate(reading)
        }
        #expect(ranked == ["high", "mid", "low", "never"])
    }

    // MARK: - Dead lines, for "fix every unreachable line"

    @MainActor
    @Test func deadLinesAreListedOncePerSourceAndLine() {
        // The batch fix writes one route per (source, line), so two dead videos on the same line are
        // one row, not two — otherwise the same fix is applied twice and counted twice.
        let probes = store()
        let now = Date()
        probes.record(SourceProbeResult(reachability: .unreachable, measuredAt: now),
                      sourceKey: "alpha", videoID: "v1", lineFlag: "l1")
        probes.record(SourceProbeResult(reachability: .unreachable, measuredAt: now.addingTimeInterval(-60)),
                      sourceKey: "alpha", videoID: "v2", lineFlag: "l1")
        probes.record(SourceProbeResult(reachability: .unreachable, measuredAt: now),
                      sourceKey: "alpha", videoID: "v1", lineFlag: "l2")
        // Healthy, so it is not in the list at all.
        probes.record(SourceProbeResult(reachability: .reachable, measuredAt: now),
                      sourceKey: "beta", videoID: "v1", lineFlag: "l1")

        let rows = probes.unreadableLines()
        #expect(rows.count == 2)
        #expect(rows.contains { $0.sourceKey == "alpha" && $0.lineFlag == "l1" })
        #expect(rows.contains { $0.sourceKey == "alpha" && $0.lineFlag == "l2" })
        #expect(!rows.contains { $0.sourceKey == "beta" })
    }

    @MainActor
    @Test func aLineThatMeasuredHealthyAgainIsNotDead() {
        // Readings live under the video they were taken on, so the newest has to win across videos:
        // filtering for `.unreachable` first would keep a line listed forever after one bad day.
        let probes = store()
        let now = Date()
        probes.record(SourceProbeResult(reachability: .unreachable, measuredAt: now.addingTimeInterval(-3600)),
                      sourceKey: "alpha", videoID: "v1", lineFlag: "l1")
        probes.record(SourceProbeResult(reachability: .reachable, measuredAt: now),
                      sourceKey: "alpha", videoID: "v2", lineFlag: "l1")
        #expect(probes.unreadableLines().isEmpty)
    }

    @MainActor
    @Test func aLineNeverMeasuredIsNotCalledDead() {
        // `.unknown` is "we have not looked", not "it does not work". The batch fix must not route a
        // line through a proxy on the strength of a reading nobody took.
        let probes = store()
        probes.record(SourceProbeResult(reachability: .unknown, measuredAt: Date()),
                      sourceKey: "alpha", videoID: "v1", lineFlag: "l1")
        #expect(probes.unreadableLines().isEmpty)
    }
}

import Foundation
import Testing
@testable import TVCore

/// Online samples from the music plan, against the real catalogs and providers. Public services
/// change without notice, so this never runs in CI or by default:
/// `TVBOX_MUSIC_LIVE=1 swift test --filter MusicLiveTests`. It prints what each sample resolved
/// to, with the date, for the plan's record; GD Studio's budget is 50 requests per 5 minutes.
private let live = ProcessInfo.processInfo.environment["TVBOX_MUSIC_LIVE"] == "1"

@Suite(.enabled(if: live), .serialized) struct MusicLiveTests {
    static let samples = ["晴天 周杰伦", "稻香 周杰伦", "七里香 周杰伦", "江南 林俊杰", "十年 陈奕迅", "Love Story Taylor Swift"]

    @MainActor @Test(arguments: samples) func searchesAndResolves(_ query: String) async throws {
        let health = MusicHealth(file: nil)
        let model = MusicSearchModel(health: health)
        model.search(query, immediately: true)
        let started = Date()
        while model.busy, Date().timeIntervalSince(started) < 15 { try await Task.sleep(for: .milliseconds(100)) }
        let failures = model.failures.map { "\($0.key.rawValue): \($0.value.detail)" }.joined(separator: "; ")
        let track = try #require(model.directHit ?? model.results.first, "no results; \(failures)")
        print("[music-live \(Date().formatted(.iso8601))] \(query) → \(track.title) / \(track.artistLine) / \(track.album ?? "-") ids=\(track.ids.map { "\($0.key.rawValue):\($0.value)" }.sorted()) direct=\(model.directHit != nil) search=\(String(format: "%.1f", Date().timeIntervalSince(started)))s \(failures)")
        for other in model.results.prefix(6) {
            print("[music-live]    result \(other.title) / \(other.artistLine) / \(other.album ?? "-") \(other.duration.map { String(format: "%.0fs", $0) } ?? "-") \(other.ids.keys.map(\.rawValue).sorted()) score=\(MusicMatching.score(other, query: query))")
        }
        // The channels come from the subscription, as in the app.
        if CloudMusic.current == nil { CloudSources.current = try await CloudSources.fetch(http: HTTPClient()) }
        let resolver = MusicResolver(preferences: MusicPreferences(), health: health)
        let start = Date()
        do {
            let selection = try await resolver.select(track, preference: .losslessPreferred)
            print("[music-live] \(query) → \(selection.candidate.name) \(selection.probe.format.label) \(selection.probe.completeness.rawValue) duration=\(selection.probe.duration.map { String(format: "%.2f", $0) } ?? "-") expected=\(track.duration.map { String(format: "%.2f", $0) } ?? "-") evidence=\(selection.probe.evidence.map(\.rawValue).sorted()) degraded=\(selection.degraded) in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
            for attempt in selection.attempts { print("[music-live]    \(attempt.candidate.name): \(attempt.outcome)") }
            #expect(selection.probe.completeness != .preview)
        } catch {
            print("[music-live] \(query) → failed: \(MusicProviderError(error).detail)")
            throw error
        }
    }
}

import AVFoundation
import TVCore
import XCTest
@testable import PlaybackHistoryQA

/// Runs the production PlaybackSession, including its periodic sampler and pause observation, with a local
/// movie and isolated history. The same tests run on Mac, iPhone, iPad and Apple TV; no iCloud account is used.
final class PlaybackHistoryTests: XCTestCase {
    @MainActor private func context(_ episode: String) -> PlaybackHistoryContext {
        PlaybackHistoryContext(origin: URL(string: "https://example.com/qa.json")!, sourceKey: "qa", sourceName: "QA",
                               videoID: "series", videoName: "Series", episodeID: episode,
                               episodeName: "Episode " + episode, episodeFlag: "line")
    }

    @MainActor private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !predicate() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for the player", file: file, line: line)
                throw NSError(domain: "PlaybackHistoryTests", code: 1)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @MainActor private func start(_ session: PlaybackSession, episode: String = "17", at position: Double = 20) async throws {
        let clip = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "clip", withExtension: "mp4"))
        session.player.isMuted = true
        session.start(Channel(name: "History QA", url: clip, historyContext: context(episode), resumePosition: position))
        try await waitUntil { session.player.timeControlStatus == .playing && session.player.currentTime().seconds >= position }
        XCTAssertNil(session.error)
    }

    @MainActor private func fixture() -> (PlaybackSession, PlaybackHistory, URL) {
        // These defaults belong to the isolated test host, never the installed app.
        UserDefaults.standard.set(false, forKey: DanmakuService.automaticKey)
        UserDefaults.standard.set(false, forKey: "danmakuEnabled")
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
        let history = PlaybackHistory(file: file)
        let session = PlaybackSession()
        session.history = history
        return (session, history, file)
    }

    @MainActor func testPausedEpisodeCannotReplaceRemoteHistoryOnTimerOrStop() async throws {
        let (session, history, file) = fixture()
        defer { session.stop(); try? FileManager.default.removeItem(at: file) }
        try await start(session)
        session.player.pause()
        // Pausing must save the tail immediately, before a later remote update arrives.
        try await waitUntil { history.entries.first?.context.episodeID == "17" }
        let remote = PlaybackHistoryEntry(context: context("18"), position: 90, duration: 120, updatedAt: Date().addingTimeInterval(1))
        history.adopt([remote])
        // Let the production five-second history sampler run while the old player remains paused.
        try await Task.sleep(for: .seconds(6))
        XCTAssertEqual(history.entries, [remote])
        session.stop()
        XCTAssertEqual(history.entries, [remote])
        XCTAssertEqual(PlaybackHistory(file: file).entries, [remote], "Reopening must retain episode 18")
    }

    @MainActor func testPausedPositionCannotUndoRemoteSeekButDeliberateRewindCan() async throws {
        let (session, history, file) = fixture()
        defer { session.stop(); try? FileManager.default.removeItem(at: file) }
        try await start(session)
        session.player.pause()
        try await waitUntil { history.entries.first != nil }
        let remote = PlaybackHistoryEntry(context: context("17"), position: 90, duration: 120, updatedAt: Date().addingTimeInterval(1))
        history.adopt([remote])
        session.saveHistory()
        XCTAssertEqual(history.entries, [remote])
        // This is an intentional seek on the old player, so its new position should become current.
        await session.player.seek(to: CMTime(seconds: 10, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        session.saveHistory()
        XCTAssertEqual(try XCTUnwrap(history.entries.first).position, 10, accuracy: 0.25)
        XCTAssertGreaterThan(try XCTUnwrap(history.entries.first).updatedAt, remote.updatedAt)
        session.stop()
        XCTAssertEqual(try XCTUnwrap(PlaybackHistory(file: file).entries.first).position, 10, accuracy: 0.25)
    }

    @MainActor func testResumingOldEpisodeAndStartingAnotherEpisodeCanUpdateHistory() async throws {
        let (session, history, file) = fixture()
        defer { session.stop(); try? FileManager.default.removeItem(at: file) }
        try await start(session)
        session.player.pause()
        try await waitUntil { history.entries.first != nil }
        let pausedAt = session.player.currentTime().seconds
        history.adopt([PlaybackHistoryEntry(context: context("18"), position: 90, duration: 120, updatedAt: Date())])
        session.player.play()
        try await waitUntil { session.player.currentTime().seconds > pausedAt + 1 }
        session.player.pause()
        try await waitUntil { history.entries.first?.context.episodeID == "17" }
        XCTAssertGreaterThan(try XCTUnwrap(history.entries.first).position, pausedAt)
        // Starting a new episode resets the per-player checkpoint even at the same playback position.
        try await start(session, episode: "19", at: history.entries[0].position)
        session.player.pause()
        try await waitUntil { history.entries.first?.context.episodeID == "19" }
        session.stop()
        XCTAssertEqual(PlaybackHistory(file: file).entries.first?.context.episodeID, "19")
    }
}

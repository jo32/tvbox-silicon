import Foundation
@main struct Check {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "history.json")
        let history = PlaybackHistory(file: file)
        func context(_ id: String) -> PlaybackHistoryContext {
            PlaybackHistoryContext(origin: URL(string: "https://example.invalid/catalog")!, sourceKey: "source", sourceName: "Source", videoID: id, videoName: id, episodeID: "1", episodeName: "1", episodeFlag: "main")
        }
        let start = Date()
        history.record(context("first"), position: 10, duration: 100)
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed < 0.1 else { throw NSError(domain: "record blocked MainActor for \(elapsed) seconds", code: 1) }
        let second = PlaybackHistory(file: file)
        check(second.entries.first?.position == 10, "new instance missed pending snapshot")
        for i in 11...50 { history.record(context("first"), position: Double(i), duration: 100) }
        check(WriteProbe.lock.withLock { WriteProbe.queuedPriorityJobs } <= 2, "each progress update queued another retained priority snapshot")
        second.record(context("second"), position: 20, duration: 100)
        check(second.entries.count == 2, "same-file instance lost newer entries")
        history.remove(context("first").id)
        check(awaitFlush(await history.flushPersistence()))
        var decoded = try JSONDecoder().decode([PlaybackHistoryEntry].self, from: Data(contentsOf: file))
        check(decoded.map(\.context.videoID) == ["second"], "late write resurrected deletion")
        check(WriteProbe.lock.withLock { WriteProbe.writes } < 10, "pending snapshots were not coalesced")
        let stamp = decoded[0].updatedAt
        second.record(context("second"), position: 21, duration: 100, now: .distantPast)
        check(second.entries[0].updatedAt > stamp, "local clock rollback broke cloud timestamp semantics")
        check(awaitFlush(await second.flushPersistence()))
        WriteProbe.lock.withLock { WriteProbe.fail = true }
        second.clear()
        check(!awaitFlush(await second.flushPersistence()), "disk error hidden")
        let before = WriteProbe.lock.withLock { WriteProbe.writes }
        check(!awaitFlush(await second.flushPersistence()))
        check(WriteProbe.lock.withLock { WriteProbe.writes } == before + 1, "flush retry is not bounded to one write")
        WriteProbe.lock.withLock { WriteProbe.fail = false }
        check(awaitFlush(await second.flushPersistence()))
        decoded = try JSONDecoder().decode([PlaybackHistoryEntry].self, from: Data(contentsOf: file))
        check(decoded.isEmpty)
        check(WriteProbe.lock.withLock { WriteProbe.mainWrites } == 0)
        print("PASS: nonblocking writes, shared latest snapshot, coalescing, deletion, clock semantics, bounded failure retry and durable flush")
    }
    static func check(_ condition: Bool, _ message: String = "regression") { precondition(condition, message) }
    static func awaitFlush(_ value: Bool) -> Bool { value }
}

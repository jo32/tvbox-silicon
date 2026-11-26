import Foundation
import Testing
@testable import TVCore

private actor ImageWorkProbe {
    var active = 0, peak = 0, starts: [String] = [], cancellations = 0
    func load(_ key: String, delay: Duration = .milliseconds(100)) async throws -> Data {
        active += 1; peak = max(active, peak); starts.append(key)
        defer { active -= 1 }
        do { try await Task.sleep(for: delay) }
        catch { cancellations += 1; throw error }
        return Data(key.utf8)
    }
    func started(_ count: Int) -> Bool { starts.count >= count }
}
private func waitForStarts(_ probe: ImageWorkProbe, _ count: Int) async throws {
    for _ in 0..<200 {
        if await probe.started(count) { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("image work did not start")
}

@Test func cancellingOneImageWaiterPreservesTheOther() async throws {
    let work = MangaImageWork(), probe = ImageWorkProbe()
    let first = Task { try await work.data(key: "same", page: true) { try await probe.load("same") } }
    let second = Task { try await work.data(key: "same", page: true) { try await probe.load("same") } }
    try await waitForStarts(probe, 1)
    try await Task.sleep(for: .milliseconds(10))
    first.cancel()
    await #expect(throws: CancellationError.self) { _ = try await first.value }
    #expect(try await second.value == Data("same".utf8))
    #expect(await probe.starts.count == 1)
    #expect(await probe.cancellations == 0)
}
@Test func lastImageWaiterCancelsUnderlyingWork() async throws {
    let work = MangaImageWork(), probe = ImageWorkProbe()
    let first = Task { try await work.data(key: "same", page: false) { try await probe.load("same") } }
    try await waitForStarts(probe, 1)
    first.cancel()
    await #expect(throws: CancellationError.self) { _ = try await first.value }
    try await Task.sleep(for: .milliseconds(20))
    #expect(await probe.cancellations == 1)
}
@Test func imageWorkNeverExceedsSixConcurrentDownloads() async throws {
    let work = MangaImageWork(), probe = ImageWorkProbe()
    try await withThrowingTaskGroup(of: Data.self) { group in
        for i in 0..<14 { group.addTask { try await work.data(key: "\(i)", page: false) { try await probe.load("\(i)", delay: .milliseconds(20)) } } }
        for try await _ in group {}
    }
    #expect(await probe.peak <= 6)
    #expect(await probe.starts.count == 14)
}
@Test func queuedReaderPageStartsBeforeQueuedCovers() async throws {
    let work = MangaImageWork(), probe = ImageWorkProbe()
    let running = (0..<6).map { i in Task { try await work.data(key: "running\(i)", page: false) { try await probe.load("running\(i)") } } }
    try await waitForStarts(probe, 6)
    let cover = Task { try await work.data(key: "cover", page: false) { try await probe.load("cover") } }
    try await Task.sleep(for: .milliseconds(10))
    let page = Task { try await work.data(key: "page", page: true) { try await probe.load("page") } }
    for task in running { _ = try await task.value }
    _ = try await cover.value; _ = try await page.value
    let order = await probe.starts
    #expect(order.firstIndex(of: "page")! < order.firstIndex(of: "cover")!)
}

@Test func cancelledFlightCannotClearANewerFlightForTheSameKey() async throws {
    let work = MangaImageWork()
    let old = Task { try await work.data(key: "same", page: true) {
        // Model a provider hook that observes cancellation late.
        try? await Task.sleep(for: .milliseconds(200))
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { continuation.resume() }
        }
        return Data("old".utf8)
    } }
    try await Task.sleep(for: .milliseconds(10))
    old.cancel()
    await #expect(throws: CancellationError.self) { _ = try await old.value }
    let replacement = Task { try await work.data(key: "same", page: true) {
        try await Task.sleep(for: .milliseconds(60))
        return Data("new".utf8)
    } }
    #expect(try await replacement.value == Data("new".utf8))
}
@Test func cancelledQueuedImageNeverStarts() async throws {
    let work = MangaImageWork(), probe = ImageWorkProbe()
    let running = (0..<6).map { i in Task { try await work.data(key: "running\(i)", page: false) { try await probe.load("running\(i)") } } }
    try await waitForStarts(probe, 6)
    let queued = Task { try await work.data(key: "queued", page: true) { try await probe.load("queued") } }
    try await Task.sleep(for: .milliseconds(10))
    queued.cancel()
    await #expect(throws: CancellationError.self) { _ = try await queued.value }
    for task in running { _ = try await task.value }
    #expect(await !probe.starts.contains("queued"))
}
@Test func imageRequestIdentityIncludesHookContextAndKind() {
    let page = MangaImageRequest(source: "s", url: "u", page: true, comic: "c", chapter: "1")
    let chapter = MangaImageRequest(source: "s", url: "u", page: true, comic: "c", chapter: "2")
    let cover = MangaImageRequest(source: "s", url: "u", page: false, comic: "c", chapter: "1")
    #expect(Set([page.key, chapter.key, cover.key]).count == 3)
    #expect(page.maximumBytes == 64 << 20)
    #expect(cover.maximumBytes == 8 << 20)
    #expect(MangaImageRequest(source: "a\nb", url: "c", page: true, comic: nil, chapter: nil).key !=
            MangaImageRequest(source: "a", url: "b\nc", page: true, comic: nil, chapter: nil).key)
}

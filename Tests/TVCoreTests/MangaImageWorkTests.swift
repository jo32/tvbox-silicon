import Foundation
import Testing
@testable import TVCore

/// Image work that finishes only when the test releases it (or its task is cancelled), so nothing here waits on
/// the clock: each test steps the queue itself.
private actor ImageWorkProbe {
    private(set) var starts: [String] = []
    private(set) var priorities: [String: TaskPriority] = [:]
    private(set) var cancellations = 0
    private(set) var active = 0, peak = 0
    private var gates: [String: CheckedContinuation<Bool, Never>] = [:]
    private var released = Set<String>()
    private var waiters: [(starts: Int, cancellations: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// Work that a cancelled task stops.
    func load(_ key: String) async throws -> Data {
        guard await gate(key, cancellable: true) else { throw CancellationError() }
        return Data(key.utf8)
    }
    /// Work that ignores cancellation, as a slow provider hook can: it ends only when released.
    func hold(_ key: String) async { _ = await gate(key, cancellable: false) }

    private func gate(_ key: String, cancellable: Bool) async -> Bool {
        starts.append(key); priorities[key] = Task.currentPriority
        active += 1; peak = max(active, peak); wake()
        let finished: Bool = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if released.contains(key) { continuation.resume(returning: true) }
                else if cancellable, Task.isCancelled { continuation.resume(returning: false) }
                else { gates[key] = continuation }
            }
        } onCancel: { if cancellable { Task { await self.open(key, finished: false) } } }
        active -= 1
        if !finished { cancellations += 1 }
        wake()
        return finished
    }

    /// Lets `key`'s work finish, now or whenever it starts.
    func release(_ key: String) { released.insert(key); open(key, finished: true) }
    private func open(_ key: String, finished: Bool) { gates.removeValue(forKey: key)?.resume(returning: finished) }

    /// Returns once this many works have started and this many were cancelled.
    func until(starts: Int = 0, cancellations: Int = 0) async {
        if self.starts.count >= starts, self.cancellations >= cancellations { return }
        await withCheckedContinuation { waiters.append((starts, cancellations, $0)) }
    }
    private func wake() {
        waiters.removeAll { waiter in
            guard starts.count >= waiter.starts, cancellations >= waiter.cancellations else { return false }
            waiter.continuation.resume(); return true
        }
    }
}

/// Lets the work actor take what was just asked of it. Clock-free: it only hands the executor over, and gives up
/// (failing the test) after many turns.
private func settle(_ condition: () async -> Bool) async {
    for _ in 0..<100_000 where !(await condition()) { await Task.yield() }
    #expect(await condition())
}

@Test func cancellingOneImageWaiterPreservesTheOther() async throws {
    let work = MangaImageWork(), probe = ImageWorkProbe()
    let first = Task { try await work.data(key: "same", page: true) { try await probe.load("same") } }
    await probe.until(starts: 1)
    let second = Task { try await work.data(key: "same", page: true) { try await probe.load("same") } }
    await settle { await work.waiters(for: "same") == 2 }
    first.cancel()
    await #expect(throws: CancellationError.self) { _ = try await first.value }
    await settle { await work.waiters(for: "same") == 1 }
    await probe.release("same")
    #expect(try await second.value == Data("same".utf8))
    #expect(await probe.starts == ["same"])
    #expect(await probe.cancellations == 0)
}

@Test func lastImageWaiterCancelsUnderlyingWork() async throws {
    let work = MangaImageWork(), probe = ImageWorkProbe()
    let only = Task { try await work.data(key: "same", page: false) { try await probe.load("same") } }
    await probe.until(starts: 1)
    only.cancel()
    await #expect(throws: CancellationError.self) { _ = try await only.value }
    await probe.until(cancellations: 1)
    await settle { await work.busySlots == 0 }
}

@Test func imageWorkNeverExceedsSixConcurrentDownloads() async throws {
    let work = MangaImageWork(), probe = ImageWorkProbe()
    let tasks = (0..<14).map { i in Task { try await work.data(key: "\(i)", page: false) { try await probe.load("\(i)") } } }
    await probe.until(starts: 6)
    await settle { await work.queuedCount == 8 }
    #expect(await probe.starts.count == 6)
    // Each finished download lets exactly one more start.
    for done in 0..<14 {
        await probe.release(await probe.starts[done])
        if done + 6 < 14 { await probe.until(starts: done + 7) }
    }
    for task in tasks { _ = try await task.value }
    #expect(await probe.peak == 6)
    #expect(await probe.starts.count == 14)
}

@Test func queuedReaderPageStartsBeforeQueuedCovers() async throws {
    let work = MangaImageWork(), probe = ImageWorkProbe()
    let running = (0..<6).map { i in Task { try await work.data(key: "running\(i)", page: false) { try await probe.load("running\(i)") } } }
    await probe.until(starts: 6)
    let cover = Task { try await work.data(key: "cover", page: false) { try await probe.load("cover") } }
    await settle { await work.isQueued("cover") }
    let page = Task { try await work.data(key: "page", page: true) { try await probe.load("page") } }
    await settle { await work.isQueued("page") }
    await probe.release("running0")
    await probe.until(starts: 7)
    #expect(await probe.starts.last == "page")
    for key in ["running1", "running2", "running3", "running4", "running5", "page", "cover"] { await probe.release(key) }
    for task in running + [cover, page] { _ = try await task.value }
    #expect(await probe.starts.last == "cover")
}

@Test func onScreenImageGoesFirstAndKeepsItsPriority() async throws {
    let work = MangaImageWork(), probe = ImageWorkProbe()
    let running = (0..<6).map { i in Task { try await work.data(key: "running\(i)", page: true) { try await probe.load("running\(i)") } } }
    await probe.until(starts: 6)
    // The reader prefetches at .utility; a page on screen asks from its view's task.
    let prefetch = Task(priority: .utility) { try await work.data(key: "prefetch", page: true) { try await probe.load("prefetch") } }
    await settle { await work.isQueued("prefetch") }
    let shown = Task(priority: .userInitiated) { try await work.data(key: "shown", page: true) { try await probe.load("shown") } }
    await settle { await work.isQueued("shown") }
    await probe.release("running0")
    await probe.until(starts: 7)
    #expect(await probe.starts.last == "shown")
    for key in ["running1", "running2", "running3", "running4", "running5", "shown", "prefetch"] { await probe.release(key) }
    for task in running + [prefetch, shown] { _ = try await task.value }
    #expect(await probe.priorities["shown"] == .userInitiated)
    #expect(await probe.priorities["prefetch"] == .utility)
}

@Test func cancelledFlightCannotClearANewerFlightForTheSameKey() async throws {
    let work = MangaImageWork(), probe = ImageWorkProbe()
    let old = Task { try await work.data(key: "same", page: true) {
        await probe.hold("old")
        return Data("old".utf8)
    } }
    await probe.until(starts: 1)
    old.cancel()
    await #expect(throws: CancellationError.self) { _ = try await old.value }
    let replacement = Task { try await work.data(key: "same", page: true) { try await probe.load("new") } }
    await probe.until(starts: 2)
    #expect(await work.busySlots == 2)
    // The old flight finishes late, while the replacement is still in flight: it must not answer or drop it.
    await probe.release("old")
    await settle { await work.busySlots == 1 }
    #expect(await work.waiters(for: "same") == 1)
    await probe.release("new")
    #expect(try await replacement.value == Data("new".utf8))
}

@Test func cancelledQueuedImageNeverStarts() async throws {
    let work = MangaImageWork(), probe = ImageWorkProbe()
    let running = (0..<6).map { i in Task { try await work.data(key: "running\(i)", page: false) { try await probe.load("running\(i)") } } }
    await probe.until(starts: 6)
    let queued = Task { try await work.data(key: "queued", page: true) { try await probe.load("queued") } }
    await settle { await work.isQueued("queued") }
    queued.cancel()
    await #expect(throws: CancellationError.self) { _ = try await queued.value }
    await settle { await !work.isQueued("queued") }
    for i in 0..<6 { await probe.release("running\(i)") }
    for task in running { _ = try await task.value }
    await settle { await work.busySlots == 0 }
    #expect(await !probe.starts.contains("queued"))
}

@Test func imageCacheKeysStayAsBefore() {
    // The cache on disk keeps working: pages under "page\n…" since #836, covers by source and address.
    let page = MangaImageRequest(source: "s", url: "u", page: true, comic: "c", chapter: "1")
    let cover = MangaImageRequest(source: "s", url: "u", page: false, comic: nil, chapter: nil)
    #expect(page.key == "page\ns\nu")
    #expect(cover.key == "s\nu")
    #expect(MangaImageRequest(source: "s", url: "u", page: true, comic: "c", chapter: "2").key == page.key)
    #expect(page.maximumBytes == 64 << 20)
    #expect(cover.maximumBytes == 8 << 20)
}

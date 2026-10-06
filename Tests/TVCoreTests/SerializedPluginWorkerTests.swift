import Foundation
import Testing
@testable import TVCore

private final class NativeCallGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    private var calls: [String] = []
    func execute(_ value: String) -> Result<String, Error> {
        condition.lock(); calls.append(value)
        while value.hasPrefix("blocked") && !released { condition.wait() }
        condition.unlock()
        return value == "fail" ? .failure(TVError.unsupported("test failure")) : .success(value)
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    var executed: [String] { condition.lock(); defer { condition.unlock() }; return calls }
}

private func eventually(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw TVError.unsupported("Scheduling test timed out") }
        try await Task.sleep(for: .milliseconds(2))
    }
}

@Test func duplicatePluginRequestsShareNativeCallAndCancelIndependently() async throws {
    let gate = NativeCallGate(); defer { gate.release() }
    let worker = SerializedPluginWorker { _, json in gate.execute(json) }
    let first = Task { try await worker.request(resources: "app", json: "blocked") }
    try await eventually { gate.executed.count == 1 }
    let second = Task { try await worker.request(resources: "app", json: "blocked") }
    try await eventually { worker.scheduling.callers == 2 }
    first.cancel()
    await #expect(throws: CancellationError.self) { try await first.value }
    #expect(worker.scheduling.callers == 1)
    gate.release()
    #expect(try await second.value == "blocked")
    #expect(gate.executed == ["blocked"])
    // Results are not cached: a new call must refresh playback tokens/content.
    #expect(try await worker.request(resources: "app", json: "blocked") == "blocked")
    #expect(gate.executed.count == 2)
}

@Test func searchesRunUpToWidthAndDetailNeverWaitsBehindThem() async throws {
    let gate = NativeCallGate(); defer { gate.release() }
    let worker = SerializedPluginWorker(width: 2) { _, json in gate.execute(json) }
    let first = Task { try await worker.request(resources: "app", json: "blocked-1", search: true) }
    let second = Task { try await worker.request(resources: "app", json: "blocked-2", search: true) }
    try await eventually { gate.executed.count == 2 }
    // The search width is full: another search queues.
    let third = Task { try await worker.request(resources: "app", json: "search-3", search: true) }
    try await eventually { worker.scheduling.pending == 1 }
    // Opening a result starts at once, beside the running searches and ahead of the queued one.
    #expect(try await worker.request(resources: "app", json: "detail") == "detail")
    #expect(gate.executed.count == 3)
    gate.release()
    #expect(try await first.value == "blocked-1")
    #expect(try await second.value == "blocked-2")
    #expect(try await third.value == "search-3")
}

@Test func cancelledQueuedPluginWorkNeverRunsAndFreesCapacity() async throws {
    let gate = NativeCallGate(); defer { gate.release() }
    let worker = SerializedPluginWorker(maximumPending: 1, interactiveWidth: 1) { _, json in gate.execute(json) }
    let active = Task { try await worker.request(resources: "app", json: "blocked") }
    try await eventually { gate.executed.count == 1 }
    let abandoned = Task { try await worker.request(resources: "app", json: "abandoned") }
    try await eventually { worker.scheduling.pending == 1 }
    await #expect(throws: (any Error).self) { try await worker.request(resources: "app", json: "overflow") }
    abandoned.cancel()
    await #expect(throws: CancellationError.self) { try await abandoned.value }
    #expect(worker.scheduling.pending == 0)
    let next = Task { try await worker.request(resources: "app", json: "next") }
    try await eventually { worker.scheduling.pending == 1 }
    active.cancel()
    await #expect(throws: CancellationError.self) { try await active.value }
    // Cancelling Swift cannot interrupt Java. The next native call stays queued.
    #expect(gate.executed == ["blocked"])
    gate.release()
    #expect(try await next.value == "next")
    #expect(gate.executed == ["blocked", "next"])
}

@Test func slowDetailTimesOutAloneAndTheNextOneStillRuns() async throws {
    let gate = NativeCallGate(); defer { gate.release() }
    let worker = SerializedPluginWorker(timeout: 0.1) { _, json in gate.execute(json) }
    let slow = Task { try await worker.request(resources: "app", json: "blocked") }
    await #expect(throws: (any Error).self) { try await slow.value }
    // Switching to another result is not blocked by the stuck one.
    #expect(try await worker.request(resources: "app", json: "other-detail") == "other-detail")
    gate.release()
}

@Test func slowSearchTimesOutAloneWithoutPoisoningTheRuntime() async throws {
    let gate = NativeCallGate(); defer { gate.release() }
    let worker = SerializedPluginWorker(timeout: 0.1, width: 2) { _, json in gate.execute(json) }
    let slow = Task { try await worker.request(resources: "app", json: "blocked-search", search: true) }
    await #expect(throws: (any Error).self) { try await slow.value }
    // Its slot stays taken until Java returns, but other work still runs.
    #expect(try await worker.request(resources: "app", json: "next-search", search: true) == "next-search")
    gate.release()
    try await eventually { worker.scheduling.callers == 0 }
    #expect(try await worker.request(resources: "app", json: "detail") == "detail")
}

@Test func cancelledBeforeSubmissionDoesNotStartNativeWork() async throws {
    let gate = NativeCallGate(); defer { gate.release() }
    let worker = SerializedPluginWorker { _, json in gate.execute(json) }
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await worker.request(resources: "app", json: "unused")
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(gate.executed.isEmpty)
    await #expect(throws: (any Error).self) { try await worker.request(resources: "app", json: "fail") }
    #expect(try await worker.request(resources: "app", json: "retry") == "retry")
}

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

@Test func abandonedRunningWorkTellsTheHostItsRequestID() async throws {
    let gate = NativeCallGate(); defer { gate.release() }
    let abandoned = NativeCallGate()
    let worker = SerializedPluginWorker(abandon: { _, id in _ = abandoned.execute(id) }) { _, json in
        // The host sees the request id first; keep the call running like a plugin opening.
        gate.execute(json.contains("\"open\"") ? "blocked:" + json : json)
    }
    let task = Task { try await worker.request(resources: "app", json: "{\"open\":1}") }
    try await eventually { gate.executed.count == 1 }
    let sent = try #require(gate.executed.first)
    #expect(sent.hasPrefix("blocked:{\"request\":\"") && sent.hasSuffix(",\"open\":1}"))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    try await eventually { abandoned.executed.count == 1 }
    let id = try #require(abandoned.executed.first)
    #expect(sent.contains("\"request\":\"\(id)\""))
    // A call that still has callers is never abandoned.
    #expect(try await worker.request(resources: "app", json: "{\"quick\":1}").contains("\"quick\":1"))
    #expect(abandoned.executed.count == 1)
}

@Test func newPluginRequestsDoNotJoinAbandonedNativeCalls() async throws {
    let gate = NativeCallGate(); defer { gate.release() }
    let worker = SerializedPluginWorker(width: 2) { _, json in gate.execute(json) }
    let old = Task { try await worker.request(resources: "app", json: "blocked", search: true) }
    try await eventually { gate.executed.count == 1 }
    old.cancel()
    await #expect(throws: CancellationError.self) { try await old.value }
    let retry = Task { try await worker.request(resources: "app", json: "blocked", search: true) }
    try await eventually { gate.executed.count == 2 }
    gate.release()
    #expect(try await retry.value == "blocked")
}

@Test func pluginStartNotificationsFollowExecutionAndJoinedCallers() async throws {
    let gate = NativeCallGate(); defer { gate.release() }
    let starts = NativeCallGate()
    let worker = SerializedPluginWorker(interactiveWidth: 1) { _, json in gate.execute(json) }
    let first = Task { try await worker.request(resources: "app", json: "blocked", onStart: { _ = starts.execute("first") }) }
    try await eventually { gate.executed.count == 1 }
    let joined = Task { try await worker.request(resources: "app", json: "blocked", onStart: { _ = starts.execute("joined") }) }
    try await eventually { starts.executed.count == 2 }
    let queued = Task { try await worker.request(resources: "app", json: "next", onStart: { _ = starts.execute("next") }) }
    try await eventually { worker.scheduling.pending == 1 }
    #expect(starts.executed == ["first", "joined"])
    gate.release()
    _ = try await first.value; _ = try await joined.value
    #expect(try await queued.value == "next")
    #expect(starts.executed == ["first", "joined", "next"])
}

@Test func expiredRunningWorkAsksTheHostToStopIt() async throws {
    let gate = NativeCallGate(); defer { gate.release() }
    let abandoned = NativeCallGate()
    let worker = SerializedPluginWorker(timeout: 0.1, abandon: { _, id in _ = abandoned.execute(id) }) { _, json in
        gate.execute(json.contains("\"stuck\"") ? "blocked:" + json : json)
    }
    await #expect(throws: (any Error).self) { try await worker.request(resources: "app", json: "{\"stuck\":1}") }
    // A plugin waiting for a sign-in nobody can give ends at the host's next checkpoint.
    try await eventually { abandoned.executed.count == 1 }
    let id = try #require(abandoned.executed.first)
    #expect(try #require(gate.executed.first).contains("\"request\":\"\(id)\""))
}

@Test func hostCommandsDoNotWaitBehindPluginCalls() async throws {
    let gate = NativeCallGate(); defer { gate.release() }
    let worker = SerializedPluginWorker(interactiveWidth: 1) { _, json in gate.execute(json) }
    let stuck = Task { try await worker.request(resources: "app", json: "blocked") }
    try await eventually { gate.executed.count == 1 }
    // Starting a cloud-drive video needs its CDN address while every plugin slot is busy.
    #expect(try await worker.immediate(resources: "app", json: "directMedia") == "directMedia")
    gate.release()
    _ = try await stuck.value
}

@Test func hostStopsAndBaiduOrAliyunSignInsReadAsReasons() {
    #expect(PluginFailure.message(["error": .string("x"), "errorCode": .string("source_timeout")], language: "en")?.contains("took too long") == true)
    let baidu = PluginFailure.message(["error": .string("x"), "errorCode": .string("cloud_login_required"), "drive": .string("baidu")], language: "en")
    #expect(baidu?.contains("Baidu Netdisk") == true)
    #expect(CloudDriveLoginRequired(rawValue: "aliyun")?.message(language: "zh-Hans").contains("阿里云盘") == true)
}

@Test @MainActor func baiduAndAliyunSignInCodesReachTheAppWhileTheRequestRuns() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let watch = PluginSignIn.watch(folder: folder, source: "玩偶")
    let now = Date().timeIntervalSince1970 * 1000
    let code = "{\"drive\":\"baidu\",\"time\":\(now),\"seconds\":180,\"image\":\"https://passport.baidu.com/v2/api/qrcode?sign=abc\"}"
    try Data(code.utf8).write(to: folder.appendingPathComponent("login-prompt.json"))
    for _ in 0..<150 where PluginSignIn.shared.prompt == nil { try await Task.sleep(for: .milliseconds(20)) }
    let prompt = try #require(PluginSignIn.shared.prompt)
    #expect(prompt.drive == "baidu" && prompt.image?.absoluteString.hasSuffix("sign=abc") == true && prompt.source == "玩偶")
    // Scanned and confirmed: the code closes while the source restarts with the account.
    try await Task.sleep(for: .milliseconds(1100))
    try Data("{\"drive\":\"baidu\",\"time\":\(now + 2000),\"signedIn\":true}".utf8).write(to: folder.appendingPathComponent("login-prompt.json"))
    for _ in 0..<150 where PluginSignIn.shared.prompt != nil { try await Task.sleep(for: .milliseconds(20)) }
    #expect(PluginSignIn.shared.prompt == nil)
    // The request ends (played, failed or cancelled): the code goes away with it.
    await watch.end()
    #expect(PluginSignIn.shared.prompt == nil)
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("login-prompt.json").path))
}

@Test func aliyunSignInCarriesItsRefreshTokenInBizExt() {
    // bizExt is base64 of JSON whose names can be GBK; only the token matters.
    var json = Data("{\"pds_login_result\":{\"nickName\":\"".utf8)
    json.append(contentsOf: [0xD6, 0xD0])
    json.append(contentsOf: Data("\",\"refreshToken\":\"0123456789abcdef0123456789abcdef\"}}".utf8))
    #expect(CloudDriveQRLogin.aliyunRefreshToken(json.base64EncodedString()) == "0123456789abcdef0123456789abcdef")
    #expect(CloudDriveQRLogin.aliyunRefreshToken("not base64") == nil)
}


// Watch Now rows that the full queue turned away (report a8d5d1b15be4) call again instead of disappearing.
@Test func busyPluginQueueCallsAreRetried() async throws {
    final class Calls: @unchecked Sendable {
        let lock = NSLock(); var count = 0
        func next() -> Int { lock.withLock { count += 1; return count } }
    }
    let busy = TVError.unsupported(PluginQueue.busyMessage)
    let calls = Calls()
    let value = try await PluginQueue.retrying(delays: [0, 0, 0]) { () async throws -> String in
        if calls.next() < 3 { throw busy }
        return "row"
    }
    #expect(value == "row" && calls.count == 3)

    // Other failures are the source's own and are not retried.
    let failing = Calls()
    await #expect(throws: TVError.self) {
        try await PluginQueue.retrying(delays: [0, 0]) { () async throws -> String in _ = failing.next(); throw TVError.unsupported("HTTP 500") }
    }
    #expect(failing.count == 1)

    // A queue that stays full gives up after the last wait.
    let full = Calls()
    do {
        _ = try await PluginQueue.retrying(delays: [0, 0]) { () async throws -> String in _ = full.next(); throw busy }
        Issue.record("Expected the busy error")
    } catch { #expect(PluginQueue.isBusy(error)) }
    #expect(full.count == 3)
}

// The worker's own rejection is what `PluginQueue.isBusy` recognizes.
@Test func fullPluginQueueRejectionIsBusy() async throws {
    let gate = NativeCallGate(); defer { gate.release() }
    let worker = SerializedPluginWorker(maximumPending: 1, interactiveWidth: 1) { _, json in gate.execute(json) }
    let first = Task { try await worker.request(resources: "app", json: "blocked-1") }
    try await eventually { gate.executed.count == 1 }
    let second = Task { try await worker.request(resources: "app", json: "blocked-2") }
    try await eventually { worker.scheduling.pending == 1 }
    do {
        _ = try await worker.request(resources: "app", json: "blocked-3")
        Issue.record("Expected the busy error")
    } catch { #expect(PluginQueue.isBusy(error)) }
    gate.release()
    _ = try await first.value
    _ = try await second.value
}

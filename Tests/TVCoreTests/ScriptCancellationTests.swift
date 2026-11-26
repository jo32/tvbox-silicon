import Foundation
import Testing
@testable import TVCore

private func cancellationSession(_ source: String) async throws -> (ScriptSession, URL) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let session = try await ScriptSession.start(api: "https://scripts.example/cancel.js", key: "test", ext: "",
                                                profile: folder.appendingPathComponent("profile"), label: "test", source: source)
    return (session, folder)
}

/// A cancelled call stops a script that would otherwise run for its whole time, and the session keeps its state.
@Test func cancellingAScriptCallStopsItAndKeepsTheSession() async throws {
    let (session, folder) = try await cancellationSession("let calls = 0; export default { home() { return String(++calls); } };")
    defer { session.close(); try? FileManager.default.removeItem(at: folder) }
    #expect(try await session.call([:])["result"]?.string == "1")
    let started = Date()
    let busy = Task { await session.evaluate("(() => { while (true) {} })()", within: 30) }
    try await Task.sleep(for: .milliseconds(200))
    busy.cancel()
    let stopped = await busy.value
    #expect(stopped["error"] != nil)
    // Without cancellation the loop holds the VM for the full 30 s.
    #expect(Date().timeIntervalSince(started) < 15)
    #expect(try await session.call([:])["result"]?.string == "2")
}

/// A cancelled call's timers never run in a later call; a finished call's timers still do.
@Test func cancelledTimersStayCancelled() async throws {
    let (session, folder) = try await cancellationSession("export default { home() { return '1'; } };")
    defer { session.close(); try? FileManager.default.removeItem(at: folder) }
    _ = await session.evaluate("globalThis.kept = 0; setTimeout(() => kept++, 300); 1", within: 5)
    let pending = Task {
        await session.evaluate("globalThis.stale = 0; new Promise(resolve => setTimeout(() => { stale++; resolve(1); }, 2000))", within: 10)
    }
    try await Task.sleep(for: .milliseconds(100))
    pending.cancel()
    #expect(await pending.value["error"] != nil)
    let later = await session.evaluate("new Promise(resolve => setTimeout(() => resolve([globalThis.stale ?? 0, kept]), 2500))", within: 10)
    #expect(later["value"]?.array?.compactMap(\.int) == [0, 1], "\(later)")
}

/// A call's time starts when the VM takes it, not while it waits behind another call.
@Test func queuedScriptCallsGetTheirWholeTime() async throws {
    let (session, folder) = try await cancellationSession("export default { home() { return '1'; } };")
    defer { session.close(); try? FileManager.default.removeItem(at: folder) }
    let first = Task { await session.evaluate("(() => { const end = Date.now() + 1500; while (Date.now() < end) {} return 1; })()", within: 10) }
    try await Task.sleep(for: .milliseconds(50))
    let second = await session.evaluate("2", within: 1)
    #expect(second["value"]?.int == 2, "\(second)")
    #expect(await first.value["value"]?.int == 1)
}

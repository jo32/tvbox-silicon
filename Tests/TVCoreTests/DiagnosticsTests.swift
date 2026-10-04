import Foundation
import Testing
@testable import TVCore

@Test func diagnosticRotationAndExportRemainBounded() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let logger = Diagnostics(directory: root, fileLimit: 16_384, fileCount: 3)
    for batch in 0..<8 {
        for index in 0..<30 { logger.record(.info, "test", "\(batch)-\(index) " + String(repeating: "x", count: 1800)) }
        _ = await logger.snapshot()
    }
    let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    #expect(files.count == 3)
    for file in files {
        let data = try Data(contentsOf: file)
        #expect(data.count <= 16_384)
        for line in data.split(separator: 10) { _ = try JSONDecoder().decode(LogEntry.self, from: Data(line)) }
    }
    let exported = try Data(contentsOf: await logger.export())
    #expect(exported.count <= 3 * 16_384)
    #expect(String(decoding: exported, as: UTF8.self).contains("7-29"))
}

@Test func diagnosticOverloadAndRedaction() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let logger = Diagnostics(directory: root, capacity: 2)
    logger.record(.error, "test", "https://user:pass@example.com/path?token=sensitive\nAuthorization: Bearer abc\nCookie: session=xyz")
    logger.record(.info, "test", "second")
    for _ in 0..<100 { logger.record(.debug, "noise", "discard") }
    let snapshot = await logger.snapshot()
    #expect(snapshot.dropped == 100)
    let data = try Data(contentsOf: await logger.export())
    let output = try data.split(separator: 10).map { try JSONDecoder().decode(LogEntry.self, from: Data($0)).message }.joined(separator: "\n")
    for secret in ["user:pass", "sensitive", "Bearer abc", "session=xyz"] { #expect(!output.contains(secret)) }
    #expect(output.contains("example.com/path"))
}

@Test func diagnosticFileFailureDoesNotLoseViewerOrThrowToProducer() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data().write(to: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let logger = Diagnostics(directory: root.appendingPathComponent("invalid"))
    logger.record(.error, "test", "still visible")
    let snapshot = await logger.snapshot()
    #expect(snapshot.fileError != nil)
    #expect(snapshot.entries.first?.message == "still visible")
}

@Test func concurrentDiagnosticProducers() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let logger = Diagnostics(directory: root, capacity: 512)
    await withTaskGroup(of: Void.self) { group in
        for producer in 0..<8 {
            group.addTask { for index in 0..<50 { logger.record(.info, "concurrent", "\(producer):\(index)") } }
        }
    }
    let snapshot = await logger.snapshot()
    #expect(snapshot.entries.count == 400)
    #expect(snapshot.dropped == 0)
    #expect(Set(snapshot.entries.map(\.id)).count == 400)
}

@Test func pluginOutputReassemblesSecretsAcrossPipeReads() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let logger = Diagnostics(directory: root)
    let output = DiagnosticOutput(context: "session=test", logger: logger)
    output.accept(Data("Authorization: Bear".utf8))
    output.accept(Data("er secret\nhttps://example.com/?tok".utf8))
    output.accept(Data("en=private\nlast line".utf8), end: true)
    let snapshot = await logger.snapshot()
    #expect(snapshot.entries.count == 3)
    #expect(!snapshot.entries.map(\.message).joined().contains("secret"))
    #expect(!snapshot.entries.map(\.message).joined().contains("private"))
    #expect(snapshot.entries.last?.message.contains("last line") == true)
}

@Test func diagnosticOverloadPreservesErrors() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let logger = Diagnostics(directory: root, capacity: 2)
    logger.record(.debug, "test", "noise")
    logger.record(.info, "test", "noise")
    logger.record(.error, "test", "critical failure")
    let snapshot = await logger.snapshot()
    #expect(snapshot.dropped == 1)
    #expect(snapshot.entries.contains { $0.message == "critical failure" })
}

#if os(macOS)
@Test func pluginOutputFloodDoesNotBlockProcessExit() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let job = root.appendingPathComponent("job")
    try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("node")
    try Data("""
    #!/bin/sh
    i=0
    while [ "$i" -lt 5000 ]; do
      printf 'diagnostic flood line %s abcdefghijklmnopqrstuvwxyz0123456789\\n' "$i"
      i=$((i + 1))
    done
    exit 7
    """.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let process = try LocalJarProcess(host: root, job: job, request: job.appendingPathComponent("request.json"), context: "test flood", timeout: 5, script: true)
    do {
        _ = try await process.request([:], trace: "flood")
        Issue.record("Expected plugin exit error")
    } catch {
        #expect(error.localizedDescription.contains("stopped unexpectedly"))
    }
    #expect(!process.isRunning)
}
#endif

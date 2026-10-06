#if os(macOS)
import Foundation
import Testing
@testable import TVCore

/// Exercises the Mac's long-lived JVM transport against a real Java host. Needs
/// `Scripts/build-java-host.sh`; run with `TVBOX_JAVAHOST_TESTS=1 swift test`.
private let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../build").standardizedFileURL.path
private let enabled = ProcessInfo.processInfo.environment["TVBOX_JAVAHOST_TESTS"] != nil
    && FileManager.default.isExecutableFile(atPath: resources + "/JavaHost/jre/bin/java")

@Test(.enabled(if: enabled))
func pluginProcessAnswersConcurrentRequestsAndRestarts() async throws {
    let process = PluginProcess.shared
    // A request without a plugin archive fails inside Java; the failure still comes back as JSON.
    let replies = await withTaskGroup(of: Result<String, Error>.self) { group in
        for index in 0..<4 {
            group.addTask { process.call(resources: resources, json: "{\"session\":\"probe-\(index)\",\"params\":{}}") }
        }
        return await group.reduce(into: []) { $0.append($1) }
    }
    #expect(replies.count == 4)
    for reply in replies {
        let text = try reply.get()
        let envelope = try JSONDecoder().decode([String: JSONValue].self, from: Data(text.utf8))
        #expect(envelope["error"] != nil)
    }
    process.restart()
    let again = try process.call(resources: resources, json: "{\"params\":{}}").get()
    #expect(again.contains("error"))
    process.restart()
}
#endif

#if os(macOS)
import Foundation
import Testing
@testable import TVCore

/// The sandboxed JVM must bind its loopback bridge over IPv4: on macOS 15 Seatbelt refuses the
/// dual-stack IPv6 bind (report 3edeef4ef8d8, `CloudDriveBridge.listen` "Operation not permitted").
@Test(.enabled(if: SpiderSandbox.isEnabled && FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec")))
func sandboxedJavaBindsLoopbackOverIPv4() throws {
    let host = FileManager.default.temporaryDirectory.appendingPathComponent("spider-sandbox-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: host) }
    try Data("(version 1)".utf8).write(to: host.appendingPathComponent("spider.sb"))
    func wrapped(_ executable: String) -> [String] {
        SpiderSandbox.wrap(executable: host.appendingPathComponent(executable), arguments: ["-cp", "host.jar", "Main"],
                           host: host, cacheRoot: host, job: host, profile: host).arguments
    }
    let java = wrapped("jre/bin/java")
    let interpreter = try #require(java.firstIndex(of: "--")) + 1
    #expect(java[interpreter...].starts(with: [host.appendingPathComponent("jre/bin/java").path, "-Djava.net.preferIPv4Stack=true", "-cp", "host.jar", "Main"]))
    #expect(!wrapped("node").contains("-Djava.net.preferIPv4Stack=true"))
    #expect(!wrapped("python/bin/python3").contains("-Djava.net.preferIPv4Stack=true"))
}
#endif

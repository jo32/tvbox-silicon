#if os(macOS)
import Foundation

/// The Mac's plugin runtime: one long-lived desktop JVM (`tvbox.runtime.ProcessHost`) serving
/// the same requests the embedded JVM serves on iOS and tvOS. Requests run concurrently in it;
/// `SerializedPluginWorker` decides how many. Commands go in on stdin as JSON lines and each
/// answer comes back as an atomically written file, so a large reply never blocks a pipe.
/// The process starts on first use and again after it exits or `restart()`.
final class PluginProcess: @unchecked Sendable {
    static let shared = PluginProcess()
    static let available: Bool = {
        guard let resources = Bundle.main.resourceURL else { return false }
        let host = resources.appendingPathComponent("JavaHost")
        return FileManager.default.isExecutableFile(atPath: host.appendingPathComponent("jre/bin/java").path)
            && FileManager.default.fileExists(atPath: host.appendingPathComponent("host.jar").path)
    }()

    private final class Instance {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let root: URL
        init(root: URL) { self.root = root }
        var responses: URL { root.appendingPathComponent("responses", isDirectory: true) }
    }
    /// Guards `instance` and writes to its stdin.
    private let lock = NSLock()
    private var instance: Instance?

    /// Blocks the calling worker thread until Java answers or the process exits.
    func call(resources: String, json: String) -> Result<String, Error> {
        let current: Instance
        do { current = try running(resources: resources) } catch { return .failure(error) }
        let id = UUID().uuidString
        let response = current.responses.appendingPathComponent(id + ".json")
        do {
            try lock.withLock {
                try current.input.fileHandleForWriting.write(contentsOf: Data("{\"id\":\"\(id)\",\"input\":\(json)}\n".utf8))
            }
        } catch {
            return .failure(TVError.unsupported(L10n.text("The plugin stopped unexpectedly. Retry this source.")))
        }
        // The worker's own watchdog decides when a call is too slow; this only notices a dead host.
        while true {
            if let data = try? Data(contentsOf: response) {
                try? FileManager.default.removeItem(at: response)
                return .success(String(decoding: data, as: UTF8.self))
            }
            guard current.process.isRunning else {
                return .failure(TVError.unsupported(L10n.text("The plugin stopped unexpectedly. Retry this source.")))
            }
            usleep(20_000)
        }
    }

    /// Stops the host; the next call starts a fresh one. In-flight calls fail.
    func restart() {
        let retired = lock.withLock { () -> Instance? in defer { instance = nil }; return instance }
        if let retired { stop(retired) }
    }

    private func running(resources: String) throws -> Instance {
        try lock.withLock {
            if let instance, instance.process.isRunning { return instance }
            if let instance { stop(instance) }
            let started = try start(host: URL(fileURLWithPath: resources).appendingPathComponent("JavaHost"))
            instance = started
            return started
        }
    }

    private func start(host: URL) throws -> Instance {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.tvbox.yingxia/PluginHost/" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let started = Instance(root: root)
        let process = started.process
        process.executableURL = host.appendingPathComponent("jre/bin/java")
        // Lazy DEX conversion: a source only converts the classes it actually loads, as on iOS and tvOS.
        process.arguments = ["--add-opens", "java.base/java.lang=ALL-UNNAMED", "--add-opens", "java.base/sun.net.www.protocol.jar=ALL-UNNAMED",
                             "-Dtvbox.lazyDex=true", "-Dorg.slf4j.simpleLogger.defaultLogLevel=error",
                             "-cp", host.appendingPathComponent("host.jar").path + ":" + host.appendingPathComponent("lib/*").path,
                             "tvbox.runtime.ProcessHost", root.path]
        process.currentDirectoryURL = root
        process.standardInput = started.input
        process.standardOutput = started.output
        process.standardError = started.output
        let context = "host=\(root.lastPathComponent.prefix(8))"
        let captured = DiagnosticOutput(context: context)
        started.output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            captured.accept(data, end: data.isEmpty)
            if data.isEmpty { handle.readabilityHandler = nil }
        }
        process.terminationHandler = { process in
            Diagnostics.shared.record(process.terminationStatus == 0 ? .info : .warning, "jar.process",
                                      "\(context) exited status=\(process.terminationStatus) reason=\(process.terminationReason.rawValue)")
        }
        try process.run()
        Diagnostics.shared.record(.info, "jar.process", "\(context) started pid=\(process.processIdentifier)")
        // The JVM itself starts in about a second; plugin start-up happens per request.
        let ready = root.appendingPathComponent("ready.json")
        let deadline = Date().addingTimeInterval(60)
        while !FileManager.default.fileExists(atPath: ready.path) {
            guard process.isRunning, Date() < deadline else {
                stop(started)
                throw TVError.unsupported(L10n.text("The plugin took too long to initialize. Retry or choose another source."))
            }
            usleep(20_000)
        }
        return started
    }

    private func stop(_ instance: Instance) {
        try? instance.input.fileHandleForWriting.close()
        if instance.process.isRunning {
            instance.process.terminate()
            for _ in 0..<20 where instance.process.isRunning { usleep(50_000) }
            if instance.process.isRunning { kill(instance.process.processIdentifier, SIGKILL) }
        }
        try? FileManager.default.removeItem(at: instance.root)
    }
}
#endif

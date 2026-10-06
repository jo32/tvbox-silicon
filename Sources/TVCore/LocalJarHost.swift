#if os(macOS)
import Foundation
import CryptoKit

/// Each source owns a bounded, reusable JVM session. Requests to a session are serialized.
public actor LocalJarHost {
    public static let shared = LocalJarHost()
    // Bundle resources are fixed for the process lifetime; views query these while rendering.
    public static let available: Bool = Bundle.main.resourceURL.map { FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("JavaHost/jre/bin/java").path) } ?? false
    public static let scriptAvailable: Bool = Bundle.main.resourceURL.map { FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("ScriptHost/node").path) } ?? false
    private final class Entry {
        let task: Task<LocalJarProcess, Error>
        let sourceKey: String
        var ready = false
        var lastUse = Date()
        var active = 0
        init(_ task: Task<LocalJarProcess, Error>, sourceKey: String) { self.task = task; self.sourceKey = sourceKey }
    }
    private var sessions: [String: Entry] = [:]

    /// Snapshot only: do not wait for a still-starting process when ordering search.
    public func reusableSourceKeys() -> Set<String> {
        Set(sessions.values.filter { $0.ready && Date().timeIntervalSince($0.lastUse) < 300 }.map(\.sourceKey))
    }

    public func request(site: Site, jarURL: URL, params: [String: String], http: HTTPClient, scriptOrigin: URL? = nil, configurationOrigin: URL? = nil, progress: PluginPreparation? = nil) async throws -> [String: JSONValue] {
        let trace = String(UUID().uuidString.prefix(8))
        let started = ContinuousClock.now
        let context = "request=\(trace) source=\(site.key)"
        Diagnostics.shared.record(.info, "jar.request", "\(context) begin operation=\(params["ac"] ?? "home")")
        let script = scriptOrigin != nil
        guard let resources = Bundle.main.resourceURL, (script ? Self.scriptAvailable : Self.available) else {
            Diagnostics.shared.record(.error, "jar.runtime", "\(context) runtime unavailable")
            throw TVError.unsupported(L10n.text("The local JAR runtime is not installed."))
        }
        let pluginData: Data?
        if script { pluginData = nil }
        else {
            pluginData = try await PluginDownloads.shared.data(at: jarURL, http: http) { stage, received, expected in
                progress?.report(stage, received: received, expected: expected)
            }
            try Task.checkCancellation()
            progress?.report(.verifying)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let configuration = try encoder.encode(site.raw)
        let identity = Data((jarURL.absoluteString + "\n" + site.key + "\n" + site.api + "\n" + ((scriptOrigin ?? configurationOrigin)?.absoluteString ?? "")).utf8) + configuration
        let profileKey = PluginChecksum.sha256(identity)
        let key = profileKey + (pluginData.map { "-" + PluginChecksum.sha256($0) } ?? "")
        // Evict only idle sources. An in-flight request must not be killed by navigation elsewhere.
        for (other, entry) in sessions.sorted(by: { $0.value.lastUse < $1.value.lastUse }) where other != key && entry.active == 0 {
            if let process = try? await entry.task.value, process.hasRecentMediaActivity { continue }
            if sessions.count >= 3 || Date().timeIntervalSince(entry.lastUse) > 300 {
                sessions.removeValue(forKey: other)
                let retired = entry.task
                Task { if let process = try? await retired.value { process.stop() } }
            }
        }
        if let existing = sessions[key], existing.active == 0,
           let process = try? await existing.task.value, !process.isRunning { sessions.removeValue(forKey: key) }
        let entry: Entry
        if let existing = sessions[key] { entry = existing }
        else {
            let task = Task {
                let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("com.tvbox.yingxia/JarHost", isDirectory: true)
                let job = root.appendingPathComponent("Sessions/" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
                do {
                    Diagnostics.shared.record(.info, "jar.download", "\(context) downloading host=\(jarURL.host ?? "local")")
                    let data: Data
                    if let pluginData { data = pluginData }
                    else { data = try await PluginDownloads.shared.data(at: jarURL, http: http) }
                    Diagnostics.shared.record(.info, "jar.download", "\(context) downloaded bytes=\(data.count)")
                    try Task.checkCancellation()
                    let jar = job.appendingPathComponent("plugin.jar")
                    try data.write(to: jar)
                    var ext: String
                    if let value = try site.pluginExtension(origin: scriptOrigin ?? configurationOrigin) { ext = try value.string ?? String(data: encoder.encode(value), encoding: .utf8) ?? "" } else { ext = "" }
                    if let scriptOrigin, !ext.isEmpty, !ext.hasPrefix("{") { ext = (try? WebAddress.resolve(ext, relativeTo: scriptOrigin).absoluteString) ?? ext }
                    let input: [String: Any] = ["script": jar.path, "jar": jar.path, "cache": job.path, "conversionCache": root.appendingPathComponent("Converted", isDirectory: true).path, "profile": root.appendingPathComponent("Profiles/" + profileKey).path, "api": script ? jarURL.absoluteString : site.api, "key": site.key, "ext": ext, "cloudAccounts": CloudDriveAccounts.fileURL.path]
                    let request = job.appendingPathComponent("request.json")
                    try JSONSerialization.data(withJSONObject: input).write(to: request)
                    return try LocalJarProcess(host: resources.appendingPathComponent(script ? "ScriptHost" : "JavaHost"), job: job, request: request, context: "source=\(site.key) session=\(job.lastPathComponent)", script: script)
                } catch { try? FileManager.default.removeItem(at: job); throw error }
            }
            entry = Entry(task, sourceKey: site.key); sessions[key] = entry
        }
        entry.active += 1; entry.lastUse = Date()
        defer { entry.active -= 1; entry.lastUse = Date() }
        do {
            let process = try await entry.task.value
            progress?.report(entry.ready ? .loading : .preparing)
            let monitor = progress?.observe(process.preparationURL)
            defer { monitor?.cancel() }
            try Task.checkCancellation()
            var envelope = try await process.request(params, trace: trace)
            entry.ready = true
            // NewCz's upstream cookie challenge is intermittent. Retry at most once,
            // retaining the cookie/profile instead of starting another empty process.
            if site.api == "csp_NewCzGuard", envelope["errorCode"]?.string == "source_http", envelope["status"]?.int == 403 {
                Diagnostics.shared.record(.warning, "jar.retry", "\(context) HTTP 403 retry=1")
                try await Task.sleep(for: .milliseconds(300))
                envelope = try await process.request(params, trace: trace)
            }
            try Task.checkCancellation()
            if let error = Self.errorMessage(envelope) { throw TVError.unsupported(error) }
            guard let text = envelope["result"]?.string, !text.isEmpty, let payload = text.data(using: .utf8) else {
                throw TVError.unsupported(L10n.text("The plugin returned no content. Try another source."))
            }
            let result = try JSONDecoder().decode([String: JSONValue].self, from: payload)
            Diagnostics.shared.record(.info, "jar.request", "\(context) complete duration=\(started.duration(to: .now)) bytes=\(payload.count)")
            return result
        } catch {
            Diagnostics.shared.record(error is CancellationError ? .info : .error, "jar.request", "\(context) failed duration=\(started.duration(to: .now)) error=\(error.localizedDescription)")
            if sessions[key] === entry {
                if let process = try? await entry.task.value {
                    if !process.isRunning { sessions.removeValue(forKey: key) }
                } else { sessions.removeValue(forKey: key) }
            }
            throw error
        }
    }

    public func reloadCloudAccounts() async {
        let old = sessions.values.map(\.task)
        sessions.removeAll()
        for task in old { if let process = try? await task.value { process.stop() } }
    }

    static func errorMessage(_ envelope: [String: JSONValue], language: String? = nil) -> String? {
        PluginFailure.message(envelope, language: language)
    }
}

/// The serial queue owns process I/O; atomic response files avoid pipe buffering/deadlock.
final class LocalJarProcess: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let queue = DispatchQueue(label: "tvbox.jar-session")
    private let job: URL
    private let output = Pipe()
    private let context: String
    private let capturedOutput: DiagnosticOutput
    private var timer: DispatchSourceTimer?
    private var lastUse = Date()
    private let timeout: TimeInterval
    private let startupTimeout: TimeInterval
    var isRunning: Bool { process.isRunning }
    var preparationURL: URL { job.appendingPathComponent("preparation-progress.json") }
    var hasRecentMediaActivity: Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: job.appendingPathComponent("proxy-active").path),
              let date = attributes[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(date) < 300
    }

    init(host: URL, job: URL, request: URL, context: String, timeout: TimeInterval = 60, script: Bool = false) throws {
        self.job = job; self.context = context; self.timeout = timeout
        self.startupTimeout = script ? timeout : max(timeout, 180)
        let capturedOutput = DiagnosticOutput(context: context)
        self.capturedOutput = capturedOutput
        process.executableURL = host.appendingPathComponent("jre/bin/java")
        process.arguments = ["--add-opens", "java.base/java.lang=ALL-UNNAMED", "--add-opens", "java.base/sun.net.www.protocol.jar=ALL-UNNAMED", "-Dorg.slf4j.simpleLogger.defaultLogLevel=error", "-cp", host.appendingPathComponent("host.jar").path + ":" + host.appendingPathComponent("lib/*").path, "tvbox.runtime.NativeProbe", "--serve", request.path]
        if script {
            process.executableURL = host.appendingPathComponent("node")
            process.arguments = ["--no-warnings", "--experimental-vm-modules", host.appendingPathComponent("host.mjs").path, "--serve", request.path]
        }
        process.currentDirectoryURL = job
        process.standardInput = input; process.standardOutput = output; process.standardError = output
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            capturedOutput.accept(data, end: data.isEmpty)
            if data.isEmpty { handle.readabilityHandler = nil }
        }
        process.terminationHandler = { process in
            Diagnostics.shared.record(process.terminationStatus == 0 ? .info : .warning, "jar.process", "\(context) exited status=\(process.terminationStatus) reason=\(process.terminationReason.rawValue)")
        }
        do { try process.run() }
        catch { output.fileHandleForReading.readabilityHandler = nil; throw error }
        Diagnostics.shared.record(.info, "jar.process", "\(context) started pid=\(process.processIdentifier)")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            guard let self, !self.hasRecentMediaActivity, Date().timeIntervalSince(self.lastUse) > 300 else { return }
            self.shutdown()
        }
        self.timer = timer; timer.resume()
    }

    func request(_ params: [String: String], trace: String) async throws -> [String: JSONValue] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.lastUse = Date()
                defer {
                    self.lastUse = Date()
                }
                do {
                    let ready = try self.waitFor(self.job.appendingPathComponent("ready.json"), deadline: Date().addingTimeInterval(self.startupTimeout))
                    if ready["error"] != nil { continuation.resume(returning: ready); self.shutdown(); return }
                    let id = UUID().uuidString
                    Diagnostics.shared.record(.info, "jar.command", "\(self.context) request=\(trace) command=\(id)")
                    let command: [String: Any] = ["id": id, "params": params]
                    var data = try JSONSerialization.data(withJSONObject: command); data.append(0x0A)
                    try self.input.fileHandleForWriting.write(contentsOf: data)
                    let response = self.job.appendingPathComponent("responses/" + id + ".json")
                    let value = try self.waitFor(response, deadline: Date().addingTimeInterval(self.timeout))
                    try? FileManager.default.removeItem(at: response)
                    continuation.resume(returning: value)
                } catch {
                    self.shutdown(); continuation.resume(throwing: error)
                }
            }
        }
    }

    private func waitFor(_ url: URL, deadline: Date) throws -> [String: JSONValue] {
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url)) }
            guard process.isRunning else { throw TVError.unsupported(L10n.text("The plugin stopped unexpectedly. Retry this source.")) }
            usleep(50_000)
        }
        let startup = url.lastPathComponent == "ready.json"
        Diagnostics.shared.record(.error, "jar.timeout", "\(context) timeout seconds=\(startup ? startupTimeout : timeout) stage=\(startup ? "startup" : "response")")
        if startup { throw TVError.unsupported(L10n.text("The plugin took too long to initialize. Retry or choose another source.")) }
        throw TVError.unsupported(L10n.text("The plugin request timed out after 60 seconds. Retry or choose another source."))
    }
    func stop() { queue.async { self.shutdown() } }
    private func shutdown() {
        timer?.cancel(); timer = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            for _ in 0..<10 where process.isRunning { usleep(50_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        output.fileHandleForReading.readabilityHandler = nil
        capturedOutput.accept(Data(), end: true)
        try? output.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? FileManager.default.removeItem(at: job)
    }
    deinit {
        timer?.cancel()
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        output.fileHandleForReading.readabilityHandler = nil
        capturedOutput.accept(Data(), end: true)
        try? output.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
    }
}
#endif

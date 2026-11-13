#if os(iOS) || os(tvOS)
import Foundation

@_silgen_name("TVPythonRequest")
private func pythonRequest(_ resources: UnsafePointer<CChar>, _ request: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?

/// Python sources on iOS and tvOS. One CPython embedded in the app (`ApplePython.c`) runs the same
/// `host.py` and `base/` as the Mac's sandboxed Python process. Each source keeps its own spider,
/// profile and media proxy; a spider answers one request at a time, and sources run side by side.
/// Running Python can't be interrupted: a request past its deadline is abandoned, as the JVM's are.
public actor EmbeddedPythonHost {
    public static let shared = EmbeddedPythonHost()
    /// Only builds that embedded `Scripts/build-apple-python.sh`'s output have Python.
    public static let available: Bool = {
        guard let frameworks = Bundle.main.privateFrameworksURL,
              Bundle.main.url(forResource: "host", withExtension: "py", subdirectory: "PythonHost") != nil else { return false }
        return FileManager.default.fileExists(atPath: frameworks.appendingPathComponent("Python.framework/Python").path)
    }()
    private let worker = SerializedPluginWorker(timeout: 150, width: EmbeddedJarHost.searchWidth) { resources, json in
        resources.withCString { resources in
            json.withCString { json in
                guard let output = pythonRequest(resources, json) else {
                    return .failure(TVError.unsupported("The Python runtime returned no response."))
                }
                defer { free(output) }
                return .success(String(cString: output))
            }
        }
    }

    public func request(site: Site, scriptURL: URL, params: [String: String], http: HTTPClient, origin: URL) async throws -> [String: JSONValue] {
        guard Self.available, let resources = Bundle.main.resourcePath else {
            throw TVError.unsupported(L10n.text("This source requires a Python runtime, which is not available on this platform."))
        }
        let data = try await PluginDownloads.shared.data(at: scriptURL, http: http)
        try PluginDownloads.refuseWebPageScript(data)
        try Task.checkCancellation()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let identity = Data((scriptURL.absoluteString + "\n" + site.key + "\n" + site.api + "\n" + origin.absoluteString).utf8) + (try encoder.encode(site.raw))
        let profileKey = PluginChecksum.sha256(identity)
        let digest = PluginChecksum.sha256(data)
        // A changed script at the same address is a new session; its profile (spider cache) stays.
        let session = profileKey + "-" + digest
        let root = Self.storageRoot
        let script = root.appendingPathComponent("Scripts/" + digest + ".py")
        let job = root.appendingPathComponent("Sessions/" + session, isDirectory: true)
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: script.path) { try data.write(to: script, options: .atomic) }
        var ext = ""
        if let value = try site.pluginExtension(origin: origin) { ext = try value.string ?? String(decoding: encoder.encode(value), as: UTF8.self) }
        // A legacy `py_` source's ext is the script itself; the host then reads `?extend=` from it.
        if site.api.hasPrefix("py_") { ext = "" }
        let input: [String: JSONValue] = [
            "session": .string(session), "script": .string(script.path), "cache": .string(job.path),
            "profile": .string(root.appendingPathComponent("Profiles/" + profileKey).path),
            "api": .string(scriptURL.absoluteString), "key": .string(site.sourceKey), "ext": .string(ext),
            "params": .object(params.mapValues(JSONValue.string)),
        ]
        let json = String(decoding: try encoder.encode(input), as: UTF8.self)
        let kind = EmbeddedJarHost.kind(params)
        let started = ContinuousClock.now
        Diagnostics.shared.record(.info, "jar.request", "source=\(site.key) python \(kind) begin")
        let response = try await worker.request(resources: resources, json: json, search: params["wd"] != nil)
        let envelope = try JSONDecoder().decode([String: JSONValue].self, from: Data(response.utf8))
        if let message = PluginFailure.message(envelope) {
            Diagnostics.shared.record(.error, "jar.request", "source=\(site.key) python \(kind) failed duration=\(started.duration(to: .now)) error=\(message)")
            throw TVError.unsupported(message)
        }
        guard let text = envelope["result"]?.string, !text.isEmpty else {
            throw TVError.unsupported(L10n.text("The plugin returned no content. Try another source."))
        }
        Diagnostics.shared.record(.info, "jar.request", "source=\(site.key) python \(kind) complete duration=\(started.duration(to: .now)) bytes=\(text.utf8.count)")
        return try JSONDecoder().decode([String: JSONValue].self, from: Data(text.utf8))
    }

    /// Scripts download again on demand, but profiles hold what spiders cache (sign-ins among it),
    /// so iOS keeps them out of purgeable Caches. tvOS only permits Caches.
    static let storageRoot: URL = {
        let manager = FileManager.default
        #if os(iOS)
        let root = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("com.tvbox.yingxia/EmbeddedPython", isDirectory: true)
        try? manager.createDirectory(at: root, withIntermediateDirectories: true)
        var excluded = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        return root
        #else
        return manager.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("com.tvbox.yingxia/EmbeddedPython", isDirectory: true)
        #endif
    }()
}
#endif

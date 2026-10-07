#if os(iOS) || os(tvOS) || os(macOS)
import Foundation
import CryptoKit

#if !os(macOS)
@_silgen_name("TVAppleRuntimeRequest")
private func nativePluginRequest(_ resources: UnsafePointer<CChar>, _ request: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
#endif

/// One JVM per app, shared by every plugin source: sources from one archive share a runtime
/// (Init and native guards load once). Calls run on large-stack worker threads: searches up to
/// `searchWidth` at once, and home, detail and playback on their own slots beside them.
/// iOS and tvOS embed the JVM and call it over JNI. macOS runs the same Java host in one
/// long-lived desktop JVM (`PluginProcess`), which has a JIT and needs no embedding.
public actor EmbeddedJarHost {
    public static let shared = EmbeddedJarHost()
    public static let searchWidth = 5
    public static var available: Bool {
        #if os(macOS)
        PluginProcess.available
        #else
        Bundle.main.url(forResource: "host", withExtension: "jar", subdirectory: "JavaHost") != nil
        #endif
    }
    #if os(macOS)
    private let worker = SerializedPluginWorker(width: EmbeddedJarHost.searchWidth) { resources, json in
        PluginProcess.shared.call(resources: resources, json: json)
    }
    /// New cloud-drive cookies apply to spiders created afterwards; restart so every source rereads them.
    public func reloadCloudAccounts() { PluginProcess.shared.restart() }
    #else
    private let worker = SerializedPluginWorker(width: EmbeddedJarHost.searchWidth) { resources, json in
        resources.withCString { resources in
            json.withCString { json in
                guard let output = nativePluginRequest(resources, json) else {
                    return .failure(TVError.unsupported("The plugin runtime returned no response."))
                }
                defer { free(output) }
                return .success(String(cString: output))
            }
        }
    }
    #endif
    public func request(site: Site, jarURL: URL, params: [String: String], http: HTTPClient, configurationOrigin: URL, progress: PluginPreparation? = nil) async throws -> [String: JSONValue] {
        guard Self.available, let resources = Bundle.main.resourcePath else { throw TVError.unsupported("The on-device plugin runtime is missing from this build.") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let identity = Data((jarURL.absoluteString + site.key + configurationOrigin.absoluteString).utf8) + (try encoder.encode(site.raw))
        let profileKey = PluginChecksum.sha256(identity)
        let root = Self.storageRoot
        // Revalidate even when a session exists: a changed JAR at the same URL
        // gets a new session, while unchanged bytes retain their conversion cache.
        let data = try await PluginDownloads.shared.data(at: jarURL, http: http) { stage, received, expected in
            progress?.report(stage, received: received, expected: expected)
        }
        try Task.checkCancellation()
        // Dead or blocked plugin hosts answer with a web page; the archive reader would only say "zip END header not found".
        let start = String(decoding: data.prefix(256), as: UTF8.self).lowercased()
        if start.contains("<!doctype") || start.contains("<html") {
            throw TVError.unsupported(L10n.text("The plugin download returned a web page instead of a plugin. Its host may be offline."))
        }
        progress?.report(.verifying)
        let digest = PluginChecksum.sha256(data)
        let key = profileKey + "-" + digest
        let job = root.appendingPathComponent(key, isDirectory: true)
        let archives = root.appendingPathComponent("Jars", isDirectory: true)
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archives, withIntermediateDirectories: true)
        let jar = archives.appendingPathComponent(digest + ".jar")
        if (try? Data(contentsOf: jar)).map(PluginChecksum.sha256) != digest {
            try data.write(to: jar, options: .atomic)
        }
        let value = try site.pluginExtension(origin: configurationOrigin)
        let ext = try value?.string ?? value.map { String(decoding: try encoder.encode($0), as: UTF8.self) } ?? ""
        // Preserve existing account/preferences location when adding content-based session identity.
        // Sources from the same archive share one runtime: its Init and native guard load once.
        let runtime = root.appendingPathComponent("Runtimes", isDirectory: true).appendingPathComponent(digest, isDirectory: true)
        var input: [String: JSONValue] = ["session": .string(key), "runtime": .string(digest), "runtimeCache": .string(runtime.path), "jar": .string(jar.path), "cache": .string(job.path), "conversionCache": .string(root.appendingPathComponent("Converted").path), "profile": .string(root.appendingPathComponent(profileKey).appendingPathComponent("profile").path), "api": .string(site.api), "key": .string(site.key), "ext": .string(ext)]
        // Saved Quark/UC sign-ins; the spider reads them when it is created.
        input["cloudAccounts"] = .string(CloudDriveAccounts.fileURL.path)
        #if !os(macOS)
        // The embedded JVM cannot restart, so a new sign-in opens a fresh session for the source.
        let accounts = CloudDriveAccounts.revision
        if !accounts.isEmpty { input["session"] = .string(key + "-" + accounts) }
        #endif
        progress?.report(.queued)
        let monitor = progress?.observe(job.appendingPathComponent("preparation-progress.json"))
        defer { monitor?.cancel() }
        input["params"] = .object(params.mapValues(JSONValue.string))
        let json = String(decoding: try encoder.encode(input), as: UTF8.self)
        Diagnostics.shared.record(.info, "jar.request", "source=\(site.key) begin; first preparation can take several minutes")
        var response = try await worker.request(resources: resources, json: json, search: params["wd"] != nil)
        PluginPreparation.runtimeReady = true
        var envelope = try JSONDecoder().decode([String: JSONValue].self, from: Data(response.utf8))
        // NewCz's upstream cookie challenge is intermittent. Retry once; the spider keeps its cookie.
        if site.api == "csp_NewCzGuard", envelope["errorCode"]?.string == "source_http", envelope["status"]?.int == 403 {
            Diagnostics.shared.record(.warning, "jar.retry", "source=\(site.key) HTTP 403 retry=1")
            try await Task.sleep(for: .milliseconds(300))
            response = try await worker.request(resources: resources, json: json, search: params["wd"] != nil)
            envelope = try JSONDecoder().decode([String: JSONValue].self, from: Data(response.utf8))
        }
        if let message = PluginFailure.message(envelope) {
            Diagnostics.shared.record(.error, "jar.request", PluginFailure.diagnostic(source: site.key, envelope))
            if let name = envelope["error"]?.string.flatMap(PluginClassMissing.className(in:)) {
                throw PluginClassMissing(className: name, message: message)
            }
            if PluginFailure.inPlugin(envelope) { throw PluginIncompatible(message: message) }
            throw TVError.unsupported(message)
        }
        guard let result = envelope["result"]?.string else { throw TVError.unsupported("The plugin returned no content.") }
        Diagnostics.shared.record(.info, "jar.request", "source=\(site.key) completed bytes=\(result.utf8.count)")
        return try JSONDecoder().decode([String: JSONValue].self, from: Data(result.utf8))
    }

    /// Converted classes take minutes to regenerate, so iOS and macOS keep them out of purgeable
    /// Caches. tvOS only permits Caches; there a purge means preparing the plugin again.
    private static let storageRoot: URL = {
        let manager = FileManager.default
        let cached = manager.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("com.tvbox.yingxia/EmbeddedPlugins", isDirectory: true)
        #if os(iOS) || os(macOS)
        var root = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("com.tvbox.yingxia/EmbeddedPlugins", isDirectory: true)
        if !manager.fileExists(atPath: root.path) {
            try? manager.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: cached.path) { try? manager.moveItem(at: cached, to: root) }
        }
        try? manager.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        return root
        #else
        return cached
        #endif
    }()
}

#endif

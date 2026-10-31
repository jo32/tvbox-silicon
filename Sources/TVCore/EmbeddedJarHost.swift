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
    private let worker = SerializedPluginWorker(width: EmbeddedJarHost.searchWidth, abandon: { resources, id in
        _ = PluginProcess.shared.call(resources: resources, json: EmbeddedJarHost.cancelCommand(id))
    }) { resources, json in
        PluginProcess.shared.call(resources: resources, json: json)
    }
    /// New cloud-drive cookies apply to spiders created afterwards; restart so every source rereads them.
    public func reloadCloudAccounts() { PluginProcess.shared.restart() }
    #else
    private let worker = SerializedPluginWorker(width: EmbeddedJarHost.searchWidth, abandon: { resources, id in
        resources.withCString { resources in
            EmbeddedJarHost.cancelCommand(id).withCString { command in free(nativePluginRequest(resources, command)) }
        }
    }) { resources, json in
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
    /// Abandons a running request: if it is still waiting to open its plugin, it stops waiting.
    static func cancelCommand(_ id: String) -> String { "{\"command\":\"cancel\",\"request\":\"\(id)\"}" }

    /// A plugin's loopback address for a cloud-drive file (`/drive/`) or its own media proxy (`/media`).
    public static func isPluginProxy(_ url: URL) -> Bool {
        url.scheme == "http" && url.host == "127.0.0.1" && (url.path.contains("/drive/") || url.path.hasSuffix("/media"))
    }
    /// Which plugin proxy route an address uses (`drive` or `media do=<value>`), for diagnostics without the file's identity.
    public static func proxyRoute(_ url: URL) -> String {
        if url.path.contains("/drive/") { return "drive" }
        let action = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "do" })?.value
        return "media do=\(action ?? "-")"
    }

    /// Reopens a plugin's loopback listener after suspension, including retries of a cached URL.
    public func recoverProxy(_ url: URL) async throws -> URL {
        guard Self.isPluginProxy(url), Self.available, let resources = Bundle.main.resourcePath else { return url }
        let input = ["command": "recoverProxy", "url": url.absoluteString]
        let json = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
        let response = try await worker.immediate(resources: resources, json: json)
        let envelope = try JSONDecoder().decode([String: JSONValue].self, from: Data(response.utf8))
        if let error = envelope["error"]?.string { throw TVError.unsupported(error) }
        guard let address = envelope["result"]?.string else { return url }
        return try WebAddress.resolve(address)
    }

    /// The CDN address and headers behind a plugin's cloud-drive or media proxy address, or nil
    /// when the plugin did not reveal them. The app then streams the file itself (`CloudStreams`).
    public func directMedia(_ url: URL) async -> CloudStreams.Source? {
        guard Self.isPluginProxy(url),
              Self.available, let resources = Bundle.main.resourcePath,
              let input = try? JSONEncoder().encode(["command": "directMedia", "url": url.absoluteString]),
              let response = try? await worker.immediate(resources: resources, json: String(decoding: input, as: UTF8.self)),
              let envelope = try? JSONDecoder().decode([String: JSONValue].self, from: Data(response.utf8)),
              case .object(let media)? = envelope["result"],
              let address = media["url"]?.string, let direct = URL(string: address), direct.scheme == "https" || direct.scheme == "http",
              case .number(let length)? = media["length"], length > 0 else { return nil }
        var headers: [String: String] = [:]
        if case .object(let values)? = media["headers"] { for (name, value) in values { headers[name] = value.string } }
        return CloudStreams.Source(url: direct, headers: headers, length: Int(length), name: url.lastPathComponent)
    }

    public func request(site: Site, jarURL: URL, params: [String: String], http: HTTPClient, configurationOrigin: URL, progress: PluginPreparation? = nil) async throws -> [String: JSONValue] {
        guard Self.available, let resources = Bundle.main.resourcePath else { throw TVError.unsupported("The on-device plugin runtime is missing from this build.") }
        // Ahead-of-time conversion waits until requests have been quiet for a while.
        PluginConversionAhead.requestStarted()
        defer { PluginConversionAhead.requestEnded() }
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
        try Self.refuseWebPage(data)
        progress?.report(.verifying)
        let (digest, jar) = try Self.store(data)
        let key = profileKey + "-" + digest
        let job = root.appendingPathComponent(key, isDirectory: true)
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        let value = try site.pluginExtension(origin: configurationOrigin)
        let ext = try value?.string ?? value.map { String(decoding: try encoder.encode($0), as: UTF8.self) } ?? ""
        // Preserve existing account/preferences location when adding content-based session identity.
        // Sources from the same archive share one runtime: its Init and native guard load once.
        let runtime = root.appendingPathComponent("Runtimes", isDirectory: true).appendingPathComponent(digest, isDirectory: true)
        var input: [String: JSONValue] = ["session": .string(key), "runtime": .string(digest), "runtimeCache": .string(runtime.path), "jar": .string(jar.path), "cache": .string(job.path), "conversionCache": .string(root.appendingPathComponent("Converted").path), "profile": .string(root.appendingPathComponent(profileKey).appendingPathComponent("profile").path), "api": .string(site.api), "key": .string(site.sourceKey), "ext": .string(ext)]
        // Plugins read the loaded subscription from the host app's database (see HostDatabase.java).
        input["subscription"] = .string(configurationOrigin.absoluteString)
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
        let kind = Self.kind(params)
        // Once the spider starts on it, the host stops a request at its deadline: plugins wait for
        // Android sign-ins that never come here, and the source takes one request at a time.
        input["deadline"] = .number(Self.deadline(kind))
        let json = String(decoding: try encoder.encode(input), as: UTF8.self)
        Diagnostics.shared.record(.info, "jar.request", "source=\(site.key) \(kind)\(params["flag"].map { " flag=\($0)" } ?? "") begin")
        // A Baidu or Aliyun line may wait for its sign-in code to be scanned: the app shows it meanwhile.
        let signIn = params["wd"] == nil ? PluginSignIn.watch(folder: job, source: site.name) : nil
        var response: String
        do {
            response = try await worker.request(resources: resources, json: json, search: params["wd"] != nil) {
                progress?.report(PluginPreparation.runtimeReady ? .loading : .preparing)
            }
            await signIn?.end()
        } catch {
            await signIn?.end()
            throw error
        }
        PluginPreparation.runtimeReady = true
        // A Baidu or Aliyun sign-in only this plugin had becomes the app's, for every source.
        Self.adoptPluginAccounts(in: job)
        var envelope = try JSONDecoder().decode([String: JSONValue].self, from: Data(response.utf8))
        // NewCz's upstream cookie challenge is intermittent. Retry once; the spider keeps its cookie.
        if site.api == "csp_NewCzGuard", envelope["errorCode"]?.string == "source_http", envelope["status"]?.int == 403 {
            Diagnostics.shared.record(.warning, "jar.retry", "source=\(site.key) HTTP 403 retry=1")
            try await Task.sleep(for: .milliseconds(300))
            progress?.report(.queued)
            response = try await worker.request(resources: resources, json: json, search: params["wd"] != nil) {
                progress?.report(.loading)
            }
            envelope = try JSONDecoder().decode([String: JSONValue].self, from: Data(response.utf8))
        }
        if let login = CloudDriveLoginRequired(envelope: envelope) { throw login }
        if let message = PluginFailure.message(envelope) {
            Diagnostics.shared.record(.error, "jar.request", PluginFailure.diagnostic(source: site.key, envelope, archive: digest))
            if let name = envelope["error"]?.string.flatMap(PluginClassMissing.className(in:)) {
                throw PluginClassMissing(className: name, message: message)
            }
            if PluginFailure.inPlugin(envelope) { throw PluginIncompatible(message: message) }
            throw TVError.unsupported(message)
        }
        guard let result = envelope["result"]?.string else { throw TVError.unsupported("The plugin returned no content.") }
        Diagnostics.shared.record(.info, "jar.request", "source=\(site.key) \(kind) completed bytes=\(result.utf8.count)")
        let answer = try JSONDecoder().decode([String: JSONValue].self, from: Data(result.utf8))
        // An empty page from a source that recently had content is a failure the plugin swallowed.
        if let age = PluginAnswers.shared.record(source: SourceHealth.key(site, origin: configurationOrigin), params: params, answer: answer) {
            Diagnostics.shared.record(.error, "jar.empty", "source=\(site.key) \(kind) answered empty after answering with content\nlastContent=\(Int(age / 3600))h ago archive=\(digest.prefix(12))")
        }
        return answer
    }

    /// Dead or blocked plugin hosts answer with a web page; the archive reader would only say "zip END header not found".
    static func refuseWebPage(_ data: Data) throws {
        let start = String(decoding: data.prefix(256), as: UTF8.self).lowercased()
        if start.contains("<!doctype") || start.contains("<html") {
            throw TVError.unsupported(L10n.text("The plugin download returned a web page instead of a plugin. Its host may be offline."))
        }
    }

    /// Keeps a downloaded archive as Jars/<SHA-256>.jar, where the host reads it.
    static func store(_ data: Data) throws -> (digest: String, file: URL) {
        let digest = PluginChecksum.sha256(data)
        let archives = storageRoot.appendingPathComponent("Jars", isDirectory: true)
        try FileManager.default.createDirectory(at: archives, withIntermediateDirectories: true)
        let jar = archives.appendingPathComponent(digest + ".jar")
        if (try? Data(contentsOf: jar)).map(PluginChecksum.sha256) != digest {
            try data.write(to: jar, options: .atomic)
        }
        return (digest, jar)
    }

    /// One batch of ahead-of-time conversion (see `PluginConversionAhead` and `ConvertAhead.java`).
    struct ConversionBatch: Sendable {
        var digest: String
        /// The archive was already prepared for this build (`isDone`), so nothing ran.
        var skipped = false
        var converted = 0, reused = 0, planned = 0, next = 0
        var done = false
        /// Why the batch ended before `batch` classes: "busy" (a plugin request or stream), "memory", or empty.
        var stopped = ""
    }

    /// Converts up to `batch` more of the archive's likely classes, from position `from`, on a
    /// utility-priority thread outside the request lanes. Opens no plugin and runs none of its code.
    func convertAhead(jarURL: URL, spiders: [String], from: Int, limit: Int, batch: Int, http: HTTPClient,
                      isDone: @Sendable (String) -> Bool) async throws -> ConversionBatch {
        guard Self.available, let resources = Bundle.main.resourcePath else { throw TVError.unsupported("The on-device plugin runtime is missing from this build.") }
        let data = try await PluginDownloads.shared.data(at: jarURL, http: http)
        try Self.refuseWebPage(data)
        let (digest, jar) = try Self.store(data)
        if isDone(digest) { return ConversionBatch(digest: digest, skipped: true) }
        let input: [String: JSONValue] = [
            "command": .string("convertAhead"), "jar": .string(jar.path),
            "conversionCache": .string(Self.storageRoot.appendingPathComponent("Converted").path),
            "spiders": .array(spiders.map(JSONValue.string)), "from": .number(Double(from)),
            "limit": .number(Double(limit)), "batch": .number(Double(batch)),
        ]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let response = try await worker.background(resources: resources, json: String(decoding: try encoder.encode(input), as: UTF8.self))
        let envelope = try JSONDecoder().decode([String: JSONValue].self, from: Data(response.utf8))
        guard case .object(let result)? = envelope["result"] else { throw TVError.unsupported(envelope["error"]?.string ?? "The plugin runtime returned no response.") }
        return ConversionBatch(digest: digest, converted: result["converted"]?.int ?? 0, reused: result["reused"]?.int ?? 0,
                               planned: result["planned"]?.int ?? 0, next: result["next"]?.int ?? from,
                               done: result["done"] == .bool(true), stopped: result["stopped"]?.string ?? "")
    }

    /// Drops the index of the archive ahead-of-time conversion was working on.
    func releaseConversionAhead() async {
        guard Self.available, let resources = Bundle.main.resourcePath else { return }
        _ = try? await worker.background(resources: resources, json: "{\"command\":\"convertAhead\",\"action\":\"release\"}")
    }

    static func adoptPluginAccounts(in folder: URL) {
        let file = folder.appendingPathComponent("plugin-accounts.json")
        guard let data = try? Data(contentsOf: file) else { return }
        try? FileManager.default.removeItem(at: file)
        if let offered = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { CloudDriveAccounts.adopt(offered) }
    }

    /// Signs every source's plugin out of a drive: FTY keeps Baidu in `mybd_cookie` and Aliyun in `ali_*`.
    public static func forgetPluginSignIns(_ names: [String]) {
        let manager = FileManager.default
        for folder in (try? manager.contentsOfDirectory(at: storageRoot, includingPropertiesForKeys: nil)) ?? [] {
            let files = folder.appendingPathComponent("profile/files", isDirectory: true)
            for name in names { try? manager.removeItem(at: files.appendingPathComponent(name)) }
        }
    }

    static func kind(_ params: [String: String]) -> String {
        params["catLogin"] != nil ? "sign-in" : params["play"] != nil ? "play" : params["ids"] != nil ? "detail" : params["wd"] != nil ? "search" : params["t"] != nil ? "category" : "home"
    }

    /// Seconds a spider may work on a request. Generous: drive sources list many shares for a
    /// detail page, and a line resolves in seconds when it works at all.
    static func deadline(_ kind: String) -> Double {
        switch kind {
        case "play": 90
        case "search": 60
        default: 150
        }
    }

    /// Converted classes take minutes to regenerate, so iOS and macOS keep them out of purgeable
    /// Caches. tvOS only permits Caches; there a purge means preparing the plugin again.
    /// The Mac's sandboxed plugin process is granted this folder (see `PluginProcess.start`).
    static let storageRoot: URL = {
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

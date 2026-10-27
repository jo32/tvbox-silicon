#if os(iOS)
import Foundation

/// CatPawOpen (猫源) sources on iPhone and iPad. The app embeds nodejs-mobile (`Scripts/fetch-node-mobile.sh`)
/// and starts it once, the first time such a source is used: Node can't start twice in a process. It runs
/// `NodeHost/main.mjs`, the iOS twin of the Mac host's CatPawOpen mode, which starts each bundle once and
/// answers on a loopback port with a per-launch token.
public actor EmbeddedNodeHost {
    public static let shared = EmbeddedNodeHost()
    /// Only builds that embedded `Scripts/fetch-node-mobile.sh`'s output have Node.
    public static let available: Bool = {
        guard let frameworks = Bundle.main.privateFrameworksURL,
              Bundle.main.url(forResource: "main", withExtension: "mjs", subdirectory: "NodeHost") != nil else { return false }
        return FileManager.default.fileExists(atPath: frameworks.appendingPathComponent("NodeMobile.framework/NodeMobile").path)
    }()
    private struct Control: Decodable { var port: Int?; var token: String?; var error: String? }
    private var control: Task<Control, Error>?
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 150
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }()

    public func request(site: Site, bundleURL: URL, params: [String: String], http: HTTPClient, origin: URL) async throws -> [String: JSONValue] {
        guard Self.available else {
            throw TVError.unsupported(L10n.text("This device can't run CatPawOpen sources."))
        }
        let data = try await PluginDownloads.shared.data(at: bundleURL, http: http)
        try Task.checkCancellation()
        // Each address runs its own copy and settings: Node keeps a started bundle for the app's lifetime.
        let key = PluginChecksum.sha256(Data((bundleURL.absoluteString + "\n" + origin.absoluteString).utf8))
        let root = Self.storageRoot
        let bundle = root.appendingPathComponent("Bundles/" + key + "-" + PluginChecksum.sha256(data) + ".js")
        try FileManager.default.createDirectory(at: bundle.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: bundle.path) { try data.write(to: bundle, options: .atomic) }
        var params = params
        if let path = site.raw["catPawOpen"]?.string { params["catPawOpen"] = path }
        let input: [String: JSONValue] = [
            "bundle": .string(bundle.path), "api": .string(bundleURL.absoluteString),
            "profile": .string(root.appendingPathComponent("Profiles/" + key).path),
            "params": .object(params.mapValues(JSONValue.string)),
        ]
        let kind = EmbeddedJarHost.kind(params)
        let started = ContinuousClock.now
        Diagnostics.shared.record(.info, "jar.request", "source=\(site.key) node \(kind) begin")
        let control = try await self.start()
        guard let port = control.port, let token = control.token else {
            throw TVError.unsupported(control.error ?? L10n.text("The CatPawOpen runtime stopped. Quit and reopen the app to use these sources."))
        }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/call")!)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "x-yingxia-token")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(input)
        let envelope: [String: JSONValue]
        do {
            let (body, _) = try await session.data(for: request)
            envelope = try JSONDecoder().decode([String: JSONValue].self, from: body)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            Diagnostics.shared.record(.error, "jar.request", "source=\(site.key) node \(kind) failed duration=\(started.duration(to: .now)) error=\(error.localizedDescription)")
            throw error
        }
        if let message = PluginFailure.message(envelope) {
            Diagnostics.shared.record(.error, "jar.request", "source=\(site.key) node \(kind) failed duration=\(started.duration(to: .now)) error=\(message)")
            throw TVError.unsupported(message)
        }
        guard let text = envelope["result"]?.string, !text.isEmpty else {
            throw TVError.unsupported(L10n.text("The plugin returned no content. Try another source."))
        }
        Diagnostics.shared.record(.info, "jar.request", "source=\(site.key) node \(kind) complete duration=\(started.duration(to: .now)) bytes=\(text.utf8.count)")
        return try JSONDecoder().decode([String: JSONValue].self, from: Data(text.utf8))
    }

    /// Starts Node at most once; a failed start stays failed until the app relaunches.
    private func start() async throws -> Control {
        if let control { return try await control.value }
        let task = Task.detached { try await Self.launch() }
        control = task
        return try await task.value
    }

    private static func launch() async throws -> Control {
        typealias NodeStart = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
        guard let main = Bundle.main.url(forResource: "main", withExtension: "mjs", subdirectory: "NodeHost"),
              let library = Bundle.main.privateFrameworksURL?.appendingPathComponent("NodeMobile.framework/NodeMobile"),
              let handle = dlopen(library.path, RTLD_NOW), let symbol = dlsym(handle, "node_start") else {
            let reason = dlerror().map { String(cString: $0) } ?? "missing files"
            Diagnostics.shared.record(.error, "node.start", reason)
            return Control(error: L10n.text("This device can't run CatPawOpen sources."))
        }
        let nodeStart = unsafeBitCast(symbol, to: NodeStart.self)
        let file = storageRoot.appendingPathComponent("control.json")
        try? FileManager.default.removeItem(at: file)
        let arguments = ["node", main.path, file.path]
        let thread = Thread {
            // node_start expects its arguments in one contiguous block that lives as long as Node.
            let strings = arguments.map { Array($0.utf8CString) }
            let block = UnsafeMutablePointer<CChar>.allocate(capacity: strings.reduce(0) { $0 + $1.count })
            var argv: [UnsafeMutablePointer<CChar>?] = []
            var offset = 0
            for string in strings {
                (block + offset).initialize(from: string, count: string.count)
                argv.append(block + offset)
                offset += string.count
            }
            argv.append(nil)
            let status = argv.withUnsafeMutableBufferPointer { nodeStart(Int32(arguments.count), $0.baseAddress) }
            Diagnostics.shared.record(.error, "node.start", "Node exited with status \(status)")
            let stopped = ["error": L10n.text("The CatPawOpen runtime stopped. Quit and reopen the app to use these sources.")]
            try? JSONEncoder().encode(stopped).write(to: file, options: .atomic)
        }
        thread.name = "nodejs"
        thread.stackSize = 2 << 20
        thread.start()
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if let data = try? Data(contentsOf: file), let control = try? JSONDecoder().decode(Control.self, from: data) {
                Diagnostics.shared.record(.info, "node.start", control.error == nil ? "ready" : "stopped")
                return control
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        Diagnostics.shared.record(.error, "node.start", "Node did not start within 30 s")
        return Control(error: L10n.text("The CatPawOpen runtime stopped. Quit and reopen the app to use these sources."))
    }

    /// Bundles download again on demand, but profiles hold their settings (sign-ins among them), so they stay
    /// out of purgeable Caches.
    static let storageRoot: URL = {
        let manager = FileManager.default
        let root = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("com.tvbox.yingxia/EmbeddedNode", isDirectory: true)
        try? manager.createDirectory(at: root, withIntermediateDirectories: true)
        var excluded = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        return root
    }()
}
#endif

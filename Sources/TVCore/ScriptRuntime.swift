import Foundation
import CryptoKit
import QuickJS

/// Runs TVBox JavaScript sources in-process on QuickJS, the engine Android TVBox uses, so they
/// work on iOS and tvOS where no separate script process can be started. Each source keeps its
/// own runtime on its own large-stack thread; the TVBox environment comes from ScriptAssets.
public actor ScriptRuntime {
    public static let shared = ScriptRuntime()
    public static var available: Bool { ScriptAssets.root != nil }
    private var sessions: [String: ScriptSession] = [:]
    private var recent: [String] = []
    private static let maximumSessions = 6

    public func request(site: Site, scriptURL: URL, params: [String: String], http: HTTPClient, origin: URL) async throws -> [String: JSONValue] {
        let started = ContinuousClock.now
        let session = try await self.session(site: site, scriptURL: scriptURL, origin: origin, http: http)
        let envelope = try await session.call(params)
        if let message = PluginFailure.message(envelope) {
            Diagnostics.shared.record(.error, "script.request", PluginFailure.diagnostic(source: site.key, envelope))
            throw TVError.unsupported(message)
        }
        guard let text = envelope["result"]?.string, !text.isEmpty else {
            throw TVError.unsupported(L10n.text("The plugin returned no content. Try another source."))
        }
        Diagnostics.shared.record(.info, "script.request", "source=\(site.key) completed duration=\(started.duration(to: .now)) bytes=\(text.utf8.count)")
        return try JSONDecoder().decode([String: JSONValue].self, from: Data(text.utf8))
    }

    private func session(site: Site, scriptURL: URL, origin: URL, http: HTTPClient) async throws -> ScriptSession {
        var ext: String
        if let value = try site.pluginExtension(origin: origin) {
            ext = try value.string ?? String(decoding: JSONEncoder().encode(value), as: UTF8.self)
        } else { ext = "" }
        // JavaScript ext names a rule script, resolved like the source's own address.
        if !ext.isEmpty, !ext.hasPrefix("{") { ext = (try? WebAddress.resolve(ext, relativeTo: origin).absoluteString) ?? ext }
        let key = PluginChecksum.sha256(Data((scriptURL.absoluteString + "\n" + site.key + "\n" + ext).utf8))
        if let existing = sessions[key] {
            recent.removeAll { $0 == key }; recent.append(key)
            return existing
        }
        let profile = ScriptAssets.profiles.appendingPathComponent(PluginChecksum.sha256(Data((site.key + "\n" + origin.absoluteString).utf8)), isDirectory: true)
        let session = try await ScriptSession.start(api: scriptURL.absoluteString, key: site.key, ext: ext, profile: profile, label: site.key)
        sessions[key] = session
        recent.append(key)
        while recent.count > Self.maximumSessions {
            let evicted = recent.removeFirst()
            sessions.removeValue(forKey: evicted)?.close()
        }
        return session
    }
}

/// The bundled TVBox script libraries and the prelude.
enum ScriptAssets {
    static let root: URL? = Bundle.module.url(forResource: "ScriptAssets", withExtension: nil)
    static let cache: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.tvbox.yingxia/Scripts", isDirectory: true)
    static let profiles: URL = cache.appendingPathComponent("Profiles", isDirectory: true)

    // Widely shared drpy2 builds import their helper libraries from a qu.ax mirror that no longer
    // serves them. They are drpy's standard bundled libraries, so load the bundled copies instead.
    static let retiredLibraries = ["cLFE.js": "jsencrypt.js", "kOUW.js": "node-rsa.js", "ucoN.js": "pako.min.js", "XUKQ.js": "模板.js", "wYCz.js": "gbk.js"]

    /// Module resolution as Runtime/ScriptHost/host.mjs `moduleURL`.
    static func resolve(_ specifier: String, from base: String) -> String? {
        if specifier.hasPrefix("lib/") { return "assets://js/" + specifier }
        if specifier.hasPrefix("assets://") || specifier.hasPrefix("http://") || specifier.hasPrefix("https://") { return retired(specifier) ?? specifier }
        guard let parent = URL(string: base), let resolved = URL(string: specifier, relativeTo: parent)?.absoluteString
                ?? specifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed).flatMap({ URL(string: $0, relativeTo: parent)?.absoluteString }) else { return nil }
        return retired(resolved) ?? resolved
    }
    private static func retired(_ address: String) -> String? {
        guard let range = address.range(of: #"/qu\.ax/(\w+\.js)$"#, options: .regularExpression) else { return nil }
        let name = String(address[range].dropFirst("/qu.ax/".count))
        return retiredLibraries[name].map { "assets://js/lib/" + $0 }
    }
    static func bundled(_ address: String) -> String? {
        guard let root, address.hasPrefix("assets://") else { return nil }
        let relative = String(address.dropFirst("assets://".count)).removingPercentEncoding ?? ""
        let file = root.appendingPathComponent(relative).standardizedFileURL
        guard file.path.hasPrefix(root.standardizedFileURL.path + "/") else { return nil }
        return try? String(contentsOf: file, encoding: .utf8)
    }
}

/// One QuickJS runtime pinned to one thread.
final class ScriptSession: @unchecked Sendable {
    private let thread: ScriptThread
    private let bridge: ScriptBridge
    private var script: OpaquePointer?

    private init(thread: ScriptThread, bridge: ScriptBridge) { self.thread = thread; self.bridge = bridge }

    /// `source`, when given, is served for `api` instead of downloading it.
    static func start(api: String, key: String, ext: String, profile: URL, label: String, source: String? = nil) async throws -> ScriptSession {
        let session = ScriptSession(thread: ScriptThread(label: label), bridge: ScriptBridge(profile: profile, label: label, supplied: source.map { [api: $0] } ?? [:]))
        session.thread.start()
        let failure: String? = await session.thread.run {
            let opaque = Unmanaged.passUnretained(session.bridge).toOpaque()
            guard let script = tv_script_create(opaque, scriptHost, 256 << 20, 12 << 20) else { return "QuickJS could not start" }
            session.script = script
            guard let prelude = ScriptAssets.bundled("assets://tvbox/prelude.js") else { return "The script prelude is missing from this build" }
            if let error = tv_script_module(script, "assets://tvbox/prelude.js", prelude, 60) { defer { free(error) }; return String(cString: error) }
            let input = (try? String(decoding: JSONSerialization.data(withJSONObject: ["api": api, "key": key, "ext": ext]), as: UTF8.self)) ?? "{}"
            guard let envelope = session.evaluate("__tvbox.init(\(input))", seconds: 60) else { return "The script runtime stopped" }
            if envelope["value"]?.object?["ready"] != nil { return nil }
            return envelope["value"]?.object?["error"]?.string ?? envelope["error"]?.string ?? "The script did not start"
        }
        if let failure {
            session.close()
            throw TVError.unsupported(L10n.text("Plugin error: %@", String(failure.prefix(300))))
        }
        return session
    }

    /// The spider's answer envelope: {"result": ...} or a PluginFailure envelope.
    func call(_ params: [String: String]) async throws -> [String: JSONValue] {
        let json = (try? String(decoding: JSONSerialization.data(withJSONObject: params), as: UTF8.self)) ?? "{}"
        let envelope = await thread.run { self.evaluate("__tvbox.call(\(json))", seconds: 60) }
        guard let envelope else { return ["error": .string("The script runtime stopped"), "errorCode": .string("script_error")] }
        if let value = envelope["value"]?.object { return value }
        return ["error": .string(envelope["error"]?.string ?? "The script failed"), "errorCode": .string("script_error")]
    }

    /// Runs on the session thread.
    private func evaluate(_ expression: String, seconds: Double) -> [String: JSONValue]? {
        guard let script, let output = tv_script_call(script, expression, seconds) else { return nil }
        defer { free(output) }
        let text = String(cString: output)
        if let envelope = try? JSONDecoder().decode([String: JSONValue].self, from: Data(text.utf8)) { return envelope }
        return ["error": .string("unreadable script result: " + String(text.prefix(300)))]
    }

    func close() {
        thread.run {
            if let script = self.script { tv_script_free(script); self.script = nil }
        } then: { self.thread.cancel() }
    }
}

/// QuickJS keeps deep native recursion (cheerio, large regular expressions), so each runtime
/// gets a thread with a large stack instead of a dispatch queue worker.
final class ScriptThread: Thread, @unchecked Sendable {
    private let condition = NSCondition()
    private var work: [() -> Void] = []

    init(label: String) {
        super.init()
        name = "script " + label
        stackSize = 16 << 20
    }

    override func main() {
        while !isCancelled {
            condition.lock()
            while work.isEmpty && !isCancelled { condition.wait() }
            let next = work.isEmpty ? nil : work.removeFirst()
            condition.unlock()
            next?()
        }
    }

    private func enqueue(_ job: @escaping () -> Void) {
        condition.lock(); work.append(job); condition.signal(); condition.unlock()
    }

    func run<T: Sendable>(_ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in enqueue { continuation.resume(returning: body()) } }
    }

    func run(_ body: @escaping () -> Void, then finish: @escaping () -> Void) {
        enqueue { body(); finish() }
    }

    override func cancel() {
        condition.lock(); super.cancel(); condition.signal(); condition.unlock()
    }
}

/// Native services behind `__host`. Called on the session thread; may block it.
final class ScriptBridge: @unchecked Sendable {
    private let profile: URL
    private let label: String
    private let supplied: [String: String]
    private var preferences: [String: String]
    private var preferencesFile: URL { profile.appendingPathComponent("preferences.json") }

    init(profile: URL, label: String, supplied: [String: String] = [:]) {
        self.profile = profile
        self.label = label
        self.supplied = supplied
        try? FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        preferences = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: profile.appendingPathComponent("preferences.json")))) ?? [:]
    }

    func answer(_ operation: String, _ argument: String) throws -> String? {
        switch operation {
        case "log":
            Diagnostics.shared.record(.info, "script.log", "source=\(label) \(argument.prefix(500))")
            return nil
        case "resolve":
            let parts = argument.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, let resolved = ScriptAssets.resolve(parts[1], from: parts[0]) else { throw ScriptHostError("invalid module specifier") }
            return resolved
        case "module": return try module(argument)
        case "http": return try ScriptHTTP.perform(argument)
        case "encode": return Data(argument.utf8).base64EncodedString()
        case "decode":
            let request = try JSONDecoder().decode([String: String].self, from: Data(argument.utf8))
            let data = Data(base64Encoded: request["base64"] ?? "") ?? Data()
            return ScriptHTTP.text(data, encoding: request["encoding"] ?? "utf-8")
        case "md5": return Insecure.MD5.hash(data: Data(argument.utf8)).map { String(format: "%02x", $0) }.joined()
        case "crypto": return try ScriptCrypto.run(argument)
        case "url": return try ScriptURL.parse(argument)
        case "local":
            let parts = try JSONDecoder().decode([String].self, from: Data(argument.utf8))
            guard parts.count >= 3 else { throw ScriptHostError("invalid storage request") }
            let key = String(decoding: try JSONSerialization.data(withJSONObject: [parts[1], parts[2]]), as: UTF8.self)
            switch parts[0] {
            case "get": return preferences[key] ?? ""
            case "set": preferences[key] = parts.count > 3 ? parts[3] : ""
            default: preferences.removeValue(forKey: key)
            }
            if let data = try? JSONEncoder().encode(preferences) { try? data.write(to: preferencesFile, options: .atomic) }
            return nil
        default: throw ScriptHostError("unsupported host operation \(operation)")
        }
    }

    /// Module sources: bundled assets, or downloads kept for five minutes and reused when offline.
    private func module(_ address: String) throws -> String {
        if let source = supplied[address] { return source }
        if address.hasPrefix("assets://") {
            guard let source = ScriptAssets.bundled(address) else { throw ScriptHostError("no bundled module \(address)") }
            return source
        }
        let folder = ScriptAssets.cache.appendingPathComponent("Modules", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(PluginChecksum.sha256(Data(address.utf8)) + ".js")
        let age = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { Date().timeIntervalSince($0) }
        if let age, age < 300, let cached = try? String(contentsOf: file, encoding: .utf8) { return cached }
        let answer = try JSONDecoder().decode([String: JSONValue].self, from: Data(try ScriptHTTP.perform(String(decoding: JSONSerialization.data(withJSONObject: ["url": address, "timeout": 20000]), as: UTF8.self)).utf8))
        if let code = answer["code"]?.int, (200..<300).contains(code), let source = answer["content"]?.string, !source.isEmpty {
            try? Data(source.utf8).write(to: file, options: .atomic)
            return source
        }
        if let cached = try? String(contentsOf: file, encoding: .utf8) { return cached }
        throw ScriptHostError("cannot download module \(address) (HTTP \(answer["code"]?.int ?? 0))")
    }
}

struct ScriptHostError: Error { let message: String; init(_ message: String) { self.message = message } }

/// The C callback behind `__host`; errors become JavaScript exceptions.
private let scriptHost: TVScriptHost = { opaque, operation, argument in
    guard let opaque, let operation else { return nil }
    let bridge = Unmanaged<ScriptBridge>.fromOpaque(opaque).takeUnretainedValue()
    let answer: String?
    do { answer = try bridge.answer(String(cString: operation), argument.map { String(cString: $0) } ?? "") }
    catch let error as ScriptHostError { answer = "\u{1}" + error.message }
    catch { answer = "\u{1}" + error.localizedDescription }
    guard let answer else { return nil }
    return strdup(answer)
}

/// Synchronous HTTP for scripts, which call `req` without awaiting. Runs on a session thread.
enum ScriptHTTP {
    private final class Redirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    private static let following = URLSession(configuration: .ephemeral)
    private static let stopping = URLSession(configuration: .ephemeral, delegate: Redirects(), delegateQueue: nil)

    static func perform(_ json: String) throws -> String {
        let options = try JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))
        guard let address = options["url"]?.string, let url = try? WebAddress.resolve(address) else { throw ScriptHostError("Only HTTP and HTTPS script requests are supported") }
        var request = URLRequest(url: url, timeoutInterval: min(30, max(1, Double(options["timeout"]?.int ?? 20000) / 1000)))
        let method = (options["method"]?.string ?? "GET").uppercased()
        request.httpMethod = method == "HEADER" ? "HEAD" : method
        var headers = options["headers"]?.object?.compactMapValues(\.string) ?? [:]
        if !headers.keys.contains(where: { $0.lowercased() == "user-agent" }) { headers["User-Agent"] = "Mozilla/5.0" }
        for (field, value) in headers where !(field + value).contains(where: \.isNewline) { request.setValue(value, forHTTPHeaderField: field) }
        if method != "GET", method != "HEAD" {
            // `bodyBase64` carries binary request bodies (for example protobuf) that a string would corrupt.
            if let encoded = options["bodyBase64"]?.string { request.httpBody = Data(base64Encoded: encoded) ?? Data() }
            else if let body = options["body"]?.string { request.httpBody = Data(body.utf8) }
        }
        let session = options["redirect"].map { if case .bool(false) = $0 { return true } else { return false } } == true ? stopping : following
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: (Data?, URLResponse?, Error?)
        session.dataTask(with: request) { data, response, error in result = (data, response, error); semaphore.signal() }.resume()
        semaphore.wait()
        let host = url.host ?? ""
        var answer: [String: Any] = ["url": (result.1?.url ?? url).absoluteString, "host": host]
        if let error = result.2 {
            answer["code"] = 0; answer["content"] = ""; answer["failed"] = "Network request to \(host) failed: \(error.localizedDescription)"
        } else {
            let response = result.1 as? HTTPURLResponse
            let data = result.0 ?? Data()
            answer["code"] = response?.statusCode ?? 0
            var fields: [String: String] = [:]
            for (field, value) in response?.allHeaderFields ?? [:] { fields[String(describing: field).lowercased()] = String(describing: value) }
            answer["headers"] = fields
            if options["binary"].map({ if case .bool(true) = $0 { return true } else { return false } }) == true { answer["base64"] = data.base64EncodedString() }
            else { answer["content"] = text(data, encoding: options["encoding"]?.string ?? "utf-8") }
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: answer), as: UTF8.self)
    }

    /// Text in the requested encoding, including GBK/GB2312/GB18030 and Big5 used by Chinese sites.
    static func text(_ data: Data, encoding name: String) -> String {
        let label = name.lowercased()
        if label == "utf-8" || label == "utf8" || label.isEmpty { return String(decoding: data, as: UTF8.self) }
        let cf = CFStringConvertIANACharSetNameToEncoding(label as CFString)
        if cf != kCFStringEncodingInvalidId {
            let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
            if let text = String(data: data, encoding: encoding) { return text }
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// WHATWG-style URL parts for the prelude's URL class.
enum ScriptURL {
    static func parse(_ json: String) throws -> String {
        let request = try JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))
        let href = request["href"]?.string ?? ""
        let base = request["base"]?.string.flatMap { URL(string: $0) ?? $0.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:)) }
        func make(_ text: String) -> URL? { URL(string: text, relativeTo: base) ?? text.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap { URL(string: $0, relativeTo: base) } }
        guard let url = make(href)?.absoluteURL, let scheme = url.scheme, base != nil || url.host != nil || scheme == "data" || scheme == "assets" else { throw ScriptHostError("Invalid URL: \(href)") }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        let hostname = components?.host ?? ""
        let port = components?.port.map(String.init) ?? ""
        let host = port.isEmpty ? hostname : hostname + ":" + port
        let path = components?.percentEncodedPath ?? ""
        let pathname = path.isEmpty && (scheme == "http" || scheme == "https") ? "/" : path
        let search = components?.percentEncodedQuery.map { $0.isEmpty ? "" : "?" + $0 } ?? ""
        let hash = components?.percentEncodedFragment.map { $0.isEmpty ? "" : "#" + $0 } ?? ""
        let credentials = (components?.percentEncodedUser ?? "").isEmpty ? "" : (components?.percentEncodedUser ?? "") + ((components?.percentEncodedPassword).map { ":" + $0 } ?? "") + "@"
        let normalized = hostname.isEmpty && scheme != "http" && scheme != "https" ? url.absoluteString : scheme + "://" + credentials + host + pathname + search + hash
        let parts: [String: String] = ["href": normalized, "protocol": scheme + ":", "username": components?.percentEncodedUser ?? "", "password": components?.percentEncodedPassword ?? "",
                                       "host": host, "hostname": hostname, "port": port, "pathname": pathname, "search": search, "hash": hash,
                                       "origin": hostname.isEmpty ? "null" : scheme + "://" + host]
        return String(decoding: try JSONSerialization.data(withJSONObject: parts), as: UTF8.self)
    }
}

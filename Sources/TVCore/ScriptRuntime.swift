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
    private static let maximumSessions = 10

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
        // JavaScript ext names a rule script, resolved like the source's own address. A lite port's ext is
        // its JAR spider's configuration (possibly encrypted text), so it reaches the port unchanged.
        if !ext.isEmpty, !ext.hasPrefix("{"), site.liteScript == nil { ext = (try? WebAddress.resolve(ext, relativeTo: origin).absoluteString) ?? ext }
        let key = PluginChecksum.sha256(Data((scriptURL.absoluteString + "\n" + site.key + "\n" + ext).utf8))
        if let existing = sessions[key] {
            recent.removeAll { $0 == key }; recent.append(key)
            return existing
        }
        let profile = ScriptAssets.profiles.appendingPathComponent(PluginChecksum.sha256(Data((site.key + "\n" + origin.absoluteString).utf8)), isDirectory: true)
        let session = try await ScriptSession.start(api: scriptURL.absoluteString, key: site.sourceKey, ext: ext, profile: profile, label: site.key)
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

/// One QuickJS runtime pinned to one thread. Cancellation retains the native execution fence.
final class ScriptSession: @unchecked Sendable {
    private let thread: ScriptThread
    private let bridge: ScriptBridge
    private var script: OpaquePointer?
    private let stateLock = NSLock()
    private var closed = false
    private var operations: [UUID: (ScriptCancellation, ScriptRequestScope)] = [:]

    private init(thread: ScriptThread, bridge: ScriptBridge) { self.thread = thread; self.bridge = bridge }

    static func start(api: String, key: String, ext: String, profile: URL, label: String, source: String? = nil) async throws -> ScriptSession {
        try Task.checkCancellation()
        let session = ScriptSession(thread: ScriptThread(label: label), bridge: ScriptBridge(profile: profile, label: label, supplied: source.map { [api: $0] } ?? [:]))
        session.thread.start()
        let failure: String? = await session.perform(seconds: 60, stopped: "The script runtime stopped") { token in
            if let failure = session.boot(token) { return failure }
            let input = (try? String(decoding: JSONSerialization.data(withJSONObject: ["api": api, "key": key, "ext": ext]), as: UTF8.self)) ?? "{}"
            guard let envelope = session.evaluate("__tvbox.init(\(input))", seconds: 60, token: token) else { return "The script runtime stopped" }
            if envelope["value"]?.object?["ready"] != nil { return nil }
            return envelope["value"]?.object?["error"]?.string ?? envelope["error"]?.string ?? "The script did not start"
        }
        if Task.isCancelled { session.close(); throw CancellationError() }
        if let failure { session.close(); throw TVError.unsupported(L10n.text("Plugin error: %@", String(failure.prefix(300)))) }
        return session
    }

    static func start(module: String, supplied: [String: String], profile: URL, label: String, extension handler: ScriptHostExtension? = nil) async throws -> ScriptSession {
        try Task.checkCancellation()
        let session = ScriptSession(thread: ScriptThread(label: label), bridge: ScriptBridge(profile: profile, label: label, supplied: supplied, extension: handler))
        session.thread.start()
        let failure: String? = await session.perform(seconds: 60, stopped: "The script runtime stopped") { token in
            if let failure = session.boot(token) { return failure }
            guard let source = ScriptAssets.bundled(module), let script = session.script else { return "The script module is missing from this build" }
            if let error = tv_script_module_cancellable(script, module, source, 30, token.pointer) { defer { free(error) }; return String(cString: error) }
            return nil
        }
        if Task.isCancelled { session.close(); throw CancellationError() }
        if let failure { session.close(); throw TVError.unsupported(L10n.text("Plugin error: %@", String(failure.prefix(300)))) }
        return session
    }

    func evaluate(_ expression: String, within seconds: Double) async -> [String: JSONValue] {
        let stopped: [String: JSONValue] = ["error": .string("The script operation stopped")]
        return await perform(seconds: seconds, stopped: stopped) { token in
            self.evaluate(expression, seconds: seconds, token: token) ?? stopped
        }
    }

    private func perform<T: Sendable>(seconds: Double, stopped: T, _ body: @escaping (ScriptCancellation) -> T) async -> T {
        let token = ScriptCancellation(), scope = ScriptRequestScope(deadline: Date().addingTimeInterval(seconds))
        let id = UUID()
        guard token.pointer != nil, stateLock.withLock({
            guard !closed else { return false }
            operations[id] = (token, scope); return true
        }) else { return stopped }
        let expiry = DispatchWorkItem { token.cancel(); scope.cancel() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, seconds), execute: expiry)
        defer { expiry.cancel(); _ = stateLock.withLock { operations.removeValue(forKey: id) } }
        return await withTaskCancellationHandler {
            if Task.isCancelled { token.cancel(); scope.cancel() }
            return await thread.run(stopped: stopped) {
                guard !token.cancelled, scope.deadline.timeIntervalSinceNow > 0 else { return stopped }
                self.bridge.beginRequest(scope)
                defer {
                    if token.cancelled { scope.cancel() }
                    self.bridge.endRequest(scope)
                    if scope.cancelled, let script = self.script {
                        if let result = tv_script_call(script, "__tvbox.cancelTimers()", 0.2) { free(result) }
                    }
                }
                let result = body(token)
                return token.cancelled ? stopped : result
            }
        } onCancel: { token.cancel(); scope.cancel() }
    }

    private func boot(_ token: ScriptCancellation) -> String? {
        let opaque = Unmanaged.passUnretained(bridge).toOpaque()
        guard let script = tv_script_create(opaque, scriptHost, 256 << 20, 12 << 20) else { return "QuickJS could not start" }
        self.script = script
        guard let prelude = ScriptAssets.bundled("assets://tvbox/prelude.js") else { return "The script prelude is missing from this build" }
        if let error = tv_script_module_cancellable(script, "assets://tvbox/prelude.js", prelude, 60, token.pointer) { defer { free(error) }; return String(cString: error) }
        return nil
    }

    func call(_ params: [String: String]) async throws -> [String: JSONValue] {
        try Task.checkCancellation()
        let json = (try? String(decoding: JSONSerialization.data(withJSONObject: params), as: UTF8.self)) ?? "{}"
        let envelope = await evaluate("__tvbox.call(\(json))", within: 60)
        try Task.checkCancellation()
        if let value = envelope["value"]?.object { return value }
        return ["error": .string(envelope["error"]?.string ?? "The script failed"), "errorCode": .string("script_error")]
    }

    private func evaluate(_ expression: String, seconds: Double, token: ScriptCancellation) -> [String: JSONValue]? {
        guard let script, let output = tv_script_call_cancellable(script, expression, seconds, token.pointer) else { return nil }
        defer { free(output) }
        let text = String(cString: output)
        if let envelope = try? JSONDecoder().decode([String: JSONValue].self, from: Data(text.utf8)) { return envelope }
        return ["error": .string("unreadable script result: " + String(text.prefix(300)))]
    }

    func close() {
        let active: [(ScriptCancellation, ScriptRequestScope)]? = stateLock.withLock {
            guard !closed else { return nil }
            closed = true
            return Array(operations.values)
        }
        guard let active else { return }
        for (token, scope) in active { token.cancel(); scope.cancel() }
        thread.run {
            self.bridge.cancelPending()
            if let script = self.script { tv_script_free(script); self.script = nil }
        } then: { self.thread.cancel() }
    }
}

private final class ScriptCancellation: @unchecked Sendable {
    let pointer: OpaquePointer?
    private let lock = NSLock()
    private var stopped = false
    init() { pointer = tv_script_cancellation_create() }
    var cancelled: Bool { lock.withLock { stopped } }
    func cancel() { lock.withLock { stopped = true; tv_script_cancellation_cancel(pointer) } }
    deinit { tv_script_cancellation_free(pointer) }
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

    /// A session operation with an explicit stopped result. Close can race an actor's last
    /// session lookup; queued callers must resume when the worker exits, even after close.
    func run<T: Sendable>(stopped: T, _ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            condition.lock()
            if isCancelled {
                condition.unlock(); continuation.resume(returning: stopped)
            } else {
                work.append { continuation.resume(returning: self.isCancelled ? stopped : body()) }
                condition.signal(); condition.unlock()
            }
        }
    }

    func run(_ body: @escaping () -> Void, then finish: @escaping () -> Void) {
        condition.lock()
        if isCancelled { condition.unlock(); return }
        work.append { if !self.isCancelled { body(); finish() } }
        condition.signal(); condition.unlock()
    }

    override func cancel() {
        condition.lock(); super.cancel()
        let queued = work; work.removeAll()
        condition.signal(); condition.unlock()
        // Stop is requested by the final close job on this worker, after freeing the VM.
        // Operations using the stopped overload only resume their continuation here.
        queued.forEach { $0() }
    }
}

/// Native services behind `__host`. Called on the session thread; may block it.
final class ScriptBridge: @unchecked Sendable {
    private let profile: URL
    private let label: String
    private let supplied: [String: String]
    private var preferences: [String: String]
    private var preferencesFile: URL { profile.appendingPathComponent("preferences.json") }
    private let pending = PendingRequests()
    private let handler: ScriptHostExtension?

    private var request: ScriptRequestScope?
    deinit { pending.cancelAll() }
    func beginRequest(_ request: ScriptRequestScope) { self.request = request }
    func endRequest(_ request: ScriptRequestScope) {
        if request.cancelled { request.cancelAndWait(); pending.cancelAllAndWait(); handler?.cancelPending() }
        self.request = nil
    }
    func cancelPending() { request?.cancelAndWait(); pending.cancelAllAndWait(); handler?.cancelPending() }

    init(profile: URL, label: String, supplied: [String: String] = [:], extension handler: ScriptHostExtension? = nil) {
        self.handler = handler
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
        case "http": return try ScriptHTTP.perform(argument, scope: request)
        // Requests that don't block the script: start one, then poll for its answer from a timer.
        case "httpStart":
            let id = pending.add()
            do {
                let cancel = try ScriptHTTP.start(argument, scope: request) { [pending] answer in pending.finish(id, answer) }
                pending.setCancel(id, cancel)
            } catch { pending.finish(id, ""); throw error }
            return String(id)
        case "httpPoll": return pending.take(Int(argument) ?? -1)
        case "httpCancel": pending.cancel(Int(argument) ?? -1); return nil
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
        default:
            if let handled = try handler?.answer(operation, argument) { return handled }
            throw ScriptHostError("unsupported host operation \(operation)")
        }
    }

    /// Module sources: bundled assets, or downloads kept for five minutes and reused when offline.
    private func module(_ address: String) throws -> String {
        if let source = supplied[address] { return source }
        // A sandboxed script (a subtitle source) runs the app's modules and its own, nothing fetched or read.
        if handler?.allowsRemoteModules == false, !address.hasPrefix("assets://") { throw ScriptHostError("this script can't load \(address)") }
        if let url = URL(string: address), let data = try ImportedFiles.data(at: url) { return String(decoding: data, as: UTF8.self) }
        if address.hasPrefix("assets://") {
            guard let source = ScriptAssets.bundled(address) else { throw ScriptHostError("no bundled module \(address)") }
            return source
        }
        let folder = ScriptAssets.cache.appendingPathComponent("Modules", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(PluginChecksum.sha256(Data(address.utf8)) + ".js")
        let age = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { Date().timeIntervalSince($0) }
        if let age, age < 300, let cached = try? String(contentsOf: file, encoding: .utf8) { return cached }
        let answer = try JSONDecoder().decode([String: JSONValue].self, from: Data(try ScriptHTTP.perform(String(decoding: JSONSerialization.data(withJSONObject: ["url": address, "timeout": 20000]), as: UTF8.self), scope: request).utf8))
        if let code = answer["code"]?.int, (200..<300).contains(code), let source = answer["content"]?.string, !source.isEmpty {
            try? Data(source.utf8).write(to: file, options: .atomic)
            return source
        }
        if let cached = try? String(contentsOf: file, encoding: .utf8) { return cached }
        throw ScriptHostError("cannot download module \(address) (HTTP \(answer["code"]?.int ?? 0))")
    }
}

/// More host operations for one kind of script (MangaHost): an answer, `.some(nil)` for null, or nil when
/// the operation isn't one of its own.
protocol ScriptHostExtension: AnyObject, Sendable {
    func answer(_ operation: String, _ argument: String) throws -> String??
    /// Called on the VM thread before a cancelled operation or VM close releases its fence.
    func cancelPending()
    /// Whether the script may load modules from the network or the device's files.
    var allowsRemoteModules: Bool { get }
}

extension ScriptHostExtension {
    func cancelPending() {}
    var allowsRemoteModules: Bool { true }
}

/// Requests started with `httpStart`, until their answers are taken.
final class PendingRequests: @unchecked Sendable {
    private let lock = NSCondition()
    private var next = 1
    private var answers: [Int: String] = [:]
    private var cancels: [Int: () -> Void] = [:]
    private var active = Set<Int>()
    private var discarded = Set<Int>()

    func add() -> Int { lock.withLock { defer { next += 1 }; active.insert(next); return next } }
    func setCancel(_ id: Int, _ cancel: @escaping () -> Void) {
        let stop = lock.withLock {
            guard active.contains(id) else { return false }
            if discarded.contains(id) { return true }
            cancels[id] = cancel
            return false
        }
        if stop { cancel() }
    }
    func finish(_ id: Int, _ answer: String) {
        lock.withLock {
            cancels[id] = nil; active.remove(id)
            if discarded.remove(id) == nil { answers[id] = answer }
            lock.broadcast()
        }
    }
    func take(_ id: Int) -> String? { lock.withLock { answers.removeValue(forKey: id) } }
    func cancel(_ id: Int) {
        let cancel = lock.withLock {
            answers[id] = nil
            if active.contains(id) { discarded.insert(id) }
            return cancels.removeValue(forKey: id)
        }
        cancel?()
    }
    func cancelAll() {
        let all = lock.withLock {
            defer { cancels = [:]; answers = [:] }
            discarded.formUnion(active)
            return Array(cancels.values)
        }
        all.forEach { $0() }
    }
    func cancelAllAndWait() {
        cancelAll()
        lock.lock()
        while !active.isEmpty { lock.wait() }
        lock.unlock()
    }
}

struct ScriptHostError: Error { let message: String; init(_ message: String) { self.message = message } }

/// A VM call may synchronously enter HTTP, where the bytecode interrupt cannot run.
/// Keep that transport cancellable and retain the execution fence through its callback.
final class ScriptRequestScope: @unchecked Sendable {
    let deadline: Date
    private let condition = NSCondition()
    private var stopped = false
    private var next = 0
    private var active: [Int: (() -> Void)?] = [:]
    init(deadline: Date) { self.deadline = deadline }
    var cancelled: Bool { condition.withLock { stopped } }
    func begin() throws -> Int {
        try condition.withLock {
            guard !stopped, deadline.timeIntervalSinceNow > 0 else { throw CancellationError() }
            defer { next += 1 }
            active[next] = .some(nil)
            return next
        }
    }
    func attach(_ id: Int, cancel: @escaping () -> Void) {
        let stop = condition.withLock {
            guard active.keys.contains(id) else { return false }
            active[id] = cancel
            return stopped
        }
        if stop { cancel() }
    }
    func finish(_ id: Int) { condition.withLock { active.removeValue(forKey: id); condition.broadcast() } }
    func cancel() {
        let cancels = condition.withLock { stopped = true; return active.values.compactMap { $0 } }
        cancels.forEach { $0() }
    }
    func cancelAndWait() {
        cancel()
        condition.lock()
        while !active.isEmpty { condition.wait() }
        condition.unlock()
    }
}

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

    /// Cookie jars a script names (`jar`): requests naming the same jar share its cookies and no others, so a
    /// sign-in's cookies neither leak into a source's other requests nor pick theirs up. In memory only.
    final class Jars: @unchecked Sendable {
        struct Jar { let following: URLSession; let stopping: URLSession; let storage: HTTPCookieStorage? }
        static let shared = Jars()
        static let limit = 8
        private let lock = NSLock()
        private var jars: [String: Jar] = [:]
        private var order: [String] = []

        func jar(_ name: String) -> Jar {
            lock.withLock {
                if let jar = jars[name] { return jar }
                // An ephemeral configuration has a cookie store of its own, which both sessions share.
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpCookieAcceptPolicy = .always
                let jar = Jar(following: URLSession(configuration: configuration),
                              stopping: URLSession(configuration: configuration, delegate: Redirects(), delegateQueue: nil),
                              storage: configuration.httpCookieStorage)
                jars[name] = jar; order.append(name)
                while order.count > Self.limit {
                    let old = jars.removeValue(forKey: order.removeFirst())
                    old?.following.invalidateAndCancel(); old?.stopping.invalidateAndCancel()
                }
                return jar
            }
        }
    }
    typealias Reply = (Data?, URLResponse?, Error?)

    /// Starts one try, and another each time `hedge` seconds pass without an answer or a try fails, up to
    /// `racers` tries. The first HTTP answer below 500 wins and the other tries are cancelled; when none
    /// wins, the last failure is returned. `start` begins a try and returns how to cancel it. Blocks.
    static func race(racers: Int, hedge: TimeInterval, start: (@escaping @Sendable (Reply) -> Void) -> (() -> Void)) -> Reply {
        final class State: @unchecked Sendable { let lock = NSLock(); var winner: Reply?; var last: Reply?; var running = 0 }
        let state = State(), signal = DispatchSemaphore(value: 0)
        var cancels: [() -> Void] = []
        func launch() {
            state.lock.withLock { state.running += 1 }
            cancels.append(start { reply in
                state.lock.withLock {
                    state.running -= 1
                    let status = (reply.1 as? HTTPURLResponse)?.statusCode ?? 0
                    if reply.2 == nil, (1..<500).contains(status), state.winner == nil { state.winner = reply } else { state.last = reply }
                }
                signal.signal()
            })
        }
        launch()
        while true {
            _ = signal.wait(timeout: .now() + hedge)
            let (won, running) = state.lock.withLock { (state.winner != nil, state.running) }
            if won { break }
            // Here the wait timed out or a try failed: both start the next try.
            if cancels.count < racers { launch() } else if running == 0 { break }
        }
        cancels.forEach { $0() }
        return state.lock.withLock { state.winner ?? state.last ?? (nil, nil, URLError(.unknown)) }
    }

    static func perform(_ json: String, scope: ScriptRequestScope? = nil) throws -> String {
        let options = try JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))
        let (prepared, stopsRedirects) = try prepare(options)
        let request: URLRequest = {
            var value = prepared
            if let scope { value.timeoutInterval = min(value.timeoutInterval, max(0.05, scope.deadline.timeIntervalSinceNow)) }
            return value
        }()
        let jar = options["jar"]?.string.flatMap { $0.isEmpty || $0.count > 80 ? nil : Jars.shared.jar($0) }
        let racers = jar == nil ? min(4, max(1, options["racers"]?.int ?? 1)) : 1
        let result: Reply
        if racers > 1 {
            let hedge = Double(options["hedge"]?.int ?? 0) / 1000
            result = race(racers: racers, hedge: hedge > 0 ? hedge : 2.5) { finish in
                // Each try gets its own connection: a stalled HTTP/2 connection must not carry the next one.
                let session = URLSession(configuration: .ephemeral, delegate: stopsRedirects ? Redirects() : nil, delegateQueue: nil)
                do {
                    let id = try scope?.begin()
                    let task = session.dataTask(with: request) { data, response, error in
                        defer { if let id { scope?.finish(id) }; session.finishTasksAndInvalidate() }
                        finish((data, response, error))
                    }
                    if let id { scope?.attach(id, cancel: { task.cancel() }) }
                    task.resume()
                    return { session.invalidateAndCancel() }
                } catch { session.invalidateAndCancel(); finish((nil, nil, error)); return {} }
            }
        } else {
            let semaphore = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var reply: Reply = (nil, nil, nil)
            let session = stopsRedirects ? jar?.stopping ?? stopping : jar?.following ?? following
            let id = try scope?.begin()
            let task = session.dataTask(with: request) { data, response, error in
                defer { if let id { scope?.finish(id) } }
                reply = (data, response, error); semaphore.signal()
            }
            if let id { scope?.attach(id, cancel: { task.cancel() }) }
            task.resume()
            semaphore.wait()
            result = reply
        }
        return try answer(result, request: request, options: options, cookies: jar?.storage)
    }

    /// Starts a request without waiting for it (`httpStart`): `finish` gets the same answer `perform` returns.
    /// Returns how to cancel it.
    static func start(_ json: String, scope: ScriptRequestScope? = nil, finish: @escaping @Sendable (String) -> Void) throws -> () -> Void {
        let options = try JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))
        let (prepared, stopsRedirects) = try prepare(options)
        let request: URLRequest = {
            var value = prepared
            if let scope { value.timeoutInterval = min(value.timeoutInterval, max(0.05, scope.deadline.timeIntervalSinceNow)) }
            return value
        }()
        let id = try scope?.begin()
        let task = (stopsRedirects ? stopping : following).dataTask(with: request) { data, response, error in
            defer { if let id { scope?.finish(id) } }
            finish((try? answer((data, response, error), request: request, options: options)) ?? #"{"code":0,"content":"","failed":"Network request failed"}"#)
        }
        if let id { scope?.attach(id, cancel: { task.cancel() }) }
        task.resume()
        return { task.cancel() }
    }

    private static func prepare(_ options: [String: JSONValue]) throws -> (URLRequest, stopsRedirects: Bool) {
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
        // `cookies: false`: only the request's own Cookie header goes, and nothing the answer sets is kept.
        if case .bool(false)? = options["cookies"] { request.httpShouldHandleCookies = false }
        let stopsRedirects = options["redirect"].map { if case .bool(false) = $0 { return true } else { return false } } == true
        return (request, stopsRedirects)
    }

    private static func answer(_ result: Reply, request: URLRequest, options: [String: JSONValue], cookies: HTTPCookieStorage? = nil) throws -> String {
        let url = request.url!
        let host = url.host ?? ""
        var answer: [String: Any] = ["url": (result.1?.url ?? url).absoluteString, "host": host]
        if let cookies {
            // The jar's live cookies for the answered address, or for the one the script asks about.
            let about = options["cookiesFor"]?.string.flatMap { try? WebAddress.resolve($0) } ?? result.1?.url ?? url
            var fields: [String: String] = [:]
            for cookie in cookies.cookies(for: about) ?? [] where !cookie.value.isEmpty && (cookie.expiresDate.map { $0 > Date() } ?? true) { fields[cookie.name] = cookie.value }
            answer["cookies"] = fields
        }
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

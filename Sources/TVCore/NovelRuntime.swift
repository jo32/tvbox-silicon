import Foundation
import CryptoKit
#if canImport(WebKit) && !os(tvOS)
import WebKit
#endif

/// Runs Legado book sources (github.com/LegadoTeam/legado) in-process on QuickJS, with Legado's rule engine
/// ported to ScriptAssets/legado/engine.js. Requests are synchronous inside a runtime, as in Legado's Rhino
/// scripts, so a runtime answers one call at a time.
///
/// Two kinds of runtime: a pool of up to `poolSize` shared ones that switch source with `__legado.load` for
/// searching and exploring (a search fans out over hundreds of sources), and one kept runtime per source for
/// reading a book (details, table of contents, chapters). Sources keep their variables and cookies in
/// NovelStore and NovelHTTP, whichever runtime runs them.
public actor NovelRuntime {
    public static let shared = NovelRuntime()
    /// Shared runtimes for searching: as many as searches run at once (NovelBooks fans out 16 at a time).
    static let poolSize = 16
    /// Runtimes kept for reading, one per source.
    static let keptSessions = 6
    /// How long one source may take to search; many sources in public lists are dead.
    static let searchBudget = 15.0

    final class Session: @unchecked Sendable {
        let script: ScriptSession
        /// The loaded source's key and revision.
        var key = "", revision = ""
        var used = Date()
        init(script: ScriptSession) { self.script = script }
    }
    private var reading: [String: Session] = [:]
    private var readingBusy: [String: Task<Session, Error>] = [:]
    private var idle: [Session] = []
    private var pooled = 0
    private var waiting: [CheckedContinuation<Session?, Never>] = []
    private var trimming: Task<Void, Never>?

    // MARK: The API

    public func search(_ source: NovelSource, keyword: String, page: Int) async throws -> [NovelBook] {
        try decode([NovelBook].self, try await pooledCall(source, "search", [keyword, page], budget: Self.searchBudget))
    }

    public func exploreKinds(_ source: NovelSource) async throws -> [NovelExploreKind] {
        try decode([NovelExploreKind].self, try await pooledCall(source, "exploreKinds", [], budget: 20))
    }

    public func explore(_ source: NovelSource, url: String, page: Int) async throws -> [NovelBook] {
        try decode([NovelBook].self, try await pooledCall(source, "explore", [url, page], budget: 25))
    }

    /// The book's page read: intro, cover, kind, the table of contents' address, and so on.
    public func details(_ source: NovelSource, book: NovelBook) async throws -> NovelBook {
        var filled = try decode(NovelBook.self, try await readingCall(source, "info", [Self.object(book)], budget: 30))
        filled.sourceKey = source.key
        return filled
    }

    /// The table of contents (reads the book's page first when its `tocURL` isn't known yet).
    public func chapters(_ source: NovelSource, book: NovelBook) async throws -> [NovelChapter] {
        let value = try await readingCall(source, "toc", [Self.object(book)], budget: 90) as? [String: Any]
        return try decode([NovelChapter].self, value?["chapters"])
    }

    /// A chapter's text. `next` is the following chapter (not a volume heading), which tells a source whose
    /// chapters run over several pages where this one ends.
    public func content(_ source: NovelSource, book: NovelBook, chapter: NovelChapter, next: NovelChapter?) async throws -> NovelContent {
        let value = try await readingCall(source, "content", [Self.object(book), Self.object(chapter), next.map(Self.object) ?? NSNull()], budget: 45) as? [String: Any]
        let content = try decode(NovelContent.self, value)
        return NovelContent(title: content.title.isEmpty ? chapter.title : content.title, paragraphs: content.paragraphs)
    }

    /// Drops a source's reading runtime and what it keeps in memory, e.g. after its list was updated or removed.
    public func reset(_ key: String) {
        reading.removeValue(forKey: key)?.script.close()
        readingBusy.removeValue(forKey: key)?.cancel()
        for session in idle where session.key == key { session.key = ""; session.revision = "" }
    }

    // MARK: Pooled runtimes

    private func lease(_ source: NovelSource) async throws -> Session {
        if let index = idle.lastIndex(where: { $0.key == source.key && $0.revision == source.revision }) ?? idle.indices.last {
            return idle.remove(at: index)
        }
        if pooled < Self.poolSize {
            pooled += 1
            do { return try await Self.boot(label: "novel pool") } catch { pooled -= 1; throw error }
        }
        if let session = await withCheckedContinuation({ waiting.append($0) }) { return session }
        // A runtime was closed: its place is this caller's (`pooled` already counts it).
        do { return try await Self.boot(label: "novel pool") } catch { pooled -= 1; throw error }
    }

    private func giveBack(_ session: Session, broken: Bool) {
        session.used = Date()
        if broken {
            session.script.close()
            if waiting.isEmpty { pooled -= 1 } else { waiting.removeFirst().resume(returning: nil) }
            return
        }
        if !waiting.isEmpty { waiting.removeFirst().resume(returning: session); return }
        idle.append(session)
        scheduleTrim()
    }

    /// Idle runtimes past the first two close a while after a search.
    private func scheduleTrim() {
        trimming?.cancel()
        trimming = Task { [weak self] in
            try? await Task.sleep(for: .seconds(90))
            guard !Task.isCancelled else { return }
            await self?.trim()
        }
    }

    private func trim() {
        while idle.count > 2 {
            idle.removeFirst().script.close()
            pooled -= 1
        }
    }

    private func pooledCall(_ source: NovelSource, _ function: String, _ arguments: [Any], budget: Double) async throws -> Any? {
        let encoded = arguments.map { Self.json($0) }
        let session = try await lease(source)
        var broken = false
        defer { giveBack(session, broken: broken) }
        do {
            try await Self.load(source, into: session)
            return try await Self.call(session, source: source, function, encoded, budget: budget)
        } catch {
            broken = Self.isStuck(error)
            throw error
        }
    }

    // MARK: Reading runtimes

    private func readingSession(_ source: NovelSource) async throws -> Session {
        if let session = reading[source.key], session.revision == source.revision { session.used = Date(); return session }
        if let task = readingBusy[source.key] { return try await task.value }
        reading.removeValue(forKey: source.key)?.script.close()
        let task = Task { () throws -> Session in
            let session = try await Self.boot(label: "novel \(source.name)")
            do { try await Self.load(source, into: session) } catch { session.script.close(); throw error }
            return session
        }
        readingBusy[source.key] = task
        defer { readingBusy[source.key] = nil }
        let session = try await task.value
        reading[source.key] = session
        if reading.count > Self.keptSessions, let oldest = reading.min(by: { $0.value.used < $1.value.used })?.key, oldest != source.key {
            reading.removeValue(forKey: oldest)?.script.close()
        }
        return session
    }

    private func readingCall(_ source: NovelSource, _ function: String, _ arguments: [Any], budget: Double) async throws -> Any? {
        let encoded = arguments.map { Self.json($0) }
        let session = try await readingSession(source)
        do { return try await Self.call(session, source: source, function, encoded, budget: budget) } catch {
            if Self.isStuck(error), reading[source.key] === session { reading.removeValue(forKey: source.key)?.script.close() }
            throw error
        }
    }

    // MARK: Running the engine

    /// A runtime with the engine loaded and no source yet.
    static func boot(label: String) async throws -> Session {
        let began = ContinuousClock.now
        let script = try await ScriptSession.start(module: "assets://legado/engine.js", supplied: [:], profile: NovelLibrary.root.appendingPathComponent("Runtime", isDirectory: true),
                                                   label: label, extension: NovelHost())
        Diagnostics.shared.record(.info, "novel.boot", "\(label) \(began.duration(to: .now))")
        return Session(script: script)
    }

    static func load(_ source: NovelSource, into session: Session) async throws {
        if session.key == source.key, session.revision == source.revision { return }
        session.key = ""; session.revision = ""
        _ = try await evaluate(session.script, "__legado.load(\(json(source.json)))", seconds: 20)
        session.key = source.key; session.revision = source.revision
    }

    private static func call(_ session: Session, source: NovelSource, _ function: String, _ arguments: [String], budget: Double) async throws -> Any? {
        let started = ContinuousClock.now
        // The engine stops making requests once `budget` is spent; the runtime's own deadline is a backstop.
        let list = (arguments + [String(Int(budget * 1000))]).joined(separator: ", ")
        do {
            let value = try await evaluate(session.script, "__legado.\(function)(\(list))", seconds: budget + 10)
            Diagnostics.shared.record(.info, "novel.call", "source=\(source.name) \(function) ok \(started.duration(to: .now))")
            return value
        } catch {
            Diagnostics.shared.record(.error, "novel.call", "source=\(source.name) \(function) failed: \(error.localizedDescription.prefix(300))")
            throw error
        }
    }

    static func isStuck(_ error: Error) -> Bool {
        let text = "\(error)"
        return text.contains("took too long") || text.contains("runtime stopped")
    }

    /// Evaluates a `__legado` call and unwraps its {value} or {error}.
    static func evaluate(_ script: ScriptSession, _ expression: String, seconds: Double) async throws -> Any? {
        let envelope = await script.evaluate("Promise.resolve(\(expression)).then(value => JSON.stringify(value))", within: seconds)
        if let error = envelope["error"]?.string { throw TVError.unsupported(readable(error)) }
        guard let text = envelope["value"]?.string,
              let answer = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) as? [String: Any] else {
            throw TVError.unsupported(L10n.text("The book source returned nothing."))
        }
        if let error = answer["error"] as? String { throw TVError.unsupported(readable(error)) }
        return answer["value"]
    }

    static func readable(_ error: String) -> String {
        let first = error.split(separator: "\n").first.map(String.init) ?? error
        if first.contains("did not finish in time") || first.contains("interrupted") { return L10n.text("The book source took too long to answer.") }
        // The engine's own messages are English keys; anything else (a script error) comes back as is.
        return L10n.text(String(first.prefix(400)))
    }

    static func json(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "null" }
        return (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    static func object<T: Encodable>(_ value: T) -> Any {
        (try? JSONEncoder().encode(value)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? NSNull()
    }

    private func decode<T: Decodable>(_ type: T.Type, _ value: Any?) throws -> T {
        guard let value, !(value is NSNull), JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            if let empty = [] as? T { return empty }
            throw TVError.unsupported(L10n.text("The book source returned nothing."))
        }
        return decoded
    }

    /// Where sources keep their variables, logins and caches; the probe points it elsewhere.
    nonisolated(unsafe) public static var profilesRoot: URL?
    static var profiles: URL { profilesRoot ?? NovelLibrary.root.appendingPathComponent("Profiles", isDirectory: true) }
}

extension NovelRuntime {
    /// What the pool costs, for tuning: `sessions` runtimes booted (the first alone, the rest at once, as a search
    /// boots them), then each of `sources` loaded into one of them in turn.
    public static func benchmark(_ sources: [NovelSource], sessions: Int) async throws -> [String] {
        var lines: [String] = []
        let before = residentBytes()
        var began = ContinuousClock.now
        var booted = [try await boot(label: "novel.bench.0")]
        lines.append("first boot: \(began.duration(to: .now))")
        began = ContinuousClock.now
        try await withThrowingTaskGroup(of: Session.self) { group in
            for index in 1..<max(sessions, 1) { group.addTask { try await boot(label: "novel.bench.\(index)") } }
            for try await session in group { booted.append(session) }
        }
        lines.append("\(booted.count - 1) more booted at once: \(began.duration(to: .now))")
        let afterBoot = residentBytes()
        lines.append("memory: \(before >> 20) MB → \(afterBoot >> 20) MB with \(booted.count) runtimes (≈\(((afterBoot - min(before, afterBoot)) / UInt64(booted.count)) >> 20) MB each)")
        var times: [Double] = [], failed = 0
        for (index, source) in sources.enumerated() {
            let session = booted[index % booted.count]
            began = ContinuousClock.now
            do { try await load(source, into: session) } catch { failed += 1; continue }
            let d = began.duration(to: .now).components
            times.append(Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15)
        }
        times.sort()
        if !times.isEmpty {
            func at(_ q: Double) -> String { String(format: "%.1f ms", times[min(times.count - 1, Int(Double(times.count) * q))]) }
            lines.append("load() of \(times.count) sources (\(failed) failed): median \(at(0.5)), p90 \(at(0.9)), max \(at(1))")
        }
        let afterLoad = residentBytes()
        lines.append("memory after the loads: \(afterLoad >> 20) MB")
        for session in booted { session.script.close() }
        return lines
    }

    static func residentBytes() -> UInt64 {
        #if canImport(Darwin)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
        return result == KERN_SUCCESS ? info.resident_size : 0
        #else
        return 0
        #endif
    }
}

/// What engine.js asks of the app beyond the TVBox host.
final class NovelHost: ScriptHostExtension, @unchecked Sendable {
    var allowsRemoteModules: Bool { false }
    /// LEGADO_LOG=1 prints the engine's log (the probe).
    static let echo = ProcessInfo.processInfo.environment["LEGADO_LOG"] != nil

    func answer(_ operation: String, _ argument: String) throws -> String?? {
        guard operation.hasPrefix("novel.") else { return nil }
        switch operation.dropFirst("novel.".count) {
        case "http": return .some(NovelHTTP.shared.perform(argument))
        case "webview":
            #if canImport(WebKit) && !os(tvOS)
            // The script thread waits while the main thread drives WebKit.
            let semaphore = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var reply = ""
            Task { @MainActor in
                let options = (try? JSONSerialization.jsonObject(with: Data(argument.utf8))) as? [String: Any] ?? [:]
                let answer = await NovelWebView.run(options)
                reply = (try? JSONSerialization.data(withJSONObject: answer)).map { String(decoding: $0, as: UTF8.self) } ?? #"{"failed":"The web view failed."}"#
                semaphore.signal()
            }
            semaphore.wait()
            return .some(reply)
            #else
            return .some(#"{"failed":"This source checks for a web browser, which Apple TV doesn't have. Read it on iPhone, iPad or Mac."}"#)
            #endif
        case "store": return .some(NovelStore.shared.handle(argument))
        case "flag": return .some(argument == "trace" && ProcessInfo.processInfo.environment["LEGADO_TRACE"] != nil ? "1" : "")
        case "log":
            Diagnostics.shared.record(.info, "novel.log", String(argument.prefix(800)))
            if Self.echo { FileHandle.standardError.write(Data(("[legado] " + argument.prefix(1500) + "\n").utf8)) }
            return .some(nil)
        default: break
        }
        let request = (try? JSONSerialization.jsonObject(with: Data(argument.utf8))) as? [String: Any] ?? [:]
        let text = request["text"] as? String ?? ""
        switch operation.dropFirst("novel.".count) {
        case "encode":
            let data = text.data(using: Self.encoding(request["encoding"] as? String), allowLossyConversion: true) ?? Data(text.utf8)
            return .some(data.base64EncodedString())
        case "decode":
            let data = Data(base64Encoded: request["base64"] as? String ?? "") ?? Data()
            let encoding = Self.encoding(request["encoding"] as? String)
            return .some(encoding == .utf8 ? String(decoding: data, as: UTF8.self) : String(data: data, encoding: encoding) ?? String(decoding: data, as: UTF8.self))
        case "convert":
            let toTraditional = (request["to"] as? String) == "hant"
            return .some(text.applyingTransform(StringTransform("Hans-Hant"), reverse: !toTraditional) ?? text)
        default:
            return nil
        }
    }

    static func encoding(_ name: String?) -> String.Encoding {
        let label = (name ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if label.isEmpty || label == "utf-8" || label == "utf8" { return .utf8 }
        // Sites say gbk or gb2312 and mean GB 18030's superset.
        if ["gbk", "gb2312", "gb18030", "x-gbk", "gb_2312-80"].contains(label) {
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        }
        let cf = CFStringConvertIANACharSetNameToEncoding(label as CFString)
        return cf == kCFStringEncodingInvalidId ? .utf8 : String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }
}

/// Book sources' requests: one URLSession per source with its own cookies (in memory, as Legado's OkHttp
/// cookie jar), trusting servers' certificates as Legado does (many novel sites have broken TLS setups).
final class NovelHTTP: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = NovelHTTP()
    private let lock = NSLock()
    private var sessions: [String: URLSession] = [:]
    private var order: [String] = []

    private final class Stop: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else { completionHandler(.performDefaultHandling, nil) }
    }

    private func session(_ jar: String) -> URLSession {
        lock.withLock {
            if let session = sessions[jar] { order.removeAll { $0 == jar }; order.append(jar); return session }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieAcceptPolicy = .always
            configuration.tlsMinimumSupportedProtocolVersion = .TLSv10
            configuration.httpMaximumConnectionsPerHost = 4
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            sessions[jar] = session; order.append(jar)
            while order.count > 64 { sessions.removeValue(forKey: order.removeFirst())?.finishTasksAndInvalidate() }
            return session
        }
    }

    func cookies(_ jar: String, for url: URL) -> [HTTPCookie] { session(jar).configuration.httpCookieStorage?.cookies(for: url) ?? [] }
    func keep(_ cookie: HTTPCookie, jar: String) { session(jar).configuration.httpCookieStorage?.setCookie(cookie) }

    /// {url, method, headers, body | bodyBase64, timeout (ms), jar, redirect: false} → {url, code, headers, base64, cookies} or {failed}.
    func perform(_ json: String) -> String {
        let options = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        guard let address = options["url"] as? String, let url = URL(string: address) ?? address.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return Self.reply(["code": 0, "failed": "Not a web address: \(String((options["url"] as? String ?? "").prefix(200)))"])
        }
        let timeout = min(30, max(1, (options["timeout"] as? Double ?? 15000) / 1000))
        var request = URLRequest(url: url, timeoutInterval: timeout)
        let method = (options["method"] as? String ?? "GET").uppercased()
        request.httpMethod = method
        for (field, value) in options["headers"] as? [String: Any] ?? [:] {
            let text = "\(value)"
            if !(field + text).contains(where: \.isNewline) { request.setValue(text, forHTTPHeaderField: field) }
        }
        if method != "GET", method != "HEAD" {
            if let encoded = options["bodyBase64"] as? String { request.httpBody = Data(base64Encoded: encoded) } else if let body = options["body"] as? String { request.httpBody = Data(body.utf8) }
        }
        let session = session(options["jar"] as? String ?? "")
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: (Data?, URLResponse?, Error?) = (nil, nil, nil)
        let task = session.dataTask(with: request) { data, response, error in result = (data, response, error); semaphore.signal() }
        if options["redirect"] as? Bool == false { task.delegate = Stop() }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout + 5) == .timedOut { task.cancel(); return Self.reply(["code": 0, "failed": "The site did not answer in time."]) }
        if let error = result.2 {
            return Self.reply(["code": 0, "failed": "Network request to \(url.host ?? "") failed: \(error.localizedDescription)"])
        }
        guard let response = result.1 as? HTTPURLResponse else { return Self.reply(["code": 0, "failed": "Network request to \(url.host ?? "") failed"]) }
        var headers: [String: String] = [:]
        for (name, value) in response.allHeaderFields { headers["\(name)".lowercased()] = "\(value)" }
        let final = response.url ?? url
        var cookies: [String: String] = [:]
        for cookie in session.configuration.httpCookieStorage?.cookies(for: final) ?? [] { cookies[cookie.name] = cookie.value }
        return Self.reply(["url": final.absoluteString, "code": response.statusCode, "headers": headers, "base64": (result.0 ?? Data()).base64EncodedString(), "cookies": cookies])
    }

    private static func reply(_ value: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: value)).map { String(decoding: $0, as: UTF8.self) } ?? #"{"code":0,"failed":"unreadable answer"}"#
    }
}

/// Sources' variables, logins, caches and saved cookies, per source, on disk (Profiles/<hash>.json).
final class NovelStore: @unchecked Sendable {
    static let shared = NovelStore()
    private let lock = NSLock()
    private var values: [String: [String: String]] = [:]
    private let writer = DispatchQueue(label: "novel.store")

    private static func file(_ source: String) -> URL {
        let digest = SHA256.hash(data: Data(source.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        return NovelRuntime.profiles.appendingPathComponent(digest + ".json")
    }

    /// {op: get|set|remove, source, key, value}
    func handle(_ json: String) -> String? {
        let request = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        let source = request["source"] as? String ?? "", key = request["key"] as? String ?? ""
        return lock.withLock { () -> String? in
            if values[source] == nil {
                values[source] = (try? Data(contentsOf: Self.file(source))).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
            }
            switch request["op"] as? String {
            case "get": return values[source]?[key] ?? ""
            case "set": values[source]?[key] = request["value"] as? String ?? ""
            default: values[source]?.removeValue(forKey: key)
            }
            let snapshot = values[source] ?? [:], file = Self.file(source)
            writer.async {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: file, options: .atomic) }
            }
            return nil
        }
    }
}

// MARK: - Web views (java.webView, java.startBrowserAwait, `webView: true` URLs)

#if canImport(WebKit) && !os(tvOS)
/// Loads a page in an off-screen WKWebView, as Legado's BackstageWebView does: for sites that build their pages in
/// script, and for bot checks (Cloudflare, a probe.js page) that a browser passes by itself. Cookies go both ways
/// with the source's NovelHTTP session.
@MainActor final class NovelWebView: NSObject, WKNavigationDelegate {
    private var view: WKWebView?
    private var finished: CheckedContinuation<Void, Never>?
    private var loaded = false

    /// {url, html, js, ua, headers, jar, timeout (s), challenge} → {content, url} or {failed}
    static func run(_ options: [String: Any]) async -> [String: Any] {
        await NovelWebView().load(options)
    }

    private func load(_ options: [String: Any]) async -> [String: Any] {
        let timeout = min(40, max(5, options["timeout"] as? Double ?? 20))
        let deadline = Date().addingTimeInterval(timeout)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        self.view = view
        defer { view.stopLoading(); view.navigationDelegate = nil; self.view = nil }
        view.navigationDelegate = self
        if let agent = options["ua"] as? String, !agent.isEmpty { view.customUserAgent = agent }
        let address = (options["url"] as? String).flatMap { URL(string: $0) }
        let jar = options["jar"] as? String ?? ""
        let store = configuration.websiteDataStore.httpCookieStore
        if let address { for cookie in NovelHTTP.shared.cookies(jar, for: address) { await store.setCookie(cookie) } }
        if let html = options["html"] as? String, !html.isEmpty {
            view.loadHTMLString(html, baseURL: address)
        } else if let address {
            var request = URLRequest(url: address, timeoutInterval: timeout)
            for (name, value) in options["headers"] as? [String: String] ?? [:] where name.lowercased() != "user-agent" { request.setValue(value, forHTTPHeaderField: name) }
            view.load(request)
        } else { return ["failed": "Nothing to load in the web view."] }
        await withCheckedContinuation { continuation in
            if loaded { continuation.resume() } else { finished = continuation }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.finish()
            }
        }
        let script = (options["js"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let challenge = options["challenge"] as? Bool ?? false
        var content = ""
        // Pages that fill in by script, or that pass a bot check and reload, get a few more looks.
        repeat {
            if let script {
                let value = try? await view.evaluateJavaScript(script)
                content = Self.text(value)
                if !content.isEmpty, content != "null", content != "undefined" { break }
            } else {
                content = Self.text(try? await view.evaluateJavaScript("document.documentElement.outerHTML"))
                if !challenge || !Self.isChallenge(content) { break }
            }
            try? await Task.sleep(for: .milliseconds(700))
        } while Date() < deadline
        // A check's own scripts may still be setting cookies once the page is there.
        if challenge { try? await Task.sleep(for: .milliseconds(1500)) }
        for cookie in await store.allCookies() { NovelHTTP.shared.keep(cookie, jar: jar) }
        return ["content": content, "url": view.url?.absoluteString ?? address?.absoluteString ?? ""]
    }

    static func isChallenge(_ html: String) -> Bool {
        (html.count < 400 && html.contains("<script")) || (html.count < 2000 && html.contains("location.replace(")) || html.contains("Just a moment...") || html.contains("/probe.js") || html.contains("challenge-platform") || html.contains("cf-browser-verification")
    }

    private static func text(_ value: Any?) -> String {
        switch value {
        case let text as String: text
        case let number as NSNumber: number.stringValue
        case nil, is NSNull: ""
        default: (try? JSONSerialization.data(withJSONObject: value!, options: [.fragmentsAllowed])).map { String(decoding: $0, as: UTF8.self) } ?? "\(value!)"
        }
    }

    private func finish() {
        loaded = true
        finished?.resume(); finished = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish() }
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust { completionHandler(.useCredential, URLCredential(trust: trust)) } else { completionHandler(.performDefaultHandling, nil) }
    }
}
#endif

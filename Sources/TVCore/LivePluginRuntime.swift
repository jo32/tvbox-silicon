import CryptoKit
import Foundation
import Security
import JavaScriptCore
import zlib

/// What a live plugin's script threw: `Host.makeError(code, message, context)`, or an `LP_PLUGIN_ERROR:` message.
public struct LivePluginError: LocalizedError, Sendable, Equatable {
    /// AUTH_REQUIRED, UPSTREAM, INVALID_ARGS, INVALID_RESPONSE, NOT_FOUND, UNSUPPORTED, ...
    public let code: String
    public let message: String
    public var errorDescription: String? {
        switch code {
        case "AUTH_REQUIRED": L10n.text("Sign in to this platform to see this.")
        case "NOT_LIVE": L10n.text("The streamer isn't live now.")
        case "UNSUPPORTED", "NOT_SUPPORTED": L10n.text("This platform's plugin can't do this.")
        default: message.isEmpty ? code : message
        }
    }

    static func parse(_ text: String) -> LivePluginError {
        if let range = text.range(of: "LP_PLUGIN_ERROR:"),
           let json = try? JSONDecoder().decode(JSONValue.self, from: Data(text[range.upperBound...].utf8)).object {
            let code = json["code"]?.string ?? json["code"]?.double.map { String(Int($0)) } ?? "UNKNOWN"
            return LivePluginError(code: canonical(code), message: json["message"]?.string ?? "")
        }
        let message = text.hasPrefix("Error: ") ? String(text.dropFirst(7)) : text
        let lower = message.lowercased()
        let code = lower.contains("login") || lower.contains("cookie") ? "AUTH_REQUIRED" : lower.contains("timeout") || lower.contains("timed out") ? "TIMEOUT"
            : lower.contains("not found") ? "NOT_FOUND" : "UNKNOWN"
        return LivePluginError(code: code, message: message)
    }

    /// Older codes some plugins still throw, as the canonical ones.
    static func canonical(_ code: String) -> String {
        switch code.uppercased() {
        case "REQUIRES_AUTH", "AUTH", "AUTH_FAILED": "AUTH_REQUIRED"
        case "INVALID_INPUT", "INVALID_STATE": "INVALID_ARGS"
        case "DECODE_FAILED": "PARSE"
        case "OFFLINE", "STREAM_UNAVAILABLE": "NOT_LIVE"
        case "406", "UPSTREAM_RESTRICTED": "BLOCKED"
        case "REQUEST_FAILED": "NETWORK"
        case let other where other == "DEPRECATED" || other.hasPrefix("SIGNING_"): "UNSUPPORTED"
        case let other: other
        }
    }
}

/// Runs installed live plugins (`LivePlugins`) in JavaScriptCore, one context per plugin on its own queue, and
/// gives them the `Host` object AngelLive plugins expect: HTTP, crypto, storage, cookies and time. A plugin is
/// `globalThis.LiveParsePlugin`, whose async methods (`getCategories`, `getRooms`, `getPlayback`, `search`, ...)
/// take one payload object.
public actor LivePluginRuntime {
    public static let shared = LivePluginRuntime()
    private var loaded: [String: LoadedLivePlugin] = [:]
    private var loading: [String: Task<LoadedLivePlugin, Error>] = [:]

    /// Calls `method` with `payload` and returns what its promise resolves to.
    public func call(_ id: String, _ method: String, _ payload: [String: JSONValue] = [:], timeout: Double = 45) async throws -> JSONValue {
        // The app keeps sign-in cookies; these never reach the plugin.
        switch method {
        case "setCookie", "setCredential":
            let credential = payload["credential"]?.object ?? payload
            LivePluginAccounts.setCookie(id, credential["cookie"]?.string)
            return .object(["ok": .bool(true), "managedByHost": .bool(true), "hasCookie": .bool(!LivePluginAccounts.cookie(id).isEmpty)])
        case "clearCookie", "clearCredential":
            LivePluginAccounts.setCookie(id, nil)
            return .object(["ok": .bool(true), "managedByHost": .bool(true), "hasCookie": .bool(false)])
        default: break
        }
        let plugin = try await plugin(id)
        return try await plugin.call(method, payload: .object(payload), timeout: timeout)
    }

    /// Whether the plugin defines `method`.
    public func has(_ id: String, _ method: String) async -> Bool {
        guard let plugin = try? await plugin(id) else { return false }
        return plugin.has(method)
    }

    func unload(_ id: String) {
        loading[id]?.cancel()
        loading[id] = nil
        loaded.removeValue(forKey: id)?.close()
    }

    private func plugin(_ id: String) async throws -> LoadedLivePlugin {
        if let plugin = loaded[id] { return plugin }
        if let task = loading[id] { return try await task.value }
        let task = Task { () throws -> LoadedLivePlugin in
            let folder = try await LivePlugins.shared.files(id)
            return try LoadedLivePlugin(id: id, folder: folder)
        }
        loading[id] = task
        defer { loading[id] = nil }
        let plugin = try await task.value
        loaded[id] = plugin
        return plugin
    }
}

/// One plugin's JavaScript context. Everything that touches it runs on `queue`.
final class LoadedLivePlugin: @unchecked Sendable {
    let id: String
    private let queue: DispatchQueue
    private let context: JSContext
    private let storageKey: String
    private var calls: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var nextCall = 1
    private var closed = false
    private let network: URLSession
    /// Hosts that get the sign-in cookie (`authMode: "platform_cookie"`): `loginFlow.cookieDomains` and its login page's.
    private let cookieDomains: [String]
    /// A cookie sent even when signed out (`sessionMigration.defaultCookie`, SOOP's `AbroadChk=OK`).
    private let defaultCookie: String

    init(id: String, folder: URL) throws {
        self.id = id
        queue = DispatchQueue(label: "tvbox.liveplugin.\(id)")
        storageKey = "livePluginStorage." + id
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20
        network = URLSession(configuration: configuration, delegate: LivePluginRedirects.shared, delegateQueue: nil)
        guard let context = JSContext() else { throw TVError.unsupported("JavaScriptCore") }
        self.context = context
        let manifestData = try Data(contentsOf: folder.appending(path: "manifest.json"))
        guard let manifest = try JSONDecoder().decode(JSONValue.self, from: manifestData).object else { throw LivePlugins.Failure.noManifest }
        let scripts = (manifest["preloadScripts"]?.array ?? []).compactMap(\.string) + [manifest["entry"]?.string ?? "index.js"]
        let flow = manifest["loginFlow"]?.object ?? [:]
        var domains = (flow["cookieDomains"]?.array ?? []).compactMap { $0.string?.lowercased() }
        if let login = flow["loginURL"]?.string.flatMap(URL.init(string:))?.host()?.lowercased() { domains.append(login) }
        cookieDomains = domains.map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }.filter { !$0.isEmpty }
        defaultCookie = manifest["sessionMigration"]?.object?["defaultCookie"]?.string ?? ""
        var failure: Error?
        queue.sync {
            context.name = "LivePlugin \(id)"
            context.exceptionHandler = { [id] _, exception in
                Diagnostics.shared.record(.warning, "plugins", "\(id) uncaught \(exception?.toString() ?? "-")")
            }
            install()
            context.evaluateScript(Self.prelude, withSourceURL: URL(string: "yingxia://host.js"))
            for name in scripts {
                guard SubtitleArchive.safe(name), let source = try? String(contentsOf: folder.appending(path: name), encoding: .utf8) else {
                    failure = TVError.unsupported(L10n.text("The plugin %@ is missing its script %@.", id, name)); return
                }
                context.exception = nil
                context.evaluateScript(source, withSourceURL: URL(string: "plugin://\(id)/\(name)"))
                if let exception = context.exception {
                    failure = LivePluginError.parse(exception.toString() ?? ""); return
                }
            }
            if context.objectForKeyedSubscript("LiveParsePlugin")?.isObject != true {
                failure = TVError.unsupported(L10n.text("The plugin %@ defines no LiveParsePlugin.", id))
            } else if let version = context.evaluateScript("LiveParsePlugin.apiVersion"), !version.isUndefined, version.toInt32() != 1 {
                failure = TVError.unsupported(L10n.text("The plugin %@ needs a newer version of Yingxia.", id))
            }
        }
        if let failure { throw failure }
    }

    func close() {
        queue.async { [self] in
            closed = true
            let pending = calls; calls = [:]
            pending.values.forEach { $0.resume(throwing: CancellationError()) }
        }
        network.invalidateAndCancel()
    }

    func has(_ method: String) -> Bool {
        queue.sync { context.evaluateScript("typeof LiveParsePlugin[\(Self.literal(method))] === 'function'")?.toBool() ?? false }
    }

    func call(_ method: String, payload: JSONValue, timeout: Double) async throws -> JSONValue {
        let json = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        return try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask { try await self.start(method, json: json) }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw LivePluginError(code: "TIMEOUT", message: L10n.text("The platform took too long to answer."))
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func start(_ method: String, json: String) async throws -> JSONValue {
        let id = queue.sync { () -> Int in nextCall += 1; return nextCall }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
                queue.async { [self] in
                    guard !closed else { return continuation.resume(throwing: CancellationError()) }
                    calls[id] = continuation
                    context.exception = nil
                    context.objectForKeyedSubscript("__yxInvoke")?.call(withArguments: [id, method, json])
                    if let exception = context.exception, let pending = calls.removeValue(forKey: id) {
                        pending.resume(throwing: LivePluginError.parse(exception.toString() ?? ""))
                    }
                }
            }
        } onCancel: { [self] in
            queue.async { [self] in calls.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
        }
    }

    // MARK: Host functions (called on `queue`)

    private func install() {
        let finish: @convention(block) (Int, Bool, String) -> Void = { [weak self] id, ok, payload in
            guard let self, let continuation = self.calls.removeValue(forKey: id) else { return }
            if ok {
                let value = (try? JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8))) ?? .null
                continuation.resume(returning: value)
            } else {
                continuation.resume(throwing: LivePluginError.parse(payload))
            }
        }
        context.setObject(finish, forKeyedSubscript: "__yxFinish" as NSString)

        let sync: @convention(block) (String, String) -> String = { [weak self] name, json in
            guard let self else { return "null" }
            let args = (try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))?.array ?? []
            return self.syncCall(name, args)
        }
        context.setObject(sync, forKeyedSubscript: "__yxSync" as NSString)

        let async: @convention(block) (String, String, Int) -> Void = { [weak self] name, json, ticket in
            guard let self else { return }
            let args = (try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))?.array ?? []
            Task { [self] in
                let result: (Bool, String)
                do { result = (true, try await self.asyncCall(name, args)) }
                catch let error as LivePluginError { result = (false, "LP_PLUGIN_ERROR:" + Self.errorJSON(error.code, error.message)) }
                catch { result = (false, "LP_PLUGIN_ERROR:" + Self.errorJSON("NETWORK", Diagnostics.describe(error))) }
                self.queue.async { [self] in
                    guard !closed else { return }
                    context.objectForKeyedSubscript("__yxSettle")?.call(withArguments: [ticket, result.0, result.1])
                }
            }
        }
        context.setObject(async, forKeyedSubscript: "__yxAsync" as NSString)

        let log: @convention(block) (String, String) -> Void = { [id] level, text in
            Diagnostics.shared.record(level == "error" ? .warning : .debug, "plugins", "\(id): \(text.prefix(600))")
        }
        context.setObject(log, forKeyedSubscript: "__yxLog" as NSString)
    }

    private func syncCall(_ name: String, _ args: [JSONValue]) -> String {
        func string(_ index: Int) -> String { index < args.count ? args[index].string ?? args[index].double.map { String($0) } ?? "" : "" }
        func encode(_ value: JSONValue) -> String { String(decoding: (try? JSONEncoder().encode(value)) ?? Data("null".utf8), as: UTF8.self) }
        switch name {
        case "md5": return encode(.string(Insecure.MD5.hash(data: Data(string(0).utf8)).map { String(format: "%02x", $0) }.joined()))
        case "sha1": return encode(.string(Insecure.SHA1.hash(data: Data(string(0).utf8)).map { String(format: "%02x", $0) }.joined()))
        case "sha256": return encode(.string(SHA256.hash(data: Data(string(0).utf8)).map { String(format: "%02x", $0) }.joined()))
        case "hmacSha256":
            let mac = HMAC<SHA256>.authenticationCode(for: Data(string(0).utf8), using: SymmetricKey(data: Data(string(1).utf8)))
            return encode(.string(Data(mac).map { String(format: "%02x", $0) }.joined()))
        case "base64Encode": return encode(.string(Data(string(0).utf8).base64EncodedString()))
        case "base64Decode":
            let text = string(0).removingPercentEncoding ?? string(0)
            guard let data = Data(base64Encoded: Self.padded(text)), let decoded = String(data: data, encoding: .utf8) else { return encode(.string("")) }
            return encode(.string(decoded))
        case "storageGet":
            let stored = UserDefaults.standard.dictionary(forKey: storageKey)?[string(0)] as? String
            return encode(stored.map(JSONValue.string) ?? .null)
        case "storageSet":
            var stored = UserDefaults.standard.dictionary(forKey: storageKey) ?? [:]
            if args.count > 1, case .null = args[1] { stored.removeValue(forKey: string(0)) } else { stored[string(0)] = string(1) }
            UserDefaults.standard.set(stored, forKey: storageKey)
            return "null"
        case "cookieHeader":
            // Only the plugin's own platform.
            let asked = string(0)
            return encode(.string(asked.isEmpty || asked == id ? cookie() : ""))
        case "inflate":
            // [base64, "zlib" | "gzip" | "raw"] -> base64
            guard let data = Data(base64Encoded: Self.padded(string(0))), let out = Self.inflate(data, format: string(1)) else { return "null" }
            return encode(.string(out.base64EncodedString()))
        default:
            return "null"
        }
    }

    private func asyncCall(_ name: String, _ args: [JSONValue]) async throws -> String {
        switch name {
        case "http":
            guard let options = args.first?.object else { throw LivePluginError(code: "INVALID_ARGS", message: "request options") }
            return try await http(options)
        default:
            throw LivePluginError(code: "UNSUPPORTED", message: "host \(name)")
        }
    }

    /// `Host.http.request(options)`: `{url, method, headers, body | bodyBase64, timeout}` answered with
    /// `{status, statusCode, headers, url, bodyText, bodyBase64}`.
    private func http(_ outer: [String: JSONValue]) async throws -> String {
        // Also `{platformId, authMode, request: {url, method, ...}}`.
        var options = outer
        if let inner = outer["request"]?.object { options.merge(inner) { _, new in new } }
        guard let address = options["url"]?.string, let url = URL(string: address) ?? URL(string: address.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw LivePluginError(code: "INVALID_ARGS", message: "url \(options["url"]?.string ?? "-")")
        }
        var request = URLRequest(url: url)
        request.httpMethod = (options["method"]?.string ?? "GET").uppercased()
        let inner = outer["request"]?.object ?? [:]
        let seconds = inner["timeoutMs"]?.double.map { $0 / 1000 } ?? inner["timeout"]?.double ?? outer["timeoutMs"]?.double.map { $0 / 1000 } ?? outer["timeout"]?.double ?? 20
        request.timeoutInterval = min(120, max(0.1, seconds))
        var headers: [String: String] = [:]
        for (key, value) in options["headers"]?.object ?? [:] { if let text = value.string ?? value.double.map({ String(format: "%g", $0) }) { headers[key] = text } }
        let signedIn = Self.usesAccount(options)
        if signedIn {
            // The app's cookie, and only to the platform's own sites over HTTPS.
            headers = headers.filter { !["cookie", "authorization"].contains($0.key.lowercased()) }
            let host = url.host()?.lowercased() ?? ""
            let own = cookieDomains.isEmpty || cookieDomains.contains { host == $0 || host.hasSuffix("." + $0) }
            guard url.scheme?.lowercased() == "https", own else {
                throw LivePluginError(code: "UNSUPPORTED", message: "platform cookie refused for \(host)")
            }
            let cookie = cookie()
            if !cookie.isEmpty { headers["Cookie"] = cookie }
        }
        if !headers.keys.contains(where: { $0.lowercased() == "user-agent" }) { headers["User-Agent"] = Self.browserAgent }
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if let base64 = options["bodyBase64"]?.string { request.httpBody = Data(base64Encoded: Self.padded(base64)) }
        else if let body = options["body"] {
            switch body {
            case .string(let text): request.httpBody = Data(text.utf8)
            case .null: break
            default: request.httpBody = try JSONEncoder().encode(body)
            }
        }
        if options["followRedirects"].map({ if case .bool(false) = $0 { true } else { false } }) == true
            || options["redirect"]?.string == "manual" {
            LivePluginRedirects.shared.refuse(request)
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await network.data(for: request) }
        catch let error as URLError where error.code == .timedOut { throw LivePluginError(code: "TIMEOUT", message: error.localizedDescription) }
        catch { throw LivePluginError(code: "NETWORK", message: error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw LivePluginError(code: "INVALID_RESPONSE", message: "no HTTP response") }
        var fields: [String: JSONValue] = [:]
        var cookies: [JSONValue] = []
        for (key, value) in http.allHeaderFields {
            guard let key = key as? String, let value = value as? String else { continue }
            if key.lowercased() == "set-cookie" {
                if signedIn { continue }
                cookies = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": value], for: http.url ?? url).map {
                    .string("\($0.name)=\($0.value); Path=\($0.path); Domain=\($0.domain)")
                }
            }
            // Plugins look names up as the server sent them and in lower case.
            fields[key] = .string(value)
            fields[key.lowercased()] = .string(value)
        }
        var reply: [String: JSONValue] = [
            "status": .number(Double(http.statusCode)), "statusCode": .number(Double(http.statusCode)),
            "headers": .object(fields), "url": .string(http.url?.absoluteString ?? address), "setCookies": .array(cookies),
            "bodyText": String(data: data, encoding: .utf8).map(JSONValue.string) ?? .null,
        ]
        if data.count <= 8 << 20 { reply["bodyBase64"] = .string(data.base64EncodedString()) }
        return String(decoding: try JSONEncoder().encode(JSONValue.object(reply)), as: UTF8.self)
    }

    /// Requests that ask for the platform's sign-in cookie (`authMode: "platform_cookie"`).
    private static func usesAccount(_ options: [String: JSONValue]) -> Bool {
        let mode = options["authMode"]?.string ?? ""
        return mode == "platform_cookie" || mode == "cookie"
    }

    static let browserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"

    /// The sign-in cookie with the plugin's default one.
    private func cookie() -> String {
        [defaultCookie, LivePluginAccounts.cookie(id)].filter { !$0.isEmpty }.joined(separator: "; ")
    }

    static func errorJSON(_ code: String, _ message: String) -> String {
        String(decoding: (try? JSONEncoder().encode(JSONValue.object(["code": .string(code), "message": .string(message)]))) ?? Data(), as: UTF8.self)
    }

    static func padded(_ base64: String) -> String {
        var text = base64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/").filter { !$0.isWhitespace }
        while text.count % 4 != 0 { text += "=" }
        return text
    }

    static func literal(_ text: String) -> String {
        String(decoding: (try? JSONEncoder().encode(JSONValue.string(text))) ?? Data("\"\"".utf8), as: UTF8.self)
    }

    /// zlib, gzip or raw deflate.
    static func inflate(_ data: Data, format: String) -> Data? {
        var stream = z_stream()
        let bits: Int32 = format == "gzip" ? 31 : format == "raw" ? -15 : 15 + 32
        guard inflateInit2_(&stream, bits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var output = Data()
        var input = data
        let chunk = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        var status: Int32 = Z_OK
        input.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            stream.next_in = raw.bindMemory(to: Bytef.self).baseAddress
            stream.avail_in = uInt(raw.count)
            repeat {
                buffer.withUnsafeMutableBufferPointer { out in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(chunk)
                    status = zlib.inflate(&stream, Z_NO_FLUSH)
                    output.append(out.baseAddress!, count: chunk - Int(stream.avail_out))
                }
            } while status == Z_OK && output.count < 64 << 20
        }
        return status == Z_STREAM_END || (status == Z_BUF_ERROR && !output.isEmpty) ? output : nil
    }

    /// The `Host` object, `atob`/`btoa` and the bare `window`/`document`/`navigator` AngelLive gives plugins,
    /// in JavaScript over the `__yx*` functions above. No timers, `fetch` or `URL`: plugins pick code paths by what exists.
    static let prelude = #"""
    (function () {
      const g = globalThis;
      // What AngelLive gives plugins, no more: they choose their code paths by what exists.
      g.document = {}; g.window = {};
      g.navigator = { userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36' };
      const sync = (name, ...args) => JSON.parse(__yxSync(name, JSON.stringify(args)));
      const tickets = new Map(); let nextTicket = 1;
      g.__yxSettle = function (ticket, ok, payload) {
        const entry = tickets.get(ticket); if (!entry) return; tickets.delete(ticket);
        if (ok) entry.resolve(JSON.parse(payload)); else entry.reject(new Error(payload));
      };
      const later = (name, ...args) => new Promise((resolve, reject) => {
        const ticket = nextTicket++; tickets.set(ticket, { resolve, reject });
        __yxAsync(name, JSON.stringify(args), ticket);
      });
      const fmt = (a) => a.map((x) => typeof x === 'string' ? x : (() => { try { return JSON.stringify(x); } catch (_) { return String(x); } })()).join(' ');
      g.console = { log: (...a) => __yxLog('log', fmt(a)), info: (...a) => __yxLog('log', fmt(a)), debug: (...a) => __yxLog('log', fmt(a)), warn: (...a) => __yxLog('warn', fmt(a)), error: (...a) => __yxLog('error', fmt(a)) };

      const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
      g.btoa = function (s) { s = String(s); let out = ''; for (let i = 0; i < s.length; i += 3) { const a = s.charCodeAt(i), b = s.charCodeAt(i + 1), c = s.charCodeAt(i + 2); if (a > 255 || b > 255 || c > 255) throw new Error('InvalidCharacterError'); const n = (a << 16) | ((b || 0) << 8) | (c || 0); out += B64[(n >> 18) & 63] + B64[(n >> 12) & 63] + (i + 1 < s.length ? B64[(n >> 6) & 63] : '=') + (i + 2 < s.length ? B64[n & 63] : '='); } return out; };
      g.atob = function (s) { s = String(s).replace(/[\s=]/g, '').replace(/-/g, '+').replace(/_/g, '/'); let out = '', bits = 0, value = 0; for (let i = 0; i < s.length; i++) { const v = B64.indexOf(s[i]); if (v < 0) continue; value = (value << 6) | v; bits += 6; if (bits >= 8) { bits -= 8; out += String.fromCharCode((value >> bits) & 255); } } return out; };

      function makeError(code, message, context) {
        const error = new Error('LP_PLUGIN_ERROR:' + JSON.stringify({ code: String(code || 'UNKNOWN'), message: String(message || ''), context: context || {} }));
        error.code = String(code || 'UNKNOWN'); error.context = context || {};
        return error;
      }
      g.Host = {
        apiVersion: 1,
        platform: 'yingxia',
        capabilities: { mediaTransform: 0, dualStream: false, loginTransaction: false, loginChallengeProtocol: 0, loginChallengePush: false,
                        loginChallengeBootstrap: false, credentialExposure: true, webSocketPlatformCookie: false },
        makeError,
        raise(code, message, context) { throw makeError(code, message, context); },
        http: { request: (options) => later('http', options || {}) },
        crypto: {
          md5: (s) => sync('md5', String(s)),
          sha1: (s) => sync('sha1', String(s)),
          sha256: (s) => sync('sha256', String(s)),
          hmacSha256: (s, key) => sync('hmacSha256', String(s), String(key)),
          base64Encode: (s) => sync('base64Encode', String(s)),
          base64Decode: (s) => sync('base64Decode', String(s)),
        },
        time: { nowMillis: () => Date.now(), now: () => Date.now() },
        storage: { get: (k) => sync('storageGet', String(k)), set: (k, v) => sync('storageSet', String(k), v === undefined || v === null ? null : String(v)), remove: (k) => sync('storageSet', String(k), null) },
        session: {
          getCookieHeader: (id) => sync('cookieHeader', id === undefined || id === null ? '' : String(id)),
          getTransactionCookieHeader: () => Promise.reject(makeError('UNSUPPORTED', 'transaction cookies')),
          seedTransactionCookies: () => Promise.resolve({ ok: true }),
        },
        runtime: {
          inflateZlib: (b64) => sync('inflate', String(b64), 'zlib'),
          inflateGzip: (b64) => sync('inflate', String(b64), 'gzip'),
          decompressGzip: (b64) => sync('inflate', String(b64), 'gzip'),
          loadBuiltinScript: () => false,
        },
      };

      g.__yxInvoke = function (ticket, method, json) {
        const plugin = g.LiveParsePlugin;
        const fn = plugin && plugin[method];
        if (typeof fn !== 'function') { __yxFinish(ticket, false, 'LP_PLUGIN_ERROR:' + JSON.stringify({ code: 'UNSUPPORTED', message: method })); return; }
        let result;
        try { result = fn.call(plugin, JSON.parse(json)); }
        catch (e) { __yxFinish(ticket, false, String((e && e.message) || e)); return; }
        Promise.resolve(result).then(
          (value) => { let text; try { text = JSON.stringify(value === undefined ? null : value); } catch (e) { __yxFinish(ticket, false, String(e)); return; } __yxFinish(ticket, true, text); },
          (e) => __yxFinish(ticket, false, String((e && e.message) || e)));
      };
    })();
    """#
}

/// Refuses redirects for requests that asked not to follow them; follows the rest.
final class LivePluginRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = LivePluginRedirects()
    private let lock = NSLock()
    private var refused = Set<URL>()

    func refuse(_ request: URLRequest) { if let url = request.url { lock.withLock { _ = refused.insert(url) } } }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let stop = task.originalRequest?.url.map { url in lock.withLock { refused.remove(url) != nil } } ?? false
        completionHandler(stop ? nil : request)
    }
}

/// The sign-in cookies plugins send for their platform (`authMode: "platform_cookie"`, `Host.session`).
/// The platforms' sign-in cookies, in the Keychain, one item per plugin. Plugins never see them unless they ask
/// with `Host.session.getCookieHeader` or a `platform_cookie` request to the platform's own sites.
public enum LivePluginAccounts {
    public static let changed = Notification.Name("LivePluginAccounts.changed")
    static let service = "com.tvbox.yingxia.live-plugin-cookies"
    nonisolated(unsafe) private static var cache: [String: String] = [:]
    private static let lock = NSLock()

    public static func cookie(_ id: String) -> String {
        if let cached = lock.withLock({ cache[id] }) { return cached }
        var query = base(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let value = status == errSecSuccess ? (result as? Data).map { String(decoding: $0, as: UTF8.self) } ?? "" : ""
        lock.withLock { cache[id] = value }
        return value
    }

    public static func isSignedIn(_ id: String) -> Bool { !cookie(id).isEmpty }

    public static func setCookie(_ id: String, _ cookie: String?) {
        let value = cookie?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        SecItemDelete(base(id) as CFDictionary)
        if !value.isEmpty {
            var item = base(id)
            item[kSecValueData as String] = Data(value.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(item as CFDictionary, nil)
            if status != errSecSuccess { Diagnostics.shared.record(.warning, "plugins", "keychain save failed status=\(status)") }
        }
        lock.withLock { cache[id] = value }
        NotificationCenter.default.post(name: changed, object: id)
    }

    private static func base(_ id: String) -> [String: Any] {
        // On the Mac this is the login keychain: the data-protection one needs an entitlement Debug builds lack.
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id]
    }
}

/// How a plugin signs in on its platform's web page (`loginFlow` in its manifest, kind `webview`).
public struct LivePluginLoginFlow: Sendable {
    public let page: URL
    public let userAgent: String?
    /// Sites whose cookies make up the sign-in.
    public let domains: [String]
    /// Cookies that appear once signed in.
    public let signals: [String]
    /// What a pasted cookie must hold, in the plugin's words.
    public let hint: String?

    init?(_ json: [String: JSONValue]) {
        guard let page = json["loginURL"]?.string.flatMap(URL.init(string:)) else { return nil }
        self.page = page
        userAgent = json["userAgent"]?.string
        var domains = (json["cookieDomains"]?.array ?? []).compactMap { $0.string?.lowercased() }
        if let host = page.host()?.lowercased() { domains.append(host) }
        self.domains = domains.map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }
        signals = (json["authSignalCookies"]?.array ?? []).compactMap(\.string)
        hint = json["requiredCookieHint"]?.string
    }

    /// The `Cookie` header of the platform's cookies, once they show a sign-in.
    public func header(from cookies: [HTTPCookie]) -> String? {
        let own = cookies.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return domains.contains { domain == $0 || domain.hasSuffix("." + $0) || $0.hasSuffix("." + domain) }
        }
        guard signals.isEmpty ? !own.isEmpty : own.contains(where: { signals.contains($0.name) && !$0.value.isEmpty }) else { return nil }
        var seen = Set<String>()
        return own.filter { seen.insert($0.name).inserted }.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}

extension LivePlugins {
    /// The plugin's web sign-in, when it has one.
    public func loginFlow(_ id: String) async -> LivePluginLoginFlow? {
        guard let folder = try? await files(id), let data = try? Data(contentsOf: folder.appending(path: "manifest.json")),
              let manifest = try? JSONDecoder().decode(JSONValue.self, from: data).object,
              let flow = manifest["loginFlow"]?.object else { return nil }
        return LivePluginLoginFlow(flow)
    }

    /// Asks the plugin whether the saved cookie still signs in (`validateCredential`); nil when it can't tell.
    public func checkSignIn(_ id: String) async -> Bool? {
        guard LivePluginAccounts.isSignedIn(id), await LivePluginRuntime.shared.has(id, "validateCredential") else { return nil }
        do {
            let reply = try await LivePluginRuntime.shared.call(id, "validateCredential", ["credentialAvailable": .bool(true)], timeout: 20)
            let object = reply.object ?? [:]
            for key in ["valid", "isValid", "ok", "loggedIn", "isLoggedIn"] { if case .bool(let flag)? = object[key] { return flag } }
            if let status = object["status"]?.string?.lowercased() { return ["valid", "ok", "logged_in", "active"].contains(status) }
            return nil
        } catch let error as LivePluginError where error.code == "AUTH_REQUIRED" || error.code == "AUTH_EXPIRED" {
            return false
        } catch { return nil }
    }
}

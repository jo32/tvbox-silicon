import Foundation

/// HTTP for comic sources and their page images: one connection pool, a desktop browser's user agent
/// (as Venera's), and a persistent cookie jar, since sources sign in and pass checks with cookies.
enum MangaHTTP {
    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36"

    /// Keeps cookies set by redirect responses, and sends the jar's cookies to the next address.
    private final class Redirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            if let url = response.url { MangaCookieJar.shared.store(response, for: url) }
            var next = request
            if let url = request.url, let cookie = MangaCookieJar.shared.header(for: url, merging: nil) { next.setValue(cookie, forHTTPHeaderField: "Cookie") }
            completionHandler(next)
        }
    }
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration, delegate: Redirects(), delegateQueue: nil)
    }()

    struct Request: Sendable {
        var url: URL
        var method = "GET"
        var headers: [String: String] = [:]
        var body: Data?

        func urlRequest() -> URLRequest {
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.httpMethod = method
            request.httpShouldHandleCookies = false
            var fields = headers
            if !fields.keys.contains(where: { $0.lowercased() == "user-agent" }) { fields["User-Agent"] = MangaHTTP.userAgent }
            let given = fields.first { $0.key.lowercased() == "cookie" }
            if let given { fields.removeValue(forKey: given.key) }
            if let cookie = MangaCookieJar.shared.header(for: url, merging: given?.value) { fields["Cookie"] = cookie }
            for (field, value) in fields where !(field + value).contains(where: \.isNewline) {
                // Dio sends headers as given; URLSession manages these itself.
                if ["content-length", "host", "connection"].contains(field.lowercased()) { continue }
                request.setValue(value, forHTTPHeaderField: field)
            }
            if method != "GET", method != "HEAD" { request.httpBody = body }
            return request
        }
    }

    /// Hosts that send a browser user agent to a bot challenge (MangaDex's API does) but serve plain clients.
    private static let plainHosts = PlainHosts()
    private final class PlainHosts: @unchecked Sendable {
        let lock = NSLock(); var hosts = Set<String>()
        func contains(_ host: String) -> Bool { lock.withLock { hosts.contains(host) } }
        func insert(_ host: String) { lock.withLock { _ = hosts.insert(host) } }
    }
    static let plainUserAgent = "Dart/3.5 (dart:io)"

    /// One request with the jar's cookies; the jar keeps what the answer sets.
    static func data(_ request: Request, notes: Bool = false) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, http) = try await answer(request)
            if notes, let kind = MangaSiteProblem.kind(http, data) {
                MangaSiteProblem.note(MangaSiteProblem(kind: kind, host: request.url.host ?? "", status: http.statusCode))
                #if DEBUG
                if ProcessInfo.processInfo.environment["MANGA_HTTP_LOG"] != nil || UserDefaults.standard.bool(forKey: "qaMangaHTTPLog") { NSLog("[mangahttp] problem %@", "\(kind)") }
                #endif
            }
            return (data, http)
        } catch let error as URLError where notes && error.code != .cancelled {
            MangaSiteProblem.note(MangaSiteProblem(kind: .unreachable, host: request.url.host ?? "", status: 0))
            throw error
        }
    }

    private static func answer(_ request: Request) async throws -> (Data, HTTPURLResponse) {
        var request = request
        if let answer = signedOutFavorite(request) { return answer }
        let chosenAgent = request.headers.keys.contains { $0.lowercased() == "user-agent" }
        let host = request.url.host ?? ""
        if !chosenAgent, plainHosts.contains(host) { request.headers["User-Agent"] = plainUserAgent }
        var (data, response) = try await session.data(for: request.urlRequest())
        guard var http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        MangaCookieJar.shared.store(http, for: http.url ?? request.url)
        let challenged = http.url?.path.contains("challenge") == true || http.value(forHTTPHeaderField: "cf-mitigated") == "challenge"
        if challenged, !chosenAgent, request.headers["User-Agent"] != plainUserAgent {
            plainHosts.insert(host)
            request.headers["User-Agent"] = plainUserAgent
            (data, response) = try await session.data(for: request.urlRequest())
            guard let retried = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            http = retried
            MangaCookieJar.shared.store(http, for: http.url ?? request.url)
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["MANGA_HTTP_LOG"] != nil || UserDefaults.standard.bool(forKey: "qaMangaHTTPLog") {
            NSLog("[mangahttp] %d %@ dev=%@ %@", http.statusCode, request.url.absoluteString, request.headers["device"] ?? "-", http.statusCode == 210 || http.statusCode >= 400 ? String(decoding: data.prefix(300), as: UTF8.self) : "")
        }
        #endif
        // 拷贝漫画 allows about 15 API requests a minute from one address, whatever made-up device each names, and
        // answers the rest 210: "Expected available in N seconds", or with no wait "update to the official
        // app…a cracked version". Asking again at once only adds to the count, so the wait it names (else 5, 10,
        // 20 s) is sat out, up to a minute in all, while the pages say how long is left
        // (MangaRuntime.throttleNotification), and then asked as a new device, as Venera's script does.
        var waited = 0.0, tries = 0
        while http.statusCode == 210, request.method == "GET" {
            let pause = retryDelay(data) ?? [5.0, 10, 20][min(tries, 2)]
            guard waited + pause <= 60 else { break }
            NotificationCenter.default.post(name: MangaRuntime.throttleNotification, object: nil, userInfo: ["host": host, "seconds": pause])
            try await Task.sleep(for: .seconds(pause))
            waited += pause
            tries += 1
            _ = MangaDevice.renew(&request.headers)
            (data, response) = try await session.data(for: request.urlRequest())
            guard let again = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            http = again
            #if DEBUG
            if ProcessInfo.processInfo.environment["MANGA_HTTP_LOG"] != nil || UserDefaults.standard.bool(forKey: "qaMangaHTTPLog") {
                NSLog("[mangahttp] retry %d %@ dev=%@", http.statusCode, request.url.absoluteString, request.headers["device"] ?? "-")
            }
            #endif
            MangaCookieJar.shared.store(http, for: http.url ?? request.url)
        }
        return (data, http)
    }

    /// copy_manga.js asks whether a comic is in the account's favourites on every comic page, signed out too
    /// (authorization "Token" with none after it), where the answer is always no; that request would only
    /// spend one of the site's 15 a minute.
    static func signedOutFavorite(_ request: Request) -> (Data, HTTPURLResponse)? {
        let path = request.url.path
        guard request.method == "GET", path.hasPrefix("/api/v3/comic2/"), path.hasSuffix("/query"),
              let token = request.headers.first(where: { $0.key.lowercased() == "authorization" })?.value,
              token.trimmingCharacters(in: .whitespaces) == "Token",
              let response = HTTPURLResponse(url: request.url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])
        else { return nil }
        return (Data(#"{"code":200,"message":"","results":{"collect":null}}"#.utf8), response)
    }

    /// Seconds a 210 answer asks to wait ("Expected available in 8 seconds"); nil when it names none.
    static func retryDelay(_ body: Data) -> Double? {
        let text = String(decoding: body.prefix(4096), as: UTF8.self)
        guard let range = text.range(of: #"\d+(?=\s*seconds?)"#, options: .regularExpression), let seconds = Double(text[range]) else { return nil }
        return max(1, seconds + 1)
    }

    /// `sendMessage({method: 'http'})` for the prelude: starts the request and hands `finish` the JSON answer
    /// {status, headers, text | base64} or {error}. Returns how to cancel it.
    static func start(_ options: [String: Any], finish: @escaping @Sendable (String) -> Void) -> () -> Void {
        guard let address = options["url"] as? String, let url = URL(string: address) ?? address.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:)),
              url.scheme == "http" || url.scheme == "https" else {
            finish(MangaHost.json(["error": "Invalid URL: \(options["url"] ?? "")"]) ?? "{}")
            return {}
        }
        var request = Request(url: url, method: (options["method"] as? String ?? "GET").uppercased())
        request.headers = (options["headers"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        if let body = options["body"] as? String { request.body = Data(base64Encoded: body) }
        let bytes = options["bytes"] as? Bool ?? false
        let task = Task {
            do {
                let (data, response) = try await Self.data(request, notes: true)
                var headers: [String: String] = [:]
                for (field, value) in response.allHeaderFields { headers[String(describing: field).lowercased()] = String(describing: value) }
                var answer: [String: Any] = ["status": response.statusCode, "headers": headers]
                if bytes { answer["base64"] = data.base64EncodedString() } else { answer["text"] = text(data, contentType: headers["content-type"]) }
                finish(MangaHost.json(answer) ?? "{}")
            } catch {
                finish(MangaHost.json(["error": (error as? URLError)?.code == .cancelled ? "cancelled" : error.localizedDescription]) ?? "{}")
            }
        }
        return { task.cancel() }
    }

    /// The body as text in its declared charset (GBK and Big5 included), UTF-8 otherwise.
    static func text(_ data: Data, contentType: String?) -> String {
        if let contentType, let range = contentType.range(of: "charset=", options: .caseInsensitive) {
            let name = contentType[range.upperBound...].split(separator: ";").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) } ?? ""
            if !name.isEmpty, name.lowercased() != "utf-8" { return ScriptHTTP.text(data, encoding: name) }
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Cookies of every comic source, kept across launches (Network.setCookies/getCookies/deleteCookies too).
public final class MangaCookieJar: @unchecked Sendable {
    public static let shared = MangaCookieJar()
    private let lock = NSLock()
    private var cookies: [HTTPCookie] = []
    private var loaded = false
    private var file: URL { MangaLibrary.root.appendingPathComponent("cookies.json") }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let list = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [[String: Any]] else { return }
        cookies = list.compactMap { item in
            var properties: [HTTPCookiePropertyKey: Any] = [.name: item["name"] ?? "", .value: item["value"] ?? "", .domain: item["domain"] ?? "", .path: item["path"] ?? "/"]
            if let expires = item["expires"] as? Double { properties[.expires] = Date(timeIntervalSince1970: expires) }
            if item["secure"] as? Bool == true { properties[.secure] = "TRUE" }
            return HTTPCookie(properties: properties)
        }.filter { $0.expiresDate.map { $0 > Date() } ?? true }
    }
    private func save() {
        let list: [[String: Any]] = cookies.filter { !$0.isSessionOnly || true }.map { cookie in
            var item: [String: Any] = ["name": cookie.name, "value": cookie.value, "domain": cookie.domain, "path": cookie.path, "secure": cookie.isSecure]
            if let expires = cookie.expiresDate { item["expires"] = expires.timeIntervalSince1970 }
            return item
        }
        try? FileManager.default.createDirectory(at: MangaLibrary.root, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: list) { try? data.write(to: file, options: .atomic) }
    }

    private static func matches(_ cookie: HTTPCookie, _ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if let expires = cookie.expiresDate, expires < Date() { return false }
        if cookie.isSecure, url.scheme != "https" { return false }
        var domain = cookie.domain.lowercased()
        let hostOnly = !domain.hasPrefix(".")
        if domain.hasPrefix(".") { domain.removeFirst() }
        guard host == domain || (!hostOnly && host.hasSuffix("." + domain)) || host.hasSuffix("." + domain) else { return false }
        let path = url.path.isEmpty ? "/" : url.path
        return path.hasPrefix(cookie.path) || cookie.path.isEmpty
    }

    public func cookies(for url: URL) -> [HTTPCookie] { lock.withLock { ensureLoaded(); return cookies.filter { Self.matches($0, url) } } }

    /// The Cookie header for `url`: the jar's cookies after those the request named itself.
    func header(for url: URL, merging given: String?) -> String? {
        var parts = given.map { $0.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } } ?? []
        let named = Set(parts.compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) })
        for cookie in cookies(for: url) where !named.contains(cookie.name) { parts.append("\(cookie.name)=\(cookie.value)") }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    func store(_ response: HTTPURLResponse, for url: URL) {
        var fields: [String: String] = [:]
        for (field, value) in response.allHeaderFields { fields[String(describing: field)] = String(describing: value) }
        let received = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        if !received.isEmpty { add(received) }
    }

    public func add(_ received: [HTTPCookie]) {
        lock.withLock {
            ensureLoaded()
            for cookie in received {
                cookies.removeAll { $0.name == cookie.name && $0.domain.lowercased() == cookie.domain.lowercased() && $0.path == cookie.path }
                if cookie.expiresDate.map({ $0 > Date() }) ?? true { cookies.append(cookie) }
            }
            save()
        }
    }

    public func remove(for url: URL) {
        lock.withLock {
            ensureLoaded()
            cookies.removeAll { Self.matches($0, url) }
            save()
        }
    }

    func handle(_ request: [String: Any]) throws -> String? {
        guard let address = request["url"] as? String, let url = URL(string: address) else { return nil }
        switch request["function"] as? String {
        case "set":
            let list = (request["cookies"] as? [[String: Any]] ?? []).compactMap { item -> HTTPCookie? in
                HTTPCookie(properties: [.name: item["name"] as? String ?? "", .value: item["value"] as? String ?? "",
                                        .domain: item["domain"] as? String ?? url.host ?? "", .path: "/"])
            }
            add(list)
            return nil
        case "get":
            return MangaHost.json(cookies(for: url).map { cookie -> [String: Any] in
                ["name": cookie.name, "value": cookie.value, "domain": cookie.domain, "path": cookie.path, "secure": cookie.isSecure,
                 "httpOnly": cookie.isHTTPOnly, "session": cookie.expiresDate == nil, "expires": cookie.expiresDate.map { $0.timeIntervalSince1970 * 1000 } ?? NSNull()]
            })
        case "delete":
            remove(for: url)
            return nil
        default: return nil
        }
    }
}

/// The made-up phone 拷贝漫画's app headers name (device, deviceinfo, pseudoid), in the shapes Venera's
/// copy_manga.js invents them: "AB1C.123456.789", "1234567V-1234", 16 letters and digits.
enum MangaDevice {
    /// Replaces those headers with a new phone; false when the request names none.
    static func renew(_ headers: inout [String: String]) -> Bool {
        var changed = false
        for key in headers.keys {
            switch key.lowercased() {
            case "device": headers[key] = device(); changed = true
            case "deviceinfo": headers[key] = "\(Int.random(in: 1_000_000...9_999_999))V-\(Int.random(in: 1000...9999))"; changed = true
            case "pseudoid": headers[key] = String((0..<16).map { _ in alphanumerics.randomElement()! }); changed = true
            default: break
            }
        }
        return changed
    }

    private static let alphanumerics = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    static func device() -> String {
        let letter = { String(UnicodeScalar(UInt8(65 + Int.random(in: 0...25)))) }
        let digits = { (count: Int) in String((0..<count).map { _ in Character(String(Int.random(in: 0...9))) }) }
        return letter() + letter() + digits(1) + letter() + "." + digits(6) + "." + digits(3)
    }
}

/// Why a comic source's site refused, read from its answer (status, headers, body), so a failed page can say
/// "blocks your region" or "asks for a browser check" rather than the script's own "status code 403".
public struct MangaSiteProblem: Error, Sendable {
    public enum Kind: Sendable { case regionBlocked, browserCheck, rateLimited, signInNeeded, notFound, serverError, refused, unreachable }
    public let kind: Kind
    public let host: String
    public let status: Int
    /// What the source itself said, shown under the explanation.
    public var detail = ""
    let date = Date()

    static func kind(_ http: HTTPURLResponse, _ body: Data) -> Kind? {
        let status = http.statusCode
        guard status >= 400 || status == 210 else { return nil }
        let text = String(decoding: body.prefix(8192), as: UTF8.self).lowercased()
        // Sites word this in the page's language, which follows the app's Accept-Language:
        // "The region has been denied.", 「当前区域禁止访问」, 「該地區無法訪問」.
        let region = ["region", "country", "区域", "區域", "地区", "地區", "地域", "国家", "國家"].contains { text.contains($0) }
        let refused = ["denied", "blocked", "not available", "禁止", "拒绝", "拒絕", "无法访问", "無法訪問", "不可用", "利用できません"].contains { text.contains($0) }
        if status == 451 || (status == 403 && region && refused) {
            return .regionBlocked
        }
        if http.value(forHTTPHeaderField: "cf-mitigated") == "challenge" || text.contains("challenge_required")
            || text.contains("just a moment") || text.contains("cf-chl") || text.contains("cf_chl") { return .browserCheck }
        switch status {
        case 210, 429: return .rateLimited
        case 401: return .signInNeeded
        case 404, 410: return .notFound
        case 500...: return .serverError
        default: return .refused
        }
    }

    private final class Log: @unchecked Sendable {
        let lock = NSLock()
        var latest: [MangaSiteProblem] = []
    }
    private static let log = Log()

    static func note(_ problem: MangaSiteProblem) {
        log.lock.withLock { log.latest = (log.latest + [problem]).suffix(20) }
    }

    /// The last refusal since `date`, i.e. during one call of a source.
    public static func latest(since date: Date) -> MangaSiteProblem? {
        log.lock.withLock { log.latest.last { $0.date >= date } }
    }
}

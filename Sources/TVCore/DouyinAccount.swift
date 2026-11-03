import Foundation
import CryptoKit
import Network

/// The signed-in Douyin account, which Douyin requires for live search. Douyin's sign-in only works
/// in its own web page, so iPhone, iPad and Mac sign in in a web view, and an Apple TV receives the
/// sign-in from the iPhone app over the local network (`DouyinHandoff`).
public struct DouyinAccount: Codable, Equatable, Sendable {
    /// The desktop browser Douyin's sign-in page and its account check expect.
    public static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    /// The douyin.com cookies of the signed-in web session.
    public var cookie = ""
    public var name = ""
    public init(cookie: String = "", name: String = "") { self.cookie = cookie; self.name = name }
    public var signedIn: Bool { cookie.contains("sessionid=") }

    static var fileURL: URL {
        #if os(tvOS)
        // tvOS only permits Caches; `load` restores a purged copy from user defaults.
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #endif
        return base.appendingPathComponent("com.tvbox.yingxia/Douyin/account.json")
    }
    private static let defaultsKey = "douyinAccount"

    public static func load() -> Self {
        if let data = try? Data(contentsOf: fileURL), let account = try? JSONDecoder().decode(Self.self, from: data) { return account }
        #if os(tvOS)
        if let data = UserDefaults.standard.data(forKey: defaultsKey), let account = try? JSONDecoder().decode(Self.self, from: data) {
            try? account.save()
            return account
        }
        #endif
        return Self()
    }
    public func save() throws {
        let folder = Self.fileURL.deletingLastPathComponent()
        let data = try JSONEncoder().encode(self)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: Self.fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.fileURL.path)
        #if os(tvOS)
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        #endif
    }
    public static func signOut() {
        try? FileManager.default.removeItem(at: fileURL)
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    /// The account from a signed-in web view's cookies (any for douyin.com), or nil before sign-in.
    public static func from(cookies: [HTTPCookie]) -> Self? {
        let live = cookies.filter { cookie in
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return (domain == "douyin.com" || domain.hasSuffix(".douyin.com")) && (cookie.expiresDate.map { $0 > Date() } ?? true)
        }
        guard live.contains(where: { $0.name == "sessionid" && !$0.value.isEmpty }) else { return nil }
        var fields: [String: String] = [:]
        for cookie in live { fields[cookie.name] = cookie.value }
        return Self(cookie: fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; "))
    }

    /// Fills in the account's nickname; false when Douyin no longer accepts the sign-in.
    public mutating func refresh() async -> Bool {
        guard signedIn else { return false }
        let url = LiveHTTP.url("https://live.douyin.com/webcast/user/me/", [("aid", "6383")])
        guard let reply = try? await LiveHTTP.json(url, headers: ["Cookie": cookie, "Referer": "https://live.douyin.com/", "User-Agent": DouyinAccount.userAgent]) else { return true }
        if let nickname = reply["data"]?.object?["nickname"]?.string, !nickname.isEmpty { name = nickname; return true }
        // 20003 is "please sign in"; anything else (a network hiccup, a new error) keeps the sign-in.
        return reply["status_code"]?.int != 20003
    }
}

/// Moves a Douyin sign-in from the iPhone app to an Apple TV. The TV listens on the local network
/// and shows a code holding `yingxia://douyin-login?host=…&port=…&key=…`; scanning it with the
/// iPhone's camera opens the app, which sends the account sealed with that one-time key
/// (AES-GCM), so nothing readable crosses the network and only the code's holder can send.
public enum DouyinHandoff {
    public static let scheme = "yingxia"
    public static let action = "douyin-login"

    /// A TV's handoff address, as its code carries it.
    public struct Link: Sendable, Equatable, Identifiable {
        public let host: String
        public let port: UInt16
        let key: Data
        public var id: String { "\(host):\(port)" }
        public init?(_ url: URL) {
            guard url.scheme == DouyinHandoff.scheme, url.host() == DouyinHandoff.action,
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                  let host = items.first(where: { $0.name == "host" })?.value, !host.isEmpty,
                  let port = items.first(where: { $0.name == "port" })?.value.flatMap(UInt16.init),
                  let key = items.first(where: { $0.name == "key" })?.value.flatMap(Self.decode), key.count == 32 else { return nil }
            self.host = host; self.port = port; self.key = key
        }
        init(host: String, port: UInt16, key: Data) { self.host = host; self.port = port; self.key = key }
        public var url: URL {
            var components = URLComponents()
            components.scheme = DouyinHandoff.scheme
            components.host = DouyinHandoff.action
            components.queryItems = [URLQueryItem(name: "host", value: host), URLQueryItem(name: "port", value: String(port)),
                                     URLQueryItem(name: "key", value: key.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                                        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: ""))]
            return components.url!
        }
        static func decode(_ text: String) -> Data? {
            var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
            return Data(base64Encoded: base64)
        }
    }

    /// Sends `account` to the TV behind `link`. Retries briefly: the first request on iOS can fail
    /// while the system asks for local network access.
    public static func send(_ account: DouyinAccount, to link: Link) async throws {
        let sealed = try AES.GCM.seal(try JSONEncoder().encode(account), using: SymmetricKey(data: link.key)).combined!
        var request = URLRequest(url: URL(string: "http://\(link.host):\(link.port)/\(action)")!, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.httpBody = sealed
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        var failure: Error = TVError.unsupported(L10n.text("The Apple TV didn't answer. Make sure both are on the same Wi-Fi and try again."))
        for attempt in 0..<4 {
            if attempt > 0 { try await Task.sleep(for: .seconds(2)) }
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                switch (response as? HTTPURLResponse)?.statusCode {
                case 200: return
                case 403: throw TVError.unsupported(L10n.text("This code has expired. Show a new code on the Apple TV and scan it again."))
                default: continue
                }
            } catch let error as TVError {
                throw error
            } catch {
                failure = error
            }
        }
        throw failure
    }

    #if os(tvOS) || os(macOS)
    /// The TV side: listens until one sealed account arrives, saves it, and reports it.
    public final class Receiver: @unchecked Sendable {
        private let queue = DispatchQueue(label: "tvbox.douyin.handoff")
        private let key = SymmetricKey(size: .bits256)
        private var listener: NWListener?
        private var received: (@Sendable (DouyinAccount) -> Void)?

        public init() {}

        /// Starts listening and returns the link to show as a code.
        public func start(onReceive: @escaping @Sendable (DouyinAccount) -> Void) async throws -> Link {
            guard let host = BilibiliCastReceiver.localAddress() else {
                throw TVError.unsupported(L10n.text("Connect this device to Wi-Fi or Ethernet first."))
            }
            let listener = try NWListener(using: .tcp)
            received = onReceive
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
                // State updates arrive on `queue`, one at a time.
                final class Once: @unchecked Sendable { var done = false }
                let once = Once()
                listener.stateUpdateHandler = { state in
                    guard !once.done else { return }
                    switch state {
                    case .ready: once.done = true; continuation.resume(returning: listener.port?.rawValue ?? 0)
                    case .failed(let error): once.done = true; continuation.resume(throwing: error)
                    default: break
                    }
                }
                listener.start(queue: queue)
            }
            queue.sync { self.listener = listener }
            return Link(host: host, port: port, key: key.withUnsafeBytes { Data($0) })
        }

        public func stop() {
            queue.async {
                self.listener?.cancel()
                self.listener = nil
                self.received = nil
            }
        }

        private func accept(_ connection: NWConnection) {
            connection.start(queue: queue)
            read(connection, buffer: Data())
            // A connection that never finishes its request is dropped.
            queue.asyncAfter(deadline: .now() + 15) { connection.cancel() }
        }

        private func read(_ connection: NWConnection, buffer: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                guard buffer.count < 65536, error == nil else { connection.cancel(); return }
                guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    if complete { connection.cancel() } else { self.read(connection, buffer: buffer) }
                    return
                }
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                let length = head.split(separator: "\r\n").lazy.compactMap { line -> Int? in
                    let parts = line.split(separator: ":", maxSplits: 1)
                    return parts.count == 2 && parts[0].lowercased() == "content-length" ? Int(parts[1].trimmingCharacters(in: .whitespaces)) : nil
                }.first ?? 0
                let body = buffer[end.upperBound...]
                guard body.count >= length else {
                    if complete { connection.cancel() } else { self.read(connection, buffer: buffer) }
                    return
                }
                self.respond(connection, head: head, body: Data(body.prefix(length)))
            }
        }

        private func respond(_ connection: NWConnection, head: String, body: Data) {
            var status = "400 Bad Request"
            if head.hasPrefix("POST /\(DouyinHandoff.action) ") {
                if let box = try? AES.GCM.SealedBox(combined: body), let plain = try? AES.GCM.open(box, using: key),
                   let account = try? JSONDecoder().decode(DouyinAccount.self, from: plain), account.signedIn {
                    status = "200 OK"
                    received?(account)
                    // One sign-in per code.
                    received = nil
                    listener?.cancel(); listener = nil
                } else {
                    status = "403 Forbidden"
                }
            }
            let reply = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
    #endif
}

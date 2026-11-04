import Foundation
import Network
import Observation

/// An outbound proxy the viewer defined: HTTP, HTTPS (an HTTP CONNECT proxy), or SOCKS5,
/// at a host and port with an optional username and password.
public struct CustomProxyEndpoint: Codable, Hashable, Identifiable, Sendable {
    public enum Scheme: String, Codable, CaseIterable, Identifiable, Sendable {
        case http, https, socks5
        public var id: String { rawValue }
        public var title: String { rawValue.uppercased() }
    }

    public let id: String
    public var name: String
    public var scheme: Scheme
    public var host: String
    public var port: Int
    public var username: String
    public var password: String

    public init(id: String = UUID().uuidString, name: String, scheme: Scheme, host: String, port: Int,
                username: String = "", password: String = "") {
        self.id = id; self.name = name; self.scheme = scheme; self.host = host; self.port = port
        self.username = username; self.password = password
    }

    var address: String? {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, (1...65535).contains(port) else { return nil }
        return host
    }

    // MARK: 编解码 —— 凭证明文不进盘

    /// `username` / `password` are stored obfuscated so a copied preferences file does not show
    /// proxy credentials at a glance. This is **not** encryption — a single XOR + Base64 layer —
    /// and exists only because the settings blob is otherwise plain JSON. The real fix would be
    /// Keychain, which is deliberately out of scope here.
    private static let obfuscationKey = Array("yingxia.customproxy".utf8)
    private static let obfuscationMarker = "v1:"

    private enum CodingKeys: String, CodingKey {
        case id, name, scheme, host, port, username, password
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        scheme = try container.decode(Scheme.self, forKey: .scheme)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        username = Self.deobfuscate(try container.decodeIfPresent(String.self, forKey: .username) ?? "")
        password = Self.deobfuscate(try container.decodeIfPresent(String.self, forKey: .password) ?? "")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(scheme, forKey: .scheme)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(Self.obfuscate(username), forKey: .username)
        try container.encode(Self.obfuscate(password), forKey: .password)
    }

    private static func obfuscate(_ text: String) -> String {
        let key = obfuscationKey
        let bytes = Array(text.utf8)
        let mixed = bytes.enumerated().map { $0.element ^ key[$0.offset % key.count] }
        return obfuscationMarker + Data(mixed).base64EncodedString()
    }

    private static func deobfuscate(_ text: String) -> String {
        // Values saved by earlier builds carry no marker and are plain text.
        guard text.hasPrefix(obfuscationMarker) else { return text }
        let payload = String(text.dropFirst(obfuscationMarker.count))
        guard let data = Data(base64Encoded: payload) else { return text }
        let key = obfuscationKey
        let bytes = data.enumerated().map { $0.element ^ key[$0.offset % key.count] }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Which way one source's requests leave: direct, or through one of the configured proxies.
public enum CustomProxyRoute: Codable, Hashable, Sendable {
    case direct
    case proxy(String)   // CustomProxyEndpoint.id
    public var proxyID: String? { if case .proxy(let id) = self { return id } else { return nil } }
    public var isProxy: Bool { proxyID != nil }
}

/// The tunnel that carries one HTTP request through the viewer's proxy. HTTP(S) proxies are
/// spoken to with `CONNECT host:port`; SOCKS5 with the RFC 1928 greeting, auth (when set) and
/// CONNECT request, then the connection is a raw byte pipe to the target.
///
/// It is deliberately **not** a system `URLSession` proxy (iOS ignores those keys): the app
/// implements the proxy client protocol itself over `Network`'s TCP, so a VPN app can take this
/// local egress and route it however it likes, and the caller can fall back to a direct request
/// when the tunnel cannot be opened.
public final class CustomProxyTunnel: @unchecked Sendable {
    private let endpoint: CustomProxyEndpoint
    private let targetHost: String
    private let targetPort: UInt16
    private let queue = DispatchQueue(label: "tvbox.proxy.tunnel")
    private let connection: NWConnection
    private let lock = NSLock()
    private var answered = false

    public init(endpoint: CustomProxyEndpoint, targetHost: String, targetPort: UInt16) throws {
        guard let address = endpoint.address,
              let port = NWEndpoint.Port(rawValue: UInt16(endpoint.port)) else { throw TVError.invalidConfiguration }
        self.endpoint = endpoint
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.connection = NWConnection(host: NWEndpoint.Host(address), port: port, using: .tcp)
    }

    /// Opens the proxy, negotiates its protocol, and returns once the pipe to `targetHost:targetPort`
    /// is ready for raw bytes. Throws when the proxy is unreachable or the handshake fails.
    public func open() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    self.negotiate { self.finish($0) { continuation.resume(with: $0) } }
                case .failed(let error):
                    self.finish(.failure(error)) { continuation.resume(with: $0) }
                case .cancelled:
                    self.finish(.failure(CancellationError())) { continuation.resume(with: $0) }
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    /// Answers `done` once, whatever else the connection reports afterwards.
    ///
    /// `NWConnection` keeps calling the state handler for the life of the connection, and the
    /// handshake runs after `.ready`: a `.failed` or `.cancelled` arriving in the middle of it would
    /// answer a continuation that was already answered, which traps the process rather than
    /// surfacing as an error. Clearing the handler at the same time stops the rest of the states
    /// from even reaching this code.
    private func finish(_ result: Result<Void, Error>, _ done: (Result<Void, Error>) -> Void) {
        lock.lock()
        guard !answered else {
            lock.unlock()
            return
        }
        answered = true
        lock.unlock()
        connection.stateUpdateHandler = nil
        done(result)
    }

    private func negotiate(_ done: @escaping (Result<Void, Error>) -> Void) {
        switch endpoint.scheme {
        case .http, .https:
            negotiateHTTP(done)
        case .socks5:
            negotiateSOCKS5(done)
        }
    }

    // MARK: HTTP CONNECT

    private func negotiateHTTP(_ done: @escaping (Result<Void, Error>) -> Void) {
        var request = "CONNECT \(targetHost):\(targetPort) HTTP/1.1\r\nHost: \(targetHost):\(targetPort)\r\n"
        if !endpoint.username.isEmpty {
            let raw = "\(endpoint.username):\(endpoint.password)"
            request += "Proxy-Authorization: Basic \(Data(raw.utf8).base64EncodedString())\r\n"
        }
        request += "\r\n"
        connection.send(content: Data(request.utf8), completion: .contentProcessed { [connection] error in
            if let error { done(.failure(error)); return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, error in
                if let error { done(.failure(error)); return }
                guard let data, let head = String(data: data, encoding: .utf8) else {
                    done(.failure(TVError.invalidConfiguration)); return
                }
                let status = head.split(separator: "\r\n").first ?? ""
                if status.hasPrefix("HTTP/1.1 200") || status.hasPrefix("HTTP/1.0 200") {
                    done(.success(()))
                } else {
                    done(.failure(TVError.http(Int(status.split(separator: " ").dropFirst().first ?? "502") ?? 502)))
                }
            }
        })
    }

    // MARK: SOCKS5 (RFC 1928)

    private func negotiateSOCKS5(_ done: @escaping (Result<Void, Error>) -> Void) {
        let wantsAuth = !endpoint.username.isEmpty
        var greeting = Data([0x05, wantsAuth ? 0x02 : 0x01, 0x00])
        if wantsAuth { greeting.append(0x02) }   // 0x00 none, 0x02 username/password
        connection.send(content: greeting, completion: .contentProcessed { [connection, endpoint, targetHost, targetPort] error in
            if let error { done(.failure(error)); return }
            connection.receive(minimumIncompleteLength: 2, maximumLength: 2) { data, _, _, error in
                if let error { done(.failure(error)); return }
                guard let data, data.count == 2, data[0] == 0x05 else { done(.failure(TVError.invalidConfiguration)); return }
                let method = data[1]
                switch method {
                case 0x00:
                    Self.connect(connection, host: targetHost, port: targetPort, done: done)
                case 0x02:
                    Self.authenticate(connection, endpoint: endpoint, host: targetHost, port: targetPort, done: done)
                case 0xFF:
                    done(.failure(TVError.invalidConfiguration))
                default:
                    done(.failure(TVError.invalidConfiguration))
                }
            }
        })
    }

    private static func authenticate(_ connection: NWConnection, endpoint: CustomProxyEndpoint, host: String, port: UInt16,
                                     done: @escaping (Result<Void, Error>) -> Void) {
        let user = Data(endpoint.username.utf8), pass = Data(endpoint.password.utf8)
        guard user.count <= 255, pass.count <= 255 else { done(.failure(TVError.invalidConfiguration)); return }
        var auth = Data([0x01, UInt8(user.count)]); auth.append(user); auth.append(UInt8(pass.count)); auth.append(pass)
        connection.send(content: auth, completion: .contentProcessed { error in
            if let error { done(.failure(error)); return }
            connection.receive(minimumIncompleteLength: 2, maximumLength: 2) { data, _, _, error in
                if let error { done(.failure(error)); return }
                guard let data, data.count == 2, data[0] == 0x01, data[1] == 0x00 else {
                    done(.failure(TVError.invalidConfiguration)); return
                }
                connect(connection, host: host, port: port, done: done)
            }
        })
    }

    private static func connect(_ connection: NWConnection, host: String, port: UInt16, done: @escaping (Result<Void, Error>) -> Void) {
        let name = host.utf8
        guard name.count <= 255 else { done(.failure(TVError.invalidConfiguration)); return }
        var request = Data([0x05, 0x01, 0x00, 0x03, UInt8(name.count)])
        request.append(contentsOf: name)
        request.append(contentsOf: withUnsafeBytes(of: port.bigEndian) { Data($0) })
        connection.send(content: request, completion: .contentProcessed { error in
            if let error { done(.failure(error)); return }
            connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { data, _, _, error in
                if let error { done(.failure(error)); return }
                guard let data, data.count >= 2, data[0] == 0x05, data[1] == 0x00 else {
                    done(.failure(TVError.invalidConfiguration)); return
                }
                done(.success(()))
            }
        })
    }

    public func cancel() { connection.cancel() }

    /// Opens the proxy tunnel and returns the connection once it is a raw byte pipe to the
    /// target. The caller relays bytes over it; TLS stays intact because this layer never
    /// inspects or rewrites the payload.
    public func openTunnel() async throws -> NWConnection {
        try await open()
        return connection
    }

    /// Callback form of `open()`, for callers that relay on a dispatch queue and don't want to
    /// bridge into async/await. `connection` is the raw pipe to the target once `done` succeeds.
    public func open(queue: DispatchQueue, done: @escaping @Sendable (Result<Void, Error>) -> Void) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: self.negotiate { self.finish($0, done) }
            case .failed(let error): self.finish(.failure(error), done)
            case .cancelled: self.finish(.failure(CancellationError()), done)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    /// The raw connection; valid for relaying only after `open()` / `open(queue:done:)` succeeds.
    public var relayConnection: NWConnection { connection }

    // MARK: Request relay

    /// Sends an HTTP request through the already-open tunnel and returns the response body.
    ///
    /// The tunnel is a raw pipe to the target — CONNECT for an HTTP proxy, RFC 1928 for SOCKS5 — so
    /// the request has to be origin-form (`GET /path?query HTTP/1.1`). The absolute URI this used to
    /// send is what a *forward* proxy expects; after CONNECT or SOCKS5 there is no proxy left to
    /// interpret it, and a real server answers 400. The port only belongs in `Host` when it is not
    /// the one the scheme implies.
    public func request(_ url: URL, headers: [String: String], timeout: TimeInterval, maxBytes: Int = 20_000_000) async throws -> Data {
        var path = url.path.isEmpty ? "/" : url.path
        if let query = url.query { path += "?" + query }
        var host = url.host ?? ""
        let implied = url.scheme?.lowercased() == "https" ? 443 : 80
        if let port = url.port, port != implied { host += ":\(port)" }

        var request = "GET \(path) HTTP/1.1\r\nHost: \(host)\r\n"
        for (key, value) in headers where key.lowercased() != "host" { request += "\(key): \(value)\r\n" }
        request += "Connection: close\r\n\r\n"
        let bytes = Data(request.utf8)
        let connection = self.connection
        let response: Data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error); return }
                Self.readResponse(connection, buffer: Data(), maxBytes: maxBytes) { continuation.resume(with: $0) }
            })
        }
        return try Self.body(response)
    }

    private static func readResponse(_ connection: NWConnection, buffer: Data, maxBytes: Int,
                                     _ done: @escaping (Result<Data, Error>) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            var bytes = buffer
            if let data { bytes.append(data) }
            if bytes.count > maxBytes { done(.failure(TVError.unsupported("Response too large"))); connection.cancel(); return }
            if let headerEnd = bytes.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: bytes[..<headerEnd.lowerBound], as: UTF8.self)
                if let length = Self.contentLength(head) {
                    if bytes.count >= headerEnd.upperBound + length { done(.success(bytes)); connection.cancel(); return }
                } else if complete { done(.success(bytes)); return }
            }
            if error != nil || complete { done(.success(bytes)); return }
            Self.readResponse(connection, buffer: bytes, maxBytes: maxBytes, done)
        }
    }

    private static func contentLength(_ head: String) -> Int? {
        for line in head.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length", let value = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                return value
            }
        }
        return nil
    }

    private static func body(_ response: Data) throws -> Data {
        guard let headerEnd = response.range(of: Data("\r\n\r\n".utf8)) else { return response }
        let head = String(decoding: response[..<headerEnd.lowerBound], as: UTF8.self)
        let status = head.split(separator: "\r\n").first ?? ""
        let code = status.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
        guard (200..<300).contains(code) else { throw TVError.http(code) }
        return Data(response[headerEnd.upperBound...])
    }
}

/// The viewer's outbound proxies and the per-source routes. Requests bound to a source ask here
/// whether to go direct or through a proxy tunnel; a tunnel that cannot open falls back to direct.
public final class CustomProxyStore: @unchecked Sendable {
    public static let shared = CustomProxyStore()

    private static let endpointsKey = "proxyEndpoints.v1"
    private static let routesKey = "proxyRoutes.v1"

    private let lock = NSLock()
    private let defaults: UserDefaults
    private var _endpoints: [CustomProxyEndpoint] = []
    private var _routes: [String: CustomProxyRoute] = [:]

    /// `defaults` is kept, not just read once: writing through `.standard` while reading from the
    /// injected suite meant a store built for a test or a QA session read its own empty list back on
    /// the next launch, and a route the viewer set was silently written somewhere else.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.endpointsKey),
           let saved = try? JSONDecoder().decode([CustomProxyEndpoint].self, from: data) { _endpoints = saved }
        if let data = defaults.data(forKey: Self.routesKey),
           let saved = try? JSONDecoder().decode([String: CustomProxyRoute].self, from: data) { _routes = saved }
    }

    // MARK: Reads

    public var endpoints: [CustomProxyEndpoint] { lock.withLock { _endpoints } }
    public func proxy(for id: String) -> CustomProxyEndpoint? { lock.withLock { _endpoints.first { $0.id == id } } }
    public func route(origin: URL, sourceKey: String) -> CustomProxyRoute {
        lock.withLock { _routes[Self.key(origin: origin, sourceKey: sourceKey)] ?? .direct }
    }

    // MARK: Mutations

    public func upsert(_ endpoint: CustomProxyEndpoint) {
        lock.withLock {
            if let index = _endpoints.firstIndex(where: { $0.id == endpoint.id }) { _endpoints[index] = endpoint }
            else { _endpoints.append(endpoint) }
            persistLocked()
        }
    }

    public func removeEndpoint(id: String) {
        lock.withLock {
            _endpoints.removeAll { $0.id == id }
            for (key, route) in _routes where route.proxyID == id { _routes[key] = .direct }
            persistLocked()
        }
    }

    public func setRoute(_ route: CustomProxyRoute, origin: URL, sourceKey: String) {
        lock.withLock {
            let key = Self.key(origin: origin, sourceKey: sourceKey)
            switch route {
            case .direct: _routes.removeValue(forKey: key)
            case .proxy: _routes[key] = route
            }
            persistLocked()
        }
    }

    /// Opens a tunnel to `targetHost:targetPort` through the proxy this source is assigned, or
    /// nil when the source is direct or has no proxy. The caller uses it, or falls back to direct.
    public func tunnel(origin: URL, sourceKey: String, targetHost: String, targetPort: UInt16) throws -> CustomProxyTunnel? {
        guard let id = route(origin: origin, sourceKey: sourceKey).proxyID, let endpoint = proxy(for: id) else { return nil }
        return try CustomProxyTunnel(endpoint: endpoint, targetHost: targetHost, targetPort: targetPort)
    }

    nonisolated public static func key(origin: URL, sourceKey: String) -> String {
        origin.absoluteString + "|" + sourceKey
    }

    private func persistLocked() {
        if let data = try? JSONEncoder().encode(_endpoints) { defaults.set(data, forKey: Self.endpointsKey) }
        if let data = try? JSONEncoder().encode(_routes) { defaults.set(data, forKey: Self.routesKey) }
    }
}

extension NSLock {
    @inline(__always) func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}

/// Main-actor facade the settings UI observes. `revision` changes when endpoints or routes change.
@MainActor @Observable public final class CustomProxyRouter {
    public static let shared = CustomProxyRouter()
    public let store = CustomProxyStore.shared
    public private(set) var revision = 0
    public init() {}
    public func touch() { revision += 1 }
}

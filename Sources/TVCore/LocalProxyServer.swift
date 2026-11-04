import Foundation
import Network

/// A loopback TCP proxy. URLSession (and later AVPlayer) point at `http://127.0.0.1:<port>/…`,
/// this server reads the request, opens the target — direct, or through one of the viewer's
/// proxies — and relays bytes both ways without touching TLS. That is the only way to proxy
/// HTTPS and media streams on iOS, whose URLSession ignores the system proxy dictionary.
///
/// Request path encodes the route, in one of two forms:
///   - `/d/<scheme>/<host>/<port>/<path>` — direct
///   - `/p/<proxyID>/<scheme>/<host>/<port>/<path>` — through that proxy
/// The rewritten request keeps its Host and other headers; this server only replaces the
/// request-target with the origin-form for the upstream.
public final class LocalProxyServer: @unchecked Sendable {
    public static let shared = LocalProxyServer()

    private let queue = DispatchQueue(label: "tvbox.proxy.server")
    private var listener: NWListener?
    private var port: UInt16?
    private var starting: Task<UInt16, Error>?

    public func base() async throws -> URL {
        if let port { return URL(string: "http://127.0.0.1:\(port)/")! }
        if let starting { return URL(string: "http://127.0.0.1:\(try await starting.value)/")! }
        let task = Task { try await self.start() }
        starting = task
        defer { starting = nil }
        let p = try await task.value
        return URL(string: "http://127.0.0.1:\(p)/")!
    }

    /// The base address if the server is already running, else nil. Synchronous, for callers (the
    /// player) that can't await — they ask the server to start earlier and fall back to direct.
    public var baseSync: URL? {
        port.map { URL(string: "http://127.0.0.1:\($0)/")! }
    }

    /// The local address that relays `url` directly.
    public static func directURL(base: URL, url: URL) -> URL {
        let scheme = url.scheme ?? "http"
        let host = url.host ?? ""
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        let path = url.path.isEmpty ? "/" : url.path
        let query = url.query.map { "?\($0)" } ?? ""
        return URL(string: "\(base.absoluteString)d/\(scheme)/\(host)/\(port)\(path)\(query)") ?? url
    }

    /// The local address that relays `url` through `proxyID`.
    public static func proxyURL(base: URL, url: URL, proxyID: String) -> URL {
        let scheme = url.scheme ?? "http"
        let host = url.host ?? ""
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        let path = url.path.isEmpty ? "/" : url.path
        let query = url.query.map { "?\($0)" } ?? ""
        return URL(string: "\(base.absoluteString)p/\(proxyID)/\(scheme)/\(host)/\(port)\(path)\(query)") ?? url
    }

    private func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = try NWListener(using: parameters)
        listener = server
        let queue = self.queue
        server.newConnectionHandler = { connection in
            connection.start(queue: queue)
            Self.readRequest(connection, buffer: Data(), queue: queue)
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            server.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let p = server.port?.rawValue else { return }
                    self.port = p
                    continuation.resume(returning: p)
                case .failed(let error): continuation.resume(throwing: error)
                case .cancelled: continuation.resume(throwing: CancellationError())
                default: break
                }
            }
            server.start(queue: queue)
        }
    }

    private static func readRequest(_ connection: NWConnection, buffer: Data, queue: DispatchQueue) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            var bytes = buffer
            if let data { bytes.append(data) }
            if let headerEnd = bytes.range(of: Data("\r\n\r\n".utf8)) {
                Self.route(connection, head: String(decoding: bytes[..<headerEnd.lowerBound], as: UTF8.self),
                           leftover: Data(bytes[headerEnd.upperBound...]), queue: queue)
            } else if error != nil || complete || bytes.count > 1 << 20 {
                connection.cancel()
            } else {
                readRequest(connection, buffer: bytes, queue: queue)
            }
        }
    }

    private struct Target {
        let proxyID: String?
        let scheme: String
        let host: String
        let port: UInt16
        let path: String
    }

    private static func route(_ connection: NWConnection, head: String, leftover: Data, queue: DispatchQueue) {
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { connection.cancel(); return }
        let fields = requestLine.split(separator: " ")
        guard fields.count >= 2 else { connection.cancel(); return }
        let target = String(fields[1])
        guard let parsed = parse(target) else { connection.cancel(); return }

        // Rewrite the request line to origin-form for the upstream, keeping every other header.
        let originForm = parsed.path
        let rewritten = String(fields[0]) + " " + originForm + " " + String(fields.dropFirst(2).joined(separator: " "))
        let rewrittenHead = ([rewritten] + lines.dropFirst()).joined(separator: "\r\n")

        let upstream: NWConnection
        if let proxyID = parsed.proxyID, let endpoint = CustomProxyStore.shared.proxy(for: proxyID) {
            // Through the proxy: open a tunnel, which leaves a raw byte pipe to the target.
            guard let tunnel = try? CustomProxyTunnel(endpoint: endpoint, targetHost: parsed.host, targetPort: parsed.port) else {
                connection.cancel(); return
            }
            tunnel.open(queue: queue) { result in
                switch result {
                case .success:
                    Self.sendAndRelay(connection, upstream: tunnel.relayConnection, head: rewrittenHead, leftover: leftover, isTunnel: true)
                case .failure:
                    connection.cancel()
                }
            }
            return
        } else {
            upstream = NWConnection(host: NWEndpoint.Host(parsed.host), port: NWEndpoint.Port(rawValue: parsed.port)!, using: .tcp)
            upstream.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    Self.sendAndRelay(connection, upstream: upstream, head: rewrittenHead, leftover: leftover, isTunnel: false)
                case .failed: connection.cancel(); upstream.cancel()
                case .cancelled: connection.cancel()
                default: break
                }
            }
            upstream.start(queue: queue)
        }
    }

    private static func sendAndRelay(_ connection: NWConnection, upstream: NWConnection, head: String, leftover: Data, isTunnel: Bool) {
        // For a tunnel (CONNECT/SOCKS5) the upstream is already a raw pipe to the target: the
        // client's TLS bytes flow through untouched. For direct, we forward the HTTP request.
        let toUpstream = isTunnel ? leftover : (Data(head.utf8) + Data("\r\n\r\n".utf8) + leftover)
        upstream.send(content: toUpstream, completion: .contentProcessed { _ in
            Self.pump(from: connection, to: upstream)
            Self.pump(from: upstream, to: connection)
        })
    }

    private static func pump(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { _ in })
            }
            if error != nil || complete {
                destination.send(content: nil, completion: .contentProcessed { _ in destination.cancel() })
            } else {
                pump(from: source, to: destination)
            }
        }
    }

    /// Parses `/d/<scheme>/<host>/<port>/<path>` or `/p/<proxyID>/<scheme>/<host>/<port>/<path>`.
    private static func parse(_ target: String) -> Target? {
        let parts = target.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 4 else { return nil }
        var index = 0
        let proxyID: String?
        if parts[0] == "p" {
            guard parts.count >= 5 else { return nil }
            proxyID = String(parts[1]); index = 2
        } else if parts[0] == "d" {
            proxyID = nil; index = 1
        } else { return nil }
        let scheme = String(parts[index])
        let host = String(parts[index + 1])
        guard let port = UInt16(parts[index + 2]) else { return nil }
        let path = "/" + parts[(index + 3)...].joined(separator: "/")
        return Target(proxyID: proxyID, scheme: scheme, host: host, port: port, path: path)
    }
}

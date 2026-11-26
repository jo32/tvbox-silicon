import Foundation
import Network
import Testing
@testable import TVCore

@Test func mangaDeclaredAndStreamingBodiesStopAtTheirLimit() async throws {
    for declared in [Int?.none, 128] {
        let server = try await ImageBodyServer.start(declared: declared)
        defer { server.stop() }
        do {
            _ = try await MangaHTTP.data(MangaHTTP.Request(url: server.url), maximumBytes: 16)
            Issue.record("oversized image was accepted")
        } catch { #expect((error as? URLError)?.code == .dataLengthExceedsMaximum) }
        #expect(server.chunks <= 3)
    }
}
@Test func mangaExactLimitAndExistingUnboundedAPICallsStillWork() async throws {
    let exact = try await ImageBodyServer.start(count: 2)
    defer { exact.stop() }
    #expect(try await MangaHTTP.data(MangaHTTP.Request(url: exact.url), maximumBytes: 16).0.count == 16)
    let api = try await ImageBodyServer.start(count: 3)
    defer { api.stop() }
    #expect(try await MangaHTTP.data(MangaHTTP.Request(url: api.url)).0.count == 24)
}
@Test func mangaStalledNetworkStopsWhenCallerCancels() async throws {
    let server = try await ImageBodyServer.start(count: 0)
    defer { server.stop() }
    let task = Task { try await MangaHTTP.data(MangaHTTP.Request(url: server.url), maximumBytes: 16) }
    try await Task.sleep(for: .milliseconds(60))
    task.cancel()
    await #expect(throws: (any Error).self) { _ = try await task.value }
}

/// A real socket is necessary: URLProtocol buffers its artificial body before AsyncBytes delivers it.
final class ImageBodyServer: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var sent = 0
    private var connections: [NWConnection] = []
    var chunks: Int { lock.withLock { sent } }
    var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/")! }
    private init(_ listener: NWListener) { self.listener = listener }
    static func start(declared: Int? = nil, count: Int = 16, body: Data = Data(repeating: 1, count: 8), encoding: String? = nil, redirect: Bool = false) async throws -> ImageBodyServer {
        let listener = try NWListener(using: .tcp, on: .any)
        let server = ImageBodyServer(listener)
        let queue = DispatchQueue(label: "bounded.body.fixture")
        listener.newConnectionHandler = { connection in
            server.lock.withLock { server.connections.append(connection) }
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { request, _, _, _ in
                if redirect, String(decoding: request ?? Data(), as: UTF8.self).hasPrefix("GET / HTTP") {
                    connection.send(content: Data("HTTP/1.1 302 Found\r\nLocation: /final\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
                let length = declared.map { "Content-Length: \($0)\r\n" } ?? ""
                let compression = encoding.map { "Content-Encoding: \($0)\r\n" } ?? ""
                let header = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n\(length)\(compression)Connection: close\r\n\r\n"
                connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in
                    Task {
                        guard count > 0 else { return }
                        for _ in 0..<count {
                            try? await Task.sleep(for: .milliseconds(30))
                            let failed: Bool = await withCheckedContinuation { continuation in
                                connection.send(content: body, completion: .contentProcessed { error in
                                    continuation.resume(returning: error != nil)
                                })
                            }
                            if failed { return }
                            server.lock.withLock { server.sent += 1 }
                        }
                        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
                    }
                })
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            final class Flag: @unchecked Sendable { var done = false }
            let flag = Flag()
            listener.stateUpdateHandler = { state in
                guard !flag.done else { return }
                if case .ready = state { flag.done = true; continuation.resume() }
                if case .failed(let error) = state { flag.done = true; continuation.resume(throwing: error) }
            }
            listener.start(queue: queue)
        }
        return server
    }
    func stop() { listener.cancel(); lock.withLock { connections.forEach { $0.cancel() } } }
}

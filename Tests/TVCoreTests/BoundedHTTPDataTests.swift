import Foundation
import Network
import Testing
@testable import TVCore

@Test func rejectsDeclaredLengthBeforeReadingBody() async throws {
    let server = try await BoundedBodyServer.start(declared: 128)
    defer { server.stop() }
    await #expect(throws: (any Error).self) { try await boundedLoad(server.url) }
    #expect(server.chunks <= 1)
}
@Test func stopsUnknownLengthAtFirstOversizedChunk() async throws {
    let server = try await BoundedBodyServer.start()
    defer { server.stop() }
    await #expect(throws: (any Error).self) { try await boundedLoad(server.url) }
    #expect(server.chunks <= 3)
}
@Test func acceptsExactlyTheLimit() async throws {
    let server = try await BoundedBodyServer.start(count: 2)
    defer { server.stop() }
    #expect(try await boundedLoad(server.url).count == 16)
}
@Test func cancellationInterruptsAStalledBody() async throws {
    let server = try await BoundedBodyServer.start(count: 0)
    defer { server.stop() }
    let task = Task { try await boundedLoad(server.url) }
    try await Task.sleep(for: .milliseconds(60))
    task.cancel()
    do { _ = try await task.value; Issue.record("cancelled body completed") }
    catch { #expect(error is CancellationError || (error as? URLError)?.code == .cancelled) }
}
@Test func cancellationBeforeStartingDoesNotReceiveData() async throws {
    let server = try await BoundedBodyServer.start()
    defer { server.stop() }
    let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await boundedLoad(server.url) }
    await #expect(throws: (any Error).self) { try await task.value }
    #expect(server.chunks == 0)
}

private func boundedLoad(_ url: URL) async throws -> Data {
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    return try await BoundedHTTPData.load(URLRequest(url: url), session: session, maximumBytes: 16).0
}

/// A real socket is necessary: URLProtocol buffers its artificial body before AsyncBytes delivers it.
private final class BoundedBodyServer: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var sent = 0
    private var connections: [NWConnection] = []
    var chunks: Int { lock.withLock { sent } }
    var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/")! }
    private init(_ listener: NWListener) { self.listener = listener }
    static func start(declared: Int? = nil, count: Int = 16, body: Data = Data(repeating: 1, count: 8), encoding: String? = nil, redirect: Bool = false) async throws -> BoundedBodyServer {
        let listener = try NWListener(using: .tcp, on: .any)
        let server = BoundedBodyServer(listener)
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

@Test func compressedResponsesAreLimitedAfterDecompression() async throws {
    let body = Data([31, 139, 8, 0, 0, 0, 0, 0, 2, 255, 237, 193, 1, 9, 0, 0, 0, 195, 32, 214, 191, 244, 115, 28, 212, 2, 0, 0, 0, 0, 0, 0, 0, 222, 13, 254, 129, 177, 76, 0, 32, 0, 0])
    let server = try await BoundedBodyServer.start(declared: body.count, count: 1, body: body, encoding: "gzip")
    defer { server.stop() }
    do {
        _ = try await BoundedHTTPData.load(URLRequest(url: server.url), session: .shared, maximumBytes: 256)
        Issue.record("decoded body exceeded its budget")
    } catch { #expect((error as? URLError)?.code == .dataLengthExceedsMaximum) }
}

private final class RejectRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
@Test func preservesCallerRedirectDelegateAndFinalURL() async throws {
    let server = try await BoundedBodyServer.start(count: 2, redirect: true)
    defer { server.stop() }
    let custom = URLSession(configuration: .ephemeral, delegate: RejectRedirect(), delegateQueue: nil)
    defer { custom.invalidateAndCancel() }
    let rejected = try await BoundedHTTPData.load(URLRequest(url: server.url), session: custom, maximumBytes: 16)
    #expect((rejected.1 as? HTTPURLResponse)?.statusCode == 302)
    let followed = try await BoundedHTTPData.load(URLRequest(url: server.url), session: .shared, maximumBytes: 16)
    #expect(followed.1.url?.path == "/final")
    #expect(followed.0.count == 16)
}

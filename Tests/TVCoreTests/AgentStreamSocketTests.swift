import Foundation
import Network
import Testing
@testable import TVCore

/// A real HTTP server on loopback that streams one SSE body in chunks, with pauses, as a model server would.
private final class SSEServer: @unchecked Sendable {
    private let listener: NWListener
    private let chunks: [Data]
    private let pause: Duration
    let ready = AgentLocked<UInt16?>(nil)
    let requests = AgentLocked<[String]>([])

    init(chunks: [Data], pause: Duration = .milliseconds(40)) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.chunks = chunks; self.pause = pause
    }

    func start() async throws -> URL {
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: .global())
            read(connection, Data())
        }
        listener.start(queue: .global())
        for _ in 0..<200 {
            if let port = listener.port?.rawValue, listener.state == .ready { return URL(string: "http://127.0.0.1:\(port)/v1")! }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw URLError(.cannotConnectToHost)
    }

    func stop() { listener.cancel() }

    private func read(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, complete, _ in
            var bytes = buffer
            if let data { bytes.append(data) }
            let text = String(decoding: bytes, as: UTF8.self)
            if let end = text.range(of: "\r\n\r\n") {
                let length = text[..<end.lowerBound].components(separatedBy: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-length:") }.flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                if text.utf8.count - text[..<end.upperBound].utf8.count >= length {
                    requests.update { $0.append(text) }
                    Task { await self.answer(connection) }
                    return
                }
            }
            if !complete { read(connection, bytes) }
        }
    }

    private func answer(_ connection: NWConnection) async {
        connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nx-request-id: req_socket\r\n\r\n".utf8),
                        completion: .idempotent)
        for chunk in chunks {
            try? await Task.sleep(for: pause)
            var framed = Data((String(chunk.count, radix: 16) + "\r\n").utf8)
            framed.append(chunk); framed.append(Data("\r\n".utf8))
            connection.send(content: framed, completion: .idempotent)
        }
        connection.send(content: Data("0\r\n\r\n".utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}

@Suite struct AgentStreamSocketTests {
    @Test func streamsOverARealSocket() async throws {
        // "影片" splits inside its UTF-8 bytes, and an event splits across chunks.
        let first = #"data: {"choices":[{"delta":{"content":"影片 "}}]}"# + "\n\n"
        let bytes = Array(first.utf8)
        let cut = bytes.firstIndex(of: 0xE5)! + 1
        let chunks = [Data(bytes[..<cut]), Data(bytes[cut...]),
                      Data((#"data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}"# + "\r\n").utf8), Data("\r\n".utf8),
                      Data((#"data: {"choices":[],"usage":{"prompt_tokens":7,"completion_tokens":2}}"# + "\n\ndata: [DONE]\n\n").utf8)]
        let server = try SSEServer(chunks: chunks)
        defer { server.stop() }
        let base = try await server.start()
        let client = ChatCompletionsClient(baseURL: base) { "local-key" }
        var events: [AgentEvent] = []
        var firstAt: Date?
        let started = Date()
        for try await event in client.stream(model: "local", instructions: "", messages: [AgentMessage(role: .user, text: "Hi")], tools: []) {
            if firstAt == nil { firstAt = Date() }
            events.append(event)
        }
        #expect(events == [.text("影片 "), .text("ok"), .finished(inputTokens: 7, outputTokens: 2)])
        // The first words arrive before the body ends (5 chunks, 40 ms apart).
        #expect(firstAt!.timeIntervalSince(started) < Date().timeIntervalSince(started) - 0.05)
        let request = try #require(server.requests.get().first)
        #expect(request.hasPrefix("POST /v1/chat/completions "))
        #expect(request.contains("Authorization: Bearer local-key"))
    }

    @Test func stoppingCancelsTheRequest() async throws {
        let chunks = (0..<50).map { _ in Data((#"data: {"type":"response.output_text.delta","delta":"x"}"# + "\n\n").utf8) }
        let server = try SSEServer(chunks: chunks, pause: .milliseconds(50))
        defer { server.stop() }
        let base = try await server.start()
        let client = ResponsesClient(baseURL: base) { nil }
        let task = Task {
            var count = 0
            for try await _ in client.stream(model: "m", instructions: "", messages: [AgentMessage(role: .user, text: "Hi")], tools: []) { count += 1 }
            return count
        }
        try await Task.sleep(for: .milliseconds(300))
        let started = Date()
        task.cancel()
        let count = (try? await task.value) ?? 0
        #expect(count < 50)
        #expect(Date().timeIntervalSince(started) < 1)
    }
}

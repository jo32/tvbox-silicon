import Foundation
import Network
import Testing
@testable import TVCore

#if canImport(WebKit) && os(macOS)
/// A `webView: true` search whose site answers with an error page finds no books. The web view used to report every
/// page as 200, so a Cloudflare "502: Bad gateway" page was read as a book's own page and listed as a result (#2126).
@Test func legadoWebViewErrorPageIsNoBook() async throws {
    if NovelRuntime.profilesRoot == nil {
        NovelRuntime.profilesRoot = FileManager.default.temporaryDirectory.appendingPathComponent("novel-webview-tests-\(UUID().uuidString)")
    }
    let page = """
        <html><head><title>example.com | 502: Bad gateway</title></head>
        <body><h1><span>Bad gateway</span> <span>Error code 502</span></h1><p>The web server reported a bad gateway error.</p></body></html>
        """
    let server = try await StatusServer.start(status: 502, body: page)
    defer { server.stop() }
    let site = "http://127.0.0.1:\(server.port)"
    let source = try #require(NovelSource(object: [
        "bookSourceUrl": site + "/#\(UUID().uuidString.prefix(8))", "bookSourceName": "Gateway",
        "searchUrl": site + "/search?q={{key}},{\"webView\": true}",
        "ruleSearch": ["bookList": ".content@dl", "name": "a@title", "bookUrl": "a@href"],
        "ruleBookInfo": ["name": "h1@text"],
    ]))
    let books = try await NovelRuntime.shared.search(source, keyword: "斗破", page: 1)
    #expect(books.isEmpty, "found \(books.map(\.name))")
}

/// Answers every request with one status and page.
private final class StatusServer: @unchecked Sendable {
    let port: UInt16
    private let listener: NWListener
    private init(listener: NWListener, port: UInt16) { self.listener = listener; self.port = port }

    static func start(status: Int, body: String) async throws -> StatusServer {
        let listener = try NWListener(using: .tcp)
        let queue = DispatchQueue(label: "status.server")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                let data = Data(body.utf8)
                let head = "HTTP/1.1 \(status) Error\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(head.utf8) + data, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            final class Flag: @unchecked Sendable { var done = false }
            let resumed = Flag()
            listener.stateUpdateHandler = { state in
                guard !resumed.done else { return }
                if case .ready = state, let port = listener.port?.rawValue { resumed.done = true; continuation.resume(returning: port) }
                if case .failed(let error) = state { resumed.done = true; continuation.resume(throwing: error) }
            }
            listener.start(queue: queue)
        }
        return StatusServer(listener: listener, port: port)
    }

    func stop() { listener.cancel() }
}
#endif

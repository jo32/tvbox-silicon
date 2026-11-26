import Foundation
import Network

// Protocol-only dependencies; the real network code below is compiled unchanged.
enum L10n { static func text(_ value: String, _ arguments: CVarArg...) -> String { String(format: value, arguments: arguments) } }
final class Diagnostics: Sendable {
    static let shared = Diagnostics()
    enum Level { case info, warning }
    func record(_ level: Level, _ category: String, _ message: String) {}
}

func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw NSError(domain: "DLNACheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

final class Fixture: Sendable {
    let listener: NWListener
    let port: UInt16
    let actions: Actions
    init(listener: NWListener, port: UInt16, actions: Actions) { self.listener = listener; self.port = port; self.actions = actions }
    static func start() async throws -> Fixture {
        let listener = try NWListener(using: .tcp)
        let queue = DispatchQueue(label: "dlna.fixture")
        let actions = Actions()
        listener.newConnectionHandler = { connection in
            actions.keep(connection)
            connection.start(queue: queue)
            Self.read(connection, buffer: Data()) { text in
                let path = text.components(separatedBy: " ").dropFirst().first ?? ""
                var status = "200 OK", body = Data(), type = "video/mp4", extra = ""
                if path == "/slow.mp4" || path == "/huge.m3u8" {
                    let head = "HTTP/1.1 200 OK\r\nContent-Type: \(path.hasSuffix("m3u8") ? "application/vnd.apple.mpegurl" : "video/mp4")\r\nContent-Length: 99999999\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
                    return
                }
                if path == "/soap" {
                    let action = text.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("soapaction:") }?.components(separatedBy: "#").last?.replacingOccurrences(of: "\"", with: "") ?? ""
                    actions.append(action, text)
                    type = "text/xml"
                    body = Data("<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><u:\(action)Response xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\"><RelTime>0:02:05</RelTime><TrackDuration>0:10:00</TrackDuration><CurrentTransportState>PLAYING</CurrentTransportState></u:\(action)Response></s:Body></s:Envelope>".utf8)
                }
                else if !text.lowercased().contains("referer: https://site.example/") { status = "403 Forbidden" }
                else if path == "/movie.mp4" {
                    if text.contains("bytes=4-7") { status = "206 Partial Content"; body = Data("4567".utf8); extra = "Content-Range: bytes 4-7/16\r\n" }
                    else { body = Data("0123456789abcdef".utf8) }
                } else if path == "/index.m3u8" || path == "/dispatch" { type = path == "/dispatch" ? "application/octet-stream" : "application/vnd.apple.mpegurl"; body = Data("#EXTM3U\n#EXTINF:1,\nsegment.ts\n#EXT-X-ENDLIST\n".utf8) }
                else if path == "/segment.ts" || path.hasPrefix("/s/") { body = Data("TS".utf8) }
                else { status = "404 Not Found" }
                let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n\(extra)Connection: close\r\n\r\n"
                if path == "/soap", actions.holdResponse(connection, response: Data(head.utf8) + body) { return }
                connection.send(content: Data(head.utf8) + body, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = FixtureOnce()
            listener.stateUpdateHandler = { state in
                if case .ready = state, let port = listener.port?.rawValue { once.run { continuation.resume(returning: port) } }
                if case .failed(let error) = state { once.run { continuation.resume(throwing: error) } }
            }
            listener.start(queue: queue)
        }
        return Fixture(listener: listener, port: port, actions: actions)
    }
    static func read(_ connection: NWConnection, buffer: Data, completion: @escaping @Sendable (String) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                let count = header.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces)) } ?? 0
                if buffer.distance(from: end.upperBound, to: buffer.endIndex) >= count { completion(String(decoding: buffer, as: UTF8.self)); return }
            }
            guard !complete, error == nil, buffer.count < 65536 else { return connection.cancel() }
            read(connection, buffer: buffer, completion: completion)
        }
    }
}
final class Actions: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(String, String)] = []
    private var connections: [NWConnection] = []
    private var holdPlay = false, holdCleanupStop = false
    private var cleanupStopAfter = 2
    private var held: [(NWConnection, Data)] = []
    var values: [(String, String)] { lock.withLock { entries } }
    func append(_ action: String, _ body: String) { lock.withLock { entries.append((action, body)) } }
    func keep(_ connection: NWConnection) { lock.withLock { connections.append(connection) } }
    func prepareCancellation() { lock.withLock { holdPlay = true; holdCleanupStop = true; cleanupStopAfter = entries.filter { $0.0 == "Stop" }.count + 2 } }
    func holdResponse(_ connection: NWConnection, response: Data) -> Bool {
        lock.withLock {
            let action = entries.last?.0
            if action == "Play", holdPlay { holdPlay = false; held.append((connection, response)); return true }
            if action == "Stop", holdCleanupStop, entries.filter({ $0.0 == "Stop" }).count >= cleanupStopAfter { holdCleanupStop = false; held.append((connection, response)); return true }
            return false
        }
    }
    func releaseHeld() {
        let responses = lock.withLock { defer { held = [] }; return held }
        for (connection, response) in responses {
            connection.send(content: response, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
final class Completed: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    var value: Bool { lock.withLock { done } }
    func finish() { lock.withLock { done = true } }
}
final class FixtureOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ action: () -> Void) { lock.lock(); let first = !done; done = true; lock.unlock(); if first { action() } }
}

import Foundation

// Only UIKit's idle-timer and the already-resolved source are replaced. The
// controller's real load/catch/stop code is extracted without its UI macros.
@MainActor final class UIApplication { static let shared = UIApplication(); var isIdleTimerDisabled = false }
struct Channel: Sendable { var url: URL }
enum CastStream {
    struct Resolved: Sendable { var url: URL; var headers: [String: String]; var playlist: Bool; var direct: Bool }
    static func resolve(_ channel: Channel) async throws -> Resolved { Resolved(url: channel.url, headers: ["Referer": "https://site.example/"], playlist: false, direct: channel.url.host != "127.0.0.1") }
}

@main struct CancellationChecks {
    @MainActor static func main() async throws {
        let fixture = try await Fixture.start()
        defer { fixture.listener.cancel() }
        fixture.actions.prepareCancellation()
        let control = URL(string: "http://127.0.0.1:\(fixture.port)/soap")!
        let device = DLNADevice(id: "fixture", name: "fixture", model: "fixture", location: control, avTransport: control, renderingControl: nil)
        let cast = CastController()
        let first = Task { try await cast.cast(Channel(url: URL(string: "https://cdn.example/first.mp4")!), title: "first", from: nil, to: device) }
        try await waitFor(fixture.actions, action: "Play", count: 1)
        first.cancel()
        // The receiver accepted Play but deliberately withholds its HTTP reply.
        // Closing the panel must still send a real SOAP Stop, despite cancellation.
        try await waitFor(fixture.actions, action: "Stop", count: 2)
        let second = Task { try await cast.cast(Channel(url: URL(string: "https://cdn.example/second.mp4")!), title: "second", from: nil, to: device) }
        try await Task.sleep(for: .milliseconds(100))
        try check(fixture.actions.values.filter { $0.0 == "SetAVTransportURI" }.count == 1, "new cast must wait for old cleanup Stop")
        fixture.actions.releaseHeld()
        do { try await first.value; throw NSError(domain: "DLNACheck", code: 3, userInfo: [NSLocalizedDescriptionKey: "cancelled cast must fail"]) } catch is CancellationError {} catch let error as DLNA.Failure { _ = error } catch let error as URLError where error.code == .cancelled {}
        try await second.value
        let actions = fixture.actions.values
        let newLoad = actions.lastIndex { $0.0 == "SetAVTransportURI" }!
        try check(actions[newLoad].1.contains("second.mp4") && !actions[(newLoad + 1)...].contains { $0.0 == "Stop" }, "late old cleanup must not stop the new video on the same TV")
        _ = await cast.stop()
        // Starting a new cast also cancels an old in-flight load whose caller has not canceled its Task.
        let oldPlays = fixture.actions.values.filter { $0.0 == "Play" }.count
        let oldStops = fixture.actions.values.filter { $0.0 == "Stop" }.count
        fixture.actions.prepareCancellation()
        let third = Task { try await cast.cast(Channel(url: URL(string: "https://cdn.example/third.mp4")!), title: "third", from: nil, to: device) }
        try await waitFor(fixture.actions, action: "Play", count: oldPlays + 1)
        let fourth = Task { try await cast.cast(Channel(url: URL(string: "https://cdn.example/fourth.mp4")!), title: "fourth", from: nil, to: device) }
        try await waitFor(fixture.actions, action: "Stop", count: oldStops + 2)
        try check(!fixture.actions.values.contains { $0.0 == "SetAVTransportURI" && $0.1.contains("fourth.mp4") }, "replacement waits for uncanceled old caller cleanup")
        fixture.actions.releaseHeld()
        do { try await third.value; throw NSError(domain: "DLNACheck", code: 3) } catch is CancellationError {}
        try await fourth.value
        let detachStops = fixture.actions.values.filter { $0.0 == "Stop" }.count
        cast.detach()
        try await Task.sleep(for: .milliseconds(50))
        try check(cast.device == nil && fixture.actions.values.filter { $0.0 == "Stop" }.count == detachStops, "direct stream keeps playing after detach")

        let relayedChannel = Channel(url: URL(string: "http://127.0.0.1:\(fixture.port)/movie.mp4")!)
        try await cast.cast(relayedChannel, title: "relay", from: nil, to: device)
        let beforeDetach = fixture.actions.values.filter { $0.0 == "Stop" }.count
        cast.detach()
        try await waitFor(fixture.actions, action: "Stop", count: beforeDetach + 1)
        try check(cast.device == nil, "relayed detach releases playback owner")

        let relay = CastRelay()
        let slow = try await relay.address(for: URL(string: "http://127.0.0.1:\(fixture.port)/slow.mp4")!, headers: [:], playlist: false, towards: nil)
        let complete = Completed()
        let download = Task { defer { complete.finish() }; return try await URLSession.shared.data(from: slow) }
        try await Task.sleep(for: .milliseconds(100))
        try check(!complete.value, "relay fixture must still be downloading")
        await relay.stop()
        do { _ = try await download.value; throw NSError(domain: "DLNACheck", code: 4) } catch is URLError {}
        print("PASS: canceled and superseded loads serialize Stop; direct detach continues; relayed detach stops; pending relay transfer closes")

    }
    static func waitFor(_ actions: Actions, action: String, count: Int) async throws {
        for _ in 0..<200 {
            if actions.values.filter({ $0.0 == action }).count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try check(false, "missing SOAP \(action) #\(count) after canceled load")
    }
}

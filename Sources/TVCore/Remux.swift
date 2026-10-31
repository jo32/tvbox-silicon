import Foundation
import Network

/// Plays files AVPlayer can't open: MKV and WebM, AVI, FLV, WMV/ASF, RMVB, MPEG program streams. They are
/// repackaged as HLS that AVPlayer plays like any other stream, so the picture keeps hardware decoding,
/// AirPlay audio, picture in picture and the player's own controls. See `RemuxSession`.
public enum Remux {
    /// Whether a file starting with these bytes is one the repackager opens and AVPlayer doesn't.
    public static func handles(_ head: Data) -> Bool {
        let bytes = [UInt8](head.prefix(16))
        guard bytes.count >= 4 else { return false }
        func text(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }
        if bytes[0..<4].elementsEqual([0x1A, 0x45, 0xDF, 0xA3]) { return true }                       // Matroska, WebM
        if bytes.count >= 12, text(0..<4) == "RIFF", text(8..<12) == "AVI " { return true }
        if text(0..<3) == "FLV" { return true }
        if bytes[0..<4].elementsEqual([0x30, 0x26, 0xB2, 0x75]) { return true }                       // ASF (WMV)
        if text(0..<4) == ".RMF" { return true }                                                      // RealMedia
        if bytes[0..<4].elementsEqual([0x00, 0x00, 0x01, 0xBA]) { return true }                       // MPEG program stream
        return false
    }

    /// Whether a link names such a file, for addresses whose bytes aren't read before playing.
    public static func handles(name: String) -> Bool {
        ["mkv", "webm", "avi", "flv", "f4v", "wmv", "asf", "rm", "rmvb", "mpg", "mpeg", "vob", "divx", "xvid"]
            .contains((name as NSString).pathExtension.lowercased())
    }

    /// Whether repackaging shows a picture AVPlayer can't decode in the file itself, from its sample entries:
    /// HEVC that an MP4 tags `hev1` (`dvhe`) plays inside HLS as it is, and VP9 is converted. AV1 isn't, as
    /// FFmpeg here has no decoder for it.
    public static func showsPicture(_ codecs: [String]) -> Bool {
        !codecs.isEmpty && codecs.allSatisfy { ["hev1", "dvhe", "vp09"].contains($0) }
    }

    /// Opens the file and returns the address of its HLS master playlist on a loopback server. `subtitles`, the
    /// files beside it, are fetched (with `headers`) while the file opens and join its own subtitles.
    public static func open(_ source: RemuxSource, subtitles: [ExternalSubtitle] = [], headers: [String: String] = [:]) async throws -> URL {
        try await open(source, subtitles: subtitles, headers: headers, session: .shared)
    }

    static func open(_ source: RemuxSource, subtitles: [ExternalSubtitle], headers: [String: String], session subtitleSession: URLSession) async throws -> URL {
        async let files = SubtitleFile.load(subtitles, headers: headers, session: subtitleSession)
        let session = RemuxSession(source: source)
        try await session.open()
        session.add(await files)
        RemuxStore.shared.add(session)
        do {
            let base = try await RemuxServer.shared.base()
            return base.appending(path: "\(session.id)/master.m3u8")
        } catch {
            RemuxStore.shared.remove(session.id)?.close()
            throw error
        }
    }

    public static func isRemuxed(_ url: URL) -> Bool { session(url) != nil }

    /// Whether the picture behind `url` is served as HDR (PQ or HLG), not converted to SDR.
    public static func isHDR(_ url: URL) -> Bool {
        guard let plan = session(url)?.plan, plan.tracks.first?.kind == .video else { return false }
        return plan.videoRange != "SDR"
    }

    /// Whether the picture behind `url` is Dolby Vision profile 5, served as it is: it has no HDR10 picture to
    /// convert to SDR, so a device that refuses it refuses it again.
    public static func isDolbyVision(_ url: URL) -> Bool { session(url)?.plan.isDolbyVision ?? false }

    /// Set once AVPlayer refused an HDR stream although the device reported HDR playback (an Apple TV can):
    /// files opened after that convert HDR pictures to SDR, as for a display that shows no HDR.
    public static var refusesHDR: Bool {
        get { hdrLock.withLock { hdrRefused } }
        set { hdrLock.withLock { hdrRefused = newValue } }
    }

    /// Whether the screen is mirrored or recorded (AirPlay mirroring, a screen recording, a Mac showing the
    /// iPhone). iOS then refuses every HDR variant of an HLS stream (-17223), though it plays them again once
    /// that stops, so files opened meanwhile convert HDR pictures to SDR. The app sets it before each file opens.
    public static var screenCaptured: Bool {
        get { hdrLock.withLock { captured } }
        set { hdrLock.withLock { captured = newValue } }
    }
    private static let hdrLock = NSLock()
    nonisolated(unsafe) private static var hdrRefused = false
    nonisolated(unsafe) private static var captured = false

    /// The address of the file behind `url` once the loopback server listens again, on a new port: iOS and tvOS
    /// take back a suspended app's listening sockets, and AVPlayer then finds `url` refusing (-1004). Nil when
    /// the file was closed meanwhile.
    public static func relisten(_ url: URL) async throws -> URL? {
        guard let id = identifier(url), RemuxStore.shared.session(id) != nil else { return nil }
        return try await RemuxServer.shared.base(replacing: url).appending(path: "\(id)/master.m3u8")
    }

    /// Stops reading and writing the file behind `url`.
    public static func stop(_ url: URL) {
        guard let id = identifier(url) else { return }
        RemuxStore.shared.remove(id)?.close()
    }

    public static func transfer(for url: URL) -> (received: Int64, host: String?)? { session(url)?.source.transfer }

    /// A file behind an HTTP(S) link that answers byte ranges. One that sends the bytes asked for is read
    /// like a cloud drive's file, in parallel chunks. One that answers every range with the rest of the file
    /// (a plugin's drive proxy, which downloads it with its own threads) is read through one connection.
    public static func httpSource(_ url: URL, headers: [String: String]) async throws -> RemuxSource {
        try await httpSource(url, headers: headers, chunks: CloudByteStream.session, configuration: RangeConnection.configuration)
    }

    static func httpSource(_ url: URL, headers: [String: String], chunks: URLSession, configuration: URLSessionConfiguration) async throws -> RemuxSource {
        let counter = CloudCounter()
        let probe = try await RangeConnection.open(url, headers: headers, from: 0, through: 1, configuration: configuration, counter: counter)
        if probe.last > 1 {
            Diagnostics.shared.record(.info, "remux", "link sends the rest of the file host=\(url.host() ?? "-") length=\(probe.length)")
            return StreamingRemuxSource(url: url, headers: headers, configuration: configuration, counter: counter, first: probe)
        }
        probe.close()
        let source = CloudStreams.Source(url: url, headers: headers, length: Int(probe.length), name: url.lastPathComponent)
        return CloudRemuxSource(stream: CloudByteStream(source: source, session: chunks, rewritesSampleEntries: false, refresh: { nil }))
    }

    /// A file on this device.
    public static func fileSource(_ url: URL) throws -> RemuxSource { try FileRemuxSource(url) }

    private static func identifier(_ url: URL) -> String? {
        guard ["127.0.0.1", "localhost"].contains(url.host() ?? "") else { return nil }
        let parts = url.path().split(separator: "/")
        return parts.count == 3 ? String(parts[1]) : nil
    }
    private static func session(_ url: URL) -> RemuxSession? { identifier(url).flatMap(RemuxStore.shared.session) }
}

struct CloudRemuxSource: RemuxSource {
    let stream: CloudByteStream
    let length: Int64
    init(stream: CloudByteStream) {
        self.stream = stream
        length = Int64(stream.sourceLength)
    }
    func read(at offset: Int64, count: Int) async throws -> Data { try await stream.read(at: Int(offset), count: count) }
    var transfer: (received: Int64, host: String?)? { (stream.counter.value, stream.host) }
    func close() async { await stream.clear() }
}

/// A link that answers every range with the rest of the file, as a plugin's drive proxy does: it downloads
/// the file with its own threads, so parallel chunk requests would each start that download again. A response
/// is read through, and another opens only when FFmpeg jumps. Each costs the plugin another drive request
/// (seconds), so a short jump forward reads through instead, and the previous response stays open, paused:
/// FFmpeg reads an MKV's index at the end of the file and then comes back to where it was.
final class StreamingRemuxSource: RemuxSource, @unchecked Sendable {
    static let readThrough: Int64 = 8 << 20
    static let kept = 2
    let length: Int64
    private let url: URL
    private let headers: [String: String]
    private let configuration: URLSessionConfiguration
    private let counter: CloudCounter
    private let lock = NSLock()
    /// The open responses, the one read last at the end.
    private var connections: [RangeConnection]
    private var closed = false

    init(url: URL, headers: [String: String], configuration: URLSessionConfiguration, counter: CloudCounter, first: RangeConnection) {
        self.url = url; self.headers = headers; self.configuration = configuration; self.counter = counter
        length = first.length; connections = [first]
    }

    func read(at offset: Int64, count: Int) async throws -> Data {
        guard offset < length else { return Data() }
        var opened = 0
        while true {
            for connection in lock.withLock({ connections.reversed() }) {
                guard let data = try await connection.read(at: offset, count: count, readThrough: Self.readThrough) else { continue }
                lock.withLock {
                    if let index = connections.firstIndex(where: { $0 === connection }), index != connections.count - 1 {
                        connections.append(connections.remove(at: index))
                    }
                }
                return data
            }
            // A response that ends, or answers nothing, twice in a row at the same place won't do better a third time.
            guard opened < 2 else { throw TVError.unsupported("The link stopped sending the file.") }
            opened += 1
            try Task.checkCancellation()
            lock.withLock { connections.count >= Self.kept ? connections.removeFirst() : nil }?.close()
            Diagnostics.shared.record(.debug, "remux", "link reopened at=\(offset)")
            let next = try await RangeConnection.open(url, headers: headers, from: offset, configuration: configuration, counter: counter)
            let stale: Bool = lock.withLock {
                if closed { return true }
                connections.append(next)
                return false
            }
            if stale { next.close(); throw CancellationError() }
        }
    }

    var transfer: (received: Int64, host: String?)? { (counter.value, url.host()) }

    func close() async {
        lock.withLock {
            closed = true
            defer { connections = [] }
            return connections
        }.forEach { $0.close() }
    }
}

/// One HTTP response read as it arrives, for `StreamingRemuxSource`. It pauses while far ahead of its reader,
/// so a paused player doesn't pull the rest of a large file into memory, and keeps a little behind it for
/// FFmpeg's short jumps back.
final class RangeConnection: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let configuration: URLSessionConfiguration = {
        let configuration = URLSessionConfiguration.ephemeral
        // A plugin's proxy first asks its drive for a download address: seconds before the first byte.
        configuration.timeoutIntervalForRequest = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return configuration
    }()
    /// About two seconds of a drive's speed ahead, and what FFmpeg may jump back over: at most 16 MB each.
    static let ahead = 8 << 20
    static let behind: Int64 = 4 << 20

    let first: Int64
    /// The response's last byte and the file's length, from its Content-Range.
    private(set) var last: Int64 = 0
    private(set) var length: Int64 = 0
    private let counter: CloudCounter
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var opening: CheckedContinuation<Void, Error>?
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// The file offset of `buffer`'s first byte, and the furthest offset handed out.
    private var base: Int64
    private var position: Int64
    private var buffer = Data()
    private var finished = false
    private var paused = false

    private init(first: Int64, counter: CloudCounter) {
        self.first = first; self.counter = counter
        base = first; position = first
    }

    /// The response to `Range: bytes=<from>-<through>`, once its headers say which bytes follow.
    static func open(_ url: URL, headers: [String: String], from first: Int64, through last: Int64? = nil,
                     configuration: URLSessionConfiguration, counter: CloudCounter) async throws -> RangeConnection {
        let connection = RangeConnection(first: first, counter: counter)
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.setValue("bytes=\(first)-\(last.map(String.init) ?? "")", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let session = URLSession(configuration: configuration, delegate: connection, delegateQueue: nil)
                let task = session.dataTask(with: request)
                let cancelled = connection.lock.withLock {
                    if connection.finished { return true }
                    connection.opening = continuation; connection.session = session; connection.task = task
                    return false
                }
                if cancelled { session.invalidateAndCancel(); continuation.resume(throwing: CancellationError()) }
                else { task.resume() }
            }
        } onCancel: { connection.close() }
        return connection
    }

    /// Up to `count` bytes at `offset`, waiting for them while they are on their way (within `readThrough`
    /// of what arrived). Nil when this response can't supply them: the caller opens another.
    func read(at offset: Int64, count: Int, readThrough: Int64) async throws -> Data? {
        enum Step { case data(Data), elsewhere, wait }
        while true {
            try Task.checkCancellation()
            var resume: URLSessionDataTask?
            let step: Step = lock.withLock {
                let end = base + Int64(buffer.count)
                guard offset >= base, offset <= last, offset <= max(end, position) + readThrough else { return .elsewhere }
                if offset < end {
                    let start = buffer.startIndex + Int(offset - base)
                    let data = Data(buffer[start..<min(buffer.endIndex, start + count)])
                    position = max(position, offset + Int64(data.count))
                    // Drop what lies well behind the reader, keeping `behind` for jumps back.
                    let keep = position - Self.behind
                    if keep - base > Self.behind {
                        buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + Int(keep - base))
                        base = keep
                    }
                    if paused, base + Int64(buffer.count) - position < Int64(Self.ahead / 2) { paused = false; resume = task }
                    return .data(data)
                }
                if finished { return .elsewhere }
                // The reader skips ahead to `offset`: what arrives before it no longer counts as read-ahead.
                position = max(position, offset)
                if paused { paused = false; resume = task }
                return .wait
            }
            resume?.resume()
            switch step {
            case .data(let data): return data
            case .elsewhere: return nil
            case .wait: await arrival(beyond: offset)
            }
        }
    }

    /// Returns once bytes past `offset` arrived, the response ended, or the read was cancelled.
    private func arrival(beyond offset: Int64) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let ready = lock.withLock {
                    if finished || base + Int64(buffer.count) > offset || Task.isCancelled { return true }
                    waiters[id] = continuation
                    return false
                }
                if ready { continuation.resume() }
            }
        } onCancel: {
            lock.withLock { waiters.removeValue(forKey: id) }?.resume()
        }
    }

    func close() {
        let session = lock.withLock {
            finished = true
            return self.session
        }
        session?.invalidateAndCancel()
        end(CancellationError())
    }

    private func end(_ error: Error?) {
        let (opening, waiters): (CheckedContinuation<Void, Error>?, [CheckedContinuation<Void, Never>]) = lock.withLock {
            finished = true
            defer { self.opening = nil; self.waiters = [:] }
            return (self.opening, Array(self.waiters.values))
        }
        opening?.resume(throwing: error ?? TVError.unsupported("no response"))
        waiters.forEach { $0.resume() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let range = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range")
        guard status == 206, let match = range?.firstMatch(of: /^bytes (\d+)-(\d+)\/(\d+)$/), Int64(match.1) == first,
              let end = Int64(match.2), let total = Int64(match.3), end < total else {
            completionHandler(.cancel)
            self.end(status >= 400 ? TVError.http(status) : TVError.unsupported("no byte ranges"))
            return
        }
        let opening = lock.withLock {
            last = end; length = total
            defer { self.opening = nil }
            return self.opening
        }
        completionHandler(.allow)
        opening?.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        counter.add(data.count)
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            buffer.append(data)
            if !paused, base + Int64(buffer.count) - position > Int64(Self.ahead) { paused = true; dataTask.suspend() }
            defer { self.waiters = [:] }
            return Array(self.waiters.values)
        }
        waiters.forEach { $0.resume() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        end(error)
        session.finishTasksAndInvalidate()
    }
}

final class FileRemuxSource: RemuxSource, @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    let length: Int64
    init(_ url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        length = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }
    func read(at offset: Int64, count: Int) async throws -> Data {
        try lock.withLock {
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: count) ?? Data()
        }
    }
    var transfer: (received: Int64, host: String?)? { nil }
    func close() async { lock.withLock { try? handle.close() } }
}

/// The open files; the oldest is closed when a fourth opens (an episode queued behind another holds two).
final class RemuxStore: @unchecked Sendable {
    static let shared = RemuxStore()
    private let lock = NSLock()
    private var sessions: [String: RemuxSession] = [:]
    private var order: [String] = []

    func add(_ session: RemuxSession) {
        let retired: [RemuxSession] = lock.withLock {
            sessions[session.id] = session; order.append(session.id)
            var old: [RemuxSession] = []
            while order.count > 3 { if let value = sessions.removeValue(forKey: order.removeFirst()) { old.append(value) } }
            return old
        }
        retired.forEach { $0.close() }
    }
    func session(_ id: String) -> RemuxSession? { lock.withLock { sessions[id] } }
    func remove(_ id: String) -> RemuxSession? {
        lock.withLock {
            order.removeAll { $0 == id }
            return sessions.removeValue(forKey: id)
        }
    }
}

/// Serves the repackaged files to AVPlayer over loopback, behind a per-launch token. A segment is sent while
/// it is being written (chunked), so playback starts once its first second is ready.
actor RemuxServer {
    static let shared = RemuxServer()
    private let token = UUID().uuidString.lowercased()
    private let queue = DispatchQueue(label: "tvbox.remux.server")
    private var listener: NWListener?
    private var address: URL?
    private var starting: Task<URL, Error>?

    func base() async throws -> URL {
        // A suspended iOS app loses its sockets; a listener that is no longer ready is replaced.
        if let address, listener?.state == .ready { return address }
        if let starting { return try await starting.value }
        listener?.cancel(); listener = nil; address = nil
        let task = Task { try await self.listen() }
        starting = task
        defer { starting = nil }
        let value = try await task.value
        address = value
        return value
    }

    /// A new listener in place of the one `stale` was served on, which refused AVPlayer though it may still say
    /// it is ready; addresses that fail together share one new listener.
    func base(replacing stale: URL) async throws -> URL {
        if starting == nil, address == nil || address?.port == stale.port {
            listener?.cancel(); listener = nil; address = nil
        }
        return try await base()
    }

    private func listen() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = try NWListener(using: parameters)
        listener = server
        let token = token
        server.newConnectionHandler = { connection in
            connection.start(queue: .global(qos: .userInitiated))
            Self.receive(connection, buffer: Data(), token: token)
        }
        let ready = OneShot<URL>()
        return try await withCheckedThrowingContinuation { continuation in
            ready.set(continuation)
            server.stateUpdateHandler = { [token] state in
                switch state {
                case .ready:
                    guard let port = server.port else { return }
                    ready.resume(.success(URL(string: "http://127.0.0.1:\(port.rawValue)/\(token)/")!))
                case .failed(let error): ready.resume(.failure(error))
                case .cancelled: ready.resume(.failure(CancellationError()))
                default: break
                }
            }
            server.start(queue: queue)
        }
    }

    private nonisolated static func receive(_ connection: NWConnection, buffer: Data, token: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, complete, error in
            var bytes = buffer
            if let data { bytes.append(data) }
            if bytes.range(of: Data("\r\n\r\n".utf8)) != nil { serve(connection, request: bytes, token: token) }
            else if error != nil || complete || bytes.count > 16384 { connection.cancel() }
            else { receive(connection, buffer: bytes, token: token) }
        }
    }

    private nonisolated static func serve(_ connection: NWConnection, request: Data, token: String) {
        let lines = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n")
        let fields = (lines.first ?? "").split(separator: " ")
        guard fields.count >= 2, fields[0] == "GET" || fields[0] == "HEAD" else { return send(connection, status: 405) }
        let head = fields[0] == "HEAD"
        let parts = String(fields[1]).components(separatedBy: "?")[0].split(separator: "/").map(String.init)
        guard parts.count == 3, parts[0] == token, let session = RemuxStore.shared.session(parts[1]) else { return send(connection, status: 404) }
        let file = parts[2], name = (file as NSString).deletingPathExtension
        switch (file as NSString).pathExtension {
        case "m3u8":
            let text = name == "master" ? session.master : Int(name).flatMap { session.playlists[$0] }
            guard let text else { return send(connection, status: 404) }
            send(connection, status: 200, body: head ? Data() : Data(text.utf8), length: text.utf8.count, mime: "application/vnd.apple.mpegurl")
        case "mp4":
            guard let data = Int(name).flatMap({ session.initializations[$0] }) else { return send(connection, status: 404) }
            send(connection, status: 200, body: head ? Data() : data, length: data.count, mime: "video/mp4")
        case "m4s", "vtt":
            let numbers = name.split(separator: "-").compactMap { Int($0) }
            guard numbers.count == 2 else { return send(connection, status: 404) }
            if head { return send(connection, status: 200, mime: file.hasSuffix("vtt") ? "text/vtt" : "video/mp4") }
            guard let segment = session.segment(track: numbers[0], index: numbers[1]) else { return send(connection, status: 404) }
            stream(segment, of: session, to: connection, mime: file.hasSuffix("vtt") ? "text/vtt" : "video/mp4")
        default:
            send(connection, status: 404)
        }
    }

    private nonisolated static func stream(_ segment: RemuxSegment, of session: RemuxSession, to connection: NWConnection, mime: String) {
        let closed = ClosedFlag()
        // AVPlayer cancels a request by closing its connection: one more receive learns of it.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, complete, error in
            if complete || error != nil { closed.set(); segment.poke() }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: closed.set(); segment.poke()
            default: break
            }
        }
        Task {
            defer { session.leave(segment); connection.cancel() }
            var offset = 0, started = false
            do {
                while let bytes = try await segment.next(after: offset, cancelled: { closed.value }) {
                    if !started {
                        started = true
                        let header = "HTTP/1.1 200 OK\r\nContent-Type: \(mime)\r\nTransfer-Encoding: chunked\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
                        try await write(Data(header.utf8), to: connection)
                    }
                    offset += bytes.count
                    try await write(Data(String(bytes.count, radix: 16).utf8) + Data("\r\n".utf8) + bytes + Data("\r\n".utf8), to: connection)
                }
                if !started {
                    // An empty segment (a subtitle one without cues has its header at least).
                    try await write(Data("HTTP/1.1 200 OK\r\nContent-Type: \(mime)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), to: connection)
                } else {
                    try await write(Data("0\r\n\r\n".utf8), to: connection)
                }
            } catch {
                if !started, !closed.value {
                    try? await write(Data("HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), to: connection)
                }
            }
        }
    }

    private nonisolated static func write(_ data: Data, to connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private nonisolated static func send(_ connection: NWConnection, status: Int, body: Data = Data(), length: Int? = nil, mime: String = "text/plain") {
        let reason = [200: "OK", 404: "Not Found", 405: "Method Not Allowed"][status] ?? "Error"
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(mime)\r\nContent-Length: \(length ?? body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}

private final class ClosedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    var value: Bool { lock.withLock { closed } }
    func set() { lock.withLock { closed = true } }
}

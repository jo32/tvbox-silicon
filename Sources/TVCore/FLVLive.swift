import Foundation

/// A live HTTP-FLV stream (Huya, Douyu, Bilibili and the live plugins hand these out) played through AVPlayer,
/// which opens no FLV. The stream is read as it arrives and cut at picture keyframes into short runs of tags,
/// each run made a small FLV file of its own (its codec configurations first) and repackaged into fragmented
/// MP4 by `HLSRemux.repackage`, then listed in a live HLS playlist served from the remux loopback server. Times
/// stay the stream's own, so the fragments line up. A changed codec configuration, or times that jump, begin a
/// discontinuity with its own initialization segment. Nothing is kept beyond a short window, and the stream
/// closes when AVPlayer stops asking for the playlist.
public enum FLVLive {
    /// Session-only catalog provenance. It is never encoded with favorites or history.
    public final class Source: Hashable, Sendable {
        public typealias Refresh = @Sendable () async throws -> (url: URL, headers: [String: String])
        let refresh: Refresh
        public init(_ refresh: @escaping Refresh) { self.refresh = refresh }
        public static func == (left: Source, right: Source) -> Bool { left === right }
        public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
    }

    /// Whether `url` names an FLV stream by its path (`.flv`), the way the platforms' addresses do.
    public static func names(_ url: URL) -> Bool { url.pathExtension.lowercased() == "flv" }

    /// What `open` throws when the stream isn't FLV at all (a plain video file a plugin labelled "flv").
    public struct NotFLV: LocalizedError {
        public var errorDescription: String? { L10n.text("This live stream isn't FLV.") }
    }

    /// Starts reading the stream and returns the address of its HLS master playlist once its first run is
    /// repackaged. Throws when the stream answers with an error, isn't FLV (`NotFLV`), or carries no H.264/HEVC picture.
    public static func open(_ url: URL, headers: [String: String], source: Source? = nil) async throws -> URL {
        let session = FLVLiveSession(url: url, headers: headers, device: RemuxSession.device(), source: source)
        RemuxStore.shared.add(session)
        do {
            return try await withTaskCancellationHandler {
                try await session.start()
                let base = try await RemuxServer.shared.base()
                try Task.checkCancellation()
                return base.appending(path: "\(session.id)/master.m3u8")
            } onCancel: { session.close() }
        } catch {
            RemuxStore.shared.remove(session.id)?.close()
            throw error
        }
    }
}

/// FLV tags as the bytes arrive: the file header once, then each complete tag.
struct FLVTagReader {
    struct Tag: Equatable {
        /// 8 audio, 9 video, 18 script data.
        var type: UInt8
        /// Milliseconds.
        var time: UInt32
        var body: Data
    }

    enum Failure: Error { case notFLV, oversized }

    private var buffer = Data()
    private var started = false
    private(set) var hasAudio = true, hasVideo = true

    mutating func append(_ data: Data) throws -> [Tag] {
        buffer.append(data)
        var tags: [Tag] = []
        var offset = buffer.startIndex
        if !started {
            guard buffer.count >= 13 else { return [] }
            guard buffer[offset] == 0x46, buffer[offset + 1] == 0x4C, buffer[offset + 2] == 0x56 else { throw Failure.notFLV }
            let flags = buffer[offset + 4]
            hasAudio = flags & 0x04 != 0; hasVideo = flags & 0x01 != 0
            let header = Int(buffer[offset + 5]) << 24 | Int(buffer[offset + 6]) << 16 | Int(buffer[offset + 7]) << 8 | Int(buffer[offset + 8])
            guard header >= 9, header < 1024 else { throw Failure.notFLV }
            guard buffer.count >= header + 4 else { return [] }
            offset += header + 4 // The header, then PreviousTagSize0.
            started = true
        }
        while buffer.endIndex - offset >= 11 {
            let size = Int(buffer[offset + 1]) << 16 | Int(buffer[offset + 2]) << 8 | Int(buffer[offset + 3])
            guard size < 32 << 20 else { throw Failure.oversized }
            guard buffer.endIndex - offset >= 11 + size + 4 else { break }
            let time = UInt32(buffer[offset + 7]) << 24 | UInt32(buffer[offset + 4]) << 16 | UInt32(buffer[offset + 5]) << 8 | UInt32(buffer[offset + 6])
            tags.append(Tag(type: buffer[offset] & 0x1F, time: time, body: Data(buffer[(offset + 11)..<(offset + 11 + size)])))
            offset += 11 + size + 4
        }
        buffer = Data(buffer[offset...])
        return tags
    }
}

/// Cuts FLV tags into runs that each begin at a picture keyframe and last at least `minimum` seconds.
struct FLVSegmenter {
    struct Run: Equatable {
        /// A complete FLV file: header, codec configurations, then the run's tags.
        var file: Data
        var start: UInt32
        var lastTimestamp: UInt32
        var duration: Double
        /// It begins a discontinuity: other codec configurations, or times that jumped.
        var discontinuity: Bool
    }

    var minimum: Double = 2
    /// A run is cut without a keyframe after this long (a stream with very rare keyframes).
    var maximum: Double = 10

    private var videoConfig: Data?, audioConfig: Data?
    private var tags: [FLVTagReader.Tag] = []
    private var start: UInt32?
    private var last: UInt32?
    private var pendingDiscontinuity = false
    private var sawKeyframe = false
    private var minimumTimestamp: UInt32?
    var bufferedStart: UInt32? { start }

    /// A new HTTP response can repeat the CDN's cached GOPs. Keep only a new keyframe at/after
    /// the last published boundary; a distant reset/wrap is a new HLS discontinuity.
    init(minimumTimestamp: UInt32? = nil) {
        self.minimumTimestamp = minimumTimestamp
        pendingDiscontinuity = minimumTimestamp != nil
    }

    mutating func finish() -> Run? {
        guard let start, let last else { return nil }
        return cut(end: last == .max ? last : last + 1, begun: start)
    }

    /// The run the tag closes, if it does. Tags before the first keyframe are dropped.
    mutating func add(_ raw: FLVTagReader.Tag) -> Run? {
        guard raw.type == 8 || raw.type == 9, !raw.body.isEmpty else { return nil }
        let tag = raw.type == 9 ? Self.enhanced(raw) : raw
        var closed: Run?
        if let last, let begun = start, !tags.isEmpty {
            let back = Int64(last) - Int64(tag.time)
            let ahead = Int64(tag.time) - Int64(last)
            if back > 1000 || ahead > 15_000 {
                // The times began again or jumped (the source reconnected): a new run, a discontinuity.
                closed = cut(end: last, begun: begun)
                pendingDiscontinuity = true
            }
        }
        if tag.type == 9, Self.isVideoConfig(tag.body) {
            if let videoConfig, videoConfig != tag.body, !tags.isEmpty, let begun = start, closed == nil {
                closed = cut(end: max(tag.time, last ?? begun), begun: begun)
            }
            if videoConfig != nil, videoConfig != tag.body { pendingDiscontinuity = true }
            videoConfig = tag.body
            return closed
        }
        if tag.type == 8, Self.isAudioConfig(tag.body) {
            if audioConfig != nil, audioConfig != tag.body { pendingDiscontinuity = true }
            audioConfig = tag.body
            return closed
        }
        let key = tag.type == 9 && Self.isKeyframe(tag.body)
        if !sawKeyframe {
            guard key, videoConfig != nil else { return closed }
            if let minimumTimestamp, tag.time < minimumTimestamp, minimumTimestamp - tag.time <= 120_000 { return closed }
            sawKeyframe = true
        }
        if let begun = start, !tags.isEmpty, closed == nil {
            let elapsed = Double(Int64(tag.time) - Int64(begun)) / 1000
            if (key && elapsed >= minimum) || elapsed >= maximum { closed = cut(end: tag.time, begun: begun) }
        }
        if tags.isEmpty { start = tag.time }
        tags.append(tag)
        last = max(last ?? tag.time, tag.time)
        if closed != nil, last ?? 0 > tag.time { last = tag.time }
        return closed
    }

    private mutating func cut(end: UInt32, begun: UInt32) -> Run? {
        defer { tags = []; start = nil }
        guard let videoConfig, !tags.isEmpty else { return nil }
        var file = Data([0x46, 0x4C, 0x56, 0x01, audioConfig == nil ? 0x01 : 0x05, 0, 0, 0, 9, 0, 0, 0, 0])
        Self.write(FLVTagReader.Tag(type: 9, time: begun, body: videoConfig), to: &file)
        if let audioConfig { Self.write(FLVTagReader.Tag(type: 8, time: begun, body: audioConfig), to: &file) }
        for tag in tags where tag.type == 9 || audioConfig != nil { Self.write(tag, to: &file) }
        let duration = max(0.04, Double(Int64(end) - Int64(begun)) / 1000)
        let run = Run(file: file, start: begun, lastTimestamp: last ?? begun, duration: duration, discontinuity: pendingDiscontinuity)
        pendingDiscontinuity = false
        return run
    }

    static func write(_ tag: FLVTagReader.Tag, to file: inout Data) {
        let size = tag.body.count
        file.append(contentsOf: [tag.type, UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF),
                                 UInt8(tag.time >> 16 & 0xFF), UInt8(tag.time >> 8 & 0xFF), UInt8(tag.time & 0xFF), UInt8(tag.time >> 24 & 0xFF),
                                 0, 0, 0])
        file.append(tag.body)
        let total = UInt32(11 + size)
        file.append(contentsOf: [UInt8(total >> 24), UInt8(total >> 16 & 0xFF), UInt8(total >> 8 & 0xFF), UInt8(total & 0xFF)])
    }

    /// A legacy HEVC tag (codec id 12, which Chinese platforms use) rewritten in the enhanced-RTMP form FFmpeg reads.
    static func enhanced(_ tag: FLVTagReader.Tag) -> FLVTagReader.Tag {
        let body = tag.body
        guard body.count >= 5, body[body.startIndex] & 0x80 == 0, body[body.startIndex] & 0x0F == 12 else { return tag }
        let first = body[body.startIndex], packet = body[body.startIndex + 1]
        let frame = (first >> 4) & 0x07
        guard packet <= 2 else { return tag }
        var out = Data([0x80 | frame << 4 | packet, 0x68, 0x76, 0x63, 0x31]) // "hvc1"
        switch packet {
        case 0: out.append(body[(body.startIndex + 5)...]) // The configuration record, without the composition time.
        case 1: out.append(body[(body.startIndex + 2)...]) // Composition time, then the NAL units.
        default: break
        }
        return FLVTagReader.Tag(type: tag.type, time: tag.time, body: out)
    }

    static func isVideoConfig(_ body: Data) -> Bool {
        guard let first = body.first else { return false }
        if first & 0x80 != 0 { return first & 0x0F == 0 } // Enhanced: SequenceStart.
        return body.count > 1 && body[body.startIndex + 1] == 0 && [7, 12].contains(first & 0x0F)
    }

    static func isKeyframe(_ body: Data) -> Bool {
        guard let first = body.first else { return false }
        return (first >> 4) & 0x07 == 1
    }

    static func isAudioConfig(_ body: Data) -> Bool {
        guard body.count > 1 else { return false }
        return body[body.startIndex] >> 4 == 10 && body[body.startIndex + 1] == 0
    }
}

/// One live FLV stream played as HLS (`FLVLive`).
final class FLVLiveSession: NSObject, SegmentedStream, URLSessionDataDelegate, @unchecked Sendable {
    struct Segment {
        var index: Int
        var duration: Double
        var discontinuity: Bool
        /// The segment beginning its discontinuity, which names its initialization segment.
        var run: Int
        var output: Task<HLSRemux.Output, Error>
    }

    /// Segments listed in the playlist; a few more are kept for a player that is behind.
    static let listed = 6, kept = 10
    /// Closed when AVPlayer hasn't asked for the playlist this long (the player went away).
    static let idle: TimeInterval = 30

    let id = UUID().uuidString.lowercased()
    let live = true
    private(set) var copiesHDR = false
    private(set) var master = ""
    private let url: URL
    private let headers: [String: String]
    private let source: FLVLive.Source?
    private let device: RemuxPlan.Device
    private let lock = NSLock()
    private var reader = FLVTagReader()
    private var segmenter = FLVSegmenter()
    private var segments: [Segment] = []
    private var next = 0
    private var discontinuities = 0
    private var initializations: [Int: [Int: Data]] = [:]
    private var tracks = [0]
    private var target = 2
    private var ended: Error?
    private var finished = false
    private var closed = false
    private var asked = Date()
    private var received: Int64 = 0
    private var began = Date()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var network: URLSession?
    private var task: URLSessionDataTask?
    private var response: CheckedContinuation<Void, Error>?
    private var watchdog: Task<Void, Never>?
    private var refreshing: Task<Void, Never>?
    private var recoveryDeadline: Task<Void, Never>?
    private var refreshID = UUID()
    private var attempts = 0
    private var connection = 0
    private var connectionDuration: Double = 0
    private var lastMediaEnd: UInt32?
    private var heldTail: FLVSegmenter.Run?
    private var responseError: Error?
    private var deadlineID = UUID()

    init(url: URL, headers: [String: String], device: RemuxPlan.Device, source: FLVLive.Source? = nil) {
        self.url = url; self.headers = headers; self.device = device; self.source = source
    }

    /// Connects, then waits for the first run's repackaging, which describes the master playlist.
    func start() async throws {
        try Task.checkCancellation()
        began = Date()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "tvbox.flv.live"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        let network = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let task = network.dataTask(with: request)
        let accepted = lock.withLock { () -> Bool in
            guard !closed else { return false }
            self.network = network; self.task = task
            return true
        }
        guard accepted else { network.invalidateAndCancel(); throw CancellationError() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let accepted = lock.withLock { () -> Bool in
                guard !closed else { return false }
                response = continuation
                return true
            }
            if accepted { task.resume() } else { continuation.resume(throwing: CancellationError()) }
        }
        try Task.checkCancellation()
        let first = try await firstSegment()
        let output = try await first.output.value
        try Task.checkCancellation()
        guard !lock.withLock({ closed }) else { throw CancellationError() }
        describe(output, at: first.index)
        Diagnostics.shared.record(.info, "remux", "flv live open host=\(url.host() ?? "-") video=\(output.video) audio=\(output.audio ?? "-") size=\(output.width)x\(output.height) ms=\(Int(Date().timeIntervalSince(began) * 1000))")
        let watchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self else { return }
                let idle = self.lock.withLock { Date().timeIntervalSince(self.asked) }
                if idle > Self.idle {
                    Diagnostics.shared.record(.info, "remux", "flv live idle; closing")
                    RemuxStore.shared.remove(self.id)?.close()
                    return
                }
            }
        }
        lock.withLock {
            if closed { watchdog.cancel() } else { self.watchdog = watchdog }
        }
    }

    private func firstSegment() async throws -> Segment {
        let deadline = Date().addingTimeInterval(20)
        while true {
            try Task.checkCancellation()
            let (segment, failure) = lock.withLock { (segments.first, ended) }
            if let segment { return segment }
            if let failure { throw failure }
            if Date() > deadline { throw TVError.unsupported(L10n.text("The live stream sent no picture.")) }
            await wait(seconds: 1)
        }
    }

    /// Returns when a segment is added or the stream ends, or after `seconds`.
    private func wait(seconds: Double) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.withLock { waiters.append(continuation) }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                self?.wake()
            }
        }
    }

    private func wake() {
        let resumed = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { waiters = [] }
            return waiters
        }
        resumed.forEach { $0.resume() }
    }

    // MARK: Reading the stream

    private func active(_ session: URLSession, _ task: URLSessionTask) -> Bool {
        lock.withLock { !closed && !finished && network === session && self.task === task }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard active(session, dataTask) else { completionHandler(.cancel); return }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { self.response = nil }
            return self.response
        }
        guard (200..<300).contains(status) else {
            let error = TVError.http(status)
            lock.withLock { responseError = error }
            waiting?.resume(throwing: error)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
        waiting?.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard active(session, dataTask) else { return }
        do {
            let added = try lock.withLock { () throws -> Bool in
                guard !closed, !finished else { return false }
                received += Int64(data.count)
                var added = false
                for tag in try reader.append(data) {
                    let run = segmenter.add(tag)
                    if let heldTail {
                        if let run, run.start == heldTail.start {
                            self.heldTail = nil
                        } else if let start = segmenter.bufferedStart, start != heldTail.start {
                            var tail = heldTail
                            if start > tail.lastTimestamp, start - tail.lastTimestamp <= 15_000 {
                                tail.duration = Double(start - tail.start) / 1000
                            }
                            appendSegment(tail, earnsCredit: false)
                            self.heldTail = nil
                            added = true
                        }
                    }
                    if let run { appendSegment(run, earnsCredit: true); added = true }
                }
                return added
            }
            if added { wake() }
        } catch {
            let failure: Error = error as? FLVTagReader.Failure == .notFLV ? FLVLive.NotFLV() : TVError.unsupported(L10n.text("This live stream isn't FLV."))
            fail(failure)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard active(session, task) else { return }
        let state = lock.withLock { () -> (Error?, [Task<HLSRemux.Output, Error>], UUID) in
            if let tail = segmenter.finish() { retainTail(tail) }
            self.task = nil // Fence this connection's late callbacks before resolving again.
            let failure = responseError ?? error
            responseError = nil
            return (failure, segments.map(\.output), refreshID)
        }
        let (failure, outputs, token) = state
        let retryable: Bool
        if let failure, case TVError.http(let status) = failure { retryable = status == 403 || status == 429 || (500...599).contains(status) }
        else { retryable = failure == nil || failure is URLError }
        guard source != nil, retryable, lock.withLock({ next > 0 || heldTail != nil }) else {
            fail(failure ?? TVError.unsupported(L10n.text("The live stream ended."))); return
        }
        // Repackaging must actually succeed before its new media earns retry credit. Keep serving old
        // segments during this wait and the refresh; neither the HLS owner nor player item is replaced.
        lock.withLock {
            guard !closed, !finished, refreshID == token else { return }
            startRecoveryDeadline()
            refreshing = Task { [weak self] in
                guard let self else { return }
                do {
                    for output in outputs { _ = try await output.value }
                    try Task.checkCancellation()
                    await self.reconnect(token: token)
                } catch { if !Task.isCancelled { self.fail(error) } }
            }
        }
    }

    private func startRecoveryDeadline() {
        guard recoveryDeadline == nil else { return }
        let deadline = UUID()
        deadlineID = deadline
        recoveryDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            self?.fail(URLError(.timedOut), deadline: deadline)
        }
    }

    private func reconnect(token: UUID) async {
        while !Task.isCancelled {
            let state = lock.withLock { () -> (FLVLive.Source, Int)? in
                guard !closed, !finished, refreshID == token, let source else { return nil }
                attempts += 1
                startRecoveryDeadline()
                return (source, attempts)
            }
            guard let (source, attempt) = state else { return }
            guard attempt <= 3 else { fail(TVError.unsupported(L10n.text("The live stream could not reconnect."))); return }
            do {
                if attempt > 1 { try await Task.sleep(for: .seconds(attempt == 2 ? 1 : 3)) }
                let fresh = try await source.refresh()
                try Task.checkCancellation()
                guard FLVLive.names(fresh.url), ["https", "http"].contains(fresh.url.scheme) else {
                    fail(TVError.unsupported(L10n.text("The live source changed its stream format."))); return
                }
                let task = lock.withLock { () -> URLSessionDataTask? in
                    guard !closed, !finished, refreshID == token, let network else { return nil }
                    var request = URLRequest(url: fresh.url, timeoutInterval: 8)
                    fresh.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
                    request.setValue(nil, forHTTPHeaderField: "Range")
                    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                    let task = network.dataTask(with: request)
                    reader = FLVTagReader(); segmenter = FLVSegmenter(minimumTimestamp: heldTail?.start ?? lastMediaEnd)
                    connection += 1; connectionDuration = 0
                    self.task = task
                    return task
                }
                task?.resume()
                return
            } catch {
                if Task.isCancelled { return }
                if error is CancellationError { fail(error); return }
                if attempt == 3 { fail(error); return }
            }
        }
    }

    private func fail(_ error: Error, deadline: UUID? = nil) {
        let state = lock.withLock { () -> (URLSessionDataTask?, CheckedContinuation<Void, Error>?, Task<Void, Never>?, Task<Void, Never>?)? in
            guard !closed, !finished, deadline == nil || deadline == deadlineID else { return nil }
            if let tail = segmenter.finish() { retainTail(tail) }
            if let heldTail { appendSegment(heldTail, earnsCredit: false); self.heldTail = nil }
            finished = true; ended = error; refreshID = UUID()
            defer { response = nil; task = nil }
            return (task, response, refreshing, recoveryDeadline)
        }
        guard let (task, response, refresh, deadline) = state else { return }
        task?.cancel(); refresh?.cancel(); deadline?.cancel()
        response?.resume(throwing: error)
        wake()
    }

    private func retainTail(_ tail: FLVSegmenter.Run) {
        if let heldTail, heldTail.start == tail.start, heldTail.lastTimestamp >= tail.lastTimestamp { return }
        heldTail = tail
    }

    private func appendSegment(_ run: FLVSegmenter.Run, earnsCredit: Bool) {
        let device = device, file = run.file
        let activeConnection = connection
        let output = Task.detached(priority: .userInitiated) { [weak self] in
            let output = try HLSRemux.repackage(file, device: device)
            guard output.media[0]?.isEmpty == false else { throw TVError.unsupported("FLV has no picture") }
            if earnsCredit {
                self?.lock.withLock {
                    guard let self, !self.closed, !self.finished, self.connection == activeConnection else { return }
                    self.connectionDuration += run.duration
                    if self.connectionDuration >= 2 {
                        self.attempts = 0
                        if self.task != nil {
                            self.deadlineID = UUID()
                            self.recoveryDeadline?.cancel(); self.recoveryDeadline = nil
                        }
                    }
                }
            }
            return output
        }
        let index = next
        next += 1
        lastMediaEnd = run.start &+ UInt32((run.duration * 1000).rounded())
        let runStart = run.discontinuity || segments.isEmpty ? index : (segments.last?.run ?? index)
        segments.append(Segment(index: index, duration: run.duration, discontinuity: run.discontinuity && index > 0, run: runStart, output: output))
        target = max(target, Int(run.duration.rounded(.up)))
        while segments.count > Self.kept {
            let gone = segments.removeFirst()
            if gone.discontinuity { discontinuities += 1 }
            gone.output.cancel()
        }
        let runs = Set(segments.map(\.run))
        initializations = initializations.filter { runs.contains($0.key) }
    }

    // MARK: Serving

    private func describe(_ first: HLSRemux.Output, at position: Int) {
        let audio = first.media[1] != nil
        copiesHDR = first.transfer == 16 || first.transfer == 18
        lock.withLock {
            tracks = audio ? [0, 1] : [0]
            if let run = segments.first(where: { $0.index == position })?.run { initializations[run] = first.initializations }
        }
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7"]
        if audio {
            lines.append("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"Audio\",DEFAULT=YES,AUTOSELECT=YES,URI=\"1.m3u8\"")
        }
        var attributes = ["BANDWIDTH=8000000"]
        if first.width > 0 { attributes.append("RESOLUTION=\(first.width)x\(first.height)") }
        if copiesHDR { attributes.append("VIDEO-RANGE=\(first.transfer == 16 ? "PQ" : "HLG")") }
        if audio { attributes.append("AUDIO=\"audio\"") }
        lines.append("#EXT-X-STREAM-INF:" + attributes.joined(separator: ","))
        lines.append("0.m3u8")
        master = lines.joined(separator: "\n") + "\n"
    }

    /// A track's live playlist: the newest segments. The first answer waits for three, or ten seconds' worth when
    /// keyframes are far apart (NetEase CC's 8 s), so playback starts with room to spare instead of stalling at once.
    func playlist(_ track: Int) async -> String? {
        lock.withLock { asked = Date() }
        let deadline = Date().addingTimeInterval(12)
        while lock.withLock({ segments.count < 3 && segments.reduce(0, { $0 + $1.duration }) < 10 && !finished }), Date() < deadline { await wait(seconds: 1) }
        return lock.withLock { () -> String? in
            guard tracks.contains(track), !segments.isEmpty else { return nil }
            let shown = Array(segments.suffix(Self.listed))
            let hidden = segments.count - shown.count
            let dropped = discontinuities + segments.prefix(hidden).filter(\.discontinuity).count
            var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(target)", "#EXT-X-MEDIA-SEQUENCE:\(shown[0].index)",
                         "#EXT-X-DISCONTINUITY-SEQUENCE:\(dropped)"]
            for (offset, segment) in shown.enumerated() {
                if segment.discontinuity { lines.append("#EXT-X-DISCONTINUITY") }
                if offset == 0 || segment.discontinuity { lines.append("#EXT-X-MAP:URI=\"\(track)-\(segment.run).mp4\"") }
                lines.append(String(format: "#EXTINF:%.3f,", segment.duration))
                lines.append("\(track)-\(segment.index).m4s")
            }
            if finished { lines.append("#EXT-X-ENDLIST") }
            return lines.joined(separator: "\n") + "\n"
        }
    }

    func initialization(track: Int, index: Int) async throws -> Data {
        let (cached, member) = lock.withLock { (initializations[index], segments.first { $0.run == index }) }
        if let data = cached?[track] { return data }
        guard let member else { throw TVError.unsupported("no such initialization") }
        let fresh = try await member.output.value.initializations
        lock.withLock { initializations[index] = fresh }
        guard let data = fresh[track] else { throw TVError.unsupported("no track \(track)") }
        return data
    }

    func segment(track: Int, index: Int) async throws -> Data {
        guard let segment = lock.withLock({ segments.first { $0.index == index } }) else { throw TVError.unsupported("no such segment") }
        guard let data = try await segment.output.value.media[track] else { throw TVError.unsupported("segment \(index) has no track \(track)") }
        return data
    }

    func close() {
        let state = lock.withLock { () -> (URLSessionDataTask?, URLSession?, [Task<HLSRemux.Output, Error>],
                                          CheckedContinuation<Void, Error>?, [Task<Void, Never>]) in
            closed = true; finished = true; ended = CancellationError(); refreshID = UUID(); deadlineID = UUID()
            defer { segments = []; initializations = [:]; heldTail = nil; self.response = nil; self.task = nil }
            return (self.task, self.network, segments.map(\.output), self.response, [watchdog, refreshing, recoveryDeadline].compactMap { $0 })
        }
        let (task, network, outputs, response, work) = state
        work.forEach { $0.cancel() }
        response?.resume(throwing: CancellationError())
        task?.cancel(); network?.invalidateAndCancel()
        outputs.forEach { $0.cancel() }
        wake()
    }
}

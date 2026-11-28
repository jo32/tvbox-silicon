import Foundation

/// A live HTTP-FLV stream (Huya, Douyu, Bilibili and the live plugins hand these out) played through AVPlayer,
/// which opens no FLV. The stream is read as it arrives and cut at picture keyframes into short runs of tags,
/// each run made a small FLV file of its own (its codec configurations first) and repackaged into fragmented
/// MP4 by `HLSRemux.repackage`, then listed in a live HLS playlist served from the remux loopback server. Times
/// stay the stream's own, so the fragments line up. A changed codec configuration, or times that jump, begin a
/// discontinuity with its own initialization segment. Nothing is kept beyond a short window, and the stream
/// closes when AVPlayer stops asking for the playlist.
public enum FLVLive {
    /// Whether `url` names an FLV stream by its path (`.flv`), the way the platforms' addresses do.
    public static func names(_ url: URL) -> Bool { url.pathExtension.lowercased() == "flv" }

    /// What `open` throws when the stream isn't FLV at all (a plain video file a plugin labelled "flv").
    public struct NotFLV: LocalizedError {
        public var errorDescription: String? { L10n.text("This live stream isn't FLV.") }
    }

    /// A fresh address for the same stream, and the headers it wants: the episode resolved again by its source.
    /// Nil when there is none.
    public typealias Renew = @Sendable () async -> (url: URL, headers: [String: String])?

    /// Starts reading the stream and returns the address of its HLS master playlist once its first run is
    /// repackaged. Throws when the stream answers with an error, isn't FLV (`NotFLV`), or carries no H.264/HEVC picture.
    /// `trusting` accepts the server's certificate whatever it is (`PlaybackRescue`). With `renew`, a stream whose
    /// connection ends after it played (a platform's address stops working after a while; Huya's after about two
    /// minutes, #488) goes on from a fresh address in the same playlist, so the player keeps its item.
    public static func open(_ url: URL, headers: [String: String], trusting: Bool = false, renew: Renew? = nil) async throws -> URL {
        let session = FLVLiveSession(url: url, headers: headers, device: RemuxSession.device(), trusting: trusting, renew: renew)
        RemuxStore.shared.add(session)
        do {
            try await session.start()
            let base = try await RemuxServer.shared.base()
            return base.appending(path: "\(session.id)/master.m3u8")
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
    /// Where the last run cut ended, in the stream's milliseconds.
    private(set) var lastEnd: UInt32?
    /// Keyframes before this are skipped (`resuming`).
    private var after: UInt32?

    /// Cuts the same stream read again from a new connection, which begins at a picture the server had: one before
    /// `end` was played already and is skipped. A time far behind it is the stream's clock starting again, which
    /// plays on. Either way the first run begins a discontinuity.
    static func resuming(after end: UInt32?) -> FLVSegmenter {
        var segmenter = FLVSegmenter()
        segmenter.after = end
        segmenter.pendingDiscontinuity = true
        return segmenter
    }

    /// The run under way, cut where the stream stopped; nil when there is none.
    mutating func finish() -> Run? {
        guard let begun = start, let last, !tags.isEmpty else { return nil }
        return cut(end: last == .max ? last : last + 1, begun: begun)
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
            if let after, tag.time < after, after - tag.time <= 120_000 { return closed }
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
        let run = Run(file: file, start: begun, duration: duration, discontinuity: pendingDiscontinuity)
        pendingDiscontinuity = false
        lastEnd = end
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

/// One live stream played as HLS: FLV (`FLVLive`), or MPEG-TS (`TSLive`), cut by its `LiveCutter`.
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
    private let device: RemuxPlan.Device
    private let lock = NSLock()
    private var cutter: any LiveCutter
    /// What the log lines call the stream: `flv` or `ts`.
    private let kind: String
    /// The server's certificate is accepted whatever it is (`PlaybackRescue`).
    private let trusting: Bool
    /// A fresh address once a connection ends (`FLVLive.Renew`), and how many were asked in a row without a new run.
    private let renew: FLVLive.Renew?
    private var renewals = 0
    static let renewalsInARow = 3
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

    init(url: URL, headers: [String: String], device: RemuxPlan.Device, cutter: any LiveCutter = FLVCutter(), trusting: Bool = false,
         renew: FLVLive.Renew? = nil) {
        self.url = url; self.headers = headers; self.device = device
        self.cutter = cutter; kind = cutter.name; self.trusting = trusting; self.renew = renew
    }

    /// Connects, then waits for the first run's repackaging, which describes the master playlist.
    func start() async throws {
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
        lock.withLock { self.network = network; self.task = task }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.withLock { response = continuation }
            task.resume()
        }
        let first = try await firstSegment()
        let output = try await first.output.value
        describe(output, at: first.index)
        Diagnostics.shared.record(.info, "remux", "\(kind) live open host=\(url.host() ?? "-") video=\(output.video) audio=\(output.audio ?? "-") size=\(output.width)x\(output.height) ms=\(Int(Date().timeIntervalSince(began) * 1000))")
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                let idle = self.lock.withLock { Date().timeIntervalSince(self.asked) }
                if idle > Self.idle {
                    Diagnostics.shared.record(.info, "remux", "\(self.kind) live idle; closing")
                    RemuxStore.shared.remove(self.id)?.close()
                    return
                }
            }
        }
    }

    private func firstSegment() async throws -> Segment {
        let deadline = Date().addingTimeInterval(20)
        while true {
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

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { self.response = nil }
            return self.response
        }
        guard (200..<300).contains(status) else {
            completionHandler(.cancel)
            let error = TVError.http(status)
            lock.withLock { ended = error }
            waiting?.resume(throwing: error)
            return
        }
        completionHandler(.allow)
        waiting?.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let runs: [FLVSegmenter.Run]
        do {
            runs = try lock.withLock { () throws -> [FLVSegmenter.Run] in
                received += Int64(data.count)
                let runs = try cutter.feed(data)
                if !runs.isEmpty { renewals = 0 }
                return runs
            }
        } catch {
            Diagnostics.shared.record(.warning, "remux", "\(kind) live \(error)")
            let failure: Error = error is FLVLive.NotFLV || error is TSLive.NotTS ? error : TVError.unsupported(L10n.text("This live stream isn't FLV."))
            lock.withLock { ended = failure }
            dataTask.cancel(); wake()
            return
        }
        guard !runs.isEmpty else { return }
        runs.forEach(add)
        wake()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let reason = lock.withLock { ended } ?? error
        if let renewal = renewing(after: error) {
            Diagnostics.shared.record(.info, "remux", "\(kind) live renewing try=\(renewal) bytes=\(received) \(reason.map(Diagnostics.describe) ?? "eof")")
            Task { [weak self] in await self?.reconnect(renewal) }
            return
        }
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { response = nil }
            finished = true
            if ended == nil { ended = error ?? TVError.unsupported(L10n.text("The live stream ended.")) }
            return response
        }
        waiting?.resume(throwing: error ?? TVError.unsupported(L10n.text("The live stream ended.")))
        if !closed { Diagnostics.shared.record(.info, "remux", "\(kind) live ended bytes=\(received) \(reason.map(Diagnostics.describe) ?? "eof")") }
        wake()
    }

    /// Whether the connection that just ended goes on from a fresh address (`renew`), and which try in a row that is:
    /// a stream that played, whose server ended it or refused it with an HTTP error, or whose network dropped. The run
    /// under way is kept, and the cutter set to take the stream up again after it.
    private func renewing(after error: Error?) -> Int? {
        let (renewal, tail) = lock.withLock { () -> (Int?, FLVSegmenter.Run?) in
            guard renew != nil, !closed, response == nil, !segments.isEmpty, renewals < Self.renewalsInARow else { return (nil, nil) }
            if let ended {
                guard case TVError.http = ended else { return (nil, nil) } // Not FLV after all, or too big: no address helps.
            } else if let error, (error as? URLError).map({ $0.code == .cancelled }) ?? true {
                return (nil, nil)
            }
            renewals += 1; ended = nil
            return (renewals, cutter.resume())
        }
        if let tail { add(tail); wake() }
        return renewal
    }

    /// Reads on from the address `renew` gives now; the stream ends when there is none.
    private func reconnect(_ renewal: Int) async {
        if renewal > 1 { try? await Task.sleep(for: .seconds(renewal - 1)) }
        let fresh = await renew?()
        let task = lock.withLock { () -> URLSessionDataTask? in
            guard !closed, let fresh, ["http", "https"].contains(fresh.url.scheme?.lowercased() ?? ""), let network else { return nil }
            var request = URLRequest(url: fresh.url)
            fresh.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
            let task = network.dataTask(with: request)
            self.task = task
            return task
        }
        guard let task, let fresh else {
            let ended = lock.withLock { () -> Bool in
                guard !closed, !finished else { return false }
                finished = true
                self.ended = TVError.unsupported(L10n.text("The live stream ended."))
                return true
            }
            if ended { Diagnostics.shared.record(.warning, "remux", "\(kind) live not renewed: \(fresh == nil ? "no address" : "not HTTP")") }
            wake()
            return
        }
        Diagnostics.shared.record(.info, "remux", "\(kind) live renewed host=\(fresh.url.host() ?? "-")")
        task.resume()
    }

    /// A link AVPlayer refused over its certificate is read anyway, when `trusting`, from its own host.
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Only the link's own host: a redirect elsewhere is checked as usual.
        if trusting, challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           challenge.protectionSpace.host.lowercased() == url.host()?.lowercased(), let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    private func add(_ run: FLVSegmenter.Run) {
        let device = device
        let file = run.file
        let output = Task.detached(priority: .userInitiated) { try HLSRemux.repackage(file, device: device) }
        lock.withLock {
            guard !closed else { return }
            let index = next
            next += 1
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
        let (task, network, outputs) = lock.withLock { () -> (URLSessionDataTask?, URLSession?, [Task<HLSRemux.Output, Error>]) in
            closed = true
            defer { segments = []; initializations = [:] }
            return (self.task, self.network, segments.map(\.output))
        }
        watchdog?.cancel()
        task?.cancel()
        network?.invalidateAndCancel()
        outputs.forEach { $0.cancel() }
        wake()
    }
}

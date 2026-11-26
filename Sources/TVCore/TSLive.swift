import Foundation

/// A continuous MPEG-TS stream over plain HTTP (an IPTV relay's `/rtp/...`, `.php` or `.ts` channel): one response that
/// never ends and has no Content-Length. AVPlayer plays MPEG-TS only inside HLS and asks such a link for a byte range
/// first, so it gives up at once (CoreMedia -12939, "byte range and no content length"). The stream is read as it
/// arrives, cut at picture keyframes into runs of packets, and each run is repackaged and served as live HLS exactly
/// as `FLVLive` does with an FLV stream (`FLVLiveSession`), sound AVPlayer can't decode (MP2) converted on the way.
public enum TSLive {
    /// Starts reading the stream and returns the address of its HLS master playlist once its first run is repackaged.
    /// `trusting` accepts the server's certificate whatever it is, for a link AVPlayer refused over it.
    public static func open(_ url: URL, headers: [String: String], trusting: Bool = false) async throws -> URL {
        let session = FLVLiveSession(url: url, headers: headers, device: RemuxSession.device(), cutter: TSCutter(), trusting: trusting)
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

    /// What `open` throws when the bytes aren't MPEG-TS packets.
    public struct NotTS: LocalizedError {
        public var errorDescription: String? { "not MPEG-TS" }
    }
}

/// Turns a live stream's bytes, as they arrive, into runs that `HLSRemux.repackage` makes fragmented MP4 of: each a
/// complete little file of its own that begins at a picture keyframe.
protocol LiveCutter {
    /// The name the stream's log lines use (`flv`, `ts`).
    var name: String { get }
    mutating func feed(_ data: Data) throws -> [FLVSegmenter.Run]
    /// Ready for the same stream from a new connection (`FLVLive.Renew`): returns the run the old one left under way.
    mutating func resume() -> FLVSegmenter.Run?
}

/// FLV tags (`FLVTagReader`) cut by `FLVSegmenter`.
struct FLVCutter: LiveCutter {
    var name: String { "flv" }
    private var reader = FLVTagReader()
    private var segmenter = FLVSegmenter()
    mutating func feed(_ data: Data) throws -> [FLVSegmenter.Run] {
        do { return try reader.append(data).compactMap { segmenter.add($0) } }
        catch FLVTagReader.Failure.notFLV { throw FLVLive.NotFLV() }
    }
    mutating func resume() -> FLVSegmenter.Run? {
        let tail = segmenter.finish()
        reader = FLVTagReader()
        segmenter = .resuming(after: segmenter.lastEnd)
        return tail
    }
}

/// Cuts MPEG-TS packets into runs that each begin with the stream's PAT and PMT and a picture keyframe (a packet with
/// the random access indicator, or a PES whose first bytes carry an IDR or parameter sets), and last at least `minimum`
/// seconds by the PTS of the picture (or of the sound, in a stream without one). Times that jump begin a discontinuity.
struct TSCutter: LiveCutter {
    var name: String { "ts" }
    var minimum: Double = 2
    /// A run is cut without a keyframe after this long (a stream with very rare keyframes).
    var maximum: Double = 10
    /// Bytes read without finding packets before the stream is taken for something else.
    static let searchLimit = 64 << 10

    private var pending = Data()
    private var searched = 0
    private var synced = false
    private var pat: Data?, pmt: Data?
    private var pmtPID: Int?
    private var clockPID: Int?
    private var videoHEVC = false
    private var hasVideo = false
    private var run = Data()
    private var runStart: Int64?
    private var lastPTS: Int64?
    private var started = false
    private var pendingDiscontinuity = false

    mutating func feed(_ data: Data) throws -> [FLVSegmenter.Run] {
        pending.append(data)
        var runs: [FLVSegmenter.Run] = []
        var offset = pending.startIndex
        while pending.endIndex - offset >= 188 {
            if pending[offset] != 0x47 || (pending.endIndex - offset >= 376 && pending[offset + 188] != 0x47) {
                // Lost (or not yet found) the packet boundary: look for two sync bytes 188 apart.
                synced = false
                offset += 1
                searched += 1
                if searched > Self.searchLimit, !started { throw TSLive.NotTS() }
                continue
            }
            synced = true
            if let closed = packet(pending[offset..<offset + 188]) { runs.append(closed) }
            offset += 188
        }
        pending = Data(pending[offset...])
        return runs
    }

    mutating func resume() -> FLVSegmenter.Run? {
        let tail = started ? lastPTS.flatMap { cut(end: $0) } : nil
        var fresh = TSCutter()
        fresh.minimum = minimum; fresh.maximum = maximum; fresh.pendingDiscontinuity = true
        self = fresh
        return tail
    }

    /// Adds one packet; returns the run it closes, if it does.
    private mutating func packet(_ bytes: Data) -> FLVSegmenter.Run? {
        let base = bytes.startIndex
        let pid = Int(bytes[base + 1] & 0x1F) << 8 | Int(bytes[base + 2])
        if pid == 0x1FFF { return nil }
        let unitStart = bytes[base + 1] & 0x40 != 0
        let control = (bytes[base + 3] >> 4) & 0x03
        var payload = base + 4
        var randomAccess = false
        if control & 0x02 != 0 {
            let length = Int(bytes[base + 4])
            if length > 0, base + 5 < bytes.endIndex { randomAccess = bytes[base + 5] & 0x40 != 0 }
            payload = base + 5 + length
        }
        guard control & 0x01 != 0, payload < bytes.endIndex else {
            if started { run.append(bytes) }
            return nil
        }
        let body = bytes[payload...]
        if pid == 0, unitStart {
            pat = Data(bytes)
            pmtPID = Self.programMap(body)
            return nil
        }
        if let pmtPID, pid == pmtPID, unitStart {
            pmt = Data(bytes)
            if let streams = Self.streams(body) {
                if let video = streams.first(where: { Self.videoTypes.contains($0.type) }) {
                    clockPID = video.pid; hasVideo = true; videoHEVC = video.type == 0x24
                } else if let audio = streams.first(where: { Self.audioTypes.contains($0.type) }) {
                    clockPID = audio.pid; hasVideo = false
                }
            }
            return nil
        }
        guard let clockPID, pid == clockPID, unitStart, let pts = Self.pts(body) else {
            if started { run.append(bytes) }
            return nil
        }
        let key = !hasVideo || randomAccess || Self.keyframe(body, hevc: videoHEVC)
        var closed: FLVSegmenter.Run?
        if let last = lastPTS, started {
            let step = Self.difference(pts, last)
            if step < -90_000 || step > 15 * 90_000 {
                // The times began again or jumped (the relay reconnected to its source): a discontinuity.
                closed = cut(end: last)
                pendingDiscontinuity = true
                started = false
            }
        }
        if !started {
            guard key, let pat, let pmt else { return closed }
            started = true
            run = pat + pmt
            runStart = pts
        } else if let begun = runStart, closed == nil {
            let elapsed = Double(Self.difference(pts, begun)) / 90_000
            if (key && elapsed >= minimum) || elapsed >= maximum {
                closed = cut(end: pts)
                run = (pat ?? Data()) + (pmt ?? Data())
                runStart = pts
            }
        }
        lastPTS = pts
        run.append(bytes)
        return closed
    }

    private mutating func cut(end: Int64) -> FLVSegmenter.Run? {
        guard let begun = runStart, run.count > 376 else { return nil }
        let duration = max(0.04, Double(Self.difference(end, begun)) / 90_000)
        let closed = FLVSegmenter.Run(file: run, start: UInt32(truncatingIfNeeded: begun / 90), duration: duration, discontinuity: pendingDiscontinuity)
        pendingDiscontinuity = false
        run = Data()
        return closed
    }

    // MARK: Parsing

    static let videoTypes: Set<UInt8> = [0x01, 0x02, 0x10, 0x1B, 0x24]
    static let audioTypes: Set<UInt8> = [0x03, 0x04, 0x0F, 0x11, 0x81, 0x87]

    /// A PTS minus another, across the 33-bit wrap.
    static func difference(_ a: Int64, _ b: Int64) -> Int64 {
        var value = (a - b) & ((1 << 33) - 1)
        if value >= 1 << 32 { value -= 1 << 33 }
        return value
    }

    /// The section a payload starting with a pointer field holds.
    private static func section(_ payload: Data) -> Data? {
        guard let pointer = payload.first else { return nil }
        let start = payload.startIndex + 1 + Int(pointer)
        guard start + 3 <= payload.endIndex else { return nil }
        let length = Int(payload[start + 1] & 0x0F) << 8 | Int(payload[start + 2])
        return Data(payload[start..<min(payload.endIndex, start + 3 + length)])
    }

    /// The PMT's PID, from the PAT: the first program that isn't the network one.
    static func programMap(_ payload: Data) -> Int? {
        guard let section = section(payload), section.count >= 12, section[0] == 0x00 else { return nil }
        var index = 8
        while index + 4 <= section.count - 4 {
            let program = Int(section[index]) << 8 | Int(section[index + 1])
            let pid = Int(section[index + 2] & 0x1F) << 8 | Int(section[index + 3])
            if program != 0 { return pid }
            index += 4
        }
        return nil
    }

    /// The elementary streams a PMT lists: their stream types and PIDs.
    static func streams(_ payload: Data) -> [(type: UInt8, pid: Int)]? {
        guard let section = section(payload), section.count >= 16, section[0] == 0x02 else { return nil }
        let info = Int(section[10] & 0x0F) << 8 | Int(section[11])
        var index = 12 + info
        var result: [(type: UInt8, pid: Int)] = []
        while index + 5 <= section.count - 4 {
            let type = section[index]
            let pid = Int(section[index + 1] & 0x1F) << 8 | Int(section[index + 2])
            let length = Int(section[index + 3] & 0x0F) << 8 | Int(section[index + 4])
            result.append((type, pid))
            index += 5 + length
        }
        return result
    }

    /// The PTS of a PES that starts in this payload.
    static func pts(_ payload: Data) -> Int64? {
        let p = payload.startIndex
        guard payload.count >= 14, payload[p] == 0, payload[p + 1] == 0, payload[p + 2] == 1, payload[p + 7] & 0x80 != 0 else { return nil }
        let b = (9...13).map { Int64(payload[p + $0]) }
        return (b[0] >> 1 & 0x07) << 30 | b[1] << 22 | (b[2] >> 1) << 15 | b[3] << 7 | b[4] >> 1
    }

    /// Whether the first bytes of a picture's PES hold an IDR (or IRAP) picture or the parameter sets before one.
    static func keyframe(_ payload: Data, hevc: Bool) -> Bool {
        let p = payload.startIndex
        guard payload.count > 9 else { return false }
        var index = p + 9 + Int(payload[p + 8])
        while index + 3 < payload.endIndex {
            if payload[index] == 0, payload[index + 1] == 0, payload[index + 2] == 1 {
                let header = payload[index + 3]
                if hevc {
                    let type = (header >> 1) & 0x3F
                    if (16...21).contains(type) || (32...34).contains(type) { return true }
                } else {
                    let type = header & 0x1F
                    if type == 5 || type == 7 { return true }
                }
                index += 3
            } else {
                index += 1
            }
        }
        return false
    }
}

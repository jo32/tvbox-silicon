import Foundation
import CommonCrypto
import TVMedia

/// HLS whose MPEG-TS segments carry HEVC. AVPlayer plays their sound and drops the picture without an error (HLS
/// carries HEVC only in fragmented MP4), so such a stream opens again here (#292). Each segment is repackaged on its
/// own into fragmented MP4 when AVPlayer asks for it, video and audio copied as they are, and served from the
/// repackager's loopback server under the playlist's own durations and discontinuities. AES-128 keys are applied
/// here. A live stream's playlist is read again as AVPlayer reloads the repackaged one, which then lists the same
/// segments (an IPTV channel in 4K, #361). An HDR picture is tone mapped to SDR on a device that doesn't show HDR
/// now, as a repackaged file's is: AVPlayer refuses its HDR variant there (#345).
public enum HLSRemux {
    /// Opens the stream behind `url` (a master or media playlist) and returns the address of its repackaged master
    /// playlist. Throws when its first segment isn't MPEG-TS carrying HEVC, or the playlist is one this doesn't handle.
    public static func open(_ url: URL, headers: [String: String]) async throws -> URL {
        try await open(url, headers: headers, network: HLSRemuxSession.network, device: RemuxSession.device())
    }

    static func open(_ url: URL, headers: [String: String], network: URLSession, device: RemuxPlan.Device = .init()) async throws -> URL {
        let session = try await HLSRemuxSession.make(url, headers: headers, network: network, device: device)
        RemuxStore.shared.add(session)
        do {
            let base = try await RemuxServer.shared.base()
            return base.appending(path: "\(session.id)/master.m3u8")
        } catch {
            RemuxStore.shared.remove(session.id)?.close()
            throw error
        }
    }

    struct Segment: Equatable {
        struct Key: Equatable { var url: URL; var iv: Data? }
        var url: URL
        var duration: Double
        var key: Key?
        /// Its media sequence number, the IV of a key that names none.
        var sequence: Int
        /// The segment begins a discontinuity (not counted before the first one).
        var discontinuity: Bool
    }

    /// A media playlist's segments; nil for one this doesn't handle: already fragmented MP4, byte ranges, or a key
    /// other than AES-128.
    static func segments(_ text: String, base: URL) -> [Segment]? {
        var result: [Segment] = []
        var sequence = 0, duration: Double?, key: Segment.Key?, discontinuity = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                sequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count).trimmingCharacters(in: .whitespaces)) ?? 0
            } else if line.hasPrefix("#EXTINF:") {
                duration = Double(line.dropFirst("#EXTINF:".count).prefix { $0 != "," }.trimmingCharacters(in: .whitespaces))
            } else if line == "#EXT-X-DISCONTINUITY" {
                discontinuity = true
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let fields = HLS.attributes(String(line.dropFirst("#EXT-X-KEY:".count)))
                switch fields["METHOD"] {
                case nil, "NONE": key = nil
                case "AES-128":
                    guard let uri = fields["URI"], let url = URL(string: uri, relativeTo: base)?.absoluteURL else { return nil }
                    key = Segment.Key(url: url, iv: fields["IV"].flatMap(Self.hex))
                default: return nil
                }
            } else if line.hasPrefix("#EXT-X-MAP:") || line.hasPrefix("#EXT-X-BYTERANGE:") {
                return nil
            } else if !line.hasPrefix("#") {
                guard let url = URL(string: line, relativeTo: base)?.absoluteURL else { return nil }
                result.append(Segment(url: url, duration: duration ?? 0, key: key, sequence: sequence + result.count,
                                      discontinuity: discontinuity && !result.isEmpty))
                duration = nil; discontinuity = false
            }
        }
        return result.isEmpty ? nil : result
    }

    /// A playlist's EXT-X-TARGETDURATION, in whole seconds.
    static func targetDuration(_ text: String) -> Int? {
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("#EXT-X-TARGETDURATION:") else { continue }
            return Double(line.dropFirst("#EXT-X-TARGETDURATION:".count).trimmingCharacters(in: .whitespaces)).map { Int($0.rounded(.up)) }
        }
        return nil
    }

    /// The bytes of an IV attribute (`0x` and 32 hex digits).
    static func hex(_ text: String) -> Data? {
        var digits = Substring(text)
        if digits.hasPrefix("0x") || digits.hasPrefix("0X") { digits = digits.dropFirst(2) }
        guard !digits.isEmpty, digits.count <= 32 else { return nil }
        let padded = String(repeating: "0", count: 32 - digits.count) + digits
        var bytes: [UInt8] = []
        var index = padded.startIndex
        while index < padded.endIndex {
            let next = padded.index(index, offsetBy: 2)
            guard let byte = UInt8(padded[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    /// The IV of a segment whose key names none: its media sequence number, big-endian.
    static func iv(_ sequence: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        var value = UInt64(max(sequence, 0))
        for index in (8..<16).reversed() { bytes[index] = UInt8(value & 0xFF); value >>= 8 }
        return Data(bytes)
    }

    static func decrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else { throw TVError.unsupported("AES-128 key") }
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { bytes in
                key.withUnsafeBytes { key in
                    iv.withUnsafeBytes { iv in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                key.baseAddress, kCCKeySizeAES128, iv.baseAddress, bytes.baseAddress, data.count,
                                out.baseAddress, capacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw TVError.unsupported("AES-128 decryption failed") }
        return output.prefix(moved)
    }

    /// One segment repackaged: each track's initialization segment and fragments (0 video, 1 audio).
    struct Output: Sendable {
        var format = ""
        /// The source's picture codec, and the one the segments carry (`hevc` or `h264` once tone mapped).
        var video = "", picture = "", toneMapped = false
        var audio: String?, audioProfile = 0
        var width = 0, height = 0, transfer = 0
        var bytes = 0
        var initializations: [Int: Data] = [:]
        var media: [Int: Data] = [:]
    }

    /// Repackages one segment's bytes: the picture (H.264 or HEVC) and the first audio, copied when Apple devices
    /// decode it, else converted to AAC. An HDR picture is tone mapped to SDR when `device` shows no HDR. Times
    /// stay the segment's own, so segments line up as they did.
    static func repackage(_ data: Data, device: RemuxPlan.Device = .init()) throws -> Output {
        RemuxSession.installLog()
        let memory = MemoryMedia(data)
        let context = Unmanaged.passUnretained(memory).toOpaque()
        var error = [CChar](repeating: 0, count: 256)
        guard let input = tvm_open(context, memoryRead, memoryInterrupted, Int64(data.count), &error, Int32(error.count)) else {
            throw TVError.unsupported(message(error))
        }
        defer { tvm_close(input) }
        var output = Output(format: String(cString: tvm_format(input)), bytes: data.count)
        var video: TVMTrack?, audio: TVMTrack?
        for index in 0..<tvm_stream_count(input) {
            var raw = TVMStream()
            guard tvm_stream(input, index, &raw) == 0 else { continue }
            let codec = withUnsafeBytes(of: raw.codec) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if raw.kind == Int32(TVMKindVideo), video == nil, raw.width > 0, ["h264", "hevc"].contains(codec) {
                let stream = RemuxSession.stream(raw, index: Int(index))
                let mapped = RemuxPlan.videoTrack(stream, device: device)
                let track = mapped.toneMap ? mapped : RemuxPlan.Track(stream: stream)
                video = TVMTrack(stream: index, mode: track.mode.rawValue, bitRate: Int32(track.bitRate), channels: 0,
                                 dolbyVision: Int32(TVMDolbyVisionDrop), toneMap: track.toneMap ? 1 : 0,
                                 width: Int32(track.width), height: Int32(track.height))
                output.video = codec
                output.picture = track.mode == .copy ? codec : track.mode == .hevc ? "hevc" : "h264"
                output.toneMapped = track.toneMap
                output.width = track.width > 0 ? track.width : Int(raw.width)
                output.height = track.height > 0 ? track.height : Int(raw.height)
                // BT.709 once tone mapped.
                output.transfer = track.toneMap ? 1 : Int(raw.colorTransfer)
            } else if raw.kind == Int32(TVMKindAudio), audio == nil, raw.channels > 0 {
                let copy = ["aac", "ac3", "eac3"].contains(codec)
                audio = TVMTrack(stream: index, mode: Int32(copy ? TVMModeCopy : TVMModeAAC), bitRate: 192_000,
                                 channels: raw.channels >= 6 ? 6 : raw.channels == 1 ? 1 : 2, dolbyVision: 0, toneMap: 0, width: 0, height: 0)
                output.audio = copy ? codec : "aac"
                output.audioProfile = copy ? Int(raw.profile) : 1
            }
        }
        guard let video else { throw TVError.unsupported("no H.264 or HEVC picture in \(output.format)") }
        var tracks = [video] + (audio.map { [$0] } ?? [])
        guard let cursor = tvm_cursor_create(input, &tracks, Int32(tracks.count), RemuxSession.offset) else {
            throw TVError.unsupported("remux cursor")
        }
        defer { tvm_cursor_free(cursor) }
        for track in tracks.indices {
            guard tvm_cursor_init(cursor, Int32(track), context, memoryWrite, &error, Int32(error.count)) >= 0 else {
                throw TVError.unsupported("track \(track): \(message(error))")
            }
            output.initializations[track] = memory.take(track)
        }
        let active = [UInt8](repeating: 1, count: tracks.count)
        let status = active.withUnsafeBufferPointer { active in
            tvm_cursor_segment(cursor, tvm_start_time(input), -1, active.baseAddress, context, memoryWrite, nil, &error, Int32(error.count))
        }
        guard status >= 0 else { throw TVError.unsupported("segment: \(message(error))") }
        for track in tracks.indices { output.media[track] = memory.take(track) }
        return output
    }

    private static func message(_ error: [CChar]) -> String {
        String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// One HLS stream played through `HLSRemux`. Segments are made as AVPlayer asks for them, the next one ahead, and
/// the last few are kept for both tracks' requests. A segment is named by its position: its place in a VOD
/// playlist, or in the order a live one listed it, so a live stream's names stay put as its playlist moves on.
final class HLSRemuxSession: RemuxStored, @unchecked Sendable {
    static let network: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()
    static let kept = 6

    let id = UUID().uuidString.lowercased()
    /// The playlist has no end: it is read again as AVPlayer reloads the repackaged one (#361).
    let live: Bool
    /// Whether HDR plays here (`RemuxSession.device`), decided once so that every segment matches the first.
    let device: RemuxPlan.Device
    /// The picture is HDR, copied as it is.
    private(set) var copiesHDR = false
    private(set) var master = ""
    /// The media playlist, read again while the stream is live.
    private let source: URL
    private let headers: [String: String]
    private let network: URLSession
    private let lock = NSLock()
    /// The segments the playlist lists now, the first at position `first`.
    private var listed: [HLSRemux.Segment]
    private var first = 0
    /// For each listed segment, the position of the one beginning its discontinuity, which names its
    /// initialization segment.
    private var runs: [Int]
    /// Discontinuities that left a live playlist (its EXT-X-DISCONTINUITY-SEQUENCE).
    private var discontinuities = 0
    /// Each listed discontinuity's initialization segments by track, kept so that a live one's outlast its segments.
    private var initializations: [Int: [Int: Data]] = [:]
    private var tracks = [0]
    private var target: Int
    private var refreshed = Date()
    private var refreshing: Task<Void, Never>?
    private var made: [Int: Task<HLSRemux.Output, Error>] = [:]
    private var order: [Int] = []
    private var keys: [URL: Task<Data, Error>] = [:]
    private var closed = false

    private init(segments: [HLSRemux.Segment], source: URL, live: Bool, target: Int, headers: [String: String],
                 network: URLSession, device: RemuxPlan.Device) {
        listed = segments; runs = Self.runs(segments, start: 0, run: 0)
        self.source = source; self.live = live; self.target = target
        self.headers = headers; self.network = network; self.device = device
    }

    /// Reads the playlist (the variant with the highest bandwidth of a master one) and repackages one segment, which
    /// must be MPEG-TS carrying HEVC: a VOD stream's first, a live one's newest.
    static func make(_ url: URL, headers: [String: String], network: URLSession, device: RemuxPlan.Device) async throws -> HLSRemuxSession {
        let began = Date()
        var source = url
        var (text, address) = try await playlist(url, headers: headers, network: network)
        if text.contains("#EXT-X-STREAM-INF") {
            guard let variant = HLS.variants(text, base: address).max(by: { $0.bandwidth < $1.bandwidth }) else {
                throw TVError.unsupported("no variant")
            }
            source = variant.url
            (text, address) = try await playlist(source, headers: headers, network: network)
        }
        guard let segments = HLSRemux.segments(text, base: address) else { throw TVError.unsupported("playlist not repackaged") }
        let live = !text.contains("#EXT-X-ENDLIST")
        let target = max(1, HLSRemux.targetDuration(text) ?? 0, Int((segments.map(\.duration).max() ?? 1).rounded(.up)))
        let session = HLSRemuxSession(segments: segments, source: source, live: live, target: target, headers: headers,
                                      network: network, device: device)
        let probe = live ? segments.count - 1 : 0
        let first: HLSRemux.Output
        do { first = try await session.output(probe) } catch { session.close(); throw error }
        guard first.format == "mpegts", first.video == "hevc" else {
            session.close()
            throw TVError.unsupported("not HEVC in MPEG-TS: \(first.format) \(first.video)")
        }
        session.describe(first, at: probe)
        Diagnostics.shared.record(.info, "remux", "hls open host=\(address.host() ?? "-") segments=\(segments.count) live=\(live) audio=\(first.audio ?? "-") size=\(first.width)x\(first.height) transfer=\(first.transfer) hdr=\(device.hdr) sdr=\(first.toneMapped) discontinuities=\(segments.filter(\.discontinuity).count) ms=\(Int(Date().timeIntervalSince(began) * 1000))")
        return session
    }

    /// The playlist's text, and the address it came from after redirects, which its relative addresses follow.
    private static func playlist(_ url: URL, headers: [String: String], network: URLSession) async throws -> (String, URL) {
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await network.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else { throw TVError.http(status) }
        guard Transfer.isPlaylist(data) else { throw TVError.unsupported("not a playlist") }
        return (String(decoding: data, as: UTF8.self), response.url ?? url)
    }

    /// The master playlist, from the segment at `position`, whose initialization segments are kept for its discontinuity.
    private func describe(_ first: HLSRemux.Output, at position: Int) {
        let audio = first.media[1] != nil
        copiesHDR = first.transfer == 16 || first.transfer == 18
        let (seconds, discontinuous) = lock.withLock { () -> (Double, Bool) in
            tracks = audio ? [0, 1] : [0]
            initializations[runs[position - self.first]] = first.initializations
            return (listed[position - self.first].duration, listed.contains(where: \.discontinuity))
        }
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7"]
        if audio {
            lines.append("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"Audio\",DEFAULT=YES,AUTOSELECT=YES,URI=\"1.m3u8\"")
        }
        var attributes = ["BANDWIDTH=\(seconds > 0 ? Int(Double(first.bytes) * 8 / seconds * 1.5) : 8_000_000)"]
        // Codecs are named only when one picture runs throughout: an inserted advert can bring another.
        if !discontinuous, let codecs = codecs(first) { attributes.append("CODECS=\"\(codecs)\"") }
        if first.width > 0 { attributes.append("RESOLUTION=\(first.width)x\(first.height)") }
        if first.transfer == 16 || first.transfer == 18 { attributes.append("VIDEO-RANGE=\(first.transfer == 16 ? "PQ" : "HLG")") }
        if audio { attributes.append("AUDIO=\"audio\"") }
        lines.append("#EXT-X-STREAM-INF:" + attributes.joined(separator: ","))
        lines.append("0.m3u8")
        master = lines.joined(separator: "\n") + "\n"
    }

    private func codecs(_ first: HLSRemux.Output) -> String? {
        guard let initialization = first.initializations[0] else { return nil }
        let video = first.picture == "hevc" ? RemuxPlan.box("hvcC", in: initialization).flatMap { RemuxPlan.hevcCodec($0) }
            : RemuxPlan.box("avcC", in: initialization).flatMap(RemuxPlan.avcCodec)
        guard let video else { return nil }
        guard let audio = first.audio else { return video }
        let name: String? = switch audio {
        case "aac": first.audioProfile == 4 ? "mp4a.40.5" : first.audioProfile == 28 ? "mp4a.40.29" : "mp4a.40.2"
        case "ac3": "ac-3"
        case "eac3": "ec-3"
        default: nil
        }
        return name.map { "\(video),\($0)" }
    }

    /// A track's media playlist: the source's durations and discontinuities, each discontinuity with its own
    /// initialization segment (an inserted advert can differ in size or codec). A live one is read again first.
    func playlist(_ track: Int) async -> String? {
        if live { await refresh() }
        return lock.withLock { () -> String? in
            guard tracks.contains(track) else { return nil }
            var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(target)", "#EXT-X-MEDIA-SEQUENCE:\(first)"]
            lines.append(live ? "#EXT-X-DISCONTINUITY-SEQUENCE:\(discontinuities)" : "#EXT-X-PLAYLIST-TYPE:VOD")
            for (offset, segment) in listed.enumerated() {
                if segment.discontinuity { lines.append("#EXT-X-DISCONTINUITY") }
                if offset == 0 || segment.discontinuity { lines.append("#EXT-X-MAP:URI=\"\(track)-\(runs[offset]).mp4\"") }
                lines.append(String(format: "#EXTINF:%.6f,", segment.duration))
                lines.append("\(track)-\(first + offset).m4s")
            }
            if !live { lines.append("#EXT-X-ENDLIST") }
            return lines.joined(separator: "\n") + "\n"
        }
    }

    /// Reads a live playlist again, at most twice a target duration, while AVPlayer reloads the repackaged one.
    private func refresh() async {
        let task: Task<Void, Never>? = lock.withLock {
            if let refreshing { return refreshing }
            guard !closed, Date().timeIntervalSince(refreshed) >= Double(target) / 2 else { return nil }
            let task = Task { [self] in
                do {
                    let (text, address) = try await Self.playlist(source, headers: headers, network: network)
                    if let segments = HLSRemux.segments(text, base: address) { lock.withLock { list(segments) } }
                } catch {
                    Diagnostics.shared.record(.debug, "remux", "hls playlist \(Diagnostics.describe(error))")
                }
                lock.withLock { refreshed = Date(); refreshing = nil }
            }
            refreshing = task
            return task
        }
        await task?.value
    }

    /// Lists a live playlist read again: its segments after the last one listed join (after a gap, or a count
    /// that began again, with a discontinuity), and as many old ones leave as keep the source's length. Called
    /// with the lock held.
    private func list(_ fresh: [HLSRemux.Segment]) {
        guard let last = listed.last, let oldest = listed.first, let newest = fresh.last else { return }
        var added = newest.sequence < oldest.sequence ? fresh : fresh.filter { $0.sequence > last.sequence }
        if let next = added.first, next.sequence != last.sequence + 1 { added[0].discontinuity = true }
        let start = first + listed.count
        listed += added
        runs += Self.runs(added, start: start, run: runs.last ?? start)
        let drop = max(0, listed.count - fresh.count)
        if drop > 0 {
            discontinuities += listed.prefix(drop).filter(\.discontinuity).count
            listed.removeFirst(drop); runs.removeFirst(drop); first += drop
            let current = Set(runs)
            initializations = initializations.filter { current.contains($0.key) }
        }
        if let longest = added.map(\.duration).max() { target = max(target, Int(longest.rounded(.up))) }
    }

    /// The position of the segment beginning each one's discontinuity: `run` until one of them begins another.
    private static func runs(_ segments: [HLSRemux.Segment], start: Int, run: Int) -> [Int] {
        var run = run
        return segments.indices.map { index in
            if segments[index].discontinuity { run = start + index }
            return run
        }
    }

    func close() {
        let running: [Task<HLSRemux.Output, Error>] = lock.withLock {
            closed = true
            refreshing?.cancel()
            defer { made = [:]; order = []; keys = [:] }
            return Array(made.values)
        }
        running.forEach { $0.cancel() }
    }

    /// The initialization segment of `track` for the discontinuity that begins at segment `index`: any of its
    /// segments' (they match), kept once made.
    func initialization(track: Int, index: Int) async throws -> Data {
        let (cached, member) = lock.withLock { () -> ([Int: Data]?, Int?) in
            if let cached = initializations[index] { return (cached, nil) }
            let members = runs.indices.filter { runs[$0] == index }.map { first + $0 }
            return (nil, members.first { made[$0] != nil } ?? members.first)
        }
        var outputs = cached
        if outputs == nil {
            guard let member else { throw TVError.unsupported("no such initialization") }
            let fresh = try await output(member).initializations
            lock.withLock { if runs.contains(index) { initializations[index] = fresh } }
            outputs = fresh
        }
        guard let data = outputs?[track] else { throw TVError.unsupported("segment \(index) has no track \(track)") }
        return data
    }

    func segment(track: Int, index: Int) async throws -> Data {
        lock.withLock { if !closed, segment(at: index + 1) != nil { _ = try? start(index + 1) } }
        guard let data = try await output(index).media[track] else { throw TVError.unsupported("segment \(index) has no track \(track)") }
        return data
    }

    func output(_ index: Int) async throws -> HLSRemux.Output {
        let task = try lock.withLock { () throws -> Task<HLSRemux.Output, Error> in
            if closed { throw CancellationError() }
            return try start(index)
        }
        return try await task.value
    }

    /// The listed segment at `position`. Called with the lock held.
    private func segment(at position: Int) -> HLSRemux.Segment? {
        listed.indices.contains(position - first) ? listed[position - first] : nil
    }

    /// The segment's repackaging, started now unless it already is. Called with the lock held.
    private func start(_ index: Int) throws -> Task<HLSRemux.Output, Error> {
        order.removeAll { $0 == index }
        if let task = made[index] { order.append(index); return task }
        guard let segment = segment(at: index) else { throw TVError.unsupported("no such segment") }
        order.append(index)
        let task = Task { [self] in
            do { return try await make(segment) }
            catch {
                // Made again when AVPlayer asks again.
                lock.withLock { _ = made.removeValue(forKey: index); order.removeAll { $0 == index } }
                if !(error is CancellationError) { Diagnostics.shared.failure("remux", "hls segment=\(index)", error) }
                throw error
            }
        }
        made[index] = task
        while order.count > Self.kept { made.removeValue(forKey: order.removeFirst()) }
        return task
    }

    private func make(_ segment: HLSRemux.Segment) async throws -> HLSRemux.Output {
        var data = try await fetch(segment.url)
        if let key = segment.key {
            data = try HLSRemux.decrypt(data, key: try await keyData(key.url), iv: key.iv ?? HLSRemux.iv(segment.sequence))
        }
        try Task.checkCancellation()
        return try HLSRemux.repackage(MediaPayload.transportStream(data), device: device)
    }

    private func keyData(_ url: URL) async throws -> Data {
        let task: Task<Data, Error> = lock.withLock {
            if let task = keys[url] { return task }
            let task = Task { [self] in try await fetch(url) }
            keys[url] = task
            return task
        }
        do { return try await task.value }
        catch {
            lock.withLock { _ = keys.removeValue(forKey: url) }
            throw error
        }
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await network.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else { throw TVError.http(status) }
        return data
    }
}

/// A segment's bytes in memory for FFmpeg, and what it writes for each track.
private final class MemoryMedia {
    let data: Data
    var written: [Int: Data] = [:]
    init(_ data: Data) { self.data = data }
    func take(_ track: Int) -> Data {
        defer { written[track] = nil }
        return written[track] ?? Data()
    }
}

private func memory(_ context: UnsafeMutableRawPointer?) -> MemoryMedia {
    Unmanaged<MemoryMedia>.fromOpaque(context!).takeUnretainedValue()
}

private let memoryRead: TVMReadFunction = { context, offset, buffer, size in
    let media = memory(context)
    guard let buffer, offset >= 0, offset < Int64(media.data.count), size > 0 else { return 0 }
    let count = min(Int(size), media.data.count - Int(offset))
    media.data.withUnsafeBytes { bytes in
        buffer.update(from: bytes.baseAddress!.advanced(by: Int(offset)).assumingMemoryBound(to: UInt8.self), count: count)
    }
    return Int32(count)
}
private let memoryInterrupted: TVMInterruptFunction = { _ in 0 }
private let memoryWrite: TVMWriteFunction = { context, track, bytes, size in
    guard let bytes, size > 0 else { return }
    memory(context).written[Int(track), default: Data()].append(bytes, count: Int(size))
}

import Foundation
import TVMedia
import AVFoundation
import VideoToolbox

/// The bytes of a file being repackaged for AVPlayer.
public protocol RemuxSource: Sendable {
    var length: Int64 { get }
    /// Up to `count` bytes at `offset` (fewer is fine, none only at the end).
    func read(at offset: Int64, count: Int) async throws -> Data
    /// Bytes received so far and from where, for the player's speed readout; nil for a local file.
    var transfer: (received: Int64, host: String?)? { get }
    func close() async
}

/// One file played through the repackager. FFmpeg runs on a thread of its own, which reads through `source`,
/// writes segments as AVPlayer asks for them, and goes on to the next one while it is idle. Playing through
/// reads the file once, front to back: each segment continues where the last stopped. A segment nobody waits
/// for any more (AVPlayer moved on after a seek) is abandoned for the one that is wanted.
final class RemuxSession: @unchecked Sendable {
    /// Added to every output time, so audio priming and reordered video never start before zero.
    static let offset: Int64 = 10_000_000
    let id = UUID().uuidString.lowercased()
    let source: RemuxSource
    private(set) var plan: RemuxPlan!
    private(set) var master = ""
    private(set) var playlists: [Int: String] = [:]
    private(set) var initializations: [Int: Data] = [:]
    private(set) var format = ""
    /// The cues of the subtitle files added after the file's own tracks, by track.
    private var external: [Int: [RemuxPlan.Cue]] = [:]
    private var codecs: [Int: String] = [:]
    private var startTime: Int64 = 0

    private let condition = NSCondition()
    private var segments: [Key: RemuxSegment] = [:]
    /// When AVPlayer last asked for each audio track: the one it plays is produced along with the picture.
    private var asked: [Int: Date] = [:]
    private var latest = 0
    private var producing: Int?
    private var abandon = false
    private var closed = false
    private var produced: Int?
    private let budget: Int

    private struct Key: Hashable { var track: Int, segment: Int }

    init(source: RemuxSource) {
        self.source = source
        budget = Int(min(max(ProcessInfo.processInfo.physicalMemory / 24, 96 << 20), 384 << 20))
    }

    /// Reads the file's streams and index, decides the plan and makes the initialization segments.
    func open() async throws {
        RemuxSession.installLog()
        let ready = OneShot<Void>()
        let thread = Thread { [self] in run(ready) }
        thread.name = "tvbox.remux"
        thread.stackSize = 4 << 20
        thread.qualityOfService = .userInitiated
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ready.set(continuation)
                thread.start()
            }
        } onCancel: { close() }
    }

    func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    /// Adds subtitle files as subtitles of the stream, before it is served. Their cues count from the start
    /// of the picture, which is where the file's clock starts.
    func add(_ files: [SubtitleFile.Track]) {
        guard !files.isEmpty else { return }
        condition.lock()
        defer { condition.unlock() }
        let start = startTime
        for (track, file) in zip(plan.addSubtitles(files), files) {
            external[track] = file.cues.map { RemuxPlan.Cue(start: $0.start + start, end: $0.end + start, text: $0.text) }
            playlists[track] = plan.mediaPlaylist(track: track)
        }
        master = plan.masterPlaylist(codecs: codecs, supplemental: initializations[0].flatMap(plan.supplementalCodec))
        Diagnostics.shared.record(.info, "remux", "subtitle files=\(files.count) cues=\(files.map(\.cues.count))")
    }

    /// The segment's bytes as they are written. The caller reads it and then calls `leave`.
    func segment(track: Int, index: Int) -> RemuxSegment? {
        guard let plan, plan.tracks.indices.contains(track), (0..<plan.segments).contains(index), plan.tracks[track].kind != .other else { return nil }
        condition.lock()
        defer { condition.unlock() }
        // A subtitle file's segment is made from its cues at once; FFmpeg has no part in it.
        if let cues = external[track] {
            let segment = RemuxSegment()
            segment.join()
            segment.append(Data(RemuxPlan.webVTT(plan.cues(cues, segment: index), offset: Self.offset).utf8))
            segment.finish()
            return segment
        }
        let key = Key(track: track, segment: index)
        let segment: RemuxSegment
        if let existing = segments[key], existing.state != .failed { segment = existing }
        else { segment = RemuxSegment(); segments[key] = segment }
        segment.join()
        if plan.tracks[track].kind == .audio { asked[track] = Date() }
        latest = index
        // A segment no one waits for gives way to this one.
        if let producing, producing != index, !segments.contains(where: { $0.key.segment == producing && $0.value.readers > 0 }) { abandon = true }
        condition.broadcast()
        return segment
    }

    func leave(_ segment: RemuxSegment) {
        condition.lock()
        segment.leave()
        condition.broadcast()
        condition.unlock()
    }

    // MARK: - The FFmpeg thread

    private var input: OpaquePointer?
    private var cursor: OpaquePointer?
    private var writing: [Int: RemuxSegment] = [:]
    private var cues: [Int: [RemuxPlan.Cue]] = [:]
    private var interrupted: Bool {
        condition.lock(); defer { condition.unlock() }
        return closed || abandon
    }

    private func run(_ ready: OneShot<Void>) {
        do {
            try start()
            ready.resume(.success(()))
        } catch {
            ready.resume(.failure(error))
            finishRun()
            return
        }
        while let job = nextJob() { produce(job) }
        finishRun()
    }

    private func finishRun() {
        if let cursor { tvm_cursor_free(cursor) }
        if let input { tvm_close(input) }
        cursor = nil; input = nil
        condition.lock()
        for segment in segments.values where segment.state != .done { segment.fail() }
        segments.removeAll()
        condition.unlock()
        let source = source
        Task { await source.close() }
    }

    private var context: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    private func start() throws {
        let began = Date()
        var error = [CChar](repeating: 0, count: 256)
        guard let input = tvm_open(context, remuxRead, remuxInterrupted, source.length, &error, Int32(error.count)) else {
            throw TVError.unsupported(Self.message(error))
        }
        self.input = input
        format = String(cString: tvm_format(input))
        var streams: [RemuxPlan.Stream] = []
        var video: Int32 = -1
        for index in 0..<tvm_stream_count(input) {
            var raw = TVMStream()
            guard tvm_stream(input, index, &raw) == 0 else { continue }
            let stream = Self.stream(raw, index: Int(index))
            if stream.kind == .video, video < 0, stream.width > 0 { video = index }
            streams.append(stream)
        }
        var keyframes: [Int64] = []
        if video >= 0 {
            let count = tvm_keyframes(input, video, nil, 0)
            if count > 0 {
                keyframes = [Int64](repeating: 0, count: Int(count))
                _ = tvm_keyframes(input, video, &keyframes, count)
            }
        }
        var device = RemuxPlan.Device(hevc: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC),
                                      av1: VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1),
                                      hevcEncoder: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC),
                                      hdr: AVPlayer.eligibleForHDRPlayback && !Remux.refusesHDR && !Remux.screenCaptured)
        #if !os(macOS)
        // An Apple TV or iPhone tone maps a 4K picture too slowly to keep up; one that shows no HDR gets 1080p.
        device.toneMapWidth = 1920
        device.toneMapHeight = 1080
        #endif
        guard let plan = RemuxPlan.make(streams: streams, keyframes: keyframes, start: tvm_start_time(input), duration: tvm_duration(input),
                                        size: source.length, device: device) else {
            throw TVError.unsupported(L10n.text("This media cannot be played. Try another channel or source."))
        }
        self.plan = plan
        var tracks = plan.tracks.map { track in
            TVMTrack(stream: Int32(track.stream.index), mode: track.mode.rawValue, bitRate: Int32(track.bitRate),
                     channels: Int32(track.channels), dolbyVision: track.dolbyVision.rawValue, toneMap: track.toneMap ? 1 : 0,
                     width: Int32(track.width), height: Int32(track.height))
        }
        guard let cursor = tvm_cursor_create(input, &tracks, Int32(tracks.count), Self.offset) else { throw TVError.unsupported("remux cursor") }
        self.cursor = cursor
        startTime = tvm_start_time(input)
        for (index, track) in plan.tracks.enumerated() where track.kind == .video || track.kind == .audio {
            let segment = RemuxSegment()
            writing = [index: segment]
            let status = tvm_cursor_init(cursor, Int32(index), context, remuxWrite, &error, Int32(error.count))
            writing = [:]
            guard status >= 0 else { throw TVError.unsupported("\(track.stream.codec): \(Self.message(error))") }
            let data = segment.bytes
            initializations[index] = data
            codecs[index] = plan.codec(track: index, initialization: data)
        }
        master = plan.masterPlaylist(codecs: codecs, supplemental: initializations[0].flatMap(plan.supplementalCodec))
        for index in plan.tracks.indices where plan.tracks[index].kind != .other { playlists[index] = plan.mediaPlaylist(track: index) }
        let summary = plan.tracks.map { "\($0.stream.codec)\($0.mode == .copy ? "" : ">\($0.mode)")\($0.toneMap ? "(sdr)" : "")" }.joined(separator: ",")
        Diagnostics.shared.record(.info, "remux", "open format=\(format) tracks=\(summary) segments=\(plan.segments) keyframes=\(keyframes.count) size=\(source.length) transfer=\(plan.tracks[0].stream.colorTransfer) hdr=\(device.hdr) ms=\(Int(Date().timeIntervalSince(began) * 1000))")
    }

    private struct Job { var segment: Int, active: [UInt8] }

    /// The oldest segment someone waits for, else the one after the last made while AVPlayer is close behind.
    private func nextJob() -> Job? {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if closed { return nil }
            abandon = false
            let waited = segments.filter { $0.value.state == .waiting && $0.value.readers > 0 }.min { $0.value.created < $1.value.created }?.key.segment
            var index = waited
            if index == nil, let produced, produced + 1 < plan.segments, produced + 1 <= latest + 1, storedBytes < budget { index = produced + 1 }
            if let index {
                if let job = job(index) { producing = index; return job }
                continue
            }
            condition.wait()
        }
    }

    private var storedBytes: Int { segments.values.reduce(0) { $0 + $1.count } }

    /// The tracks a segment is made for: those asked for, the picture, the audio AVPlayer plays, the subtitles
    /// (which cost nothing). Tracks it already has are left out.
    private func job(_ index: Int) -> Job? {
        var active = [UInt8](repeating: 0, count: plan.tracks.count)
        let recent = asked.filter { Date().timeIntervalSince($0.value) < 30 }.map(\.key)
        let audio = recent.isEmpty ? [plan.defaultAudio].compactMap { $0 } : recent
        writing = [:]
        for (track, kind) in plan.tracks.map(\.kind).enumerated() where external[track] == nil {
            let key = Key(track: track, segment: index)
            let existing = segments[key]
            let wanted = existing?.readers ?? 0 > 0 || kind == .video || kind == .subtitle || audio.contains(track)
            guard wanted, existing == nil || existing?.state == .waiting || existing?.state == .failed else { continue }
            let segment = existing?.state == .waiting ? existing! : RemuxSegment()
            segment.state = .producing
            segments[key] = segment
            writing[track] = segment
            active[track] = 1
        }
        guard !writing.isEmpty else {
            if produced == nil || index > produced! { produced = index }
            return nil
        }
        return Job(segment: index, active: active)
    }

    private func produce(_ job: Job) {
        let index = job.segment
        let start = plan.bounds[index], end = index + 1 == plan.segments ? -1 : plan.bounds[index + 1]
        cues = [:]
        var error = [CChar](repeating: 0, count: 256)
        let began = Date()
        let status = job.active.withUnsafeBufferPointer { active in
            tvm_cursor_segment(cursor, start, end, active.baseAddress, context, remuxWrite, remuxCue, &error, Int32(error.count))
        }
        condition.lock()
        let gaveWay = abandon || closed
        producing = nil
        for (track, segment) in writing {
            let key = Key(track: track, segment: index)
            if status >= 0 {
                if plan.tracks[track].kind == .subtitle {
                    segment.append(Data(RemuxPlan.webVTT(cues[track] ?? [], offset: Self.offset).utf8))
                }
                segment.finish()
            } else if gaveWay {
                // Made again from the start when someone asks for it.
                segment.fail()
                segments[key] = nil
            } else {
                segment.fail()
            }
        }
        writing = [:]
        // A segment that fails is not tried again until AVPlayer asks for it again.
        if !gaveWay { produced = index }
        evict()
        condition.unlock()
        if status < 0, !gaveWay {
            Diagnostics.shared.record(.error, "remux", "segment=\(index) format=\(format) \(Self.message(error)) status=\(status)")
        } else if status >= 0 {
            Diagnostics.shared.record(.debug, "remux", "segment=\(index) tracks=\(job.active.enumerated().filter { $0.element == 1 }.map(\.offset)) ms=\(Int(Date().timeIntervalSince(began) * 1000))")
        }
    }

    /// Keeps the segments near where AVPlayer reads within the memory budget; read ones go first.
    private func evict() {
        var total = storedBytes
        guard total > budget else { return }
        let candidates = segments.filter { $0.value.state == .done && $0.value.readers == 0 }
            .sorted { ($0.value.served ? 0 : 1, -abs($0.key.segment - latest)) < ($1.value.served ? 0 : 1, -abs($1.key.segment - latest)) }
        for (key, segment) in candidates where total > budget {
            total -= segment.count
            segments[key] = nil
        }
    }

    // MARK: - Callbacks from FFmpeg

    fileprivate func read(at offset: Int64, into buffer: UnsafeMutablePointer<UInt8>, size: Int) -> Int32 {
        if offset >= source.length { return 0 }
        let result = ReadResult()
        let done = DispatchSemaphore(value: 0)
        let source = source
        let task = Task {
            do { result.data = try await source.read(at: offset, count: size) } catch { result.error = error }
            done.signal()
        }
        while done.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
            if interrupted { task.cancel(); return -1 }
        }
        guard let data = result.data, !data.isEmpty else {
            if let error = result.error, !interrupted, !(error is CancellationError) {
                Diagnostics.shared.failure("remux", "read offset=\(offset)", error)
            }
            return result.error == nil ? 0 : -1
        }
        let count = min(size, data.count)
        data.copyBytes(to: buffer, count: count)
        return Int32(count)
    }

    fileprivate func write(track: Int, bytes: UnsafePointer<UInt8>, size: Int) {
        writing[track]?.append(Data(bytes: bytes, count: size))
    }

    fileprivate func cue(track: Int, start: Int64, end: Int64, text: Data) {
        guard let value = RemuxPlan.cueText(text, codec: plan.tracks[track].stream.codec) else { return }
        cues[track, default: []].append(RemuxPlan.Cue(start: start, end: end > start ? end : start + 4_000_000, text: value))
    }

    fileprivate var isInterrupted: Bool { interrupted }

    // MARK: -

    private static func message(_ error: [CChar]) -> String {
        String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func stream(_ raw: TVMStream, index: Int) -> RemuxPlan.Stream {
        func text<T>(_ value: T) -> String {
            withUnsafeBytes(of: value) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
        let kind: RemuxPlan.Stream.Kind = switch raw.kind {
        case Int32(TVMKindVideo): .video
        case Int32(TVMKindAudio): .audio
        case Int32(TVMKindSubtitle): .subtitle
        default: .other
        }
        return RemuxPlan.Stream(index: index, kind: kind, codec: text(raw.codec), profile: Int(raw.profile), level: Int(raw.level),
                                width: Int(raw.width), height: Int(raw.height), bitDepth: Int(raw.bitDepth), chroma: Int(raw.chroma),
                                frameRate: raw.frameRate, colorTransfer: Int(raw.colorTransfer), doviProfile: Int(raw.doviProfile),
                                doviCompatibility: Int(raw.doviCompatibility), sampleRate: Int(raw.sampleRate), channels: Int(raw.channels),
                                bitRate: raw.bitRate, language: text(raw.language), title: text(raw.title),
                                isDefault: raw.isDefault != 0, isForced: raw.isForced != 0, isText: raw.isText != 0)
    }

    private static let logOnce: Void = {
        tvm_set_log { level, message in
            guard let message else { return }
            Diagnostics.shared.record(level <= 16 ? .warning : .debug, "remux", "ffmpeg \(String(cString: message))")
        }
    }()
    private static func installLog() { _ = logOnce }
}

private final class ReadResult: @unchecked Sendable {
    var data: Data?
    var error: Error?
}

private func session(_ context: UnsafeMutableRawPointer?) -> RemuxSession {
    Unmanaged<RemuxSession>.fromOpaque(context!).takeUnretainedValue()
}

private let remuxRead: TVMReadFunction = { context, offset, buffer, size in
    session(context).read(at: offset, into: buffer!, size: Int(size))
}
private let remuxInterrupted: TVMInterruptFunction = { context in session(context).isInterrupted ? 1 : 0 }
private let remuxWrite: TVMWriteFunction = { context, track, bytes, size in
    guard let bytes, size > 0 else { return }
    session(context).write(track: Int(track), bytes: bytes, size: Int(size))
}
private let remuxCue: TVMCueFunction = { context, track, start, end, text, size in
    guard let text, size > 0 else { return }
    session(context).cue(track: Int(track), start: start, end: end, text: Data(bytes: text, count: Int(size)))
}

/// One track's segment: its bytes as they are written, and the requests that read them.
final class RemuxSegment: @unchecked Sendable {
    enum State { case waiting, producing, done, failed }
    private let lock = NSLock()
    private var data = Data()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var _state = State.waiting
    private var _readers = 0
    private var _served = false
    let created = Date()

    var state: State {
        get { lock.withLock { _state } }
        set { lock.withLock { _state = newValue } }
    }
    var readers: Int { lock.withLock { _readers } }
    var served: Bool { lock.withLock { _served } }
    var count: Int { lock.withLock { data.count } }
    var bytes: Data { lock.withLock { data } }

    func join() { lock.withLock { _readers += 1 } }
    func leave() { lock.withLock { _readers -= 1 } }

    func append(_ bytes: Data) { wake { data.append(bytes) } }
    func finish() { wake { _state = .done } }
    func fail() { wake { _state = .failed } }
    /// Wakes the readers, so one whose request was cancelled can stop.
    func poke() { wake {} }

    private func wake(_ change: () -> Void) {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            change()
            defer { waiters.removeAll() }
            return waiters
        }
        for waiter in waiting { waiter.resume() }
    }

    /// The bytes after `offset` once there are any; nil at the end. Throws when the segment failed.
    func next(after offset: Int, cancelled: @Sendable () -> Bool) async throws -> Data? {
        while true {
            if cancelled() { throw CancellationError() }
            enum Step { case bytes(Data), end, failed, wait }
            let step: Step = lock.withLock {
                if data.count > offset { return .bytes(data.subdata(in: offset..<data.count)) }
                switch _state {
                case .done: _served = true; return .end
                case .failed: return .failed
                default: return .wait
                }
            }
            switch step {
            case .bytes(let bytes): return bytes
            case .end: return nil
            case .failed: throw TVError.unsupported("segment failed")
            case .wait:
                await withCheckedContinuation { continuation in
                    let ready = lock.withLock { () -> Bool in
                        if data.count > offset || _state == .done || _state == .failed { return true }
                        waiters.append(continuation)
                        return false
                    }
                    if ready { continuation.resume() }
                }
            }
        }
    }
}

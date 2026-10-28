import Foundation
import TVMedia
import VideoToolbox

/// Keeps an HDR video in MKV as a plain MP4, its picture, sound and text subtitles copied as they are, for
/// AVPlayer to open by itself: it shows HDR as HDR, or tone maps it on a display without. Through the
/// repackager the same file is HLS, and AVPlayer refuses an HDR picture in HLS where it isn't shown as HDR
/// (an Apple TV refuses it even when it says it can). The repackager then converts the picture while it
/// plays, which a 4K picture outruns on an Apple TV (10–19 s for each 5 s segment): the player never starts.
/// Used for downloads, which are on the device whole.
public enum Rewrap {
    struct Selection: Sendable, Equatable {
        /// What the MP4 holds: the picture first, then the sound, then the text subtitles.
        var streams: [RemuxPlan.Stream]
        var dolbyVision: RemuxPlan.DolbyVision
        /// What it leaves out: sound no Apple device decodes inside MP4, picture subtitles.
        var dropped: [RemuxPlan.Stream]
    }

    /// What goes into the MP4, or nil when the file plays as well through the repackager: an SDR picture, one
    /// an MP4 can't hold or the device doesn't decode, or no sound left.
    static func select(_ streams: [RemuxPlan.Stream], hevc: Bool) -> Selection? {
        guard let video = streams.first(where: { $0.kind == .video && $0.width > 0 && $0.height > 0 }),
              [16, 18].contains(video.colorTransfer), video.doviProfile != 5,
              video.codec == "hevc", hevc, video.bitDepth <= 10, video.chroma == 420 || video.chroma == 0 else { return nil }
        let audio = streams.filter { $0.kind == .audio && $0.channels > 0 }
        let kept = audio.filter { RemuxPlan.audioTrack($0).mode == .copy }
        guard audio.isEmpty || !kept.isEmpty else { return nil }
        let text = streams.filter { $0.kind == .subtitle && $0.isText }
        let dropped = audio.filter { !kept.contains($0) } + streams.filter { $0.kind == .subtitle && !$0.isText }
        // Profile 8 keeps its Dolby Vision configuration on an HDR10 picture, as in the repackager.
        return Selection(streams: [video] + kept + text, dolbyVision: video.doviProfile == 8 ? .hvc1 : .drop, dropped: dropped)
    }

    /// Writes `source` as an MP4 at `target` when the MP4 plays it better, on a thread of its own; returns what
    /// it copied, or nil when the file is better left as it is. `progress` gets 0...1. Cancelling stops it.
    static func run(_ source: URL, to target: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Selection? {
        let state = RewrapState(progress: progress)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let thread = Thread { continuation.resume(with: Result { try write(source, to: target, state: state) }) }
                thread.name = "tvbox.rewrap"
                thread.stackSize = 4 << 20
                thread.qualityOfService = .utility
                thread.start()
            }
        } onCancel: { state.cancel() }
    }

    /// Whether `run` would write an MP4 for the file, without writing it.
    static func needed(_ source: URL) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result {
                    var error = [CChar](repeating: 0, count: 256)
                    guard let input = tvm_open_file(source.path, &error, Int32(error.count)) else { throw TVError.unsupported(message(error)) }
                    defer { tvm_close(input) }
                    return selection(input) != nil
                })
            }
        }
    }

    /// `run` for TVBoxProbe: what it copied and left out, or nil when it wrote nothing.
    public static func probe(_ source: URL, to target: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> String? {
        try await run(source, to: target, progress: progress).map { selection in
            "copied \(selection.streams.map { "\($0.codec)\($0.language.isEmpty ? "" : ":\($0.language)")" }) dropped \(selection.dropped.map(\.codec))"
        }
    }

    private static func selection(_ input: OpaquePointer) -> Selection? {
        let streams = (0..<tvm_stream_count(input)).compactMap { index -> RemuxPlan.Stream? in
            var raw = TVMStream()
            return tvm_stream(input, index, &raw) == 0 ? RemuxSession.stream(raw, index: Int(index)) : nil
        }
        #if targetEnvironment(simulator)
        // A simulator reports no HEVC decoder of its own, yet AVPlayer plays HEVC there through the Mac's.
        return select(streams, hevc: true)
        #else
        return select(streams, hevc: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC))
        #endif
    }

    private static func write(_ source: URL, to target: URL, state: RewrapState) throws -> Selection? {
        var error = [CChar](repeating: 0, count: 256)
        guard let input = tvm_open_file(source.path, &error, Int32(error.count)) else { throw TVError.unsupported(message(error)) }
        defer { tvm_close(input) }
        guard let selection = selection(input) else { return nil }
        state.codecs = selection.streams.map(\.codec)
        state.size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let indices = selection.streams.map { Int32($0.index) }
        let context = Unmanaged.passUnretained(state).toOpaque()
        let status = indices.withUnsafeBufferPointer { streams in
            tvm_rewrap(input, streams.baseAddress, Int32(streams.count), selection.dolbyVision.rawValue, target.path, context,
                       rewrapText, rewrapProgress, &error, Int32(error.count))
        }
        if state.cancelled { throw CancellationError() }
        guard status >= 0 else { throw TVError.unsupported(message(error)) }
        return selection
    }

    /// A subtitle event's words without markup, as tx3g shows them.
    static func plainText(_ data: Data, codec: String) -> String? {
        guard let text = RemuxPlan.cueText(data, codec: codec) else { return nil }
        let plain = text.replacing(/<[^>]*>/, with: "")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
        return plain.isEmpty ? nil : plain
    }

    private static func message(_ error: [CChar]) -> String {
        String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// What the FFmpeg thread reads while it writes: the subtitle codecs, the file's size, whether to stop.
private final class RewrapState: @unchecked Sendable {
    let progress: @Sendable (Double) -> Void
    var codecs: [String] = []
    var size: Int64 = 0
    private var reported = -1
    private let lock = NSLock()
    private var stopped = false
    init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }
    var cancelled: Bool { lock.withLock { stopped } }
    func cancel() { lock.withLock { stopped = true } }
    /// Tells `progress` each whole percent once.
    func reached(_ position: Int64) {
        guard size > 0 else { return }
        let percent = Int(min(100, position * 100 / size))
        guard percent != reported else { return }
        reported = percent
        progress(Double(percent) / 100)
    }
}

private func rewrapState(_ context: UnsafeMutableRawPointer?) -> RewrapState {
    Unmanaged<RewrapState>.fromOpaque(context!).takeUnretainedValue()
}

private let rewrapText: TVMTextFunction = { context, track, text, size, out, capacity in
    let state = rewrapState(context)
    guard let text, let out, size > 0, state.codecs.indices.contains(Int(track)),
          let plain = Rewrap.plainText(Data(bytes: text, count: Int(size)), codec: state.codecs[Int(track)]) else { return 0 }
    // Cut at a character's end, within what tx3g's 16-bit length and the buffer hold.
    var bytes = Array(plain.utf8)
    if bytes.count > Int(capacity) {
        var end = Int(capacity)
        while end > 0, bytes[end] & 0xC0 == 0x80 { end -= 1 }
        bytes = Array(bytes[..<end])
    }
    guard !bytes.isEmpty else { return 0 }
    bytes.withUnsafeBufferPointer { out.update(from: $0.baseAddress!, count: $0.count) }
    return Int32(bytes.count)
}

private let rewrapProgress: TVMProgressFunction = { context, position in
    let state = rewrapState(context)
    state.reached(position)
    return state.cancelled ? 1 : 0
}

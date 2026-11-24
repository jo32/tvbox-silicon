import AVFoundation
import CoreGraphics
import VideoToolbox

/// The frame above the seek bar's handle for a stream (#1600). `AVAssetImageGenerator` makes frames from files only;
/// for HLS a second reader of the same stream, never played, seeks to where the finger is and hands over one frame.
public enum ScrubPreview {
    /// How far apart a stream's frames are asked for: about 240 across the video, 2 to 10 seconds. Each one is a
    /// segment to fetch, and a finger's smallest move on a film's bar is seconds anyway.
    public static func step(duration: Double) -> Double {
        guard duration.isFinite, duration > 0 else { return 2 }
        return min(10, max(2, duration / 240))
    }

    /// `seconds` on the stream's grid of frames, so a finger that barely moves asks for nothing new.
    public static func snapped(_ seconds: Double, duration: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        let step = step(duration: duration)
        let value = (max(0, seconds) / step).rounded() * step
        return duration.isFinite && duration > 0 ? min(value, duration) : value
    }

    /// Whether a second reader may open the stream at `url`: a web address, a download's local playlist or a DASH
    /// stream's playlists. Not what the repackager serves (`repackaged`), which makes each part for one reader as it
    /// plays, nor a drive's or a decrypted file, whose read-ahead belongs to the playing video.
    public static func reads(_ url: URL, repackaged: Bool) -> Bool {
        guard !repackaged, let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == DashStreams.scheme
    }

    /// Whether a drag from `old` to `new` earns a tick: it crossed the start of a chapter, or reached either end.
    public static func ticks(from old: Double, to new: Double, marks: [Double], duration: Double) -> Bool {
        guard old.isFinite, new.isFinite, duration.isFinite, duration > 0, old != new else { return false }
        if new <= 0, old > 0 { return true }
        if new >= duration, old < duration { return true }
        return marks.contains { $0 > 0 && $0 < duration && (old < $0) != (new < $0) }
    }
}

/// A stream's second reader: an item on the playing video's own asset, so its headers and its playlist loader are
/// the same ones, held to the smallest picture the stream offers, muted and never played. One seek at a time.
@MainActor public final class StreamPreviewReader {
    /// The stream gave no frame: nothing more is asked of it.
    public private(set) var failed = false
    private let player = AVPlayer()
    private let item: AVPlayerItem
    private let output: AVPlayerItemVideoOutput
    private var delivered = false

    public init(asset: AVAsset) {
        item = AVPlayerItem(asset: asset)
        // The lowest variant: one frame 160 points wide needs no more, and its segments are the smallest.
        item.preferredPeakBitRate = 200_000
        item.preferredPeakBitRateForExpensiveNetworks = 200_000
        item.preferredMaximumResolution = CGSize(width: 480, height: 270)
        item.preferredMaximumResolutionForExpensiveNetworks = CGSize(width: 480, height: 270)
        item.preferredForwardBufferDuration = 1
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        player.isMuted = true
        player.allowsExternalPlayback = false
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .pause
        player.replaceCurrentItem(with: item)
    }

    /// The frame nearest `seconds`, no wider than `width` pixels; nil when there is none (see `failed`).
    public func frame(at seconds: Double, width: Int = 320) async -> CGImage? {
        guard !failed, await ready() else { failed = true; return nil }
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        // A keyframe nearby is good enough and quick: the one before, as a segment starts with one.
        guard await player.seek(to: time, toleranceBefore: CMTime(seconds: 6, preferredTimescale: 600),
                                toleranceAfter: CMTime(seconds: 2, preferredTimescale: 600)) else { return nil }
        for _ in 0..<(delivered ? 80 : 160) {
            if item.status == .failed { failed = true; return nil }
            let now = item.currentTime()
            if output.hasNewPixelBuffer(forItemTime: now), let buffer = output.copyPixelBuffer(forItemTime: now, itemTimeForDisplay: nil) {
                delivered = true
                return Self.image(buffer, width: width)
            }
            try? await Task.sleep(for: .milliseconds(25))
            if Task.isCancelled { return nil }
        }
        // Nothing in four seconds on its first try (two afterwards): a stream this reader can't follow.
        failed = true
        return nil
    }

    public func stop() {
        player.replaceCurrentItem(with: nil)
        item.remove(output)
    }

    private func ready() async -> Bool {
        for _ in 0..<320 where item.status == .unknown {
            try? await Task.sleep(for: .milliseconds(25))
            if Task.isCancelled { return false }
        }
        return item.status == .readyToPlay
    }

    /// The buffer drawn small: a single-variant 4K stream's frame is 33 MB as it comes.
    private static func image(_ buffer: CVPixelBuffer, width: Int) -> CGImage? {
        var full: CGImage?
        VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &full)
        guard let full, full.width > width else { return full }
        let height = max(1, Int((Double(full.height) * Double(width) / Double(full.width)).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return full }
        context.interpolationQuality = .medium
        context.draw(full, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? full
    }
}

import CoreGraphics
import Foundation
import TVMedia

/// A bitmap subtitle track (Blu-ray PGS, DVD VobSub) of a repackaged file (#576 M3). AVPlayer can't show these, so
/// the repackager offers each as an empty WebVTT rendition to choose it by, decodes its packets as it reads them,
/// and keeps the pictures here for the player to draw over the video. Safe to use from any thread.
public final class BitmapSubtitleTrack: @unchecked Sendable {
    public struct Picture: @unchecked Sendable {
        /// Where it goes on the cue's canvas, in the canvas's pixels.
        public let rect: CGRect
        public let image: CGImage
    }
    public struct Cue: @unchecked Sendable {
        /// Microseconds of the item's clock. `end` is nil until the stream says; the next cue ends it.
        public let start: Int64
        public let end: Int64?
        /// The frame the pictures are placed on: the stream's (PGS's presentation size, VobSub's), else the video's.
        public let canvas: CGSize
        /// None for a cue that clears the screen.
        public let pictures: [Picture]
        var bytes: Int { pictures.reduce(64) { $0 + Int($1.rect.width * $1.rect.height) * 4 } }
    }

    /// The rendition's NAME in the master playlist.
    public let name: String
    /// Its place among the stream's subtitle renditions, in the master playlist's order.
    public let position: Int
    /// The video's size, for a stream that names no canvas.
    public let videoSize: CGSize
    /// A cue with no known end shows at most this long.
    static let longest: Int64 = 10_000_000
    /// Pictures beyond this are let go from the earliest; a segment made again brings them back.
    static let budget = 96 << 20
    private let lock = NSLock()
    private var cues: [Cue] = []
    private var bytes = 0

    public init(name: String, position: Int = 0, videoSize: CGSize) {
        self.name = name; self.position = position; self.videoSize = videoSize
    }

    public var count: Int { lock.withLock { cues.count } }

    /// Keeps a cue in time order. A segment made again repeats its cues: kept once.
    public func add(_ cue: Cue) {
        lock.withLock {
            let index = cues.firstIndex { $0.start >= cue.start } ?? cues.count
            if index < cues.count, cues[index].start == cue.start { return }
            cues.insert(cue, at: index)
            bytes += cue.bytes
            while bytes > Self.budget, cues.count > 1 {
                bytes -= cues.removeFirst().bytes
            }
        }
    }

    /// The cues on screen at `time`, by start: a cue lasts to its end, else to the next cue, else `longest`.
    public func cues(at time: Int64) -> [Cue] {
        lock.withLock {
            let after = cues.firstIndex { $0.start > time } ?? cues.count
            var showing: [Cue] = []
            for index in cues[..<after].indices.reversed() {
                let cue = cues[index]
                let next = index + 1 < cues.count ? cues[index + 1].start : nil
                let end = cue.end ?? min(next ?? .max, cue.start + Self.longest)
                if time < end, !cue.pictures.isEmpty { showing.insert(cue, at: 0) }
                // A cue with no end of its own is over once another starts: nothing before it still shows.
                if cue.end == nil { break }
            }
            return showing
        }
    }

    /// A decoded packet, on the item's clock (`offset` is the file's start time).
    func add(_ subtitle: TVMBitmapSubtitle, offset: Int64) {
        var subtitle = subtitle
        let canvas = subtitle.canvasWidth > 0 && subtitle.canvasHeight > 0
            ? CGSize(width: Int(subtitle.canvasWidth), height: Int(subtitle.canvasHeight)) : videoSize
        let pictures = withUnsafeBytes(of: &subtitle.rects) { raw in
            raw.bindMemory(to: TVMBitmapRect.self).prefix(Int(subtitle.count)).compactMap { rect -> Picture? in
                guard let pixels = rect.pixels, let image = Self.image(pixels, width: Int(rect.width), height: Int(rect.height)) else { return nil }
                return Picture(rect: CGRect(x: Int(rect.x), y: Int(rect.y), width: Int(rect.width), height: Int(rect.height)), image: image)
            }
        }
        add(Cue(start: subtitle.start - offset, end: subtitle.end >= 0 ? subtitle.end - offset : nil, canvas: canvas, pictures: pictures))
    }

    static func image(_ pixels: UnsafePointer<UInt8>, width: Int, height: Int) -> CGImage? {
        let data = Data(bytes: pixels, count: width * height * 4) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Draws a bitmap subtitle track: the pictures on screen at a moment, as one image on their canvas, which the
/// overlay stretches over the video's rect. Draws only when the cues on screen change.
public final class BitmapSubtitleRenderer: StyledSubtitleSource, @unchecked Sendable {
    private let track: BitmapSubtitleTrack
    private let lock = NSLock()
    private var shown: [Int64]?

    public init(track: BitmapSubtitleTrack) { self.track = track }

    public func render(at time: Int64, size: CGSize, video: CGSize) -> StyledSubtitleFrame? {
        let cues = track.cues(at: time)
        let starts = cues.map(\.start)
        let changed = lock.withLock { () -> Bool in
            guard starts != shown else { return false }
            shown = starts
            return true
        }
        guard changed else { return nil }
        let canvas = cues.last?.canvas ?? track.videoSize
        let pictures = cues.flatMap(\.pictures)
        guard let first = pictures.first, canvas.width > 0, canvas.height > 0 else {
            return StyledSubtitleFrame(image: nil, rect: .zero, size: canvas)
        }
        let union = pictures.dropFirst().reduce(first.rect) { $0.union($1.rect) }
        if pictures.count == 1 { return StyledSubtitleFrame(image: first.image, rect: union, size: canvas) }
        guard let context = CGContext(data: nil, width: Int(union.width), height: Int(union.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        for picture in pictures {
            // Core Graphics counts from the bottom.
            let rect = CGRect(x: picture.rect.minX - union.minX, y: union.maxY - picture.rect.maxY, width: picture.rect.width, height: picture.rect.height)
            context.draw(picture.image, in: rect)
        }
        return StyledSubtitleFrame(image: context.makeImage(), rect: union, size: canvas)
    }
}

extension Remux {
    /// The bitmap subtitle tracks of the file repackaged at `url`, which the player draws itself while one is chosen.
    public static func bitmapSubtitles(_ url: URL) -> [BitmapSubtitleTrack] { session(url)?.bitmapSubtitles ?? [] }
}

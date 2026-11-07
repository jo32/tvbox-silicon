import CoreGraphics
import Foundation
import TVMedia

/// What a styled subtitle renderer drew for one moment (#576 M3): an image over `rect` of a frame `size` pixels big,
/// or nothing (`image` nil).
public struct StyledSubtitleFrame: @unchecked Sendable, Equatable {
    public let image: CGImage?
    /// Pixels of the frame the image covers.
    public let rect: CGRect
    /// The frame it was drawn for, in pixels.
    public let size: CGSize

    public init(image: CGImage?, rect: CGRect, size: CGSize) { self.image = image; self.rect = rect; self.size = size }
    public static func == (lhs: StyledSubtitleFrame, rhs: StyledSubtitleFrame) -> Bool {
        lhs.image === rhs.image && lhs.rect == rhs.rect && lhs.size == rhs.size
    }
}

/// Subtitles the app draws as pictures rather than lines of text: ASS/SSA through libass, and bitmap subtitles.
public protocol StyledSubtitleSource: AnyObject, Sendable {
    /// What shows at `time` (microseconds of the subtitle's clock) on a frame `size` pixels big that shows a picture
    /// `video` pixels big. Nil when it is the same as what the last call returned, so nothing needs drawing again.
    func render(at time: Int64, size: CGSize, video: CGSize) -> StyledSubtitleFrame?
}

/// A font a Matroska file carries for its subtitles.
public struct StyledSubtitleFont: Sendable, Equatable {
    public let name: String
    public let data: Data
    public init(name: String, data: Data) { self.name = name; self.data = data }

    /// Whether an attachment (its codec, file name and MIME type) is a font.
    static func isFont(codec: String, name: String, mime: String) -> Bool {
        if ["ttf", "otf"].contains(codec) { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        if ["ttf", "otf", "ttc", "otc"].contains(ext) { return true }
        let mime = mime.lowercased()
        return mime.hasPrefix("font/") || mime.contains("truetype") || mime.contains("opentype") || mime.contains("font-sfnt")
    }
}

/// A Matroska file's ASS/SSA track as the repackager reads it: its header, the file's fonts, and its events, which
/// arrive segment by segment ahead of the picture (`RemuxSession`). Times are microseconds of the player item's clock.
public final class StyledSubtitleEvents: @unchecked Sendable {
    public struct Event: Sendable, Equatable {
        /// The Matroska event: ReadOrder, Layer, Style, Name, MarginL, MarginR, MarginV, Effect, Text.
        public let data: Data
        public let start: Int64, end: Int64
    }
    /// The track's name in the master playlist, which AVPlayer's subtitle option shows as its `displayName`.
    public let name: String
    /// Its place among the stream's subtitle renditions, in the master playlist's order.
    public let position: Int
    public let header: Data
    public let fonts: [StyledSubtitleFont]
    /// Kept events stop growing past this many bytes (a film's are a few hundred KB; karaoke-heavy ones a few MB).
    static let budget = 24 << 20
    private let lock = NSLock()
    private var events: [Event] = []
    private var seen: Set<Int> = []
    private var bytes = 0

    public init(name: String, position: Int = 0, header: Data, fonts: [StyledSubtitleFont]) {
        self.name = name; self.position = position; self.header = header; self.fonts = fonts
    }

    /// An event, unless the same ReadOrder came already (a segment made again after a seek repeats its events).
    func add(_ data: Data, start: Int64, end: Int64) {
        let order = Self.readOrder(data)
        lock.withLock {
            guard bytes + data.count <= Self.budget else { return }
            if let order { guard seen.insert(order).inserted else { return } }
            events.append(Event(data: data, start: start, end: end))
            bytes += data.count
        }
    }

    public var count: Int { lock.withLock { events.count } }

    /// The events after the first `index`.
    public func events(from index: Int) -> [Event] {
        lock.withLock { index < events.count ? Array(events[index...]) : [] }
    }

    static func readOrder(_ data: Data) -> Int? {
        guard let comma = data.firstIndex(of: UInt8(ascii: ",")) else { return nil }
        return Int(String(decoding: data[data.startIndex..<comma], as: UTF8.self).trimmingCharacters(in: .whitespaces))
    }
}

/// ASS/SSA drawn by libass (FreeType, HarfBuzz, FriBidi; the system's fonts through CoreText and a file's own): its
/// fonts, positions, outlines, shadows, rotations, drawings and karaoke. Safe to use from any thread; draws one
/// frame at a time.
public final class ASSRenderer: StyledSubtitleSource, @unchecked Sendable {
    private let lock = NSLock()
    private let renderer: OpaquePointer
    private let track: StyledSubtitleEvents?
    private var consumed = 0

    /// Whether libass starts here; without it, ASS shows as plain lines.
    public static let isAvailable: Bool = {
        guard let renderer = tvs_ass_create() else { return false }
        tvs_ass_free(renderer)
        return true
    }()

    /// A whole ASS/SSA file, as text.
    public init?(script: String, fonts: [StyledSubtitleFont] = []) {
        guard let renderer = tvs_ass_create() else { return nil }
        Self.add(fonts, to: renderer)
        var bytes = Array(script.utf8)
        guard !bytes.isEmpty, bytes.withUnsafeMutableBufferPointer({ buffer in
            buffer.withMemoryRebound(to: CChar.self) { tvs_ass_load(renderer, $0.baseAddress, Int32($0.count)) }
        }) == 0, tvs_ass_event_count(renderer) > 0 else {
            tvs_ass_free(renderer)
            return nil
        }
        self.renderer = renderer
        track = nil
    }

    /// A Matroska track, whose events it takes as they arrive.
    public init?(track: StyledSubtitleEvents) {
        guard let renderer = tvs_ass_create() else { return nil }
        Self.add(track.fonts, to: renderer)
        let status = track.header.withUnsafeBytes { raw in
            tvs_ass_begin(renderer, raw.bindMemory(to: CChar.self).baseAddress, Int32(raw.count))
        }
        guard status == 0 else { tvs_ass_free(renderer); return nil }
        self.renderer = renderer
        self.track = track
    }

    deinit { tvs_ass_free(renderer) }

    /// The events it has, for tests and diagnostics.
    public var eventCount: Int { lock.withLock { Int(tvs_ass_event_count(renderer)) } }

    public func render(at time: Int64, size: CGSize, video: CGSize) -> StyledSubtitleFrame? {
        lock.withLock {
            if let track {
                let events = track.events(from: consumed)
                consumed += events.count
                for event in events {
                    event.data.withUnsafeBytes { raw in
                        tvs_ass_event(renderer, raw.bindMemory(to: CChar.self).baseAddress, Int32(raw.count),
                                      event.start / 1_000, max(1, (event.end - event.start) / 1_000))
                    }
                }
            }
            var image = TVSImage()
            let width = Int32(size.width.rounded()), height = Int32(size.height.rounded())
            let status = tvs_ass_render(renderer, time / 1_000, width, height, Int32(video.width.rounded()), Int32(video.height.rounded()), &image)
            guard status == 1 else { return nil }
            let frame = CGSize(width: Int(width), height: Int(height))
            guard image.width > 0, image.height > 0, let pixels = image.pixels else { return StyledSubtitleFrame(image: nil, rect: .zero, size: frame) }
            let picture = Self.image(pixels, width: Int(image.width), height: Int(image.height), stride: Int(image.stride))
            return StyledSubtitleFrame(image: picture, rect: CGRect(x: Int(image.x), y: Int(image.y), width: Int(image.width), height: Int(image.height)), size: frame)
        }
    }

    private static func add(_ fonts: [StyledSubtitleFont], to renderer: OpaquePointer) {
        for font in fonts {
            font.data.withUnsafeBytes { raw in
                tvs_ass_add_font(renderer, font.name, raw.bindMemory(to: UInt8.self).baseAddress, Int32(raw.count))
            }
        }
    }

    /// Premultiplied BGRA pixels as an image of their own (the renderer reuses its buffer).
    static func image(_ pixels: UnsafePointer<UInt8>, width: Int, height: Int, stride: Int) -> CGImage? {
        let data = Data(bytes: pixels, count: stride * height)
        guard let provider = CGDataProvider(data: data as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride, space: space,
                       bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

extension SubtitleDocument {
    /// An ASS/SSA file's whole text, for libass; nil for other formats.
    public var styledScript: String? {
        guard format.isStyled else { return nil }
        return SubtitleFile.text(data, encoding: encoding)
    }
}

extension Remux {
    /// The ASS/SSA tracks of the file repackaged at `url`, which the player draws itself while one is chosen.
    public static func styledSubtitles(_ url: URL) -> [StyledSubtitleEvents] { session(url)?.styledSubtitles ?? [] }
}

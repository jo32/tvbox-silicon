import CoreGraphics
import Foundation
import Testing
@testable import TVCore

/// Bitmap subtitles (PGS, VobSub) the player draws itself (#576 M3).
@Suite struct BitmapSubtitleTests {
    @Test func bitmapTracksJoinThePlanOnlyWhenThePlayerDrawsThem() throws {
        typealias Stream = RemuxPlan.Stream
        let streams = [Stream(index: 0, kind: .video, codec: "h264", width: 1920, height: 1080, frameRate: 24),
                       Stream(index: 1, kind: .subtitle, codec: "subrip", language: "eng", isText: true),
                       Stream(index: 2, kind: .subtitle, codec: "hdmv_pgs_subtitle", language: "chi", title: "Blu-ray"),
                       Stream(index: 3, kind: .subtitle, codec: "dvd_subtitle", language: "jpn"),
                       Stream(index: 4, kind: .subtitle, codec: "dvb_subtitle", language: "ger")]
        let plain = try #require(RemuxPlan.make(streams: streams, keyframes: [0], start: 0, duration: 10_000_000, size: 1 << 20, device: .init()))
        #expect(plain.tracks.map(\.stream.index) == [0, 1])
        var device = RemuxPlan.Device()
        device.bitmapSubtitles = true
        let drawn = try #require(RemuxPlan.make(streams: streams, keyframes: [0], start: 0, duration: 10_000_000, size: 1 << 20, device: device))
        #expect(drawn.tracks.map(\.stream.index) == [0, 1, 2, 3])
        let master = drawn.masterPlaylist(codecs: [:])
        #expect(master.contains(#"NAME="Blu-ray",LANGUAGE="zh""#) && master.contains(#"URI="3.m3u8""#))
        // Translation twins are made from text only.
        #expect(SubtitleTranslation.sources(drawn.tracks, detected: [:], target: .init(identifier: "en")).isEmpty)
    }

    @Test func pgsPlacementUsesAuthoredCoordinatesAndKeepsTheWholeCueVisible() {
        let source = CGSize(width: 1920, height: 1080)
        // The one rectangle includes the gap between the Chinese and English lines.
        let frame = StyledSubtitleFrame(image: nil, rect: CGRect(x: 480, y: 120, width: 800, height: 160),
                                        size: source, fitsCanvas: true)
        let video = CGRect(x: -100, y: 58, width: 1200, height: 400)
        let viewport = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let area = video.intersection(viewport)
        let original = PGSSubtitleStyle().imageRect(for: frame, in: CGRect(origin: .zero, size: source),
                                                    visible: CGRect(origin: .zero, size: source))
        #expect(original == frame.rect)
        let normal = PGSSubtitleStyle().imageRect(for: frame, in: video, visible: viewport)
        let smaller = PGSSubtitleStyle(scale: 0.5).imageRect(for: frame, in: video, visible: viewport)
        #expect(abs(smaller.midX - normal.midX) < 0.001 && abs(smaller.midY - normal.midY) < 0.001)
        #expect(abs(smaller.width * 2 - normal.width) < 0.001 && abs(smaller.height * 2 - normal.height) < 0.001)
        for x in [0.0, 1.0] {
            for y in [0.0, 1.0] {
                let rect = PGSSubtitleStyle(scale: 2, position: CGPoint(x: x, y: y)).imageRect(for: frame, in: video, visible: viewport)
                #expect(area.contains(rect))
                #expect(abs(rect.width / rect.height - 5) < 0.001)
                #expect(abs((x == 0 ? rect.minX - area.minX : rect.maxX - area.maxX)) < 0.001)
                #expect(abs((y == 0 ? rect.minY - area.minY : rect.maxY - area.maxY)) < 0.001)
            }
        }
        let full = StyledSubtitleFrame(image: nil, rect: CGRect(origin: .zero, size: source), size: source, fitsCanvas: true)
        let bounded = PGSSubtitleStyle(scale: 2).imageRect(for: full, in: video, visible: viewport)
        #expect(area.contains(bounded) && bounded.height == area.height)
        #expect(abs(bounded.width / bounded.height - source.width / source.height) < 0.001)
        #expect(PGSSubtitleStyle().imageRect(for: frame, in: video, visible: .zero) == .zero)
    }

    @Test func pgsPreferencesAreIndependentOfTextAndRestoreSourceDefaults() throws {
        let name = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var text = SubtitleStyle()
        text.size = 7
        text.save(defaults)
        #expect(PGSSubtitleStyle.load(defaults) == PGSSubtitleStyle())
        let custom = PGSSubtitleStyle(scale: 1.5, position: CGPoint(x: 0.2, y: 0.7))
        custom.save(defaults)
        #expect(PGSSubtitleStyle.load(defaults) == custom)
        PGSSubtitleStyle().save(defaults)
        #expect(PGSSubtitleStyle.load(defaults).position == nil && PGSSubtitleStyle.load(defaults).scale == 1)
        #expect(SubtitleStyle.load(defaults) == text)
    }

    @Test func cuesLastUntilTheNextOne() {
        let track = BitmapSubtitleTrack(name: "PGS", videoSize: CGSize(width: 1920, height: 1080))
        let image = BitmapSubtitleTrack.image([UInt8](repeating: 255, count: 4 * 4 * 4), width: 4, height: 4)!
        let picture = BitmapSubtitleTrack.Picture(rect: CGRect(x: 10, y: 10, width: 4, height: 4), image: image)!
        let canvas = CGSize(width: 1920, height: 1080)
        track.add(.init(start: 1_000_000, end: nil, canvas: canvas, pictures: [picture]))
        track.add(.init(start: 2_000_000, end: nil, canvas: canvas, pictures: []))
        track.add(.init(start: 1_000_000, end: nil, canvas: canvas, pictures: [picture]))
        track.add(.init(start: 30_000_000, end: nil, canvas: canvas, pictures: [picture]))
        #expect(track.count == 3)
        #expect(track.cues(at: 500_000).isEmpty)
        #expect(track.cues(at: 1_500_000).count == 1)
        #expect(track.cues(at: 2_500_000).isEmpty)
        // With nothing after it, a cue shows ten seconds at most.
        #expect(track.cues(at: 35_000_000).count == 1 && track.cues(at: 41_000_000).isEmpty)
        // VobSub says when its cues end.
        let vob = BitmapSubtitleTrack(name: "VobSub", videoSize: canvas)
        vob.add(.init(start: 1_000_000, end: 1_200_000, canvas: canvas, pictures: [picture]))
        #expect(vob.cues(at: 1_100_000).count == 1 && vob.cues(at: 1_300_000).isEmpty)
    }

    /// A line's picture: a band of white text with a black outline on a transparent box, as PGS draws it.
    private static func line(width: Int = 1200, height: Int = 90) -> Data {
        var pixels = Data(count: width * height * 4)
        for y in 30..<60 { for x in stride(from: 100, to: width - 100, by: 1) where x % 7 < 4 {
            let offset = (y * width + x) * 4
            let white: UInt8 = y > 32 && y < 58 ? 255 : 0
            pixels[offset] = white; pixels[offset + 1] = white; pixels[offset + 2] = white; pixels[offset + 3] = 255
        } }
        return pixels
    }

    @Test func picturesAreKeptSmallAndDrawnAsTheyWere() throws {
        let pixels = Self.line()
        let picture = BitmapSubtitleTrack.Picture(rect: CGRect(x: 360, y: 950, width: 1200, height: 90), pixels: pixels)
        #expect(picture.packed.count * 10 < pixels.count, "\(picture.packed.count) of \(pixels.count)")
        let image = try #require(picture.image)
        #expect(image.width == 1200 && image.height == 90)
        #expect(image.dataProvider?.data as Data? == pixels)
    }

    /// #1383: AVPlayer reads subtitle segments far ahead; their pictures must not push out the line on screen.
    @Test func picturesFarAheadGiveWayToTheLineOnScreen() {
        let canvas = CGSize(width: 1920, height: 1080)
        let picture = BitmapSubtitleTrack.Picture(rect: CGRect(x: 360, y: 950, width: 1200, height: 90), pixels: Self.line())
        let one = picture.packed.count + 64
        let track = BitmapSubtitleTrack(name: "PGS", videoSize: canvas, budget: one * 20)
        for second in 0..<10 { track.add(.init(start: Int64(second) * 5_000_000, end: nil, canvas: canvas, pictures: [picture])) }
        #expect(track.cues(at: 46_000_000).count == 1)
        // Forty lines from much later in the film arrive while the tenth line is on screen.
        for second in 0..<40 { track.add(.init(start: 3_000_000_000 + Int64(second) * 5_000_000, end: nil, canvas: canvas, pictures: [picture])) }
        #expect(track.count == 20)
        #expect(track.cues(at: 46_000_000).count == 1)
        #expect(track.cues(at: 41_000_000).count == 1)
        // Without a playhead yet, the earliest go first, as before.
        let fresh = BitmapSubtitleTrack(name: "PGS", videoSize: canvas, budget: one * 2)
        for second in 0..<3 { fresh.add(.init(start: Int64(second) * 5_000_000, end: nil, canvas: canvas, pictures: [picture])) }
        #expect(fresh.count == 2 && fresh.cues(at: 1_000_000).isEmpty)
    }

    @Test func remuxedMatroskaDecodesPGSAndVobSub() async throws {
        let file = try #require(Bundle.module.url(forResource: "remux-bitmap", withExtension: "mkv", subdirectory: "Fixtures"))
        let url = try await Remux.open(try Remux.fileSource(file))
        defer { Remux.stop(url) }
        let master = String(decoding: try await URLSession.shared.data(from: url).0, as: UTF8.self)
        #expect(master.contains(#"NAME="PGS",LANGUAGE="en""#) && master.contains(#"NAME="VobSub",LANGUAGE="ja""#))
        let tracks = Remux.bitmapSubtitles(url)
        #expect(tracks.map(\.name) == ["PGS", "VobSub"] && tracks.map(\.position) == [0, 1])
        let folder = url.deletingLastPathComponent()
        for playlist in ["1.m3u8", "2.m3u8"] {
            let text = String(decoding: try await URLSession.shared.data(from: folder.appending(path: playlist)).0, as: UTF8.self)
            for name in text.split(separator: "\n").filter({ $0.hasSuffix(".vtt") }) {
                let cues = String(decoding: try await URLSession.shared.data(from: folder.appending(path: String(name))).0, as: UTF8.self)
                #expect(cues.hasPrefix("WEBVTT") && !cues.contains("-->"), "\(name)")
            }
        }
        let pgs = try #require(tracks.first)
        // Two lines, each with the display set that clears it.
        #expect(pgs.count == 4)
        let renderer = BitmapSubtitleRenderer(track: pgs)
        let size = CGSize(width: 640, height: 360), video = CGSize(width: 192, height: 108)
        let one = try #require(renderer.render(at: 500_000, size: size, video: video))
        #expect(one.image != nil && one.size == CGSize(width: 1920, height: 1080))
        // A 1080-line subtitle canvas over cropped video: both lines keep square pixels and stay on screen.
        let cropped = CGRect(x: 0, y: 0, width: 1920, height: 800)
        let canvas = one.canvasRect(in: cropped, visible: cropped)
        #expect(abs(canvas.width / one.size.width - canvas.height / one.size.height) < 0.0001)
        #expect(cropped.contains(canvas))
        let zoom = CGRect(x: -150, y: -100, width: 2250, height: 1000)
        #expect(one.canvasRect(in: zoom, visible: cropped) == canvas)
        let original = CGRect(origin: .zero, size: one.size)
        #expect(one.canvasRect(in: original, visible: original) == original)
        #expect(one.rect.maxY > 900 && abs(one.rect.midX - 960) < 2)
        #expect(renderer.render(at: 700_000, size: size, video: video) == nil)
        let gap = try #require(renderer.render(at: 1_200_000, size: size, video: video))
        #expect(gap.image == nil)
        let two = try #require(renderer.render(at: 2_000_000, size: size, video: video))
        #expect(two.image != nil && abs(two.rect.minY - 100) < 2)
        // The picture is the white text with its black outline, premultiplied.
        let pixels = try #require(two.image?.dataProvider?.data as Data?)
        #expect(pixels.contains(255))
        let vob = try #require(tracks.last)
        #expect(vob.count >= 2)
        let vobFrame = try #require(BitmapSubtitleRenderer(track: vob).render(at: 500_000, size: size, video: video))
        #expect(vobFrame.canvasRect(in: zoom, visible: cropped) == zoom)
        #expect(vobFrame.image != nil && vobFrame.size.width > 0)
    }
}

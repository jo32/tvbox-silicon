import CoreGraphics
import Foundation
import Testing
@testable import TVCore

/// libass rendering (#576 M3): styles, positions, CJK, timing, change detection and Matroska tracks.
@Suite struct StyledSubtitleTests {
    static let script = """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 1920
    PlayResY: 1080
    ScaledBorderAndShadow: yes

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Red,Helvetica,80,&H000000FF,&H00FFFFFF,&H00000000,&H00000000,-1,0,0,0,100,100,0,0,1,0,0,2,10,10,40,1
    Style: Top,Helvetica,60,&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,3,0,8,10,10,40,1

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Dialogue: 0,0:00:01.00,0:00:03.00,Red,,0,0,0,,Hello
    Dialogue: 0,0:00:04.00,0:00:06.00,Top,,0,0,0,,{\\pos(200,200)\\an7}Corner
    Dialogue: 0,0:00:07.00,0:00:09.00,Top,,0,0,0,,{\\fad(500,500)}字幕测试 日本語
    """

    private static let frame = CGSize(width: 960, height: 540), video = CGSize(width: 1920, height: 1080)

    /// The pixel at `x`, `y` of the frame (premultiplied BGRA), or nil when the image doesn't cover it.
    private func pixel(_ frame: StyledSubtitleFrame, x: Int, y: Int) -> (blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8)? {
        guard let image = frame.image, frame.rect.contains(CGPoint(x: x, y: y)),
              let data = image.dataProvider?.data as Data? else { return nil }
        let offset = (y - Int(frame.rect.minY)) * image.bytesPerRow + (x - Int(frame.rect.minX)) * 4
        return (data[offset], data[offset + 1], data[offset + 2], data[offset + 3])
    }

    /// The most opaque pixel of the image, for its colour.
    private func strongest(_ frame: StyledSubtitleFrame) -> (blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8)? {
        guard let image = frame.image, let data = image.dataProvider?.data as Data? else { return nil }
        var best: (UInt8, UInt8, UInt8, UInt8)?
        for y in 0..<image.height {
            for x in 0..<image.width {
                let offset = y * image.bytesPerRow + x * 4
                if data[offset + 3] > (best?.3 ?? 0) { best = (data[offset], data[offset + 1], data[offset + 2], data[offset + 3]) }
            }
        }
        return best.map { (blue: $0.0, green: $0.1, red: $0.2, alpha: $0.3) }
    }

    @Test func libassStarts() {
        #expect(ASSRenderer.isAvailable)
    }

    @Test func drawsStyledLinesWhereTheScriptPutsThem() throws {
        let renderer = try #require(ASSRenderer(script: Self.script))
        #expect(renderer.eventCount == 3)
        // Before the first line: nothing (the first frame says so once), and nothing new to draw after.
        #expect(renderer.render(at: 500_000, size: Self.frame, video: Self.video)?.image == nil)
        #expect(renderer.render(at: 600_000, size: Self.frame, video: Self.video) == nil)

        let hello = try #require(renderer.render(at: 2_000_000, size: Self.frame, video: Self.video))
        #expect(hello.image != nil)
        #expect(hello.size == Self.frame)
        // Bottom centre (alignment 2, MarginV 40 of 1080 → 20 of 540), and only the line's box, not the frame.
        #expect(hello.rect.width < Self.frame.width / 2 && hello.rect.height < 80)
        #expect(abs(hello.rect.midX - Self.frame.width / 2) < 20)
        #expect(hello.rect.maxY <= Self.frame.height - 15 && hello.rect.maxY > Self.frame.height - 40)
        // Its colour is the style's: &H000000FF is red (ASS is BGR), opaque.
        let colour = try #require(strongest(hello))
        #expect(colour.red > 240 && colour.green < 15 && colour.blue < 15 && colour.alpha > 240)

        // The same moment again is no change; a moment later on the same still line isn't either.
        #expect(renderer.render(at: 2_000_000, size: Self.frame, video: Self.video) == nil)
        #expect(renderer.render(at: 2_500_000, size: Self.frame, video: Self.video) == nil)
        // A new size draws again, at the new scale.
        let big = try #require(renderer.render(at: 2_500_000, size: Self.video, video: Self.video))
        // (Glyph bitmaps carry a few pixels of padding, so the box grows a little less than twice.)
        #expect(abs(big.rect.midX - hello.rect.midX * 2) < 12 && abs(big.rect.width / hello.rect.width - 2) < 0.25, "\(big.rect) \(hello.rect)")

        // \pos(200,200) with \an7: its top left at 200,200 of 1920×1080, so 100,100 of the half-size frame.
        let corner = try #require(renderer.render(at: 5_000_000, size: Self.frame, video: Self.video))
        #expect(abs(corner.rect.minX - 100) < 6 && abs(corner.rect.minY - 100) < 8)

        // Between lines it clears once.
        let gap = try #require(renderer.render(at: 6_500_000, size: Self.frame, video: Self.video))
        #expect(gap.image == nil)
        #expect(renderer.render(at: 6_600_000, size: Self.frame, video: Self.video) == nil)
    }

    @Test func drawsChineseAndJapaneseAndFades() throws {
        let renderer = try #require(ASSRenderer(script: Self.script))
        // Half way through the fade in, then fully in: a fade is a change every frame.
        let fading = try #require(renderer.render(at: 7_250_000, size: Self.frame, video: Self.video))
        let shown = try #require(renderer.render(at: 8_000_000, size: Self.frame, video: Self.video))
        // CJK glyphs come from CoreText's fallback: the line is as wide as its eight characters at least.
        #expect(shown.rect.width > 8 * 20)
        let faded = try #require(strongest(fading)), full = try #require(strongest(shown))
        #expect(faded.alpha < full.alpha)
        #expect(full.alpha > 240)
    }

    @Test func matroskaTrackTakesEventsAsTheyCome() throws {
        let header = Self.script.components(separatedBy: "[Events]")[0] + "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
        let events = StyledSubtitleEvents(name: "Signs", header: Data(header.utf8), fonts: [])
        let renderer = try #require(ASSRenderer(track: events))
        #expect(renderer.render(at: 1_000_000, size: Self.frame, video: Self.video)?.image == nil)
        // ReadOrder, Layer, Style, Name, MarginL, MarginR, MarginV, Effect, Text.
        events.add(Data("0,0,Red,,0,0,0,,Hello".utf8), start: 1_000_000, end: 3_000_000)
        // A segment made again repeats its events: kept once.
        events.add(Data("0,0,Red,,0,0,0,,Hello".utf8), start: 1_000_000, end: 3_000_000)
        events.add(Data("1,0,Top,,0,0,0,,{\\pos(200,200)\\an7}Corner".utf8), start: 4_000_000, end: 6_000_000)
        #expect(events.count == 2)
        let hello = try #require(renderer.render(at: 2_000_000, size: Self.frame, video: Self.video))
        #expect(hello.image != nil)
        #expect(renderer.eventCount == 2)
        let corner = try #require(renderer.render(at: 5_000_000, size: Self.frame, video: Self.video))
        #expect(abs(corner.rect.minX - 100) < 6)
        #expect(StyledSubtitleEvents.readOrder(Data("12,0,Red".utf8)) == 12)
        #expect(StyledSubtitleEvents.readOrder(Data("no order".utf8)) == nil)
    }

    @Test func refusesWhatIsNotASS() {
        #expect(ASSRenderer(script: "") == nil)
        #expect(ASSRenderer(script: "1\n00:00:01,000 --> 00:00:02,000\nHi\n") == nil)
    }

    @Test func documentsKeepTheirScript() throws {
        let ass = try SubtitleDocument(id: "a.ass", name: "a.ass", data: Data(Self.script.utf8))
        #expect(ass.styledScript?.contains("[V4+ Styles]") == true)
        let srt = try SubtitleDocument(id: "a.srt", name: "a.srt", data: Data("1\n00:00:01,000 --> 00:00:02,000\nHi\n".utf8))
        #expect(srt.styledScript == nil)
    }

    @Test func attachmentsThatAreFonts() {
        #expect(StyledSubtitleFont.isFont(codec: "ttf", name: "", mime: ""))
        #expect(StyledSubtitleFont.isFont(codec: "none", name: "Font.OTF", mime: ""))
        #expect(StyledSubtitleFont.isFont(codec: "none", name: "x", mime: "application/x-truetype-font"))
        #expect(StyledSubtitleFont.isFont(codec: "none", name: "x", mime: "font/woff2"))
        #expect(!StyledSubtitleFont.isFont(codec: "mjpeg", name: "cover.jpg", mime: "image/jpeg"))
    }

    @Test func subtitleNamesMatchTheMasterPlaylist() throws {
        typealias Stream = RemuxPlan.Stream
        let streams = [Stream(index: 0, kind: .video, codec: "h264", width: 1920, height: 1080, frameRate: 24),
                       Stream(index: 1, kind: .audio, codec: "aac", profile: 1, channels: 2),
                       Stream(index: 2, kind: .subtitle, codec: "ass", language: "chi", title: "Signs", isText: true),
                       Stream(index: 3, kind: .subtitle, codec: "ass", language: "chi", title: "Signs", isText: true),
                       Stream(index: 4, kind: .subtitle, codec: "subrip", language: "eng", isText: true)]
        let plan = try #require(RemuxPlan.make(streams: streams, keyframes: [0, 5_000_000], start: 0, duration: 10_000_000, size: 1 << 20, device: .init()))
        let names = plan.subtitleNames()
        let master = plan.masterPlaylist(codecs: [:])
        #expect(names.count == 3)
        for (track, name) in names { #expect(master.contains("NAME=\"\(name)\"") && master.contains("URI=\"\(track).m3u8\"")) }
        #expect(names[2] == "Signs" && names[3] == "Signs (2)")
    }

    /// A Matroska file's ASS track through the remuxer: its raw events reach libass as the segments are made, even
    /// several that start together, and its plain lines still go to AVPlayer.
    @Test func remuxedMatroskaHandsItsEventsOver() async throws {
        let file = try #require(Bundle.module.url(forResource: "remux-ass", withExtension: "mkv", subdirectory: "Fixtures"))
        let url = try await Remux.open(try Remux.fileSource(file))
        defer { Remux.stop(url) }
        let master = String(decoding: try await URLSession.shared.data(from: url).0, as: UTF8.self)
        #expect(master.contains(#"TYPE=SUBTITLES,GROUP-ID="subtitles",NAME="Signs""#))
        let track = try #require(Remux.styledSubtitles(url).first)
        #expect(track.name == "Signs" && track.position == 0 && String(decoding: track.header, as: UTF8.self).contains("[V4+ Styles]"))
        let folder = url.deletingLastPathComponent()
        let playlist = String(decoding: try await URLSession.shared.data(from: folder.appending(path: "1.m3u8")).0, as: UTF8.self)
        var cues = ""
        for name in playlist.split(separator: "\n").filter({ $0.hasSuffix(".vtt") }) {
            cues += String(decoding: try await URLSession.shared.data(from: folder.appending(path: String(name))).0, as: UTF8.self)
        }
        #expect(cues.contains("Bottom line") && cues.contains("Sign at the top") && cues.contains("Later, at the top"))
        #expect(track.count == 3)
        let renderer = try #require(ASSRenderer(track: track))
        let frame = CGSize(width: 640, height: 360)
        let early = try #require(renderer.render(at: 1_000_000, size: frame, video: frame))
        let late = try #require(renderer.render(at: 3_000_000, size: frame, video: frame))
        // The top line joins the sign and the bottom line: the drawn area grows.
        #expect(early.image != nil && late.image != nil && late.rect.height > early.rect.height)
        #expect(renderer.eventCount == 3)
    }
}

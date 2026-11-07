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

    @Test func cuesLastUntilTheNextOne() {
        let track = BitmapSubtitleTrack(name: "PGS", videoSize: CGSize(width: 1920, height: 1080))
        let image = BitmapSubtitleTrack.image([UInt8](repeating: 255, count: 4 * 4 * 4), width: 4, height: 4)!
        let picture = BitmapSubtitleTrack.Picture(rect: CGRect(x: 10, y: 10, width: 4, height: 4), image: image)
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
        #expect(vobFrame.image != nil && vobFrame.size.width > 0)
    }
}

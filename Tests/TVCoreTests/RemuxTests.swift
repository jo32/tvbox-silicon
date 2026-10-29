import AVFoundation
import Foundation
import Testing
@testable import TVCore

// The repackager keeps three files open; tests opening more at once would close each other's.
@Suite(.serialized) struct RemuxTests {
    private typealias Stream = RemuxPlan.Stream

    @Test func containersAreKnownByTheirFirstBytes() {
        #expect(Remux.handles(Data([0x1A, 0x45, 0xDF, 0xA3, 0, 0, 0, 0])))
        #expect(Remux.handles(Data("RIFF\0\0\0\0AVI LIST".utf8)))
        #expect(Remux.handles(Data("FLV\u{1}\u{5}".utf8)))
        #expect(Remux.handles(Data([0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11])))
        #expect(Remux.handles(Data(".RMF\0\0\0\u{12}".utf8)))
        #expect(Remux.handles(Data([0, 0, 1, 0xBA, 0x44, 0, 4, 0])))
        // MP4, WAV and MPEG-TS play without it.
        #expect(!Remux.handles(Data([0, 0, 0, 0x20, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D])))
        #expect(!Remux.handles(Data("RIFF\0\0\0\0WAVEfmt ".utf8)))
        #expect(!Remux.handles(Data(repeating: 0x47, count: 16)))
        #expect(Remux.handles(name: "第1集.MKV") && Remux.handles(name: "a.rmvb") && !Remux.handles(name: "a.mp4"))
        #expect(CloudFile.playsOriginal("a.mkv") && CloudFile.playsOriginal("a.mp4") && !CloudFile.playsOriginal("a.ape"))
    }

    @Test func whatAppleDevicesDecodeIsCopied() throws {
        let streams = [
            Stream(index: 0, kind: .video, codec: "h264", width: 1920, height: 1080, frameRate: 23.976),
            Stream(index: 1, kind: .audio, codec: "aac", profile: 1, channels: 2),
            Stream(index: 2, kind: .audio, codec: "ac3", channels: 6),
            Stream(index: 3, kind: .audio, codec: "dts", channels: 6),
            Stream(index: 4, kind: .audio, codec: "mp3", channels: 2),
            Stream(index: 5, kind: .audio, codec: "opus", channels: 1),
            Stream(index: 6, kind: .subtitle, codec: "subrip", isText: true),
            Stream(index: 7, kind: .subtitle, codec: "hdmv_pgs_subtitle"),
            Stream(index: 8, kind: .other, codec: "ttf"),
        ]
        let plan = try #require(RemuxPlan.make(streams: streams, keyframes: [], start: 0, duration: 60_000_000, size: 0, device: .init()))
        #expect(plan.tracks.map(\.stream.index) == [0, 1, 2, 3, 4, 5, 6])
        #expect(plan.tracks.map(\.mode) == [.copy, .copy, .copy, .aac, .aac, .aac, .copy])
        #expect(plan.tracks.map(\.channels) == [0, 0, 0, 6, 2, 1, 0])
        #expect(plan.tracks[3].bitRate == 384_000 && plan.tracks[4].bitRate == 160_000)
        // No picture, nothing to play.
        #expect(RemuxPlan.make(streams: [streams[1]], keyframes: [], start: 0, duration: 1, size: 0, device: .init()) == nil)
    }

    @Test func onlyPicturesTheDeviceCantDecodeAreConverted() {
        let device = RemuxPlan.Device(hevc: true, av1: false, hevcEncoder: true)
        func mode(_ stream: Stream, _ device: RemuxPlan.Device = device) -> RemuxPlan.Mode { RemuxPlan.videoTrack(stream, device: device).mode }
        #expect(mode(Stream(index: 0, kind: .video, codec: "hevc", width: 3840, height: 2160, bitDepth: 10, colorTransfer: 16)) == .copy)
        #expect(mode(Stream(index: 0, kind: .video, codec: "h264", width: 1920, height: 1080, bitDepth: 10)) == .hevc)
        #expect(mode(Stream(index: 0, kind: .video, codec: "h264", width: 1920, height: 1080, chroma: 422)) == .h264)
        #expect(mode(Stream(index: 0, kind: .video, codec: "vp9", width: 1920, height: 1080)) == .h264)
        #expect(mode(Stream(index: 0, kind: .video, codec: "vp9", width: 3840, height: 2160, bitDepth: 10, colorTransfer: 16)) == .hevc)
        #expect(mode(Stream(index: 0, kind: .video, codec: "av1", width: 1920, height: 1080)) == .h264)
        #expect(mode(Stream(index: 0, kind: .video, codec: "av1", width: 1920, height: 1080), .init(hevc: true, av1: true)) == .copy)
        // Without HEVC hardware (Apple TV HD), HEVC is converted and 10-bit pictures become 8-bit H.264.
        #expect(mode(Stream(index: 0, kind: .video, codec: "hevc", width: 1920, height: 1080, bitDepth: 10), .init(hevc: false, hevcEncoder: false)) == .h264)
        // Dolby Vision 5 keeps its own sample entry, 8 its HDR10 base with the configuration, 7 its base alone.
        let vision = { (profile: Int) in RemuxPlan.videoTrack(Stream(index: 0, kind: .video, codec: "hevc", width: 3840, height: 2160, bitDepth: 10, doviProfile: profile), device: device).dolbyVision }
        #expect(vision(5) == .dvh1 && vision(8) == .hvc1 && vision(7) == .drop && vision(-1) == .drop)
        // Where AVPlayer shows no HDR, HDR10 and HLG pictures are converted to SDR and declared so.
        let sdr = RemuxPlan.Device(hevc: true, av1: false, hevcEncoder: true, hdr: false)
        let hdr10 = Stream(index: 0, kind: .video, codec: "hevc", width: 3840, height: 1608, bitDepth: 10, frameRate: 25, colorTransfer: 16)
        let mapped = RemuxPlan.videoTrack(hdr10, device: sdr)
        #expect(mapped.mode == .hevc && mapped.toneMap && mapped.bitRate > 0 && mapped.width == 0)
        var small = sdr
        (small.toneMapWidth, small.toneMapHeight) = (1920, 1080)
        let shrunk = RemuxPlan.videoTrack(hdr10, device: small)
        #expect(shrunk.width == 1920 && shrunk.height == 804 && shrunk.bitRate < mapped.bitRate)
        #expect(RemuxPlan(tracks: [shrunk], bounds: [0, 1_000_000]).masterPlaylist(codecs: [:]).contains("RESOLUTION=1920x804"))
        #expect(RemuxPlan(tracks: [mapped], bounds: [0, 1_000_000]).videoRange == "SDR")
        #expect(RemuxPlan(tracks: [RemuxPlan.videoTrack(hdr10, device: device)], bounds: [0, 1_000_000]).videoRange == "PQ")
        #expect(!RemuxPlan.videoTrack(Stream(index: 0, kind: .video, codec: "hevc", width: 3840, height: 2160, bitDepth: 10), device: sdr).toneMap)
        #expect(!RemuxPlan.videoTrack(Stream(index: 0, kind: .video, codec: "hevc", width: 3840, height: 2160, bitDepth: 10, colorTransfer: 16, doviProfile: 5), device: sdr).toneMap)
        // Nor is Dolby Vision 5 converted later: a device that refused it would refuse it again.
        let vision5 = RemuxPlan(tracks: [RemuxPlan.videoTrack(Stream(index: 0, kind: .video, codec: "hevc", width: 3840, height: 2160, bitDepth: 10, doviProfile: 5), device: sdr)],
                                bounds: [0, 1_000_000])
        #expect(vision5.isDolbyVision && vision5.videoRange == "PQ" && !RemuxPlan(tracks: [mapped], bounds: [0, 1_000_000]).isDolbyVision)
        let converted = RemuxPlan.videoTrack(Stream(index: 0, kind: .video, codec: "mpeg4", width: 720, height: 404, frameRate: 25, bitRate: 1_200_000), device: device)
        #expect(converted.bitRate == 1_500_000)
    }

    @Test func segmentsRunFromKeyframeToKeyframe() {
        let keys = stride(from: Int64(0), to: 20_000_000, by: 2_000_000).map { $0 }
        #expect(RemuxPlan.segmentBounds(keyframes: keys, start: 0, duration: 20_000_000, copied: true)
                == [0, 4_000_000, 8_000_000, 12_000_000, 16_000_000, 20_000_000])
        // A last second joins the segment before it.
        #expect(RemuxPlan.segmentBounds(keyframes: keys, start: 0, duration: 17_000_000, copied: true)
                == [0, 4_000_000, 8_000_000, 12_000_000, 17_000_000])
        // An index that stops early (FLV, Matroska without Cues): even segments a GOP and a half long.
        let early = RemuxPlan.segmentBounds(keyframes: [0, 10_000_000], start: 0, duration: 180_000_000, copied: true)
        #expect(early.first == 0 && early.last == 180_000_000 && zip(early.dropFirst(), early).allSatisfy { $0 - $1 == 12_000_000 })
        #expect(RemuxPlan.segmentBounds(keyframes: [], start: 1_400_000, duration: 13_000_000, copied: false) == [1_400_000, 7_400_000, 14_400_000])
    }

    @Test func playlistsDescribeEveryTrack() throws {
        let streams = [
            Stream(index: 0, kind: .video, codec: "h264", width: 1920, height: 1080, frameRate: 23.976),
            Stream(index: 1, kind: .audio, codec: "aac", profile: 1, channels: 2, language: "chi", isDefault: true),
            Stream(index: 2, kind: .audio, codec: "eac3", channels: 6, language: "eng", title: "English"),
            Stream(index: 3, kind: .audio, codec: "eac3", channels: 6, language: "eng", title: "English"),
            Stream(index: 4, kind: .subtitle, codec: "ass", language: "chi", title: "简体", isForced: true, isText: true),
        ]
        let plan = try #require(RemuxPlan.make(streams: streams, keyframes: [0, 5_000_000, 10_000_000], start: 0, duration: 12_000_000, size: 9_000_000, device: .init()))
        let master = plan.masterPlaylist(codecs: [0: "avc1.640028", 1: "mp4a.40.2", 2: "ec-3", 3: "ec-3"])
        #expect(master.contains(#"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="#))
        #expect(master.contains(#"LANGUAGE="zh",DEFAULT=YES,AUTOSELECT=YES,CHANNELS="2",URI="1.m3u8""#))
        #expect(master.contains(#"NAME="English",LANGUAGE="en",DEFAULT=NO,AUTOSELECT=YES,CHANNELS="6",URI="2.m3u8""#))
        #expect(master.contains(#"NAME="English (2)""#))
        #expect(master.contains(#"TYPE=SUBTITLES,GROUP-ID="subtitles",NAME="简体",LANGUAGE="zh",DEFAULT=NO,AUTOSELECT=YES,FORCED=YES,URI="4.m3u8""#))
        #expect(master.contains(#"CODECS="avc1.640028,mp4a.40.2,ec-3",RESOLUTION=1920x1080,FRAME-RATE=23.976,VIDEO-RANGE=SDR,AUDIO="audio",SUBTITLES="subtitles""#))
        #expect(master.contains("AVERAGE-BANDWIDTH=6000000"))
        #expect(master.hasSuffix("\n0.m3u8\n"))
        let video = plan.mediaPlaylist(track: 0)
        #expect(video.contains("#EXT-X-TARGETDURATION:5\n") && video.contains(#"#EXT-X-MAP:URI="0.mp4""#))
        #expect(plan.bounds == [0, 5_000_000, 10_000_000, 12_000_000])
        #expect(video.contains("#EXTINF:5.000000,\n0-0.m4s\n#EXTINF:5.000000,\n0-1.m4s\n#EXTINF:2.000000,\n0-2.m4s\n#EXT-X-ENDLIST\n"))
        let subtitles = plan.mediaPlaylist(track: 4)
        #expect(!subtitles.contains("EXT-X-MAP") && subtitles.contains("\n4-1.vtt\n"))
    }

    @Test func codecStringsComeFromTheDecoderConfiguration() {
        #expect(RemuxPlan.avcCodec(Data([1, 0x64, 0x00, 0x28, 0xFF])) == "avc1.640028")
        let main10 = Data([1, 0x02, 0x20, 0, 0, 0, 0xB0, 0, 0, 0, 0, 0, 123])
        #expect(RemuxPlan.hevcCodec(main10) == "hvc1.2.4.L123.B0")
        let main = Data([1, 0x01, 0x60, 0, 0, 0, 0x90, 0, 0, 0, 0, 0, 93])
        #expect(RemuxPlan.hevcCodec(main) == "hvc1.1.6.L93.90")
        // Dolby Vision 8.1 at level 6: profile 8, level 6, compatibility 1.
        let vision = Data([1, 0, 8 << 1, 6 << 3 | 0b101, 1 << 4])
        #expect(RemuxPlan.doviCodec(vision)?.codec == "dvh1.08.06" && RemuxPlan.doviCodec(vision)?.compatibility == 1)
        #expect(RemuxPlan.av1Codec(Data([0x81, 0x08, 0x40])) == "av01.0.08M.10")
        // A box is found by its type after a plausible size.
        let initialization = Data([0, 0, 0, 12]) + Data("avcC".utf8) + Data([1, 0x4D, 0x40, 0x1F])
        #expect(RemuxPlan.box("avcC", in: Data("junk".utf8) + initialization) == Data([1, 0x4D, 0x40, 0x1F]))
    }

    @Test func subtitlesBecomeWebVTT() {
        #expect(RemuxPlan.cueText(Data("<i>Hello</i> & <font color=\"red\">you</font>\r\n{\\an8}<B>there</B> 1 < 2".utf8), codec: "subrip")
                == "<i>Hello</i> &amp; you\n<b>there</b> 1 &lt; 2")
        #expect(RemuxPlan.cueText(Data("3,0,Default,,0,0,0,,{\\an8\\b1}你好\\N世界, 再见".utf8), codec: "ass") == "你好\n世界, 再见")
        #expect(RemuxPlan.cueText(Data("3,0,Default,,0,0,0,,{\\p1}m 0 0 l 100 0".utf8), codec: "ass") == nil)
        #expect(RemuxPlan.cueText(Data([0, 5]) + Data("Hi <3".utf8), codec: "mov_text") == "Hi &lt;3")
        #expect(RemuxPlan.cueText(Data("  \n ".utf8), codec: "subrip") == nil)
        let text = RemuxPlan.webVTT([.init(start: 61_500_000, end: 63_000_000, text: "B"), .init(start: 500_000, end: 2_000_000, text: "A")], offset: 10_000_000)
        #expect(text == "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000\n\n00:00:00.500 --> 00:00:02.000\nA\n\n00:01:01.500 --> 00:01:03.000\nB\n")
        #expect(RemuxPlan.languageTag("chi") == "zh" && RemuxPlan.languageTag("und") == nil && RemuxPlan.languageTag("") == nil && RemuxPlan.languageTag("en") == "en")
    }

    @Test func subtitleFilesBecomeCues() throws {
        // SubRip in GB 18030, as Chinese subtitle files often are, with a cue number and a timing without hours.
        let srt = "1\r\n00:00:01,500 --> 00:00:03,000\r\n<i>你好</i>\r\n世界\r\n\r\n2\r\n01:02,250 --> 01:04,000\r\nA & B\r\n"
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let gb = try #require(srt.data(using: encoding))
        #expect(String(data: gb, encoding: .utf8) == nil)
        #expect(SubtitleFile.cues(gb) == [.init(start: 1_500_000, end: 3_000_000, text: "<i>你好</i>\n世界"),
                                         .init(start: 62_250_000, end: 64_000_000, text: "A &amp; B")])
        let vtt = "WEBVTT\n\nNOTE made by hand\n\nintro\n00:00:00.250 --> 00:00:01.000 line:90%\n<c.yellow>Hi</c>\n"
        #expect(SubtitleFile.cues(Data([0xEF, 0xBB, 0xBF]) + Data(vtt.utf8)) == [.init(start: 250_000, end: 1_000_000, text: "<c.yellow>Hi</c>")])
        let ass = """
        [Script Info]
        ScriptType: v4.00+

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:05.10,0:00:07.00,Default,,0,0,0,,{\\an8}第二句\\N, 还有
        Dialogue: 0,0:00:02.00,0:00:04.00,Default,,0,0,0,,第一句
        Dialogue: 0,0:00:03.00,0:00:04.00,Sign,,0,0,0,,{\\p1}m 0 0 l 100 0
        """
        #expect(SubtitleFile.cues(Data(ass.utf8), format: "text/x-ssa") == [.init(start: 2_000_000, end: 4_000_000, text: "第一句"),
                                                                            .init(start: 5_100_000, end: 7_000_000, text: "第二句\n, 还有")])
        #expect(SubtitleFile.cues(Data("not a subtitle".utf8)).isEmpty)
        // A play result's `subs`: entries without an HTTP address are left out.
        let subs = JSONValue.array([
            .object(["name": .string("末世行者.chs.srt"), "url": .string("http://127.0.0.1:9978/proxy?do=quark&type=sub"), "lang": .string("chs"),
                     "format": .string("application/x-subrip")]),
            .object(["url": .string("https://cdn.example.com/a.ass")]),
            .object(["name": .string("bad"), "url": .string("file:///etc/passwd")]),
        ])
        let parsed = ExternalSubtitle.parse(subs)
        #expect(parsed.map(\.name) == ["末世行者.chs.srt", "a.ass"] && parsed[0].language == "chs" && parsed[0].format == "application/x-subrip")
    }

    @Test func subtitleFilesJoinThePlan() throws {
        let streams = [Stream(index: 0, kind: .video, codec: "h264", width: 1920, height: 1080), Stream(index: 1, kind: .audio, codec: "aac", channels: 2)]
        var plan = try #require(RemuxPlan.make(streams: streams, keyframes: [0, 4_000_000, 8_000_000], start: 0, duration: 12_000_000, size: 0, device: .init()))
        let cue = { (start: Int64) in RemuxPlan.Cue(start: start, end: start + 500_000, text: "\(start)") }
        let added = plan.addSubtitles([.init(name: "末世行者.chs.srt", language: "chs", cues: [cue(1_000_000)]),
                                       .init(name: "末世行者.英文.srt", language: "英文", cues: [cue(1_000_000)])])
        #expect(added == [2, 3] && plan.tracks[2].stream.index < 0 && plan.tracks[2].kind == .subtitle)
        let master = plan.masterPlaylist(codecs: [:])
        // The file has no subtitles of its own, so the first file's are on; a language HLS can't take is left out.
        #expect(master.contains(#"TYPE=SUBTITLES,GROUP-ID="subtitles",NAME="末世行者.chs.srt",LANGUAGE="zh-Hans",DEFAULT=YES"#))
        #expect(master.contains(#"NAME="末世行者.英文.srt",DEFAULT=NO"#) && master.contains(#"SUBTITLES="subtitles""#))
        #expect(plan.mediaPlaylist(track: 2).contains("2-0.vtt"))
        // Each cue goes to the segment it starts in; the first and last take what lies outside the picture.
        let cues = [cue(-2_000_000), cue(3_900_000), cue(4_000_000), cue(11_000_000), cue(20_000_000)]
        #expect(plan.segments == 3)
        #expect(plan.cues(cues, segment: 0).map(\.start) == [-2_000_000, 3_900_000])
        #expect(plan.cues(cues, segment: 1).map(\.start) == [4_000_000])
        #expect(plan.cues(cues, segment: 2).map(\.start) == [11_000_000, 20_000_000])
    }

    // MARK: - Playing through FFmpeg

    private func fixture(_ name: String) throws -> URL {
        let ext = (name as NSString).pathExtension
        return try #require(Bundle.module.url(forResource: (name as NSString).deletingPathExtension, withExtension: ext, subdirectory: "Fixtures"))
    }

    private func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200, "\(url.lastPathComponent)")
        return data
    }

    private func ready(_ url: URL) async -> (status: AVPlayerItem.Status, duration: Double) {
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        for _ in 0..<100 where item.status == .unknown { try? await Task.sleep(for: .milliseconds(100)) }
        let result = (item.status, item.duration.seconds)
        player.replaceCurrentItem(with: nil)
        return result
    }

    @Test func matroskaPlaysCopiedThroughHLS() async throws {
        let url = try await Remux.open(try Remux.fileSource(fixture("remux-copy.mkv")))
        defer { Remux.stop(url) }
        #expect(Remux.isRemuxed(url) && url.lastPathComponent == "master.m3u8")
        let master = String(decoding: try await fetch(url), as: UTF8.self)
        #expect(master.contains("CODECS=\"avc1.4d400a,mp4a.40.2,ac-3\""))
        #expect(master.contains(#"NAME="Commentary",LANGUAGE="en""#) && master.contains(#"TYPE=SUBTITLES"#))
        let video = String(decoding: try await fetch(url.deletingLastPathComponent().appending(path: "0.m3u8")), as: UTF8.self)
        #expect(video.components(separatedBy: ".m4s").count - 1 == 2)
        let initialization = try await fetch(url.deletingLastPathComponent().appending(path: "0.mp4"))
        #expect(initialization.subdata(in: 4..<8) == Data("ftyp".utf8) && RemuxPlan.box("avcC", in: initialization) != nil)
        for file in ["0-0.m4s", "1-0.m4s", "2-1.m4s", "0-1.m4s"] {
            let segment = try await fetch(url.deletingLastPathComponent().appending(path: file))
            #expect(segment.count > 500 && segment.subdata(in: 4..<8) == Data("moof".utf8), "\(file)")
        }
        let cues = String(decoding: try await fetch(url.deletingLastPathComponent().appending(path: "3-0.vtt")), as: UTF8.self)
        #expect(cues.contains("00:00:00.500 --> 00:00:02.000\n<i>Hello</i> &amp; welcome"))
        let later = String(decoding: try await fetch(url.deletingLastPathComponent().appending(path: "3-1.vtt")), as: UTF8.self)
        #expect(later.contains("Second") && !later.contains("Hello"))
        let played = await ready(url)
        #expect(played.status == .readyToPlay && abs(played.duration - 8) < 0.2)
    }

    @Test func subtitleFilesPlayAsSubtitlesOfTheStream() async throws {
        let srt = RangeServer.add("film-\(UUID().uuidString).srt", Data("1\n00:00:07,000 --> 00:00:07,500\n从文件来的字幕\n".utf8))
        let missing = URL(string: "https://cloud.test/missing.srt")!
        let url = try await Remux.open(try Remux.fileSource(fixture("remux-copy.mkv")),
                                       subtitles: [ExternalSubtitle(name: "Chinese", url: srt, language: "chi"), ExternalSubtitle(name: "Gone", url: missing)],
                                       headers: [:], session: RangeServer.session)
        defer { Remux.stop(url) }
        let master = String(decoding: try await fetch(url), as: UTF8.self)
        // After the file's own subtitles, which stay the default; a file that can't be read is left out.
        #expect(master.contains(#"NAME="Chinese",LANGUAGE="zh",DEFAULT=NO,AUTOSELECT=YES,FORCED=NO,URI="4.m3u8""#) && !master.contains("Gone"))
        let playlist = String(decoding: try await fetch(url.deletingLastPathComponent().appending(path: "4.m3u8")), as: UTF8.self)
        #expect(playlist.contains("4-1.vtt"))
        let first = String(decoding: try await fetch(url.deletingLastPathComponent().appending(path: "4-0.vtt")), as: UTF8.self)
        let second = String(decoding: try await fetch(url.deletingLastPathComponent().appending(path: "4-1.vtt")), as: UTF8.self)
        #expect(first.hasPrefix("WEBVTT") && !first.contains("字幕"))
        #expect(second.contains("\n从文件来的字幕\n"))
        // AVFoundation lists it with the file's own, where the player's Subtitles menu finds it.
        let group = try await AVURLAsset(url: url).loadMediaSelectionGroup(for: .legible)
        #expect(group?.options.map(\.displayName).contains("Chinese") == true && group?.options.count == 2)
    }

    @Test func picturesAVPlayerCantDecodeAreRepackagedWhenThatShowsThem() {
        #expect(Remux.showsPicture(["hev1"]) && Remux.showsPicture(["dvhe"]) && Remux.showsPicture(["vp09"]))
        #expect(!Remux.showsPicture([]) && !Remux.showsPicture(["av01"]) && !Remux.showsPicture(["hev1", "av01"]))
    }

    @Test func hevcTaggedHev1PlaysRepackaged() async throws {
        // AVPlayer plays this MP4's sound alone: it can't decode the picture's sample entry.
        let file = try fixture("remux-hev1.mp4")
        let track = try #require(try await AVURLAsset(url: file).loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.isPlayable) == false)
        let url = try await Remux.open(try Remux.fileSource(file))
        defer { Remux.stop(url) }
        let master = String(decoding: try await fetch(url), as: UTF8.self)
        #expect(master.contains("CODECS=\"hvc1.") && master.contains("RESOLUTION=320x180"))
        let played = await ready(url)
        #expect(played.status == .readyToPlay && abs(played.duration - 4) < 0.2)
    }

    @Test func aviIsConvertedForAVPlayer() async throws {
        let url = try await Remux.open(try Remux.fileSource(fixture("remux-convert.avi")))
        defer { Remux.stop(url) }
        let master = String(decoding: try await fetch(url), as: UTF8.self)
        #expect(master.contains("CODECS=\"avc1.") && master.contains("mp4a.40.2"))
        let segment = try await fetch(url.deletingLastPathComponent().appending(path: "0-0.m4s"))
        #expect(segment.subdata(in: 4..<8) == Data("moof".utf8))
        let played = await ready(url)
        #expect(played.status == .readyToPlay && abs(played.duration - 4) < 0.2)
    }

    // MARK: - Links

    @Test func aLinkThatSendsTheRestOfTheFileIsReadThroughOneResponse() async throws {
        let size = 12 << 20
        var bytes = Data(count: size)
        bytes.withUnsafeMutableBytes { raw in for i in 0..<size { raw[i] = UInt8(truncatingIfNeeded: i &* 31 &+ i >> 9) } }
        let name = "rest-of-file-\(UUID().uuidString).bin"
        let url = RangeServer.add(name, bytes, restOfFile: true)
        let source = try await Remux.httpSource(url, headers: [:], chunks: RangeServer.session, configuration: RangeServer.configuration)
        defer { Task { await source.close() } }
        #expect(source is StreamingRemuxSource && source.length == Int64(size))
        // Reads in order, a jump back and jumps forward all come from the probe's own response.
        var copy = Data()
        while copy.count < 1 << 20 { copy.append(try await source.read(at: Int64(copy.count), count: 65536)) }
        #expect(copy == bytes.prefix(copy.count))
        #expect(try await source.read(at: 1000, count: 16) == bytes[1000..<1016])
        #expect(try await source.read(at: 3 << 20, count: 16) == bytes[(3 << 20)..<(3 << 20) + 16])
        #expect(try await source.read(at: Int64(size - 100), count: 100) == bytes.suffix(100))
        #expect(RangeServer.requests(name) == 1)
        // A jump back past the bytes it kept opens one more response.
        #expect(try await source.read(at: 5, count: 5) == bytes[5..<10])
        #expect(RangeServer.requests(name) == 2)
        // The first response stays open for a return to where it was.
        #expect(try await source.read(at: Int64(size - 50), count: 50) == bytes.suffix(50))
        #expect(RangeServer.requests(name) == 2)
        #expect(try await source.read(at: Int64(size), count: 1).isEmpty)
    }

    @Test func aLinkThatSendsWhatWasAskedIsReadInChunks() async throws {
        let url = RangeServer.add("exact-\(UUID().uuidString).mkv", try Data(contentsOf: fixture("remux-copy.mkv")))
        let source = try await Remux.httpSource(url, headers: [:], chunks: RangeServer.session, configuration: RangeServer.configuration)
        #expect(source is CloudRemuxSource)
        let head = try await source.read(at: 0, count: 4)
        #expect(Remux.handles(head))
    }

    @Test func matroskaFromAPluginProxyPlays() async throws {
        let url = RangeServer.add("proxy-\(UUID().uuidString).mkv", try Data(contentsOf: fixture("remux-copy.mkv")), restOfFile: true)
        let source = try await Remux.httpSource(url, headers: [:], chunks: RangeServer.session, configuration: RangeServer.configuration)
        let master = try await Remux.open(source)
        defer { Remux.stop(master) }
        let played = await ready(master)
        #expect(played.status == .readyToPlay && abs(played.duration - 8) < 0.2)
    }

    @Test func aFileFFmpegCantReadFailsToOpen() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "remux-\(UUID().uuidString).mkv")
        try (Data([0x1A, 0x45, 0xDF, 0xA3]) + Data(repeating: 0x55, count: 4096)).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        await #expect(throws: (any Error).self) { try await Remux.open(try Remux.fileSource(file)) }
    }
}

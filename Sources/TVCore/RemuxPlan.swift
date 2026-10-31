import Foundation

/// What a file AVPlayer can't open (MKV, AVI, FLV, ...) becomes for it: which streams are copied and which
/// converted, where the HLS segments begin, and the playlists that describe them. Copying is the rule, since
/// it costs almost nothing and keeps the picture as it was; only what Apple devices can't decode is converted.
/// Times are microseconds of the file's own clock. Docs/mkv-playback-plan.md has the whole design.
struct RemuxPlan: Sendable, Equatable {
    struct Stream: Sendable, Equatable {
        enum Kind: Sendable { case video, audio, subtitle, other }
        var index: Int
        var kind: Kind
        /// FFmpeg's codec name.
        var codec: String
        var profile = -99, level = -99
        var width = 0, height = 0, bitDepth = 8
        /// 420, 422 or 444; 0 when unknown.
        var chroma = 420
        var frameRate = 0.0
        /// FFmpeg's AVColorTransferCharacteristic: 16 is PQ, 18 is HLG.
        var colorTransfer = 2
        var doviProfile = -1, doviCompatibility = -1
        /// x264's intra refresh: its keyframes are recovery points, where AVPlayer can't start a segment.
        var intraRefresh = false
        var sampleRate = 0, channels = 0
        var bitRate: Int64 = 0
        var language = "", title = ""
        var isDefault = false, isForced = false, isText = false
    }
    enum Mode: Int32, Sendable { case copy = 0, aac = 1, h264 = 2, hevc = 3 }
    /// How copied HEVC keeps its Dolby Vision configuration.
    enum DolbyVision: Int32, Sendable { case drop = 0, hvc1 = 1, dvh1 = 2 }
    struct Track: Sendable, Equatable {
        var stream: Stream
        var mode: Mode = .copy
        var bitRate = 0
        var channels = 0
        var dolbyVision: DolbyVision = .drop
        /// Converted HDR video becomes SDR (BT.709), for a device that doesn't show HDR.
        var toneMap = false
        /// The size converted video is made at; 0 keeps the stream's.
        var width = 0, height = 0
        var kind: Stream.Kind { stream.kind }
    }
    /// What the device decodes and encodes in hardware.
    struct Device: Sendable {
        var hevc = true, av1 = false, hevcEncoder = true
        /// Whether AVPlayer plays HDR here. Without it, it refuses every HDR variant of an HLS stream ("cannot be
        /// played on the device"), although it tone maps the same picture in a plain file.
        var hdr = true
        /// The largest picture tone mapping makes, which costs the CPU by the pixel; 0 for no limit.
        var toneMapWidth = 0, toneMapHeight = 0
    }

    /// The video track first, then the audio, then the text subtitles.
    var tracks: [Track]
    /// Segment `k` runs from `bounds[k]` to `bounds[k + 1]`.
    var bounds: [Int64]
    /// The size of the file, for the bit rate the master playlist declares.
    var size: Int64 = 0
    var segments: Int { bounds.count - 1 }

    /// Copied audio: what every Apple device decodes inside fragmented MP4. MP3 and Opus are not among them.
    static let copiedAudio: Set<String> = ["aac", "ac3", "eac3", "flac", "alac"]
    /// AAC profiles AVPlayer decodes (LC, HE, HE v2; FFmpeg's numbers), and unknown.
    static let copiedAAC: Set<Int> = [-99, 1, 4, 28]

    /// Subtitle files from beside the video, as text subtitles after the file's own. Their cues aren't the
    /// file's, so their tracks name no stream. The first is the default when the file has no subtitles: it was
    /// put there to be read. Returns the tracks' indices.
    mutating func addSubtitles(_ files: [SubtitleFile.Track]) -> [Int] {
        let first = tracks.count, unsubtitled = !tracks.contains { $0.kind == .subtitle }
        for (number, file) in files.enumerated() {
            // HLS wants a BCP 47 tag; a source's "简体" would make the playlist invalid.
            let language = file.language.wholeMatch(of: /[A-Za-z]{2,3}(-[A-Za-z0-9]{1,8})*/) != nil ? file.language : ""
            tracks.append(Track(stream: Stream(index: -1, kind: .subtitle, codec: "external", language: language, title: file.name,
                                               isDefault: unsubtitled && number == 0, isText: true)))
        }
        return Array(first..<tracks.count)
    }

    /// The cues of a subtitle file that segment `index` carries: those starting within it, as FFmpeg places
    /// the file's own. The first and last segments take those before and after the picture too.
    func cues(_ cues: [Cue], segment index: Int) -> [Cue] {
        cues.filter { cue in
            (index == 0 || cue.start >= bounds[index]) && (index == segments - 1 || cue.start < bounds[index + 1])
        }
    }

    static func make(streams: [Stream], keyframes: [Int64], start: Int64, duration: Int64, size: Int64, device: Device) -> RemuxPlan? {
        guard duration > 0, let video = streams.first(where: { $0.kind == .video && $0.width > 0 && $0.height > 0 }) else { return nil }
        var tracks = [videoTrack(video, device: device)]
        tracks += streams.filter { $0.kind == .audio && $0.channels > 0 }.prefix(8).map(audioTrack)
        tracks += streams.filter { $0.kind == .subtitle && $0.isText }.prefix(16).map { Track(stream: $0) }
        let bounds = segmentBounds(keyframes: keyframes, start: start, duration: duration, copied: tracks[0].mode == .copy)
        return RemuxPlan(tracks: tracks, bounds: bounds, size: size)
    }

    static func videoTrack(_ stream: Stream, device: Device) -> Track {
        var track = Track(stream: stream)
        let plain = stream.chroma == 420 || stream.chroma == 0
        // Dolby Vision 5 has no HDR10 picture to map; it stays as it is.
        if !device.hdr, [16, 18].contains(stream.colorTransfer), stream.doviProfile != 5 {
            track.mode = device.hevcEncoder ? .hevc : .h264
            track.toneMap = true
            var sized = stream
            if device.toneMapWidth > 0, stream.width > device.toneMapWidth || stream.height > device.toneMapHeight {
                let scale = min(Double(device.toneMapWidth) / Double(stream.width), Double(device.toneMapHeight) / Double(stream.height))
                (track.width, track.height) = (Int(Double(stream.width) * scale / 2) * 2, Int(Double(stream.height) * scale / 2) * 2)
                (sized.width, sized.height) = (track.width, track.height)
            }
            track.bitRate = videoBitRate(sized, hevc: track.mode == .hevc)
            return track
        }
        switch stream.codec {
        case "h264" where stream.bitDepth <= 8 && plain && !stream.intraRefresh: return track
        case "hevc" where device.hevc && stream.bitDepth <= 10 && plain:
            // Profile 5 is Dolby Vision alone; 8 has an HDR10 (or SDR, HLG) base. Others keep their base only.
            track.dolbyVision = stream.doviProfile == 5 ? .dvh1 : stream.doviProfile == 8 ? .hvc1 : .drop
            return track
        case "av1" where device.av1 && stream.bitDepth <= 10 && plain: return track
        default: break
        }
        let deep = stream.bitDepth > 8 || [16, 18].contains(stream.colorTransfer)
        track.mode = deep && device.hevcEncoder ? .hevc : .h264
        track.bitRate = videoBitRate(stream, hevc: track.mode == .hevc)
        return track
    }

    /// Enough for the picture at its size and rate, never much above the original's.
    static func videoBitRate(_ stream: Stream, hevc: Bool) -> Int {
        let rate = stream.frameRate > 0 ? min(stream.frameRate, 60) : 30
        var bits = Double(stream.width * stream.height) * rate * (hevc ? 0.07 : 0.1)
        if stream.bitRate > 0 { bits = min(bits, Double(stream.bitRate) * 1.2) }
        return Int(min(max(bits, 1_500_000), 40_000_000))
    }

    static func audioTrack(_ stream: Stream) -> Track {
        var track = Track(stream: stream)
        if copiedAudio.contains(stream.codec), stream.channels <= 8, stream.codec != "aac" || copiedAAC.contains(stream.profile) { return track }
        track.mode = .aac
        track.channels = stream.channels > 2 ? 6 : max(1, stream.channels)
        track.bitRate = track.channels == 6 ? 384_000 : track.channels == 2 ? 160_000 : 96_000
        return track
    }

    /// Segments from keyframe to keyframe, at least 4 s long, when the file's index lists them all. A file
    /// whose index is missing or stops early (FLV, MPEG, a Matroska file without Cues) gets even segments: a
    /// copied one then runs from its first keyframe to the next segment's, and is long enough to hold one.
    static func segmentBounds(keyframes: [Int64], start: Int64, duration: Int64, copied: Bool) -> [Int64] {
        let end = start + duration
        let keys = keyframes.filter { $0 < end }
        let widest = zip(keys.dropFirst(), keys).map { $0 - $1 }.max() ?? 0
        let slack = max(3 * widest, min(30_000_000, duration / 4))
        var bounds: [Int64]
        if keys.count > 1, let last = keys.last, last >= end - slack {
            bounds = [keys[0]]
            for key in keys.dropFirst() where key - bounds[bounds.count - 1] >= 4_000_000 { bounds.append(key) }
        } else {
            let step = copied ? min(max(keys.count > 1 ? widest * 3 / 2 : 10_000_000, 6_000_000), 12_000_000) : 6_000_000
            bounds = Array(stride(from: start, to: end, by: Int(step)))
        }
        // A last moment of picture joins the segment before it.
        if bounds.count > 1, end - bounds[bounds.count - 1] < 2_000_000 { bounds.removeLast() }
        return bounds + [end]
    }

    // MARK: - Playlists

    var defaultAudio: Int? {
        let audio = tracks.indices.filter { tracks[$0].kind == .audio }
        return audio.first { tracks[$0].stream.isDefault } ?? audio.first
    }

    /// The master playlist. `codecs` holds each track's codec string where it is known, from its initialization
    /// segment; `supplemental` the Dolby Vision one of a profile 8 picture.
    func masterPlaylist(codecs: [Int: String], supplemental: String? = nil) -> String {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS"]
        var names = Set<String>()
        func unique(_ name: String) -> String {
            var value = name, number = 2
            while names.contains(value) { value = "\(name) (\(number))"; number += 1 }
            names.insert(value)
            return value
        }
        let audio = tracks.indices.filter { tracks[$0].kind == .audio }
        for index in audio {
            let track = tracks[index]
            var attributes = ["TYPE=AUDIO", "GROUP-ID=\"audio\"", "NAME=\"\(quoted(unique(Self.displayName(track))))\""]
            if let language = Self.languageTag(track.stream.language) { attributes.append("LANGUAGE=\"\(language)\"") }
            attributes += ["DEFAULT=\(index == defaultAudio ? "YES" : "NO")", "AUTOSELECT=YES",
                           "CHANNELS=\"\(track.mode == .copy ? track.stream.channels : track.channels)\"", "URI=\"\(index).m3u8\""]
            lines.append("#EXT-X-MEDIA:" + attributes.joined(separator: ","))
        }
        names.removeAll()
        let subtitles = tracks.indices.filter { tracks[$0].kind == .subtitle }
        for index in subtitles {
            let stream = tracks[index].stream
            var attributes = ["TYPE=SUBTITLES", "GROUP-ID=\"subtitles\"", "NAME=\"\(quoted(unique(Self.displayName(tracks[index]))))\""]
            if let language = Self.languageTag(stream.language) { attributes.append("LANGUAGE=\"\(language)\"") }
            attributes += ["DEFAULT=\(stream.isDefault && !stream.isForced ? "YES" : "NO")", "AUTOSELECT=YES",
                           "FORCED=\(stream.isForced ? "YES" : "NO")", "URI=\"\(index).m3u8\""]
            lines.append("#EXT-X-MEDIA:" + attributes.joined(separator: ","))
        }
        let video = tracks[0]
        var attributes = ["BANDWIDTH=\(bandwidth(peak: true))", "AVERAGE-BANDWIDTH=\(bandwidth(peak: false))"]
        if let videoCodec = codecs[0] {
            var list = [videoCodec]
            for index in audio { if let codec = codecs[index], !list.contains(codec) { list.append(codec) } }
            if audio.allSatisfy({ codecs[$0] != nil }) { attributes.append("CODECS=\"\(list.joined(separator: ","))\"") }
            if let supplemental { attributes.append("SUPPLEMENTAL-CODECS=\"\(supplemental)\"") }
        }
        attributes.append(video.width > 0 ? "RESOLUTION=\(video.width)x\(video.height)" : "RESOLUTION=\(video.stream.width)x\(video.stream.height)")
        if video.stream.frameRate > 0 { attributes.append(String(format: "FRAME-RATE=%.3f", video.stream.frameRate)) }
        attributes.append("VIDEO-RANGE=\(videoRange)")
        if !audio.isEmpty { attributes.append("AUDIO=\"audio\"") }
        if !subtitles.isEmpty { attributes.append("SUBTITLES=\"subtitles\"") }
        attributes.append("CLOSED-CAPTIONS=NONE")
        lines.append("#EXT-X-STREAM-INF:" + attributes.joined(separator: ","))
        lines.append("0.m3u8")
        return lines.joined(separator: "\n") + "\n"
    }

    /// A track's media playlist: fragmented MP4 after its initialization segment, or WebVTT for subtitles.
    func mediaPlaylist(track index: Int) -> String {
        let durations = (0..<segments).map { Double(bounds[$0 + 1] - bounds[$0]) / 1_000_000 }
        let target = Int((durations.max() ?? 1).rounded(.up))
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(max(1, target))", "#EXT-X-MEDIA-SEQUENCE:0",
                     "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-INDEPENDENT-SEGMENTS"]
        let text = tracks[index].kind == .subtitle
        if !text { lines.append("#EXT-X-MAP:URI=\"\(index).mp4\"") }
        for (segment, duration) in durations.enumerated() {
            lines.append(String(format: "#EXTINF:%.6f,", duration))
            lines.append("\(index)-\(segment).\(text ? "vtt" : "m4s")")
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    /// A Dolby Vision 5 picture, served as it is: it has no HDR10 picture to convert to SDR.
    var isDolbyVision: Bool { tracks[0].kind == .video && tracks[0].mode == .copy && tracks[0].dolbyVision == .dvh1 }

    var videoRange: String {
        let stream = tracks[0].stream
        if tracks[0].toneMap { return "SDR" }
        if tracks[0].mode == .copy, tracks[0].dolbyVision == .dvh1 { return "PQ" }
        return stream.colorTransfer == 16 ? "PQ" : stream.colorTransfer == 18 ? "HLG" : "SDR"
    }

    private func bandwidth(peak: Bool) -> Int {
        let seconds = Double(bounds[bounds.count - 1] - bounds[0]) / 1_000_000
        let audio = tracks.filter { $0.kind == .audio }.map { $0.mode == .copy ? Int($0.stream.bitRate) : $0.bitRate }.max() ?? 0
        let video = tracks[0]
        var bits: Double
        if video.mode != .copy { bits = Double(video.bitRate + audio) }
        else if size > 0, seconds > 0 { bits = Double(size) * 8 / seconds }
        else { bits = Double(max(Int(video.stream.bitRate), 8_000_000) + audio) }
        return Int(bits * (peak ? 1.5 : 1))
    }

    private func quoted(_ text: String) -> String { text.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\n", with: " ") }

    /// The stream's title, or its language, or its format.
    static func displayName(_ track: Track) -> String {
        let stream = track.stream
        let title = stream.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        if let tag = languageTag(stream.language), let name = Locale.current.localizedString(forLanguageCode: tag) { return name }
        let names = ["ac3": "AC-3", "eac3": "E-AC-3", "dts": "DTS", "truehd": "TrueHD", "subrip": "SRT", "ass": "ASS", "ssa": "SSA", "webvtt": "WebVTT", "mov_text": "Text"]
        let format = names[stream.codec] ?? stream.codec.uppercased()
        guard stream.kind == .audio else { return format }
        let layout = [1: "1.0", 2: "2.0", 6: "5.1", 8: "7.1"][stream.channels] ?? "\(stream.channels)ch"
        return "\(format) \(layout)"
    }

    /// The BCP 47 tag HLS wants for a Matroska (ISO 639-2) language code; nil when it names none.
    static func languageTag(_ code: String) -> String? {
        let code = code.lowercased().trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty, !["und", "mis", "mul", "zxx"].contains(code), code.allSatisfy({ $0.isLetter || $0 == "-" }) else { return nil }
        let tags = ["chi": "zh", "zho": "zh", "cmn": "zh", "eng": "en", "jpn": "ja", "kor": "ko", "fre": "fr", "fra": "fr",
                    "ger": "de", "deu": "de", "spa": "es", "rus": "ru", "ita": "it", "por": "pt", "tha": "th", "vie": "vi",
                    "ara": "ar", "hin": "hi", "ind": "id", "may": "ms", "msa": "ms", "dut": "nl", "nld": "nl", "pol": "pl",
                    "tur": "tr", "swe": "sv", "cze": "cs", "ces": "cs", "gre": "el", "ell": "el", "heb": "he", "hun": "hu",
                    "dan": "da", "fin": "fi", "nor": "no", "nob": "nb", "ukr": "uk", "rum": "ro", "ron": "ro", "fil": "fil", "tgl": "tl",
                    "chs": "zh-Hans", "cht": "zh-Hant"]
        return tags[code] ?? code
    }

    // MARK: - Codec strings

    /// The track's CODECS entry, from its initialization segment (the decoder configuration the writer made).
    func codec(track index: Int, initialization data: Data) -> String? {
        let track = tracks[index]
        switch track.kind {
        case .audio:
            if track.mode == .aac { return "mp4a.40.2" }
            switch track.stream.codec {
            case "aac": return track.stream.profile == 4 ? "mp4a.40.5" : track.stream.profile == 28 ? "mp4a.40.29" : "mp4a.40.2"
            case "ac3": return "ac-3"
            case "eac3": return "ec-3"
            case "flac": return "fLaC"
            case "alac": return "alac"
            default: return nil
            }
        case .video:
            let codec = track.mode == .h264 ? "h264" : track.mode == .hevc ? "hevc" : track.stream.codec
            switch codec {
            case "h264": return Self.box("avcC", in: data).flatMap(Self.avcCodec)
            case "hevc":
                if track.mode == .copy, track.dolbyVision == .dvh1, let dovi = Self.box("dvcC", in: data) ?? Self.box("dvvC", in: data) {
                    return Self.doviCodec(dovi)?.codec
                }
                return Self.box("hvcC", in: data).flatMap { Self.hevcCodec($0) }
            case "av1": return Self.box("av1C", in: data).flatMap(Self.av1Codec)
            default: return nil
            }
        default: return nil
        }
    }

    /// A profile 8 picture's Dolby Vision entry for SUPPLEMENTAL-CODECS.
    func supplementalCodec(initialization data: Data) -> String? {
        guard tracks[0].mode == .copy, tracks[0].dolbyVision == .hvc1,
              let dovi = Self.box("dvcC", in: data) ?? Self.box("dvvC", in: data), let value = Self.doviCodec(dovi) else { return nil }
        guard let brand = [1: "db1p", 2: "db2g", 4: "db4h"][value.compatibility] else { return nil }
        return "\(value.codec)/\(brand)"
    }

    /// The payload of the first box of this type in an initialization segment (a box header right before it).
    static func box(_ type: String, in data: Data) -> Data? {
        let bytes = [UInt8](data), tag = [UInt8](type.utf8)
        guard bytes.count >= 8 else { return nil }
        var at = 4
        while at + 4 <= bytes.count {
            if bytes[at..<at + 4].elementsEqual(tag) {
                let size = bytes[at - 4..<at].reduce(0) { $0 << 8 | Int($1) }
                if size >= 8, at - 4 + size <= bytes.count { return Data(bytes[at + 4..<at - 4 + size]) }
            }
            at += 1
        }
        return nil
    }

    static func avcCodec(_ config: Data) -> String? {
        let bytes = [UInt8](config)
        guard bytes.count >= 4, bytes[0] == 1 else { return nil }
        return String(format: "avc1.%02x%02x%02x", bytes[1], bytes[2], bytes[3])
    }

    /// RFC 6381 for HEVC: profile space and profile, compatibility flags in reverse bit order, tier and level,
    /// then the constraint bytes without trailing zeros.
    static func hevcCodec(_ config: Data, tag: String = "hvc1") -> String? {
        let bytes = [UInt8](config)
        guard bytes.count >= 13 else { return nil }
        let space = ["", "A", "B", "C"][Int(bytes[1] >> 6)]
        let tier = bytes[1] & 0x20 != 0 ? "H" : "L"
        let profile = bytes[1] & 0x1f
        let flags = bytes[2..<6].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        var reversed: UInt32 = 0
        for bit in 0..<32 where flags & (1 << bit) != 0 { reversed |= 1 << (31 - bit) }
        var constraints = Array(bytes[6..<12])
        while constraints.last == 0 { constraints.removeLast() }
        var parts = [tag, "\(space)\(profile)", String(reversed, radix: 16, uppercase: true), "\(tier)\(bytes[12])"]
        parts += constraints.map { String($0, radix: 16, uppercase: true) }
        return parts.joined(separator: ".")
    }

    static func doviCodec(_ config: Data) -> (codec: String, compatibility: Int)? {
        let bytes = [UInt8](config)
        guard bytes.count >= 5 else { return nil }
        let profile = Int(bytes[2] >> 1), level = Int(bytes[2] & 1) << 5 | Int(bytes[3] >> 3)
        return (String(format: "dvh1.%02d.%02d", profile, level), Int(bytes[4] >> 4))
    }

    static func av1Codec(_ config: Data) -> String? {
        let bytes = [UInt8](config)
        guard bytes.count >= 3, bytes[0] & 0x80 != 0 else { return nil }
        let profile = bytes[1] >> 5, level = bytes[1] & 0x1f
        let tier = bytes[2] & 0x80 != 0 ? "H" : "M"
        let depth = bytes[2] & 0x20 != 0 ? 12 : bytes[2] & 0x40 != 0 ? 10 : 8
        return String(format: "av01.%d.%02d%@.%02d", profile, level, tier, depth)
    }

    // MARK: - Subtitles

    struct Cue: Sendable, Equatable {
        var start: Int64, end: Int64
        var text: String
    }

    /// A subtitle packet's text as WebVTT cue text: SubRip keeps its italics and bold, ASS loses its styling
    /// (WebVTT has none of its own to map it to). Nil for an empty event or an ASS drawing.
    static func cueText(_ data: Data, codec: String) -> String? {
        var text: String
        switch codec {
        case "ass", "ssa":
            // FFmpeg's ASS events: ReadOrder, Layer, Style, Name, MarginL, MarginR, MarginV, Effect, Text.
            let fields = String(decoding: data, as: UTF8.self).split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
            guard fields.count == 9 else { return nil }
            text = String(fields[8])
            if text.firstMatch(of: /\{[^}]*\\p[1-9]/) != nil { return nil }
            text = text.replacing(/\{[^}]*\}/, with: "")
                .replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\h", with: " ")
            text = escaped(text)
        case "mov_text":
            let bytes = [UInt8](data)
            guard bytes.count >= 2 else { return nil }
            let length = min(Int(bytes[0]) << 8 | Int(bytes[1]), bytes.count - 2)
            text = escaped(String(decoding: bytes[2..<2 + length], as: UTF8.self))
        case "webvtt":
            text = String(decoding: data, as: UTF8.self)
        default:
            // SubRip and plain text: keep <i>, <b> and <u>, drop the rest (<font>, ASS-style {\an8}).
            text = String(decoding: data, as: UTF8.self).replacing(/\{\\[^}]*\}/, with: "")
            let kept = /<(\/?)([ibu])>/.ignoresCase()
            text = text.replacing(kept) { "\u{1}\($0.output.1)\($0.output.2.lowercased())\u{2}" }
            text = escaped(text.replacing(/<[^>]*>/, with: ""))
                .replacingOccurrences(of: "\u{1}", with: "<").replacingOccurrences(of: "\u{2}", with: ">")
        }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacing(/\n{2,}/, with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // "-->" would end the cue's timing line early.
        text = text.replacingOccurrences(of: "-->", with: "->")
        return text.isEmpty ? nil : text
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// A subtitle segment. Cue times are the file's; X-TIMESTAMP-MAP places them on the media's timeline,
    /// which runs `offset` ahead.
    static func webVTT(_ cues: [Cue], offset: Int64) -> String {
        var text = "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:\(offset * 9 / 100),LOCAL:00:00:00.000\n"
        for cue in cues.sorted(by: { $0.start < $1.start }) {
            text += "\n\(time(cue.start)) --> \(time(max(cue.end, cue.start + 1_000)))\n\(cue.text)\n"
        }
        return text
    }

    static func time(_ microseconds: Int64) -> String {
        let milliseconds = max(0, microseconds) / 1_000
        return String(format: "%02lld:%02lld:%02lld.%03lld", milliseconds / 3_600_000, milliseconds / 60_000 % 60, milliseconds / 1_000 % 60, milliseconds % 1_000)
    }
}

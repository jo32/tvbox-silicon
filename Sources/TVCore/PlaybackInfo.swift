import Foundation

/// What the player's info panel shows (Settings → Show Video Info, off by default): the picture, the sound and the
/// stream's rate, one line each, from what AVFoundation reports about the playing item. Only the wording lives here;
/// the app reads the values.
public struct PlaybackInfo: Equatable, Sendable {
    public static let key = "showsPlaybackInfo"

    /// The picture's display size in pixels.
    public var width = 0
    public var height = 0
    public var frameRate: Double?
    /// The video format's four-character code ('hvc1', 'avc1', …).
    public var videoCodec: UInt32?
    /// The video's transfer function (kCMFormatDescriptionExtension_TransferFunction), which tells HDR apart.
    public var transferFunction: String?
    public var audioCodec: UInt32?
    public var sampleRate: Double?
    public var channels: Int?
    /// What the stream plays at, in bits per second.
    public var bitrate: Double?
    /// What arrives over the network, in bytes per second.
    public var download: Double?

    public init() {}

    public var isEmpty: Bool { video == nil && audio == nil && network() == nil }

    /// "HEVC · 3840×2160 · 23.98 fps · HDR10"
    public var video: String? {
        var parts: [String] = []
        let codec = videoCodec.map(Self.videoName)
        if let codec { parts.append(codec) }
        if width > 0, height > 0 { parts.append("\(width)×\(height)") }
        if let frameRate, frameRate.isFinite, frameRate > 0 { parts.append(Self.number(frameRate, digits: 2) + " fps") }
        // Dolby Vision names itself; its base layer's transfer function would only repeat it.
        if codec?.hasPrefix("Dolby Vision") != true, let range = transferFunction.flatMap(Self.dynamicRange) { parts.append(range) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "AAC · 48 kHz · 2.0"
    public var audio: String? {
        var parts: [String] = []
        if let audioCodec { parts.append(Self.audioName(audioCodec)) }
        if let sampleRate, sampleRate.isFinite, sampleRate > 0 { parts.append(Self.number(sampleRate / 1000, digits: 1) + " kHz") }
        if let channels, channels > 0 { parts.append(Self.layout(channels)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "Bitrate 4.2 Mb/s · Download 1.3 MB/s"
    public func network(language: String? = nil) -> String? {
        var parts: [String] = []
        if let bitrate, bitrate.isFinite, bitrate > 0 { parts.append(L10n.text("Bitrate %@", Self.bits(bitrate), language: language)) }
        if let download, download.isFinite, download >= 0, bitrate != nil || download > 0 {
            parts.append(L10n.text("Download %@", Self.bytes(download), language: language))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Names

    public static func videoName(_ code: UInt32) -> String {
        switch fourCC(code) {
        case "avc1", "avc3": "H.264"
        case "hvc1", "hev1": "HEVC"
        case "dvh1", "dvhe": "Dolby Vision (HEVC)"
        case "dva1", "dvav": "Dolby Vision (H.264)"
        case "dav1": "Dolby Vision (AV1)"
        case "av01": "AV1"
        case "vp08": "VP8"
        case "vp09": "VP9"
        case "mp4v": "MPEG-4"
        case "mp2v", "mpg2": "MPEG-2"
        case "jpeg", "mjpa", "mjpb": "Motion JPEG"
        case "apcn", "apch", "apcs", "apco", "ap4h", "ap4x": "ProRes"
        case let other: other.hasPrefix("0x") ? other : other.trimmingCharacters(in: .whitespaces).uppercased()
        }
    }

    public static func audioName(_ code: UInt32) -> String {
        switch fourCC(code) {
        case "aac ", "mp4a": "AAC"
        case "aach": "HE-AAC"
        case "aacp": "HE-AAC v2"
        case "aacl": "AAC-LD"
        case "aace": "AAC-ELD"
        case "ac-3": "Dolby Digital"
        case "ec-3": "Dolby Digital Plus"
        case "ac-4": "Dolby AC-4"
        case ".mp3": "MP3"
        case ".mp2": "MP2"
        case "alac": "ALAC"
        case "flac", "fLaC": "FLAC"
        case "opus": "Opus"
        case "lpcm": "PCM"
        case let other: other.hasPrefix("0x") ? other : other.trimmingCharacters(in: CharacterSet(charactersIn: " .")).uppercased()
        }
    }

    /// HDR10 for PQ, HLG; nothing for standard range.
    public static func dynamicRange(_ transferFunction: String) -> String? {
        switch transferFunction {
        case "SMPTE_ST_2084_PQ": "HDR10"
        case "ITU_R_2100_HLG": "HLG"
        default: nil
        }
    }

    static func layout(_ channels: Int) -> String {
        switch channels {
        case 1: "1.0"
        case 2: "2.0"
        case 6: "5.1"
        case 8: "7.1"
        default: "\(channels) ch"
        }
    }

    /// 850 kb/s, 4.2 Mb/s, 120 Mb/s.
    static func bits(_ perSecond: Double) -> String {
        perSecond < 1_000_000 ? "\(Int((perSecond / 1000).rounded())) kb/s" : number(perSecond / 1_000_000, digits: perSecond < 100_000_000 ? 1 : 0) + " Mb/s"
    }

    /// 0 KB/s, 640 KB/s, 1.3 MB/s.
    static func bytes(_ perSecond: Double) -> String {
        perSecond < 1_000_000 ? "\(Int((perSecond / 1000).rounded())) KB/s" : number(perSecond / 1_000_000, digits: perSecond < 100_000_000 ? 1 : 0) + " MB/s"
    }

    /// At most `digits` decimals, trailing zeros dropped: 25, 23.98, 29.97, 44.1.
    static func number(_ value: Double, digits: Int) -> String {
        var text = String(format: "%.\(digits)f", locale: Locale(identifier: "en_US_POSIX"), value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text
    }

    static func fourCC(_ code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        guard bytes.allSatisfy({ (32..<127).contains($0) }) else { return String(format: "0x%08X", code) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

import Foundation
import Testing
@testable import TVCore

private func code(_ text: String) -> UInt32 { text.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

@Test func videoInfoNamesTheFormatSizeRateAndRange() {
    var info = PlaybackInfo()
    #expect(info.video == nil && info.audio == nil && info.network(language: "en") == nil && info.isEmpty)
    info.videoCodec = code("hvc1"); info.width = 3840; info.height = 2160; info.frameRate = 23.976
    info.transferFunction = "SMPTE_ST_2084_PQ"
    #expect(info.video == "HEVC · 3840×2160 · 23.98 fps · HDR10")
    info.videoCodec = code("dvh1")
    #expect(info.video == "Dolby Vision (HEVC) · 3840×2160 · 23.98 fps")
    info.videoCodec = code("avc1"); info.width = 1920; info.height = 1080; info.frameRate = 25; info.transferFunction = "ITU_R_709_2"
    #expect(info.video == "H.264 · 1920×1080 · 25 fps")
    info.transferFunction = "ITU_R_2100_HLG"; info.frameRate = 0
    #expect(info.video == "H.264 · 1920×1080 · HLG")
    info.videoCodec = nil; info.transferFunction = nil; info.frameRate = .nan
    #expect(info.video == "1920×1080")
    #expect(PlaybackInfo.videoName(code("xyz ")) == "XYZ")
    #expect(PlaybackInfo.videoName(0x0000_0001) == "0x00000001")
}

@Test func audioInfoNamesTheCodecRateAndChannels() {
    var info = PlaybackInfo()
    info.audioCodec = code("aac "); info.sampleRate = 48_000; info.channels = 2
    #expect(info.audio == "AAC · 48 kHz · 2.0")
    info.audioCodec = code("ec-3"); info.sampleRate = 44_100; info.channels = 6
    #expect(info.audio == "Dolby Digital Plus · 44.1 kHz · 5.1")
    info.audioCodec = code(".mp3"); info.sampleRate = nil; info.channels = 3
    #expect(info.audio == "MP3 · 3 ch")
}

@Test func networkInfoShowsTheBitrateAndDownloadSpeed() {
    var info = PlaybackInfo()
    info.bitrate = 4_230_000; info.download = 1_310_000
    #expect(info.network(language: "en") == "Bitrate 4.2 Mb/s · Download 1.3 MB/s")
    #expect(info.network(language: "zh-Hans") == "码率 4.2 Mb/s · 下载 1.3 MB/s")
    info.bitrate = 850_000; info.download = 0
    #expect(info.network(language: "en") == "Bitrate 850 kb/s · Download 0 KB/s")
    info.bitrate = nil
    #expect(info.network(language: "en") == nil)
    info.download = 640_000
    #expect(info.network(language: "en") == "Download 640 KB/s")
    info.bitrate = 120_400_000; info.download = nil
    #expect(info.network(language: "en") == "Bitrate 120 Mb/s")
    for language in L10n.supportedLanguages where language != "en" {
        #expect(L10n.text("Show Video Info", language: language) != "Show Video Info")
        #expect(L10n.text("Bitrate %@", "x", language: language) != "Bitrate x")
        #expect(L10n.text("Download %@", "x", language: language) != "Download x")
    }
}

@Test func badgesShowDecodingFormatRangeSizeAndRate() {
    var info = PlaybackInfo()
    #expect(info.badges.isEmpty)
    info.videoCodec = code("hvc1"); info.width = 1920; info.height = 1080; info.frameRate = 23.976; info.hardwareDecoding = true
    #expect(info.badges == ["HW", "H265", "1080P", "24FPS"])
    info.width = 3840; info.height = 1600; info.transferFunction = "SMPTE_ST_2084_PQ"
    #expect(info.badges == ["HW", "HDR10", "H265", "4K", "24FPS"])
    // Dolby Vision: a DV tag before its base layer's codec, never HDR10 beside it.
    info.videoCodec = code("dvh1")
    #expect(info.badges == ["HW", "DV", "H265", "4K", "24FPS"])
    // Profile 8 rides on hvc1 with Dolby Vision's box; MiraPlay's "HW DV P8 H265 4K 24FPS 25Mbps".
    info.videoCodec = code("hvc1"); info.dolbyVisionProfile = 8; info.bitrate = 25_200_000
    #expect(info.badges == ["HW", "DV P8", "H265", "4K", "24FPS", "25Mbps"])
    #expect(info.video == "Dolby Vision 8 (HEVC) · 3840×1600 · 23.98 fps")
    // Profile 7 served as its HDR10 base.
    info.dolbyVisionProfile = nil; info.droppedDolbyVisionProfile = 7; info.bitrate = 2_460_000
    #expect(info.badges == ["HW", "DV P7→HDR10", "H265", "4K", "24FPS", "2.5Mbps"])
    info.droppedDolbyVisionProfile = nil; info.bitrate = 850_000
    #expect(info.badges.last == "850Kbps")
    info.bitrate = nil
    info.videoCodec = code("av01"); info.hardwareDecoding = false; info.transferFunction = "ITU_R_2100_HLG"
    info.width = 1280; info.height = 720; info.frameRate = 29.97
    #expect(info.badges == ["SW", "HLG", "AV1", "720P", "30FPS"])
    // Smooth Motion draws 60 frames a second (#519).
    info.smoothedFrameRate = 60
    #expect(info.badges.last == "30→60FPS")
    info.frameRate = 60
    #expect(info.badges.last == "60FPS")
    info.videoCodec = code("avc1"); info.hardwareDecoding = nil; info.transferFunction = nil
    info.width = 2560; info.height = 1440; info.frameRate = nil
    #expect(info.badges == ["H264", "2K"])
    info.width = 854; info.height = 480
    #expect(info.badges == ["H264", "480P"])
    // No decoding tag without a video format to tell it from.
    info.videoCodec = nil; info.hardwareDecoding = true
    #expect(info.badges == ["480P"])
}

@Test func dolbyVisionProfileComesFromItsConfigBox() {
    // dvcC payload: version 1.0, then profile (7 bits) and level (6 bits): profile 8, level 6.
    #expect(PlaybackInfo.dolbyVisionProfile(config: Data([1, 0, 0x10, 0x35, 0x10])) == 8)
    #expect(PlaybackInfo.dolbyVisionProfile(config: Data([1, 0, 0x0A, 0x35, 0x10])) == 5)
    #expect(PlaybackInfo.dolbyVisionProfile(config: Data([1, 0, 0x0E, 0x35, 0x10])) == 7)
    #expect(PlaybackInfo.dolbyVisionProfile(config: Data([1, 0])) == nil)
}

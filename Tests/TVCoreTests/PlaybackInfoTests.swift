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

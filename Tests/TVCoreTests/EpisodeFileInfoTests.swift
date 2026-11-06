import Testing
@testable import TVCore

// Names from #620 and the netdisk lines of #318.
@Test func episodeFileInfoReadsResolutionAndSizeFromFileNames() {
    #expect(EpisodeFileInfo.summary("[5.2GB]The.Silent.Storm.2026.S01E01.2160p.HQ.WEB-DL.60fps.H.265.AAC.mp4【G 谷--雨】") == "4K · 5.2G")
    #expect(EpisodeFileInfo.summary("[1.7GB]10_4K.mkv") == "4K · 1.7G")
    #expect(EpisodeFileInfo.summary("[796.61MB] W‑我DTT鸵N先S 01.mp4") == "797M")
    #expect(EpisodeFileInfo.summary("[2.00GB] 4K 01.2160p.HDR.60fps.WEB-DL.H265.AAC-XiaoXueshen.mkv") == "4K · 2G")
    #expect(EpisodeFileInfo.summary("某剧 第十二集 1080p.mp4") == "1080P")
    #expect(EpisodeFileInfo.summary("Show.S01E02.720p【1.26G】.mkv") == "720P · 1.3G")
    #expect(EpisodeFileInfo.summary("Movie.2025.UHD.BluRay.mkv 45.3 GB") == "4K · 45.3G")
}

@Test func episodeFileInfoLeavesOtherNamesAlone() {
    for name in ["第1集", "01", "正片", "花絮", "S01E04K", "24K纯金", "5G时代 第3集", "H.265 60fps", "第10集 60M"] {
        #expect(EpisodeFileInfo.summary(name) == nil, "\(name)")
    }
}

@Test func episodeFileInfoDoesNotRepeatWhatTheTitleSays() {
    #expect(EpisodeFileInfo.summary("[1.7GB]10_4K.mkv", besides: "10_4K.mkv") == "1.7G")
    #expect(EpisodeFileInfo.summary("[2.00GB] 4K 01.2160p.mkv", besides: "第1集 · 4K") == "2G")
    #expect(EpisodeFileInfo.summary("[2.00GB] 4K 01.2160p.mkv", besides: "第1集") == "4K · 2G")
    #expect(EpisodeFileInfo.summary("4K国语", besides: "4K国语") == nil)
}

import Foundation
import Testing
@testable import TVCore

// Names below are real netdisk and magnet lines, fetched for #318.

private func labels(_ names: [String], language: String = "zh-Hans") -> [String]? {
    EpisodeLabels.labels(names: names, language: language)
}

@Test func episodeLabelsReadSeasonEpisodeMarkersInFileNames() {
    let names = (1...3).map { "[1.\($0)GB] 海市蜃楼.The.Mirage.2025.S01E0\($0).2160p.WEB-DL.H265.DDP5.1.mkv" }
    #expect(labels(names) == ["第1集", "第2集", "第3集"])
    #expect(labels(names, language: "en") == ["Episode 1", "Episode 2", "Episode 3"])
    #expect(labels(["[1.98GB] S02 QYN-S02E01.4K.TGucquark.mkv", "[1.81GB] S02 QYN-S02E02.4K.TGucquark.mkv"]) == ["第1集", "第2集"])
    #expect(labels(["某剧 第十二集 1080p.mp4", "某剧 第十三集 1080p.mp4"]) == ["第12集", "第13集"])
}

@Test func episodeLabelsUseTheNumberThatChangesBetweenNames() {
    #expect(labels(["[1.33GB]HSSL.4K.01.mkv", "[1.31GB]HSSL.4K.02.mkv", "[1.28GB]HSSL.4K.03.mkv"]) == ["第1集", "第2集", "第3集"])
    // Scrambled names, one with a suffix of its own, and one with a marker among plain numbers.
    #expect(labels(["[796.61MB] W‑我DTT鸵N先S 01.mp4", "[859.35MB] W‑我DTT鸵N先S 02.mp4", "[770.75MB] W‑我DTT鸵N先S 09 W.mp4"])
            == ["第1集", "第2集", "第9集"])
    #expect(labels(["[572.10MB]01.mp4", "[539.60MB]02.mp4", "[549.21MB]中字EP5.mp4"]) == ["第1集", "第2集", "第5集"])
}

@Test func episodeLabelsTellTwoCopiesOfAnEpisodeApart() {
    let names = ["[394.95MB] H-海市蜃.楼 01.mp4", "[483.90MB] H-海市蜃.楼 02.mp4",
                 "[186.27MB] H-海市蜃.楼 毛骗团队首部古装剧_定档预告.mp4",
                 "[2.00GB] 4K 01.2160p.HDR.60fps.WEB-DL.H265.AAC-XiaoXueshen.mkv",
                 "[2.39GB] 4K 02.2160p.HDR.60fps.WEB-DL.H265.AAC-XiaoXueshen.mkv"]
    // The trailer has no number and keeps its name, without the size tag and extension.
    #expect(labels(names) == ["第1集", "第2集", "H-海市蜃.楼 毛骗团队首部古装剧_定档预告", "第1集 · 4K", "第2集 · 4K"])
    // Copies with no quality word between them go by their order.
    #expect(labels(["S01特别版 QYN-S01TBB-E24.4K.mkv", "S01特别版 QYN-S01TBB-E25.4K(1).mkv", "S01特别版 QYN-S01TBB-E25.4K.mkv"])
            == ["第24集", "第25集 (1)", "第25集 (2)"])
}

@Test func episodeLabelsNameSeasonsOnlyWhenALineHoldsSeveral() {
    #expect(labels(["Show.S01E01.1080p.mkv", "Show.S01E02.1080p.mkv", "Show.S02E01.1080p.mkv"]) == ["S1 第1集", "S1 第2集", "S2 第1集"])
}

@Test func episodeLabelsShowMagnetPacksAsRanges() {
    #expect(labels(["01-04.2160p.HD国语中字无水印.mp4", "05-08.2160p.HD国语中字无水印.mp4", "01-08.1080p.HD国语中字无水印.mp4"])
            == ["第1-4集 · 2160p", "第5-8集 · 2160p", "第1-8集 · 1080p"])
    #expect(labels(["01-08.1080p.HD国语中字无水印.mp4", "09-15.1080p.HD国语中字无水印.mp4"]) == ["第1-8集", "第9-15集"])
}

@Test func episodeLabelsLeaveLinesWithoutATrustworthyNumber() {
    #expect(labels(["第01集", "第02集"]) == nil)
    #expect(labels(["4K国语", "精彩片段"]) == nil)
    #expect(labels(["20251024(第1期(上))", "20251024(第1期(下))"]) == nil)
    #expect(labels(["[5.48GB]Kiss.Me.My.Ghost.Friend.2026.1080p.HamiVideo.WEB-DL.AAC2.0.H.264-HamiltonShare.mkv"]) == nil)
    #expect(labels(["Variety.20251220.1080p.mp4", "Variety.20251227.1080p.mp4"]) == nil)
    #expect(labels(["Movie.2024.2160p.WEB-DL.mkv", "Movie.2025.2160p.WEB-DL.mkv"]) == nil)
    #expect(labels(["电影《神探之痕迹》高能片段释出 深圳站路演", "电影《神探之痕迹》彩蛋片段重磅释出", "“留痕”版预告"]) == nil)
}

@Test func episodeLabelsReadOneHistoryName() {
    // #521, #522: history keeps one name, where a picker keeps the whole line.
    #expect(labels(["[1.18GB] 海市蜃楼.The.Mirage.2025.S01E05.2160p.WEB-DL.mkv"]) == ["第5集"])
    #expect(labels(["[1.18GB] 海市蜃楼.The.Mirage.2025.S01E05.2160p.WEB-DL.mkv"], language: "en") == ["Episode 5"])
    #expect(labels(["HSSL.4K.01.mkv"]) == ["第1集"])
    #expect(labels(["01.mp4"]) == ["第1集"])
    #expect(labels(["某剧 第十二集 1080p.mp4"]) == ["第12集"])
    #expect(labels(["01-04.2160p.HD国语中字无水印.mp4"]) == ["第1-4集"])
    #expect(labels(["第1集"]) == nil)
    // Years, dates, codecs and versions are not episodes.
    #expect(labels(["Movie.2025.2160p.WEB-DL.mkv"]) == nil)
    #expect(labels(["Variety.20251220.1080p.mp4"]) == nil)
    #expect(labels(["Show.2026.01.02.mkv"]) == nil)
    #expect(labels(["Show.AAC2.0.mkv"]) == nil)
    #expect(labels(["Show.HEVC.1080p.mkv"]) == nil)
}

@Test func episodeLabelsKeepALoneNamesLaterSeason() {
    // History and the Watch Now header show one name: S01E05 and S02E05 must not both read 第5集.
    #expect(EpisodeLabels.historyLabel("[1.18GB] 海市蜃楼.The.Mirage.2025.S01E05.2160p.WEB-DL.mkv", language: "zh-Hans") == "第5集")
    #expect(EpisodeLabels.historyLabel("[1.18GB] 海市蜃楼.The.Mirage.2025.S02E05.2160p.WEB-DL.mkv", language: "zh-Hans") == "S2 第5集")
    #expect(EpisodeLabels.historyLabel("Show.S02E05.mkv", language: "en") == "S2 Episode 5")
    #expect(EpisodeLabels.historyLabel("HSSL.4K.01.mkv", language: "zh-Hans") == "第1集")
    // Names it can't read, and names already short, keep their text.
    #expect(EpisodeLabels.historyLabel("Movie.2025.2160p.WEB-DL.mkv", language: "zh-Hans") == "Movie.2025.2160p.WEB-DL.mkv")
    #expect(EpisodeLabels.historyLabel("第2季 第1集", language: "zh-Hans") == "第2季 第1集")
    #expect(EpisodeLabels.historyLabel("正片", language: "zh-Hans") == "正片")
}

@Test func episodeLabelsSeeAFileNameThroughTheShareTagAfterIt() {
    // #595's screenshot and #599's history: a drive share puts its own tag after the extension, and the line kept
    // its raw names ("E01.mp4【太阳鱼】"), so neither the label nor the file's details showed.
    #expect(labels(["E01.mp4【太阳鱼】", "E02.mp4【太阳鱼】", "E03.mp4【太阳鱼】"]) == ["第1集", "第2集", "第3集"])
    #expect(labels(["E01.mp4【太阳鱼】", "花絮.mp4【太阳鱼】", "E02.mp4【太阳鱼】"]) == ["第1集", "花絮", "第2集"])
    #expect(EpisodeLabels.historyLabel("[1.9GB]01.mp4【D-达-D-牧-C】", language: "zh-Hans") == "第1集")
    #expect(EpisodeLabels.historyLabel("[1.9GB]01.mp4【D-达-D-牧-C】", showsDetails: true, language: "zh-Hans") == "第1集 · 1.9GB")
    #expect(EpisodeLabels.historyLabel("[5.4GB]Where.the.Mask.Ends.2026.S01E01.2160p.HQ.WEB-DL.60fps.H.265.AAC.mp4【J 嫁！金＠钗-】",
                                       showsDetails: true, language: "zh-Hans") == "第1集 · 5.4GB · 2160p")
    // A tag inside a short name that isn't a file keeps the line's own names.
    #expect(labels(["第1集【超清】", "第2集【超清】"]) == nil)
}

@Test func episodeLabelsAddFileDetailsWhenTheViewerAsks() {
    // #595: the size tag and resolution the short label would otherwise hide.
    let name = "[5.4GB]Where.the.Mask.Ends.2026.S01E01.2160p.HQ.WEB-DL.60fps.H.265.AAC.mp4"
    #expect(EpisodeLabels.historyLabel(name, showsDetails: true, language: "zh-Hans") == "第1集 · 5.4GB · 2160p")
    #expect(EpisodeLabels.historyLabel(name, language: "zh-Hans") == "第1集")
    #expect(EpisodeLabels.historyLabel("[4.9GB]LXRG.S01E01.mkv", showsDetails: true, language: "zh-Hans") == "第1集 · 4.9GB")
    #expect(EpisodeLabels.historyLabel("Show.4K.01.mkv", showsDetails: true, language: "zh-Hans") == "第1集 · 4K")
    // A name that already reads as itself keeps its text, details included.
    #expect(EpisodeLabels.historyLabel("Movie.2025.2160p.WEB-DL.mkv", showsDetails: true, language: "zh-Hans") == "Movie.2025.2160p.WEB-DL.mkv")
    #expect(EpisodeLabels.fileDetails("[1.18GB] 海市蜃楼.The.Mirage.2025.S01E05.2160p.WEB-DL.mkv") == "1.18GB · 2160p")
    #expect(EpisodeLabels.fileDetails("[1.18GB] Show.S01E01.mkv") == "1.18GB")
    #expect(EpisodeLabels.fileDetails("Show.S01E01.mkv") == nil)
}

@Test func episodeLabelsGoByLineAndEpisodeID() {
    let episodes = [Episode(id: "a1", name: "Show.4K.01.mkv", address: "1", flag: "A"),
                    Episode(id: "b1", name: "第1集", address: "2", flag: "B"),
                    Episode(id: "a2", name: "Show.4K.02.mkv", address: "3", flag: "A")]
    #expect(EpisodeLabels.labels(episodes, language: "zh-Hans") == ["a1": "第1集", "a2": "第2集"])
}

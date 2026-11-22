import Testing
@testable import TVCore

@Suite struct MediaNameTests {
    private func check(_ raw: String, file: Bool = false, _ title: String, year: Int? = nil, season: Int? = nil, episode: Int? = nil,
                       sourceLocation: SourceLocation = #_sourceLocation) {
        let name = MediaName(raw, isFile: file)
        #expect(name.title == title, "\(raw)", sourceLocation: sourceLocation)
        #expect(name.year == year, "\(raw)", sourceLocation: sourceLocation)
        #expect(name.season == season, "\(raw)", sourceLocation: sourceLocation)
        #expect(name.episode == episode, "\(raw)", sourceLocation: sourceLocation)
        #expect(!name.isCategory, "\(raw)", sourceLocation: sourceLocation)
    }

    @Test func folderNames() {
        check("小城良方（2026）", "小城良方", year: 2026)
        check("小城良方 (2026) 4K", "小城良方", year: 2026)
        check("庆余年 第二季", "庆余年", season: 2)
        check("庆余年第二季 全三十六集", "庆余年", season: 2)
        check("Breaking.Bad.S01.1080p.BluRay.x264", "Breaking Bad", season: 1)
        check("Breaking Bad (2008)", "Breaking Bad", year: 2008)
        check("The.Last.of.Us.S02.2160p.WEB-DL.DDP5.1.Atmos.DV.HDR.H.265", "The Last of Us", season: 2)
        check("流浪地球2.The.Wandering.Earth.II.2023.2160p.WEB-DL.H265.HDR.DDP5.1", "流浪地球2", year: 2023)
        check("Blade.Runner.2049.2017.1080p.BluRay", "Blade Runner 2049", year: 2017)
        check("2012.2009.1080p.BluRay", "2012", year: 2009)
        check("老友记 Friends 全十季", "老友记")
        check("【蓝光原盘】霍比特人 三部曲", "霍比特人 三部曲")
        check("三体 完结 4K 国语", "三体")
        check("复仇者联盟 系列合集", "复仇者联盟")
        check("完美世界 [更新至200集]", "完美世界")
    }

    @Test func fileNames() {
        check("S01E01.mp4", file: true, "", season: 1, episode: 1)
        check("小城良方（2026） · S01E01.mp4", file: true, "小城良方", year: 2026, season: 1, episode: 1)
        check("[724.7MB]The.Silent.Storm.2026.S01E15.2160p.WEB-DL.H.265.AAC.mp4", file: true, "The Silent Storm", year: 2026, season: 1, episode: 15)
        check("[3.3GB]2026.1080p.英语.中英字幕.404.mp4「挽丨救丨计丨划（2026）」", file: true, "挽救计划", year: 2026)
        check("[电影天堂www.dytt89.com]消失的她-2023_HD国语中字.mp4", file: true, "消失的她", year: 2023)
        check("[Nekomoe kissaten][Sousou no Frieren][01][1080p][CHS].mp4", file: true, "Sousou no Frieren", episode: 1)
        check("繁花.第12集.4K.mp4", file: true, "繁花", episode: 12)
        check("繁花 EP12.mkv", file: true, "繁花", episode: 12)
        check("05.mp4", file: true, "", episode: 5)
        check("Oppenheimer.2023.IMAX.2160p.REMUX.mkv", file: true, "Oppenheimer", year: 2023)
        check("肯德基的救赎.The.Shawshank.Redemption.1994.BluRay.1080p.x264.mkv", file: true, "肯德基的救赎", year: 1994)
        check("寄生虫 Parasite (2019) [1080p].mkv", file: true, "寄生虫", year: 2019)
        check("The Matrix (1999).mkv", file: true, "The Matrix", year: 1999)
        check("Friends.S10E17-E18.The.Last.One.mkv", file: true, "Friends", season: 10, episode: 17)
    }

    @Test func seasonFoldersAndCategories() {
        for raw in ["Season 1", "S01", "第一季", "Season.02"] {
            let name = MediaName(raw, isFile: false)
            #expect(name.isSeasonOnly, "\(raw)")
        }
        #expect(MediaName("第十二季", isFile: false).season == 12)
        for raw in ["电影", "Movies", "TV Shows", "4K", "美剧", "4K电影", "高分美剧", "我的资源", "来自分享", "Downloads", "动漫"] {
            #expect(MediaName(raw, isFile: false).isCategory, "\(raw)")
        }
        // A title that merely ends like a kind is not a category.
        #expect(!MediaName("我的前半生", isFile: false).isCategory)
        #expect(!MediaName("流浪地球电影版2019", isFile: false).isCategory)
    }
}

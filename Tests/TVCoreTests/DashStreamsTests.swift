import Foundation
import Testing
@testable import TVCore

struct DashStreamsTests {
    @Test func recommendedSourcesRequireAnExplicitSubscription() throws {
        let data = Data(#"{"spider":"./x.jar","sites":[{"key":"a","name":"A","type":1,"api":"https://example.com/api"}],"lives":[{"name":"TV","url":"https://example.com/tv.m3u"}]}"#.utf8)
        let subscription = try Subscription.parse(data, origin: URL(string: "https://example.com/sub.json")!)
        let cloud = try Subscription.parse(Data(#"""
        {"yingxia":{"version":1},
         "sites":[{"key":"builtin.bilibili","name":"Bilibili","type":3,"api":"https://s.example/v1/js/bili.1.js","ext":{"builtin":true},
                    "yingxia":{"builtin":true,"account":"bilibili","names":{"zh-Hans":"哔哩哔哩","en":"Bilibili"}}},
                   {"key":"a","name":"Clash","type":3,"api":"https://s.example/v1/js/a.js","yingxia":{"builtin":true}}],
         "lives":[{"name":"Douyu Live","url":"douyu-live://rooms"}],
         "yingxiaLive":[{"id":"douyu","scheme":"douyu-live","api":"https://s.example/v1/js/live-douyu.1.js","name":"Douyu Live","tint":"#FF6B1A","glyph":"斗"}]}
        """#.utf8), origin: URL(string: "https://s.example/sub.json")!)
        #expect(CloudSources.accepts(cloud))
        let shown = try #require(Subscription.merge([subscription, cloud]))
        // Drives signed in on this machine add their "My <drive>" sources too; they don't matter here.
        let keys = { (subscription: Subscription) in subscription.sites.map(\.key).filter { !$0.hasPrefix(CloudFilesSource.keyPrefix) } }
        // Only explicit subscription merging adds the recommended source; clashes keep provenance.
        #expect(keys(shown).prefix(2) == ["a", "builtin.bilibili"])
        #expect(keys(try #require(Subscription.merge([shown, cloud]))) == keys(shown))
        #expect(shown.lives.map(\.url.absoluteString) == ["https://example.com/tv.m3u", "douyu-live://rooms"])
        #expect(keys(subscription.withCloudFiles()) == ["a"])
        let site = try #require(shown.sites.first { $0.key == "builtin.bilibili" })
        #expect(site.isBuiltIn && site.isBilibili && site.runsInProcess && site.account == "bilibili")
        let ext = try #require(try site.pluginExtension(origin: nil)?.object)
        #expect(ext["builtin"] == .bool(true) && ext["lang"]?.string?.isEmpty == false && ext["cookie"] != nil)
        #expect(Site.localizedName(["yingxia": .object(["names": .object(["zh-Hans": .string("哔哩哔哩")])])], language: "zh-Hans") == "哔哩哔哩")
        // The live platforms are read from the copy the app keeps.
        let saved = CloudSources.current
        defer { CloudSources.current = saved }
        CloudSources.current = cloud
        #expect(try CloudSources.address == cloud.origin)
        let douyu = try #require(LivePlatform(rawValue: "douyu"))
        #expect(LivePlatform(scheme: "douyu-live") == douyu && douyu.glyph == "斗" && douyu.searchable)
        #expect(shown.lives.last?.platform == douyu && shown.lives.first?.platform == nil)
        #expect(LiveCatalog.room(URL(string: "douyu-live://room/9999")!)?.id == "9999" && !LiveCatalog.isRoom(URL(string: "huya-live://room/1")!))
        // Disabling/removing the explicit subscription clears services instead of keeping an automatic copy.
        CloudSources.current = nil
        #expect(CloudSources.site(where: \.isBilibili) == nil)
        #expect(CloudSources.platforms.isEmpty && CloudMusic.current == nil)
        #expect(throws: TVError.self) { try CloudSources.address }
        // An app reads only the subscription versions it knows.
        #expect(!CloudSources.accepts(try Subscription.parse(Data(#"{"yingxia":{"version":2},"sites":[{"key":"x","type":3,"api":"https://x/x.js"}]}"#.utf8), origin: URL(string: "https://s.example/sub.json")!)))
    }

    @Test func biliProxyAddressesAndDanmakuFeedsNameTheirVideo() {
        #expect(CatalogClient.bilibiliProxyID("http://127.0.0.1:9978/proxy?do=bili&aid=1&cid=2&ep=3") == "1_2_3")
        #expect(CatalogClient.bilibiliProxyID("http://127.0.0.1:9978/proxy?do=bili&aid=1&cid=2") == "1_2")
        #expect(CatalogClient.bilibiliProxyID("http://127.0.0.1:9978/proxy?do=other&aid=1&cid=2") == nil)
        #expect(DanmakuSource.bilibiliCID("https://api.bilibili.com/x/v2/dm/web/seg.so?type=1&oid=12345") == "12345")
        #expect(DanmakuSource.bilibiliCID("https://example.com/dm?oid=12345") == nil)
    }

    @Test func segmentIndexListsFragmentsAfterTheBox() throws {
        // sidx v0: timescale 1000, first_offset 0, two references of 100 and 50 bytes.
        var box: [UInt8] = []
        func u32(_ value: Int) { box += [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) } }
        u32(56); box += Array("sidx".utf8); u32(0); u32(1); u32(1000); u32(0); u32(0); box += [0, 0, 0, 2]
        u32(100); u32(2000); u32(0x9000_0000)
        u32(50); u32(1500); u32(0x9000_0000)
        let index = try SegmentIndex(sidx: Data(box), at: 900, initialization: 0...899, url: URL(string: "https://cdn.example/v.m4s")!)
        #expect(index.references.map(\.offset) == [956, 1056])
        #expect(index.references.map(\.size) == [100, 50])
        #expect(index.bitRates.peak == 400)
        #expect(index.bitRates.average == 342)
    }

    @Test func representationsReadThePlayResultAndKeepOneCodecPerQuality() throws {
        func stream(_ quality: Int, _ codecs: String, range: String = "SDR") -> Representation? {
            Representation(["id": .number(Double(quality)), "label": .string("Q\(quality)"), "codecs": .string(codecs), "width": .number(1920), "height": .number(1080),
                            "bandwidth": .number(1000), "frameRate": .string("30000/1001"), "range": .string(range),
                            "urls": .array([.string("https://a.example/v.m4s"), .string("ftp://b.example/v")]),
                            "initialization": .string("0-999"), "indexRange": .string("1000-1500")])
        }
        let item = try #require(stream(80, "avc1.640032"))
        #expect(item.urls.map(\.absoluteString) == ["https://a.example/v.m4s"] && item.label == "Q80")
        #expect(item.index == 1000...1500 && item.initialization == 0...999)
        #expect(abs((item.frameRate ?? 0) - 29.97) < 0.01)
        #expect(stream(80, "") == nil)
        // AVC labelled HDR is left out; HEVC and AV1 only where hardware decodes them.
        let chosen = DashStreams.choose([item, stream(80, "hev1.1.6.L150.90")!, stream(64, "avc1.64001F")!, stream(125, "avc1.640033", range: "PQ")!, stream(32, "mp4a")!])
        #expect(chosen.map(\.quality) == [80, 64])
    }
}

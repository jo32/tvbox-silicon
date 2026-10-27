import Foundation
import Testing
@testable import TVCore

struct BilibiliTests {
    @Test func builtInSourceIsAddedOnceAndNeverFallsBackToAJar() throws {
        let data = Data(#"{"spider":"./x.jar","sites":[{"key":"a","name":"A","type":1,"api":"https://example.com/api"}]}"#.utf8)
        let subscription = try Subscription.parse(data, origin: URL(string: "https://example.com/sub.json")!)
        #expect(subscription.sites.map(\.key) == ["a"])
        let shown = subscription.withBuiltInSites()
        // Every built-in source (Bilibili, Hongguo, the short-drama sites) after the subscription's own, each once.
        #expect(shown.sites.map(\.key) == ["a"] + Site.builtInSites.map(\.key))
        #expect(shown.sites.map(\.key).starts(with: ["a", Bilibili.siteKey, Hongguo.siteKey]))
        #expect(shown.withBuiltInSites().sites.count == 1 + Site.builtInSites.count)
        // The built-in live platforms (Bilibili, Douyu, Huya, Douyin), each added once.
        #expect(shown.lives.map(\.platform) == LivePlatform.allCases && shown.withBuiltInSites().lives.count == LivePlatform.allCases.count)
        #expect(BilibiliLive.room(URL(string: "bilibili-live://room/22828499")!) == 22828499)
        let site = Site.bilibili
        #expect(site.isBuiltIn && site.runsLitePort)
        #expect(site.liteScript?.absoluteString == "assets://sites/Bili.js")
        #expect(try site.pluginExtension(origin: nil)?.object?["builtin"] == .bool(true))
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

    @Test func representationsPreferOriginCDNsAndOneCodecPerQuality() throws {
        func stream(_ quality: Int, _ codec: Int, _ urls: [String]) -> Representation? {
            Representation(["id": .number(Double(quality)), "codecid": .number(Double(codec)), "codecs": .string(codec == 7 ? "avc1.640032" : "hev1.1.6.L150.90"),
                            "base_url": .string(urls[0]), "backup_url": .array(urls.dropFirst().map { .string($0) }),
                            "segment_base": .object(["initialization": .string("0-999"), "index_range": .string("1000-1500")]), "frame_rate": .string("30000/1001")])
        }
        let item = try #require(stream(80, 7, ["https://xy1x2xy.mcdn.bilivideo.cn:8082/v.m4s", "https://upos-sz-mirrorcos.bilivideo.com/v.m4s"]))
        #expect(item.urls.first?.host() == "upos-sz-mirrorcos.bilivideo.com")
        #expect(abs((item.frameRate ?? 0) - 29.97) < 0.01)
        let chosen = BilibiliStreams.choose([item, stream(80, 12, ["https://a.example/v"])!, stream(64, 7, ["https://a.example/v"])!, stream(126, 12, ["https://a.example/v"])!])
        #expect(chosen.map(\.quality) == [80, 64])
    }
}

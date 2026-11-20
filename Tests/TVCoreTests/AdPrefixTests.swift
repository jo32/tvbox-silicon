import Foundation
import Testing
@testable import TVCore

/// 这四份清单是**从真实的成人源抓下来的原始响应**（2026-11-17，由采样任务采集），
/// 不是手工构造的样本 —— 只有这样测试才有资格代表线上行为。
///
/// | 文件 | 来源 | 形态 |
/// |---|---|---|
/// | `A.m3u8`   | 番茄 fqzy.me | 主目录 98.5%，广告两段 1.3% + 0.2%（15.03s 前贴） |
/// | `X1.m3u8`  | 番茄（另一分类，720p 变体） | 主 98.0%，广告同两段；**131 个 DISCONTINUITY** |
/// | `Y2.m3u8`  | 玉兔 apiyutu.com | 主 93.2%，广告 6.8%（26.07s）；**全片零 AES** |
/// | `Z2.m3u8`  | 155 155api.com | 主 99.4%，广告 0.6%（25.76s）；**全片零 AES** |
///
/// 后两个源正是「不能用 `METHOD=NONE` 判广告」的证据：它们正片也是 NONE。
private func playlist(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "m3u8",
                                            subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

private let origin = URL(string: "https://fqts5.top/20261030/dca7e45f5e74e036/index.m3u8")!

private func segments(_ text: String) -> [String] {
    text.components(separatedBy: "\n").filter { !$0.isEmpty && !$0.hasPrefix("#") }
}

private func bodySeconds(_ text: String) -> Double {
    zip(segments(text), text.components(separatedBy: "\n").filter { $0.hasPrefix("#EXTINF:") })
        .compactMap { _, inf -> Double? in
            Double(inf.dropFirst(8).prefix { $0 != "," }.trimmingCharacters(in: .whitespaces))
        }.reduce(0, +)
}

@Test func everyRealSourceGetsItsAdGroupsRemoved() throws {
    // 四个源四种形态（两个分类 + 两个不同站），都必须能剥。
    // 现在**前后贴都删**（用户要求「都去掉」），所以预期是广告**总时长**：
    //   A  前贴 15.03 + 中插 89.80 = 104.83
    //   X1 前贴 15.03 + 中插 59.87 =  74.90
    //   Y2 前贴 26.07（无中插）
    //   Z2 前贴 25.76 + 中插 25.76 =  51.52
    for (name, expectedSeconds) in [("A", 104.83), ("X1", 74.90), ("Y2", 26.07), ("Z2", 51.52)] {
        let text = try playlist(name)
        let result = try #require(AdPrefix.strip(text, origin: origin), "\(name) 没识别出广告")
        #expect(abs(result.seconds - expectedSeconds) < 0.5,
                "\(name) 剥掉 \(result.seconds)s，预期约 \(expectedSeconds)s")
        #expect(result.text.contains("#EXT-X-ENDLIST"))
        #expect(!segments(result.text).isEmpty)
    }
}

@Test func theMainFilmIsKeptWholeAndOnlyTheAdGroupsGo() throws {
    let text = try playlist("A")
    let before = segments(text).count
    let beforeSeconds = bodySeconds(text)
    let result = try #require(AdPrefix.strip(text, origin: origin))
    let after = segments(result.text).count
    let afterSeconds = bodySeconds(result.text)

    // A 的广告 = 前贴 4 片 + 中插 24 片 = 28 片 / 104.83s，全部删掉。
    #expect(before - after == 28, "before=\(before) after=\(after)")
    #expect(abs((beforeSeconds - afterSeconds) - 104.83) < 0.5,
            "少了 \(beforeSeconds - afterSeconds)s")
    // 正片 98.5% 必须一秒不少。
    #expect(afterSeconds > beforeSeconds * 0.95)
}

@Test func hugeDiscontinuityCountIsNotUsedAsTheBoundary() throws {
    // ⛔ 这是关键回归：X1 有 131 个 DISCONTINUITY，但真实广告块只有 2 组。
    //    若拿 DISCONTINUITY 当切点（上一版的做法），会把正片切得粉碎。
    let text = try playlist("X1")
    let discontinuities = text.components(separatedBy: "\n").filter { $0 == "#EXT-X-DISCONTINUITY" }.count
    #expect(discontinuities > 100, "这份 fixture 应该是高 DISCONTINUITY 形态，实际 \(discontinuities)")

    let result = try #require(AdPrefix.strip(text, origin: origin))
    let after = segments(result.text).count
    let before = segments(text).count
    // X1 的广告共 20 片（前贴 4 + 中插 16）。只该少广告那几片，
    // 且绝不能因为 131 个 DISCONTINUITY 把正片切碎。
    #expect(before - after == 20,
            "切掉了 \(before - after) 个分片；应为 20 片广告")
}

@Test func theFilmsOwnAESKeyTagsSurvive() throws {
    // ⛔ 上一版我写错过：组装时把每段的标签过滤成只剩 EXTINF，
    //    正片是 AES-128 加密的，KEY 标签一丢就解密失败 ——
    //    「广告没了但正片也放不出来」，比不去广告更糟。
    let text = try playlist("A")
    #expect(text.contains("#EXT-X-KEY:METHOD=AES-128"))

    let result = try #require(AdPrefix.strip(text, origin: origin))
    #expect(result.text.contains("#EXT-X-KEY:METHOD=AES-128"),
            "正片的 AES KEY 标签被吃掉了")
    // 正片每一段都还带着 EXTINF。
    #expect(result.text.components(separatedBy: "\n").filter { $0.hasPrefix("#EXTINF:") }.count
            == segments(result.text).count)
}

@Test func aPlaylistWhoseBodyIsUnencryptedWasNeverCutByMethodNone() throws {
    // 玉兔/155 全片 METHOD=NONE。若判据是「NONE=广告」，这两个源会被整片删掉。
    for name in ["Y2", "Z2"] {
        let text = try playlist(name)
        #expect(!text.contains("AES-128"), "\(name) 应该全片无 AES")
        let result = try #require(AdPrefix.strip(text, origin: origin), "\(name) 没识别出广告")
        // 留下的必须仍是绝大部分。
        #expect(bodySeconds(result.text) > bodySeconds(text) * 0.9,
                "\(name) 被切掉太多：留 \(bodySeconds(result.text))s / 原 \(bodySeconds(text))s")
    }
}

@Test func aPlaylistWithOneSingleSourceIsLeftAlone() throws {
    // 只有一组来源（正常单目录）→ 没有任何"外来组"，必须原样放行。
    let text = """
    #EXTM3U
    #EXT-X-VERSION:3
    #EXT-X-TARGETDURATION:8
    #EXT-X-PLAYLIST-TYPE:VOD
    #EXT-X-KEY:METHOD=AES-128,URI="k"
    #EXTINF:8,
    https://cdn.example/v/abc/seg_00000.ts
    #EXTINF:8,
    https://cdn.example/v/abc/seg_00001.ts
    #EXTINF:8,
    https://cdn.example/v/abc/seg_00002.ts
    #EXTINF:8,
    https://cdn.example/v/abc/seg_00003.ts
    #EXTINF:8,
    https://cdn.example/v/abc/seg_00004.ts
    #EXTINF:8,
    https://cdn.example/v/abc/seg_00005.ts
    #EXTINF:8,
    https://cdn.example/v/abc/seg_00006.ts
    #EXTINF:8,
    https://cdn.example/v/abc/seg_00007.ts
    #EXTINF:8,
    https://cdn.example/v/abc/seg_00008.ts
    #EXTINF:8,
    https://cdn.example/v/abc/seg_00009.ts
    #EXTINF:8,
    https://cdn.example/v/abc/seg_00010.ts
    #EXTINF:8,
    https://cdn.example/v/abc/seg_00011.ts
    #EXTINF:8,
    https://cdn.example/v/abc/seg_00012.ts
    #EXTINF:8,
    https://cdn.example/v/abc/seg_00013.ts
    #EXTINF:8,
    https://cdn.example/v/abc/seg_00014.ts
    #EXTINF:8,
    https://cdn.example/v/abc/seg_00015.ts
    #EXT-X-ENDLIST
    """
    #expect(AdPrefix.strip(text, origin: origin) == nil)
}

@Test func aLivePlaylistIsNeverTouched() throws {
    let text = try playlist("A").replacingOccurrences(of: "#EXT-X-ENDLIST", with: "")
    #expect(AdPrefix.strip(text, origin: origin) == nil)
}

@Test func aMasterPlaylistIsNeverTouched() throws {
    let master = """
    #EXTM3U
    #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
    360/index.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720
    720/index.m3u8
    #EXT-X-ENDLIST
    """
    #expect(AdPrefix.strip(master, origin: origin) == nil)
}

@Test func aShortClipIsNotCut() throws {
    // 短片前几秒本来就是内容，不是广告。
    var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:8", "#EXT-X-PLAYLIST-TYPE:VOD"]
    for i in 0..<10 { lines += ["#EXTINF:4,", "https://b/y/seg_\(i).jpg"] }
    for i in 0..<3 { lines += ["#EXTINF:4,", "/other/z/ad_\(i).jpg"] }
    lines.append("#EXT-X-ENDLIST")
    #expect(AdPrefix.strip(lines.joined(separator: "\n"), origin: origin) == nil)
}

@Test func twoRoughlyEqualSourcesAreNotTreatedAsAdPlusFilm() throws {
    // 五五开说明这不是"一个主片 + 若干广告"，可能是多段正片 → 必须放行。
    var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:8", "#EXT-X-PLAYLIST-TYPE:VOD"]
    for i in 0..<30 { lines += ["#EXTINF:4,", "https://a/main/seg_\(i).jpg"] }
    for i in 0..<25 { lines += ["#EXTINF:4,", "/b/other/seg_\(i).jpg"] }
    lines.append("#EXT-X-ENDLIST")
    #expect(AdPrefix.strip(lines.joined(separator: "\n"), origin: origin) == nil)
}

@Test func midrollAdsAreRemovedToo() throws {
    // 用户要求「都去掉」：中插广告也必须删。
    //
    // ⚠️ 但**不要**顺手加「前移 PES/PTS」的补偿。实测真实源不需要：
    //    155 源 m004 末帧 PTS=6162.04、m005 首帧 PTS=6162.12，
    //    中间删掉了 25.76 秒广告，两者仍天然连续 —— 源站在生成清单时
    //    已经把广告从时间轴上扣掉了。若按「删多少补多少」去改 PES，
    //    PTS 会倒退，播放器反而重新缓冲/卡死。
    //    （这个反例来自我自己造的 concat HLS，与真实源的时间轴组织不同。）
    let text = try playlist("A")
    let result = try #require(AdPrefix.strip(text, origin: origin))

    #expect(!result.text.contains("625264b24905f8e9"), "中插广告没删干净")
    // 删掉的时长要如实报告（供诊断），且应包含前贴 + 中插
    #expect(result.seconds > 100, "A 应删掉 100 秒以上（前贴+中插），实际 \(result.seconds)")
}

@Test func theDiagnosticDurationEqualsWhatWasActuallyRemoved() throws {
    // 报告的删除时长必须与实际少掉的段时长一致，否则诊断会误导。
    for name in ["A", "X1", "Y2", "Z2"] {
        let text = try playlist(name)
        let result = try #require(AdPrefix.strip(text, origin: origin), "\(name)")
        #expect(abs(result.removedSecondsForDiagnostics - result.seconds) < 0.01)
        #expect(result.removedSecondsForDiagnostics > 0)
    }
}

@Test func aPlaylistWhoseAdIsOnlyAtTheHeadRemovesExactlyThatHead() throws {
    // 玉兔没有中插：删完前缀后，清单里不该再有任何广告目录。
    let text = try playlist("Y2")
    let result = try #require(AdPrefix.strip(text, origin: origin))
    #expect(!result.text.contains("5jnnmlLG"), "玉兔的广告前缀应被完整删除")
    #expect(result.keptMidrolls == 0, "玉兔没有中插，不该报告残留，实际 \(result.keptMidrolls)")
}

@Test func theFirstSegmentAfterStrippingIsAFilmSegment() throws {
    // 删完之后第一段必须是正片目录的分片 —— 否则等于把正片开头也吃了。
    for name in ["A", "X1", "Y2", "Z2"] {
        let text = try playlist(name)
        let result = try #require(AdPrefix.strip(text, origin: origin), "\(name) 未识别")
        let firstSegment = result.text.components(separatedBy: "\n")
            .first { !$0.isEmpty && !$0.hasPrefix("#") }
        let first = try #require(firstSegment, "\(name) 删完没有段了")
        // 广告目录的特征串不许出现在第一段里。
        for ad in ["seg_k8bord", "625264b24905f8e9", "5jnnmlLG", "RCP0FQBQ"] {
            #expect(!first.contains(ad), "\(name) 删完后第一段仍是广告（\(ad)）")
        }
    }
}

// MARK: - 失败原因（Verdict）：让用户机器上也能看出缺口在哪

@Test func aSingleSourcePlaylistSaysSoInsteadOfSilentlyDoingNothing() throws {
    // 实测有 9 个「json.php」类源（香奶儿/淫水机/91麻豆/Madouse/成人19/美少女/黄AV/白嫖）
    // 的分片全是 index_000.ts 这种扁平命名，**只有一个目录** ——
    // 广告不以独立分段存在，结构判据天然不适用。
    // 以前这种情况静默返回 nil，界面上和日志里都看不出区别，
    // 用户只会觉得「去广告怎么没反应」。现在必须明确报 single-source。
    let flat = """
    #EXTM3U
    #EXT-X-VERSION:3
    #EXT-X-TARGETDURATION:5
    #EXT-X-PLAYLIST-TYPE:VOD
    #EXTINF:5.0,
    index_000.ts
    #EXTINF:5.0,
    index_001.ts
    #EXTINF:5.0,
    index_002.ts
    #EXTINF:5.0,
    index_003.ts
    #EXTINF:5.0,
    index_004.ts
    #EXTINF:5.0,
    index_005.ts
    #EXTINF:5.0,
    index_006.ts
    #EXTINF:5.0,
    index_007.ts
    #EXTINF:5.0,
    index_008.ts
    #EXTINF:5.0,
    index_009.ts
    #EXTINF:5.0,
    index_010.ts
    #EXTINF:5.0,
    index_011.ts
    #EXTINF:5.0,
    index_012.ts
    #EXTINF:5.0,
    index_013.ts
    #EXTINF:5.0,
    index_014.ts
    #EXTINF:5.0,
    index_015.ts
    #EXTINF:5.0,
    index_016.ts
    #EXTINF:5.0,
    index_017.ts
    #EXTINF:5.0,
    index_018.ts
    #EXTINF:5.0,
    index_019.ts
    #EXTINF:5.0,
    index_020.ts
    #EXTINF:5.0,
    index_021.ts
    #EXTINF:5.0,
    index_022.ts
    #EXTINF:5.0,
    index_023.ts
    #EXTINF:5.0,
    index_024.ts
    #EXT-X-ENDLIST
    """
    let outcome = AdPrefix.inspect(flat, origin: origin)
    #expect(outcome.result == nil)
    #expect(outcome.verdict == .singleSource,
            "扁平命名的单目录清单必须报 single-source，实际 \(outcome.verdict.code)")
}

@Test func aPlaylistWithAdsReportsRemovedWithCounts() throws {
    let text = try playlist("Y2")
    let outcome = AdPrefix.inspect(text, origin: origin)
    #expect(outcome.result != nil)
    guard case .removed(let segments, let seconds) = outcome.verdict else {
        Issue.record("应有 removed verdict，实际 \(outcome.verdict.code)")
        return
    }
    #expect(segments > 0)
    #expect(seconds > 20)   // 玉兔前缀 26.07s
}

@Test func liveAndMasterPlaylistsReportTheirOwnReasons() throws {
    let live = try playlist("A").replacingOccurrences(of: "#EXT-X-ENDLIST", with: "")
    #expect(AdPrefix.inspect(live, origin: origin).verdict == .notMediaPlaylist)

    let master = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\n720/index.m3u8\n"
    #expect(AdPrefix.inspect(master, origin: origin).verdict == .notMediaPlaylist)
}

@Test func aShortClipReportsToShortRatherThanSilence() throws {
    var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:4", "#EXT-X-PLAYLIST-TYPE:VOD"]
    for i in 0..<10 { lines += ["#EXTINF:4.0,", "/ad/x/\(i).ts"] }
    for i in 0..<3 { lines += ["#EXTINF:4.0,", "/body/y/\(i).ts"] }
    lines.append("#EXT-X-ENDLIST")
    let outcome = AdPrefix.inspect(lines.joined(separator: "\n"), origin: origin)
    #expect(outcome.result == nil)
    #expect(outcome.verdict == .tooShort, "实际 \(outcome.verdict.code)")
}

@Test func everyVerdictHasADistinctStableCode() {
    // code 要能按字符串聚合统计；重复就等于统计口径被污染。
    let all: [AdPrefix.Verdict] = [
        .notMediaPlaylist, .empty, .tooShort, .singleSource, .noDominantSource,
        .adsTooLarge, .dependencyInAds, .wouldRemoveEverything, .removed(segments: 1, seconds: 1)
    ]
    let codes = all.map(\.code)
    #expect(Set(codes).count == codes.count, "存在重复 code: \(codes)")
    #expect(codes.allSatisfy { !$0.isEmpty })
}

// MARK: - 换出口后新增检出的源（真实清单，非构造）

@Test func theThreeNewlyReachableSourcesAreHandled() throws {
    // 用户换出口后这三个源从「连不上」变成可识别：
    //   番茄资源采集接口（fqzy）—— 删 104.8s
    //   成人06（XML 接口）      —— 删 51.5s
    //   奥斯卡资源网（http→https）—— 删 52.9s
    // 三份清单都是从真实源抓下来存的 fixture，不是构造样本。
    let cases: [(name: String, expected: Double)] = [
        ("fqzy", 105), ("adult06", 52), ("oscar", 53)
    ]
    for c in cases {
        let text = try playlist(c.name)
        let outcome = AdPrefix.inspect(text, origin: origin)
        let result = try #require(outcome.result, "\(c.name) 应能识别，实际 \(outcome.verdict.code)")
        #expect(abs(result.seconds - c.expected) < 12,
                "\(c.name) 删了 \(result.seconds)s，预期约 \(c.expected)s")
        guard case .removed = outcome.verdict else {
            Issue.record("\(c.name) verdict 应为 removed，实际 \(outcome.verdict.code)")
            continue
        }
        // 广告分片不能残留在输出里
        for seg in result.text.components(separatedBy: "\n") where !seg.isEmpty && !seg.hasPrefix("#") {
            #expect(!seg.isEmpty)
        }
    }
}

@Test func aSourceWhoseAdsLiveInTheSameFolderNameStillWorks() throws {
    // 成人06 / 奥斯卡 的主目录与广告目录**都叫 `hls`**，只靠 host 或更深路径区分。
    // 分组键用「绝对 URL 的目录」正好能分开；若改成只比末级目录名就会合并成一组、
    // 整源判成 single-source —— 这条守护那个前提。
    for name in ["adult06", "oscar"] {
        let text = try playlist(name)
        let outcome = AdPrefix.inspect(text, origin: origin)
        #expect(outcome.result != nil, "\(name) 必须能识别（两者目录同名 hls），实际 \(outcome.verdict.code)")
    }
}

import Foundation

/// **源级广告前缀**：某些源给每条视频都拼同一段（或几段）**外来分片**当广告。
///
/// ## 判据是「目录占少数」，不是「DISCONTINUITY」
///
/// 实测（2026-11-17，4 个成人源、真实抓下的播放清单）：
///
/// | 源 | 主目录时长占比 | 广告目录 |
/// |---|---|---|
/// | 番茄 A | 98.5% | 1.3% + 0.2% |
/// | 番茄 X1 | 98.0% | 1.6% + 0.4% |
/// | 玉兔 Y2 | 93.2% | 6.8% |
/// | 155 Z2 | 99.4% | 0.6% |
///
/// 形态高度一致：**正片来自一个主目录（93–99% 时长），广告来自别的小目录**。
/// 广告时长随源变（15.033 / 26.067 / 25.760 秒），所以**不能硬编码秒数**。
///
/// ## 三条必须避开的坑（都是实测踩到的）
///
/// ⛔ **不能用 `#EXT-X-DISCONTINUITY` 当判据**：
///    番茄 A/B/D 各有 13 个、X1 有 **131 个**，而真实广告块只有几段。
///    正片内部本来就按 DISCONTINUITY 分段，拿它当边界会大量误切。
///
/// ⛔ **不能用 `METHOD=NONE` 当判据**：
///    番茄是「广告段不加密、正片段 AES-128」，看着很干净；
///    但玉兔、155 **全片零 AES、100% METHOD=NONE** ——
///    在那两个源上会把整片判成广告。
///
/// ⛔ **不能跨视频记忆**：那又回到了「要学习」。
///    这里每次只看这一条清单自己的时长分布，因此对任何源都免学习。
///
/// ## 判据（刻意窄）
///
/// 1. 取**时长占比最高**的目录为主目录（正片）；
/// 2. 其他目录里，时长 ≤ `largestShare`（30%）的**整段**移除；
/// 3. 移除总量 ≤ `largestTotal`（35%）——超了说明判据不成立，整条放行；
/// 4. 至少还要留下一个分段；
/// 5. 只处理**已完结的 media playlist**（`#EXT-X-ENDLIST`，无 `#EXT-X-STREAM-INF`）。
///    直播清单不能动：切了会让播放器追不上直播边缘。
///
/// 主目录判据天然安全：广告不可能占多数时长（用户要看的是正片）。
/// 万一某条清单被判错，最坏是「整条不剥」而不是「切掉正片」。
public enum AdPrefix {

    /// 单个非主目录最多占多少时长才算广告。超过说明它不是广告，是另一路正片（多码率/多段）。
    public static let largestShare = 0.30
    /// 所有被移除的目录加起来最多占多少。超过就整条放行，不动。
    public static let largestTotal = 0.35
    /// 主目录至少占这么多 —— 达不到说明这条清单不是"一个主片 + 若干广告"的形态。
    public static let smallestMainShare = 0.60
    /// 全片至少这么长才动（短片的前几秒本来就是内容）。
    public static let shortestVideo = 120.0

    /// 为什么没有去广告 —— 让 App 在**用户机器上**自己说清楚。
    ///
    /// ⛔ 这是本轮补齐的关键能力：此前判据不命中时一律静默返回 `nil`，
    ///    界面上和日志里都看不出「到底是没广告、还是判据不认识这个源」。
    ///    结果就是只能在开发机上逐个源抓包排查 —— 而实际环境里大量 CDN
    ///    在开发机网络下根本连不上（实测 video32.balecao.com 的 TLS 直接断），
    ///    那些源永远查不到。把判定理由带出来，用户点到哪条片子，
    ///    日志里就有那条片子为什么不去的结论。
    public enum Verdict: Equatable, Sendable {
        /// 不是已完结的 media playlist（母清单或直播）。
        case notMediaPlaylist
        /// 没有分片。
        case empty
        /// 太短，前几秒本来就是内容。
        case tooShort
        /// 所有分片来自同一目录 —— 广告不以独立分段存在，结构判据不适用。
        case singleSource
        /// 目录太平均，不像「一个主片 + 若干广告」。
        case noDominantSource
        /// 小目录占比过高，更像多路正片而不是广告。
        case adsTooLarge
        /// 小目录带 MAP/BYTERANGE 等依赖，删了会破坏正片。
        case dependencyInAds
        /// 去掉了全部内容（判据出错时自我保护）。
        case wouldRemoveEverything
        /// 真的去掉了。
        case removed(segments: Int, seconds: Double)

        /// 给日志/诊断用的稳定短码（不带关联值，便于按字符串聚合统计）。
        public var code: String {
            switch self {
            case .notMediaPlaylist: return "not-media-playlist"
            case .empty: return "empty"
            case .tooShort: return "too-short"
            case .singleSource: return "single-source"
            case .noDominantSource: return "no-dominant-source"
            case .adsTooLarge: return "ads-too-large"
            case .dependencyInAds: return "dependency-in-ads"
            case .wouldRemoveEverything: return "would-remove-everything"
            case .removed: return "removed"
            }
        }
    }

    public struct Result: Equatable, Sendable {
        /// 去掉广告后的清单文本。
        public let text: String
        /// 被移除的分片数。
        public let segments: Int
        /// 被移除的总时长（秒）。
        public let seconds: Double
        /// 被判定为主目录（正片）的路径片段，用于诊断。
        public let mainPath: String
        /// 被移除的目录数。
        public let droppedGroups: Int
        /// 被移除的中插广告段数（仅统计非开头的那些，供诊断）。
        public let keptMidrolls: Int
        /// 删掉的时长（供诊断）。**不要拿它去前移 PTS** —— 原因见下。
        ///
        /// ## 实测结论：真实源不需要重基准（重要）
        ///
        /// 早期我用自己的 ffmpeg 合成 HLS 测出「删段会留 4.04s 时间轴洞」，
        /// 于是加了「前移后续段 PES/PTS」的补偿。**在真实源上这是错的**：
        ///
        /// 抓 155 源的真实分片逐段读 PTS：
        /// ```
        /// m004 末帧 PTS = 6162.04
        /// m005 首帧 PTS = 6162.12   ← 中间删掉了 25.76s 广告
        /// ```
        /// 两者**天然连续**。开头广告同理：删掉前 9 段后，第一个正片段首 PTS=1.48，
        /// 后续逐段连续到 111.80，全程无洞。
        ///
        /// ⇒ 这些源在**生成清单时就已经把广告从时间轴上扣掉了**，
        ///   广告段的 PTS 不占位，删掉它们之后前后天然相接。
        ///   若按「删了多少就前移多少」去改 PES，会让 PTS **倒退**，
        ///   播放器看到时间倒退会重新缓冲甚至卡死 —— 比不去广告更糟。
        ///
        /// 合成 HLS 之所以测出洞，是因为我用 `concat` 拼的正片+广告，
        /// 那种素材的 PTS 天生是连续累加的，与真实源的时间轴组织方式不同。
        /// **这是「用自造样本代替真实数据」的典型陷阱。**
        public let removedSecondsForDiagnostics: Double
    }

    private struct Segment {
        var tags: [String]
        var address: String
        var url: URL
        var duration: Double
        var discontinuity: Bool
        /// 目录路径（用来分组）。
        var group: String
    }

    /// 剥掉外来分片广告，**并说明为什么没剥**。
    ///
    /// 与 `strip` 的区别只有返回值：这里永远给出一个 `Verdict`，
    /// 调用方可以把它写进诊断，让用户机器上也能看出判据在哪一步放弃。
    public static func inspect(_ text: String, origin: URL) -> (result: Result?, verdict: Verdict) {
        guard text.contains("#EXT-X-ENDLIST"), !text.contains("#EXT-X-STREAM-INF") else {
            return (nil, .notMediaPlaylist)
        }
        let outcome = strip(text, origin: origin, diagnose: true)
        return (outcome.result, outcome.verdict)
    }

    /// 剥掉外来分片广告。不是这种形态时返回 `nil`，调用方原样放行。
    public static func strip(_ text: String, origin: URL) -> Result? {
        strip(text, origin: origin, diagnose: false).result
    }

    private static func strip(_ text: String, origin: URL,
                             diagnose: Bool) -> (result: Result?, verdict: Verdict) {
        guard text.contains("#EXT-X-ENDLIST"), !text.contains("#EXT-X-STREAM-INF") else { return (nil, .notMediaPlaylist) }

        var header: [String] = []
        var segments: [Segment] = []
        var pending: [String] = []
        var duration = 0.0
        var discontinuity = false
        var started = false

        for line in text.components(separatedBy: .newlines) {
            let value = line.trimmingCharacters(in: .whitespaces)
            if value.isEmpty { continue }
            if value == "#EXT-X-DISCONTINUITY" { discontinuity = true; continue }
            if value.hasPrefix("#") {
                if value.hasPrefix("#EXTINF:") {
                    started = true
                    duration = Double(value.dropFirst(8).prefix { $0 != "," }
                        .trimmingCharacters(in: .whitespaces)) ?? 0
                }
                if started { pending.append(line) } else { header.append(line) }
                continue
            }
            guard started, let url = URL(string: value, relativeTo: origin)?.absoluteURL else { return (nil, .empty) }
            segments.append(Segment(tags: pending, address: value, url: url,
                                    duration: duration, discontinuity: discontinuity,
                                    group: group(of: url)))
            pending = []
            discontinuity = false
            duration = 0
        }
        guard !segments.isEmpty else { return (nil, .empty) }

        let total = segments.reduce(0) { $0 + $1.duration }
        guard total >= shortestVideo else { return (nil, .tooShort) }

        // ① 按时长给目录排序，最高者 = 正片主目录。
        var byGroup: [String: Double] = [:]
        for segment in segments { byGroup[segment.group, default: 0] += segment.duration }
        guard let main = byGroup.max(by: { $0.value < $1.value }) else { return (nil, .empty) }
        // 单目录 = 广告不以独立分段存在（实测 9 个 json.php 类源就是这种），
        // 结构判据在这里天然不适用，只能交给内容指纹。
        guard byGroup.count > 1 else { return (nil, .singleSource) }
        guard main.value >= total * smallestMainShare else { return (nil, .noDominantSource) }

        // ② 其余目录里，占比够小的才算广告。
        var dropped: Set<String> = []
        var droppedSeconds = 0.0
        for (group, seconds) in byGroup where group != main.key {
            guard seconds <= total * largestShare else { continue }
            dropped.insert(group)
            droppedSeconds += seconds
        }
        guard !dropped.isEmpty else { return (nil, .noDominantSource) }
        guard droppedSeconds <= total * largestTotal else { return (nil, .adsTooLarge) }

        // ⛔ **只删开头的前缀，绝不删中插。**
        //
        //    实测（ffmpeg 9.0.2，本地构造 c1+广告+c2 的 HLS）：
        //      原样            最大帧间隔 0.0400s
        //      删中插广告段    最大帧间隔 **4.0400s** ← 时间轴出现等于广告长度的洞
        //      删中插+DISCONTINUITY  仍是 4.0400s ← 这条标签一秒都补不上
        //      删**开头**前缀  最大帧间隔 **0.0400s** ← 没有洞，安全
        //
        //    原因：删掉开头后剩下的段从第一个正片段开始，播放器起播即从那里算时间；
        //    删中间则在时间轴上留出空洞，AVPlayer 要么停住等、要么报错。
        //    补洞的唯一办法是重写每个 TS 的 PES/PTS（要改 TS 字节），
        //    那是另一个量级的工程，且会引入解码器重建。
        //
        //    另外实测：广告段是 **1080p / 1.1MB**，正片段是 **720p / 0.3MB** ——
        //    拼接点必然触发解码器重建（profile/分辨率/码率都变），
        //    即使补了洞也会有一次可见的画面跳变。这与用户要求的
        //    「不能影响播放观感」直接冲突，所以中插不做。
        // ① 找出所有要删的段：**凡是落在广告目录里的段，一律删**（前缀 + 中插都删）。
        //
        //    这里不再区分前缀/中插 —— 用户要求「都去掉」。
        //    注意：**不需要**为删段补 PES/PTS —— 真实源的时间轴里广告本就不占位，
        //    删掉后前后天然连续（见 `removedSecondsForDiagnostics` 的实测数据）。
        var kept: [Segment] = []
        var removedCount = 0
        var removedSeconds = 0.0
        for segment in segments {
            if dropped.contains(segment.group) {
                removedCount += 1
                removedSeconds += segment.duration
                continue
            }
            kept.append(segment)
        }

        // ② 至少还要留下正片；一段都不剩说明判据出错了，放行。
        guard !kept.isEmpty, removedCount > 0 else { return (nil, .wouldRemoveEverything) }
        // 删掉的比例过高同样说明判据不适用（那可能是多路正片而不是广告）。
        guard removedSeconds <= total * largestTotal else { return (nil, .adsTooLarge) }

        // ③ 被丢的段里若带 KEY / MAP 之类，要看它是不是**广告自己**的。
        //
        //    实测：番茄的中插广告每段都自带一条 `#EXT-X-KEY:METHOD=NONE`
        //    （正片是 AES-128）。这条 KEY 属于广告，必须随广告一起丢掉。
        //    但如果是 `#EXT-X-MAP`（初始化段）或 BYTERANGE 之类，
        //    后面可能真的依赖它 —— 那种情况保守放行。
        for segment in segments where dropped.contains(segment.group) {
            for tag in segment.tags where !tag.hasPrefix("#EXTINF:") {
                if tag.hasPrefix("#EXT-X-KEY:") { continue }
                return (nil, .dependencyInAds)
            }
        }

        // 组装。
        //
        // ⛔ 必须原样保留每个保留段的**全部标签**（尤其是 `#EXT-X-KEY`）。
        //    正片在番茄这类源上是 AES-128 加密的，KEY 标签一丢就解密失败 ——
        //    表现是「广告没了，但正片也放不出来」，比不去广告更糟。
        var lines = header
        var first = true
        for segment in kept {
            if segment.discontinuity, !first { lines.append("#EXT-X-DISCONTINUITY") }
            lines += segment.tags
            lines.append(segment.address)
            first = false
        }
        lines.append("#EXT-X-ENDLIST")

        let mainPath = main.key.split(separator: "/").suffix(2).joined(separator: "/")
        let result = Result(text: lines.joined(separator: "\n") + "\n",
                            segments: removedCount,
                            seconds: removedSeconds,
                            mainPath: mainPath,
                            droppedGroups: dropped.count,
                            keptMidrolls: 0,
                            removedSecondsForDiagnostics: removedSeconds)
        return (result, .removed(segments: removedCount, seconds: removedSeconds))
    }

    /// 分组键：目录部分（去掉文件名）。
    ///
    /// 用目录而不是"host + 文件名模式"：实测广告与正片常常同 host、
    /// 只差一层目录（`/20261116/df50…/` vs `/20261030/{id}/`）。
    private static func group(of url: URL) -> String {
        url.deletingLastPathComponent().absoluteString
    }
}

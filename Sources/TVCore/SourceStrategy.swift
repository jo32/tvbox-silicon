import Foundation

/// Which sources to offer, and in what order.
///
/// Subscriptions often list the same site several times, once per plugin type and decoration
/// ("低端影视", "影视 | 低端影视[js]", "🛣┃低端┃影视"). Those sources form one channel. Only sources
/// this platform can run are kept. Channels are ordered by their cheapest runtime (`SourceRuntime`),
/// then by first appearance in the subscription; inside a channel, sources are ordered by runtime and
/// then subscription order, so a channel reads JSON a, JSON b, Python a, Python b, JS a, ..., JAR b.
public enum SourceStrategy {
    public static func arrange(_ sites: [Site], where available: (Site) -> Bool) -> [Site] {
        let usable = sites.filter(available)
        var channels: [String: (rank: Int, first: Int)] = [:]
        let keys = usable.map { channel(of: $0.name) }
        for (index, site) in usable.enumerated() {
            let key = keys[index]
            let rank = site.runtime.rawValue
            if let known = channels[key] { channels[key] = (min(known.rank, rank), known.first) }
            else { channels[key] = (rank, index) }
        }
        return usable.indices.sorted { lhs, rhs in
            let left = channels[keys[lhs]]!, right = channels[keys[rhs]]!
            if left.rank != right.rank { return left.rank < right.rank }
            if left.first != right.first { return left.first < right.first }
            let leftRuntime = usable[lhs].runtime.rawValue, rightRuntime = usable[rhs].runtime.rawValue
            return leftRuntime != rightRuntime ? leftRuntime < rightRuntime : lhs < rhs
        }.map { usable[$0] }
    }

    /// A channel identity for a source name: decorations, plugin tags, and generic words removed.
    /// Content words (直播, 听书, 网盘, 体育, ...) remain, so a brand's live or audio channel stays separate.
    public static func channel(of name: String) -> String {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let key = cache[name] { return key }
        let key = normalize(name)
        if cache.count > 20_000 { cache.removeAll() }
        cache[name] = key
        return key
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String] = [:]
    private static let bracket = try! NSRegularExpression(pattern: "[\\[【(（<《]([^\\]】)）>》]*)[\\]】)）>》]")
    private static let suffix = try! NSRegularExpression(pattern: "(?:[-_]?(?:py|js|jar|csp|app|v\\d+|hd|4k))+$|(?:影视|影院|视频|电影)$")
    /// Words that describe how a source is packaged or labelled, not which site it is.
    private static let generic: Set<String> = ["影视", "影院", "电影", "视频", "分享", "聚合", "官源", "官", "app", "秒播", "弹幕",
                                               "采集", "资源", "在线", "综合", "测试", "自定", "js", "py", "jar", "csp", "drpy"]

    private static func normalize(_ name: String) -> String {
        var text = name.precomposedStringWithCompatibilityMapping as NSString
        // Bracketed ASCII is a plugin tag ([js], (XP), (T4)); bracketed words are part of the name ([网盘]).
        for match in bracket.matches(in: text as String, range: NSRange(location: 0, length: text.length)).reversed() {
            let inner = text.substring(with: match.range(at: 1))
            text = text.replacingCharacters(in: match.range, with: inner.allSatisfy(\.isASCII) ? " " : " \(inner) ") as NSString
        }
        // Emoji, separators (|, ┃, •), and punctuation become word breaks.
        let spaced = String((text as String).map { $0.isLetter || $0.isNumber ? $0 : " " })
        let words = spaced.lowercased().split(separator: " ").map(String.init)
        let named = words.filter { !generic.contains($0) }
        var core = (named.isEmpty ? words : named).joined()
        for _ in 0..<3 {
            let range = NSRange(core.startIndex..., in: core)
            let stripped = suffix.stringByReplacingMatches(in: core, range: range, withTemplate: "")
            guard !stripped.isEmpty, stripped != core else { break }
            core = stripped
        }
        return core.isEmpty ? name : core
    }
}

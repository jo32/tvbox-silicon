import Foundation

/// Ad segments that a source splices into a video's HLS playlist (#567). They come as their own run of segments between
/// `#EXT-X-DISCONTINUITY` tags, from another host, folder or file-name pattern than the film. Only the playlist text is
/// changed; segments still load from the CDN. A wrong cut would remove real video, so the rule is narrow and anything
/// it doesn't clearly recognize is left exactly as it was.
public enum AdSkip {
    public static let key = "player.skipAds"
    public static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    /// A run is an ad only when it is this short ...
    static let longestRun = 60.0
    /// ... all the runs removed are this share of the video at most ...
    static let largestShare = 0.10
    /// ... there are no more than this many ...
    static let mostRuns = 4
    /// ... and the video is at least this long (a short clip's intro is part of it).
    static let shortestVideo = 180.0

    public struct Result: Equatable {
        public let text: String
        public let runs: Int
        public let seconds: Double
        /// The host the removed segments came from.
        public let host: String
    }

    private struct Segment {
        var tags: [String]
        var address: String
        var url: URL
        var duration: Double
        var discontinuity: Bool
    }

    /// The playlist without its ad runs, or nil when it has none (or isn't a finished media playlist the rule applies to).
    public static func clean(_ text: String, origin: URL) -> Result? {
        guard text.contains("#EXT-X-ENDLIST"), !text.contains("#EXT-X-STREAM-INF") else { return nil }
        var header: [String] = [], tail: [String] = [], segments: [Segment] = []
        var pending: [String] = [], duration = 0.0, discontinuity = false, started = false
        for line in text.components(separatedBy: .newlines) {
            let value = line.trimmingCharacters(in: .whitespaces)
            if value.isEmpty { continue }
            if value == "#EXT-X-DISCONTINUITY" { discontinuity = true; continue }
            if value.hasPrefix("#") {
                if value.hasPrefix("#EXTINF:") {
                    started = true
                    duration = Double(value.dropFirst(8).prefix { $0 != "," }.trimmingCharacters(in: .whitespaces)) ?? 0
                }
                if started { pending.append(line) } else { header.append(line) }
                continue
            }
            guard started, let url = URL(string: value, relativeTo: origin)?.absoluteURL else { return nil }
            segments.append(Segment(tags: pending, address: line, url: url, duration: duration, discontinuity: discontinuity))
            pending = []; discontinuity = false; duration = 0
        }
        tail = pending
        let total = segments.reduce(0) { $0 + $1.duration }
        guard segments.count > 1, total >= shortestVideo, segments.contains(where: { $0.discontinuity }) else { return nil }

        // Which family of segments is the film: the one holding most of the time.
        var time: [String: Double] = [:]
        for segment in segments { time[family(segment.url), default: 0] += segment.duration }
        guard let film = time.max(by: { $0.value < $1.value })?.key else { return nil }

        var runs: [Range<Int>] = []
        var start = 0
        for index in 1..<segments.count where segments[index].discontinuity { runs.append(start..<index); start = index }
        runs.append(start..<segments.count)
        guard runs.count > 1 else { return nil }

        var removed: [Range<Int>] = []
        for run in runs {
            let length = segments[run].reduce(0) { $0 + $1.duration }
            var share: [String: Double] = [:]
            for segment in segments[run] { share[family(segment.url), default: 0] += segment.duration }
            guard let own = share.max(by: { $0.value < $1.value })?.key, own != film, length <= longestRun else { continue }
            removed.append(run)
        }
        let seconds = removed.reduce(0.0) { $0 + segments[$1].reduce(0) { $0 + $1.duration } }
        guard !removed.isEmpty, removed.count <= mostRuns, removed.count < runs.count, seconds <= total * largestShare else { return nil }
        // Keys, init sections, byte ranges and the like inside a removed run could be what the rest relies on.
        for run in removed {
            for segment in segments[run] where segment.tags.contains(where: { !$0.hasPrefix("#EXTINF:") }) { return nil }
        }

        let dropped = Set(removed.flatMap { Array($0) })
        var lines = header
        var first = true
        for (index, segment) in segments.enumerated() where !dropped.contains(index) {
            // A discontinuity before the very first segment says nothing.
            if segment.discontinuity, !first { lines.append("#EXT-X-DISCONTINUITY") }
            lines += segment.tags
            lines.append(segment.address)
            first = false
        }
        lines += tail
        let host = removed.first.flatMap { segments[$0.lowerBound].url.host() } ?? "-"
        return Result(text: lines.joined(separator: "\n") + "\n", runs: removed.count, seconds: seconds, host: host)
    }

    /// Where a segment comes from: its host, its folder and its file name with the numbers (and hash-like runs) taken out.
    static func family(_ url: URL) -> String {
        let name = url.lastPathComponent.replacingOccurrences(of: "[0-9a-fA-F]{6,}|[0-9]+", with: "#", options: .regularExpression)
        return "\(url.host() ?? "")|\(url.deletingLastPathComponent().path)|\(name)"
    }

    /// The address to open so the playlist's ads are cut (`LiveRepair`'s loader does it), or nil when the video's playlist
    /// has none, can't be read in a few seconds, or is not one this applies to. A master playlist is judged by its first
    /// variant; the loader then cleans each variant it is asked for.
    public static func route(_ url: URL, headers: [String: String]) async -> URL? {
        guard enabled else { return nil }
        func fetch(_ address: URL) async -> (String, URL)? {
            var request = URLRequest(url: address, timeoutInterval: 6)
            headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
                  data.count < 4 << 20 else { return nil }
            return (String(decoding: data, as: UTF8.self), response.url ?? address)
        }
        guard var (text, origin) = await fetch(url), text.hasPrefix("#EXTM3U") || text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else { return nil }
        if text.contains("#EXT-X-STREAM-INF") {
            let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let marker = lines.firstIndex(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }),
                  let variant = lines[(marker + 1)...].first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
                  let address = URL(string: variant, relativeTo: origin)?.absoluteURL,
                  let next = await fetch(address) else { return nil }
            (text, origin) = next
        }
        guard let result = clean(text, origin: origin) else { return nil }
        Diagnostics.shared.record(.info, "player", "ads found runs=\(result.runs) seconds=\(Int(result.seconds)) host=\(result.host)")
        return LiveRepair.address(url, headers: headers, skipsAds: true)
    }
}

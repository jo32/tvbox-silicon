import Foundation

public struct MusicLyricLine: Hashable, Codable, Sendable {
    /// Seconds from the start; 0 for every line of unsynced lyrics.
    public var time: Double
    /// Empty for an instrumental gap.
    public var text: String
    public var translation: String?
}

/// A song's lyrics, timed when the catalog has an LRC file, with a translation per line when it has one.
public struct MusicLyrics: Hashable, Codable, Sendable {
    public var lines: [MusicLyricLine]
    public var synced: Bool
    /// Where they came from; timing fits that catalog's recording.
    public var platform: MusicPlatform

    /// The line being sung at `time`: the last line starting at or before it.
    public func index(at time: Double) -> Int? {
        guard synced, let first = lines.first, time >= first.time else { return nil }
        var low = 0, high = lines.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lines[mid].time <= time { low = mid } else { high = mid - 1 }
        }
        return low
    }

    private static let stamp = try! NSRegularExpression(pattern: "\\[(\\d{1,3}):(\\d{1,2})(?:[.:](\\d{1,3}))?\\]")
    private static let tag = try! NSRegularExpression(pattern: "^\\[([a-zA-Z#]+):([^\\]]*)\\]\\s*$")

    /// Parses LRC text: one or more `[mm:ss.xx]` stamps per line, an `[offset:ms]` tag, metadata
    /// tags skipped. Text without stamps becomes unsynced lyrics. Nil when there are no words.
    public static func parse(_ lrc: String, translation: String? = nil, platform: MusicPlatform) -> MusicLyrics? {
        let (timed, plain, offset) = lines(of: lrc)
        if timed.isEmpty {
            let text = plain.filter { !$0.isEmpty }
            return text.isEmpty ? nil : MusicLyrics(lines: text.map { MusicLyricLine(time: 0, text: $0) }, synced: false, platform: platform)
        }
        var result = timed.map { MusicLyricLine(time: max(0, $0.time - offset), text: $0.text) }
            .enumerated().sorted { $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time }.map(\.element)
        guard result.contains(where: { !$0.text.isEmpty }) else { return nil }
        if let translation {
            let (translated, _, translatedOffset) = lines(of: translation)
            let usable = translated.filter { !$0.text.isEmpty && $0.text != "//" }.map { (time: max(0, $0.time - translatedOffset), text: $0.text) }
            for index in result.indices where !result[index].text.isEmpty {
                // Translations are stamped like the original file, before its offset.
                let time = result[index].time + offset
                if let match = usable.min(by: { abs($0.time - time) < abs($1.time - time) }), abs(match.time - time) < 0.35,
                   match.text != result[index].text {
                    result[index].translation = match.text
                }
            }
        }
        // Catalogs open with the title and credits as timed lines ("晴天 - 周杰伦", "词：周杰伦",
        // "编曲 : …"); they are not sung, so they go. Only the opening run: a sung line ends it.
        if let firstSung = result.firstIndex(where: { !isCredit($0.text) }), firstSung > 0 {
            result.removeFirst(firstSung)
        }
        // Repeated empty stamps add nothing.
        result = result.enumerated().filter { $0.offset == 0 || !($0.element.text.isEmpty && result[$0.offset - 1].text.isEmpty) }.map(\.element)
        return MusicLyrics(lines: result, synced: true, platform: platform)
    }

    private static let creditLine = try! NSRegularExpression(pattern: "^[^：:]{1,16}\\s*[：:]")

    /// A title line ("Song - Artist"), a credit ("Role: Name"), or an empty stamp.
    static func isCredit(_ text: String) -> Bool {
        let line = text.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.contains(" - ") { return true }
        return creditLine.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    private static func lines(of lrc: String) -> (timed: [(time: Double, text: String)], plain: [String], offset: Double) {
        var timed: [(time: Double, text: String)] = [], plain: [String] = [], offset = 0.0
        for raw in lrc.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let range = NSRange(line.startIndex..., in: line)
            if let match = tag.firstMatch(in: line, range: range), let name = Range(match.range(at: 1), in: line), let value = Range(match.range(at: 2), in: line) {
                if line[name].lowercased() == "offset", let milliseconds = Double(line[value].trimmingCharacters(in: .whitespaces)) { offset = milliseconds / 1000 }
                continue
            }
            var times: [Double] = [], end = line.startIndex
            for match in stamp.matches(in: line, range: range) {
                guard let whole = Range(match.range, in: line), whole.lowerBound == end,
                      let minutes = Range(match.range(at: 1), in: line).flatMap({ Double(line[$0]) }),
                      let seconds = Range(match.range(at: 2), in: line).flatMap({ Double(line[$0]) }) else { break }
                var fraction = 0.0
                if let digits = Range(match.range(at: 3), in: line).map({ String(line[$0]) }), let value = Double(digits) {
                    fraction = value / pow(10, Double(digits.count))
                }
                times.append(minutes * 60 + seconds + fraction)
                end = whole.upperBound
            }
            let text = String(line[end...]).trimmingCharacters(in: .whitespaces)
            if times.isEmpty { plain.append(text) } else { timed += times.map { (time: $0, text: text) } }
        }
        return (timed, plain, offset)
    }
}

public protocol MusicLyricsSource: Sendable {
    var platform: MusicPlatform { get }
    /// Nil when the catalog has none for the song.
    func lyrics(songID: String) async throws -> MusicLyrics?
}

extension QQMusicCatalog: MusicLyricsSource {
    public func lyrics(songID: String) async throws -> MusicLyrics? {
        let url = MusicHTTP.url("https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg", [("songmid", songID), ("format", "json"), ("nobase64", "1")])
        return Self.parseLyrics(try await MusicHTTP.json(transport, MusicHTTP.request(url, timeout: Self.timeout, headers: ["Referer": "https://y.qq.com/"]), timeout: Self.timeout))
    }

    static func parseLyrics(_ json: JSONValue) -> MusicLyrics? {
        guard (json["retcode"]?.int ?? json["code"]?.int ?? 0) == 0, let lyric = json["lyric"]?.string else { return nil }
        let translation = json["trans"]?.string.flatMap { $0.isEmpty ? nil : MusicText.entities($0) }
        return MusicLyrics.parse(MusicText.entities(lyric), translation: translation, platform: .qq)
    }
}

extension NeteaseMusicCatalog: MusicLyricsSource {
    public func lyrics(songID: String) async throws -> MusicLyrics? {
        Self.parseLyrics(try await neteaseJSON(MusicHTTP.url("https://music.163.com/api/song/lyric", [("id", songID), ("lv", "1"), ("tv", "1")])))
    }

    static func parseLyrics(_ json: JSONValue) -> MusicLyrics? {
        guard json["nolyric"]?.string != "true", let lyric = json[path: "lrc", "lyric"]?.string else { return nil }
        let translation = json[path: "tlyric", "lyric"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        return MusicLyrics.parse(lyric, translation: translation, platform: .netease)
    }
}

/// Finds a track's lyrics: from the catalog whose recording is playing first, since timing
/// belongs to a recording, then from the other catalog that lists the same recording.
public struct MusicLyricsLoader: Sendable {
    let sources: [any MusicLyricsSource]
    /// Looks up a track no lyrics catalog lists, such as a music extension's own song, by title and artist (#1058).
    let companions: MusicCompanionFinder?
    public init(sources: [any MusicLyricsSource], companions: MusicCompanionFinder? = nil) {
        self.sources = sources; self.companions = companions
    }
    public init(transport: MusicTransport = URLSessionMusicTransport()) {
        let sources: [any MusicLyricsSource] = [QQMusicCatalog(transport: transport), NeteaseMusicCatalog(transport: transport)]
        let catalogs = MusicSearchModel.defaultCatalogs(transport: transport).filter { catalog in sources.contains { $0.platform == catalog.platform } }
        self.init(sources: sources, companions: MusicCompanionFinder(catalogs: catalogs))
    }

    public func lyrics(for track: MusicTrack, playing platform: MusicPlatform?) async -> MusicLyrics? {
        var track = track
        if !sources.contains(where: { track.ids[$0.platform] != nil }), let companions, let wider = await companions.find(track) { track = wider }
        let ordered = sources.sorted { a, _ in a.platform == platform }
        var unsynced: MusicLyrics?
        for source in ordered {
            guard let songID = track.ids[source.platform] else { continue }
            guard let found = try? await MusicHTTP.withTimeout(6, { try await source.lyrics(songID: songID) }) else { continue }
            if found.synced { return found }
            unsynced = unsynced ?? found
        }
        return unsynced
    }
}

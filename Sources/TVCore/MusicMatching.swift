import Foundation

/// Song identity: version tags, when two catalog entries are one recording, and how results rank
/// against a query. Titles and durations that merely look alike never merge two recordings.
public enum MusicMatching {
    /// Words that mark a version, matched inside brackets or after a dash in titles, anywhere in queries.
    static let keywords: [(MusicVersionTag, [String])] = [
        (.live, ["live", "现场", "現場", "演唱会", "演唱會", "ライブ"]),
        (.instrumental, ["伴奏", "instrumental", "纯音乐", "純音樂", "karaoke", "off vocal", "inst."]),
        (.remix, ["remix", "dj", "mix", "加速", "减速", "減速", "降调", "升调", "sped up", "slowed", "0.8x", "0.9x", "1.1x", "1.2x"]),
        (.cover, ["翻唱", "cover", "女声版", "男声版", "女生版", "男生版", "女聲版", "男聲版", "翻自", "原唱"]),
        (.rerecorded, ["taylor's version", "taylor’s version", "重录", "重錄", "re-recorded", "rerecorded"]),
        (.acoustic, ["acoustic", "不插电", "不插電", "unplugged", "钢琴版", "鋼琴版", "吉他版", "piano version"]),
        (.demo, ["demo", "小样", "小樣"]),
    ]
    private static let bracketed = try! NSRegularExpression(pattern: "[\\(（\\[【「]([^\\)）\\]】」]*)[\\)）\\]】」]")
    private static let dashSuffix = try! NSRegularExpression(pattern: "\\s[-–—]\\s(.+)$")

    /// Width-folded, lowercased letters and digits only, so "Ｌｏｖｅ Ｓｔｏｒｙ" and "love story" compare equal.
    public static func normalize(_ text: String) -> String {
        let folded = text.precomposedStringWithCompatibilityMapping.lowercased()
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    /// The version a title names. Only bracketed parts and a dash suffix count, so "Live Forever" stays an original.
    public static func tags(in title: String) -> Set<MusicVersionTag> {
        var found = Set<MusicVersionTag>()
        for part in versionParts(of: title) {
            let known = tags(inText: part)
            found.formUnion(known)
            // "治愈版", "粤语版", "Radio Version": a version all the same, just not one with a name here.
            let lowered = part.lowercased().trimmingCharacters(in: .whitespaces)
            if known.isEmpty, lowered.hasSuffix("版") || lowered.hasSuffix("version") || alternateWords.contains(where: lowered.contains) {
                found.insert(.alternate)
            }
        }
        return found
    }
    private static let alternateWords = ["粤语", "粵語", "国语", "國語", "日语", "英文", "cantonese", "mandarin", "edit"]

    /// The version a query asks for: the same words, anywhere in it.
    public static func tags(inQuery query: String) -> Set<MusicVersionTag> { Set(tags(inText: query)) }

    /// The title without its version parts, normalized.
    public static func baseTitle(_ title: String) -> String {
        let range = NSRange(title.startIndex..., in: title)
        var stripped = bracketed.stringByReplacingMatches(in: title, range: range, withTemplate: " ")
        stripped = dashSuffix.stringByReplacingMatches(in: stripped, range: NSRange(stripped.startIndex..., in: stripped), withTemplate: "")
        let base = normalize(stripped)
        return base.isEmpty ? normalize(title) : base
    }

    /// The tolerance for two durations of one recording: `max(3 s, 2%)`.
    public static func durationTolerance(_ seconds: Double) -> Double { max(3, seconds * 0.02) }

    /// Why `a` and `b` are one recording, or nil when they may not be: title, version tags and an
    /// artist must agree, and then the durations, or the album when a duration is missing.
    public static func sameRecording(_ a: MusicTrack, _ b: MusicTrack) -> [String]? {
        guard baseTitle(a.title) == baseTitle(b.title), a.tags == b.tags else { return nil }
        let artists = Set(a.artists.map(normalize)).subtracting([""])
        guard !artists.isDisjoint(with: b.artists.map(normalize)) else { return nil }
        var evidence = ["title", "artist", "version"]
        if let left = a.duration, let right = b.duration {
            let gap = abs(left - right)
            guard gap <= durationTolerance(max(left, right)) else { return nil }
            evidence.append(String(format: "duration Δ%.1fs", gap))
        } else {
            guard let left = a.album.map(normalize), !left.isEmpty, left == b.album.map(normalize) else { return nil }
            evidence.append("album")
        }
        return evidence
    }

    /// Joins each catalog's results: an entry already present by ID is dropped, and one that is the
    /// same recording as an entry from another catalog adds its ID to it.
    public static func merge(_ lists: [[MusicTrack]]) -> [MusicTrack] {
        var merged: [MusicTrack] = []
        for list in lists {
            for track in list {
                if merged.contains(where: { existing in track.ids.contains { existing.ids[$0.key] == $0.value } }) { continue }
                let platforms = Set(track.ids.keys)
                if let index = merged.firstIndex(where: { Set($0.ids.keys).isDisjoint(with: platforms) && sameRecording($0, track) != nil }) {
                    let evidence = sameRecording(merged[index], track) ?? []
                    merged[index].ids.merge(track.ids) { old, _ in old }
                    merged[index].duration = merged[index].duration ?? track.duration
                    merged[index].artwork = merged[index].artwork ?? track.artwork
                    merged[index].album = merged[index].album ?? track.album
                    merged[index].year = merged[index].year ?? track.year
                    merged[index].genre = merged[index].genre ?? track.genre
                    merged[index].language = merged[index].language ?? track.language
                    merged[index].evidence = evidence
                } else {
                    merged.append(track)
                }
            }
        }
        return merged
    }

    /// How well a track answers a query. Naming the title and an artist scores highest; a version
    /// the query did not ask for loses points, so originals come first unless asked otherwise.
    public static func score(_ track: MusicTrack, query: String) -> Int {
        let wanted = tags(inQuery: query), core = coreQuery(query)
        let title = baseTitle(track.title)
        let artists = track.artists.map(normalize).filter { !$0.isEmpty }
        var score = 0
        if !title.isEmpty, !core.isEmpty {
            if core == title { score = 100 }
            else if artists.contains(where: { core == title + $0 || core == $0 + title }) { score = 110 }
            else if core.contains(title) && artists.contains(where: { core.contains($0) }) { score = 105 }
            else if core.contains(title) { score = 60 }
            else if title.contains(core) { score = 50 }
            else if artists.contains(where: { core.contains($0) }) { score = 30 }
        }
        score += track.tags == wanted ? 20 : -15 * track.tags.symmetricDifference(wanted).count
        if track.ids.count > 1 { score += 5 }
        return score
    }

    /// Best first; ties keep the catalogs' own order, which is by popularity.
    public static func rank(_ tracks: [MusicTrack], query: String) -> [MusicTrack] {
        let scores: [Int] = tracks.map { score($0, query: query) }
        let order: [Int] = tracks.indices.sorted { (a: Int, b: Int) -> Bool in
            scores[a] == scores[b] ? a < b : scores[a] > scores[b]
        }
        return order.map { tracks[$0] }
    }

    /// An artist search's songs: those by the artist the query names, in the catalogs' order, which is by popularity
    /// (#649). Part of a name ("Taylor" for "Taylor Swift") counts only when no artist is the whole query.
    public static func byArtist(_ tracks: [MusicTrack], query: String) -> [MusicTrack] {
        let name = normalize(query)
        guard !name.isEmpty else { return [] }
        let whole = tracks.filter { $0.artists.contains { normalize($0) == name } }
        return whole.isEmpty ? tracks.filter { $0.artists.contains { normalize($0).contains(name) } } : whole
    }

    /// The one track a query clearly means, to play without asking: it names that title (and the
    /// artist, when other artists have a song of that title) and no other recording fits as well.
    /// Otherwise nil, and the viewer chooses.
    public static func directHit(_ ranked: [MusicTrack], query: String) -> MusicTrack? {
        let wanted = tags(inQuery: query)
        guard let top = ranked.first, top.tags == wanted else { return nil }
        let title = baseTitle(top.title), core = coreQuery(query)
        let artists = Set(top.artists.map(normalize)).subtracting([""])
        let namesArtist = core != title && core.contains(title) && artists.contains { core.contains($0) }
            && core.count <= title.count + (artists.map(\.count).max() ?? 0) + 2
        guard core == title || namesArtist else { return nil }
        // A title that is the whole query ("七里香周杰伦", a song by someone else) is no clear hit
        // while another result's title starts or ends the query: the query may be title plus artist.
        if core == title, ranked.contains(where: { other in
            let shorter = baseTitle(other.title)
            return !shorter.isEmpty && shorter != title && (core.hasPrefix(shorter) || core.hasSuffix(shorter))
        }) { return nil }
        let peers = ranked.filter { baseTitle($0.title) == title && $0.tags == top.tags }
        let ownPeers = peers.filter { !artists.isDisjoint(with: $0.artists.map(normalize)) }
        // Another artist's song of this title competes when the query named no artist.
        if !namesArtist && ownPeers.count < peers.count { return nil }
        // The artist's own entries group by length: compilations repeat the original, so the
        // group the top result belongs to must outnumber any other (an unmarked remix, a re-cut).
        guard let length = top.duration else { return ownPeers.count == 1 ? top : nil }
        func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= durationTolerance(max(a, b)) }
        let timed = ownPeers.compactMap(\.duration)
        let topGroup = timed.filter { close($0, length) }.count
        let largestOther = timed.filter { !close($0, length) }.map { other in timed.filter { close($0, other) }.count }.max() ?? 0
        return topGroup > largestOther ? top : nil
    }

    // MARK: - Helpers

    private static func versionParts(of title: String) -> [String] {
        let range = NSRange(title.startIndex..., in: title)
        var parts = bracketed.matches(in: title, range: range).compactMap { Range($0.range(at: 1), in: title).map { String(title[$0]) } }
        if let match = dashSuffix.firstMatch(in: title, range: range), let suffix = Range(match.range(at: 1), in: title) {
            parts.append(String(title[suffix]))
        }
        return parts
    }

    private static func tags(inText text: String) -> [MusicVersionTag] {
        let lowered = " " + text.precomposedStringWithCompatibilityMapping.lowercased() + " "
        return keywords.compactMap { tag, words in
            words.contains { word in contains(lowered, word: word) } ? tag : nil
        }
    }

    /// Latin keywords match whole words ("dj" not in "adjust"); CJK ones match anywhere.
    private static func contains(_ text: String, word: String) -> Bool {
        guard word.unicodeScalars.allSatisfy({ $0.isASCII }) else { return text.contains(word) }
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: word, range: searchRange) {
            let before = text[..<found.lowerBound].last, after = text[found.upperBound...].first
            let isWordChar: (Character?) -> Bool = { $0.map { $0.isLetter && $0.isASCII || $0.isNumber } ?? false }
            if !isWordChar(before) && !isWordChar(after) { return true }
            searchRange = found.upperBound..<text.endIndex
        }
        return false
    }

    /// The query without version words, normalized: what should match a title and artist.
    static func coreQuery(_ query: String) -> String {
        var text = " " + query.precomposedStringWithCompatibilityMapping.lowercased() + " "
        for (_, words) in keywords {
            for word in words where contains(text, word: word) {
                text = text.replacingOccurrences(of: word, with: " ")
            }
        }
        return normalize(text)
    }
}

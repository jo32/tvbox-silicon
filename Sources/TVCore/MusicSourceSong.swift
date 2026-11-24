import Foundation

/// The song a TVBox source's music episode is, read from its name, for its lyrics (#491). Sources name files every
/// which way ("周杰伦 - 晴天", "晴天-周杰伦", "03. 晴天.mp3", or the title alone in an album named after the artist), so
/// each reading is checked against Apple Music's catalog by length before QQ Music or NetEase is asked for lyrics.
public enum MusicSourceSong {
    public struct Guess: Hashable, Sendable {
        public var title: String
        public var artists: [String]
    }

    /// Words in a source's name that mean talk, not songs: a book's chapter has no lyrics to find.
    static let spokenWords = ["听书", "有声", "相声", "评书", "小说", "电台", "广播", "播客", "讲座", "故事", "FM", "Radio", "Podcast"]
    private static let numbered = try! NSRegularExpression(pattern: #"^\s*[\[(（【]?\d{1,4}[\])）】]?\s*[.、．:：_\-\s]\s*"#)
    private static let fileType = try! NSRegularExpression(pattern: #"\.(mp3|flac|m4a|aac|wav|ogg|ape|wma|dsf|dff)$"#, options: .caseInsensitive)
    private static let chapter = try! NSRegularExpression(pattern: #"^\s*(第\s*[\d零一二三四五六七八九十百千]+\s*[集章回期话讲节]|\d+\s*$)"#)
    private static let separator = try! NSRegularExpression(pattern: #"\s*[-–—_｜|]\s*"#)

    /// The readings of a source track's name worth looking up, most likely first; none for a book's chapter.
    public static func guesses(for track: MusicTrack) -> [Guess] {
        guard let context = track.source?.context else { return [] }
        if spokenWords.contains(where: { context.sourceName.localizedCaseInsensitiveContains($0) }) { return [] }
        var name = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        name = replace(fileType, in: name)
        name = replace(numbered, in: name).trimmingCharacters(in: .whitespacesAndNewlines)
        let whole = NSRange(name.startIndex..., in: name)
        guard !name.isEmpty, chapter.firstMatch(in: name, range: whole) == nil else { return [] }
        let album = context.videoName.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = separator.matches(in: name, range: whole).count == 1
            ? separator.stringByReplacingMatches(in: name, range: whole, withTemplate: "\u{1F}").components(separatedBy: "\u{1F}")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            : [name]
        var guesses: [Guess] = []
        if parts.count == 2 {
            guesses.append(Guess(title: parts[1], artists: [parts[0]]))
            guesses.append(Guess(title: parts[0], artists: [parts[1]]))
        } else if !album.isEmpty {
            // The title alone: the album or playlist may be named after its artist ("周杰伦精选" holds 周杰伦's songs).
            guesses.append(Guess(title: name, artists: [album]))
        }
        return guesses
    }

    private static func replace(_ pattern: NSRegularExpression, in text: String) -> String {
        pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    /// Lyrics for a source's song of `duration` seconds. Each reading is identified in Apple Music's catalog (which
    /// also corrects an artist read from an album's name); a reading Apple Music doesn't know is looked up as it is.
    /// QQ Music and NetEase then match it by title, artist and length, as they match any song.
    public static func lyrics(for track: MusicTrack, duration: Double, catalog: AppleMusicCatalog = .shared,
                              loader: MusicLyricsLoader = MusicLyricsLoader()) async -> MusicLyrics? {
        for guess in guesses(for: track).prefix(2) {
            if Task.isCancelled { return nil }
            let song = await catalog.identify(title: guess.title, artists: guess.artists, duration: duration)
            var lookup = MusicTrack(platform: .ext, songID: "lookup", title: song?.title ?? guess.title,
                                    artists: song.map { $0.artists.isEmpty ? [$0.artist] : $0.artists } ?? guess.artists,
                                    album: song?.album, duration: song?.duration ?? duration)
            lookup.ids = [:]
            if let found = await loader.lyrics(for: lookup, playing: nil) {
                Diagnostics.shared.record(.info, "music", "source lyrics found\(song == nil ? "" : " via Apple Music")")
                return found
            }
        }
        return nil
    }
}

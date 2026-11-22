import Foundation

/// Audiobooks from Legado audio sources (`bookSourceType` 1, 听书, #1130). Their chapters play in the music player, as
/// a TVBox listening source's episodes do (#289). Each track carries its book and chapter, so a queue restored after
/// the app was closed still knows where every chapter's sound comes from. Where listening stopped is kept on the
/// Novels shelf, not in the video history.
public enum NovelListening {
    /// The origin of their tracks' contexts, which no subscription has.
    public static let origin = URL(string: "legado-audio://books")!

    /// What a track plays: a chapter of a book, and how many chapters the book has (for the shelf).
    public struct Item: Codable, Hashable, Sendable {
        public var book: NovelBook
        public var chapter: NovelChapter
        public var count: Int
        public init(book: NovelBook, chapter: NovelChapter, count: Int) { self.book = book; self.chapter = chapter; self.count = count }
    }

    /// The music player's queue for a book from a chapter: the chapters around it, as many as a listening source's.
    public static func queue(book: NovelBook, chapters: [NovelChapter], from index: Int) -> MusicQueue {
        let line = chapters.filter { !$0.isVolume }
        let start = line.firstIndex { $0.index >= index } ?? 0
        let limit = AudioSources.queueLimit
        let first = max(0, min(start - limit / 10, line.count - limit))
        let tracks = line[first..<min(line.count, first + limit)].map { track(Item(book: book, chapter: $0, count: chapters.count)) }
        return MusicQueue(tracks: tracks, start: start - first, source: book.name)
    }

    static func track(_ item: Item) -> MusicTrack {
        let context = PlaybackHistoryContext(origin: origin, sourceKey: item.book.sourceKey, sourceName: "", videoID: item.book.url,
                                             videoName: item.book.name, poster: item.book.coverRequest?.url, episodeID: item.chapter.url,
                                             episodeName: item.chapter.title, episodeFlag: "")
        let address = (try? JSONEncoder().encode(item)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return MusicTrack(source: context, address: address)
    }

    /// The book and chapter of an audiobook's track; nil for other tracks.
    public static func item(_ source: MusicSourceEpisode) -> Item? {
        guard isAudiobook(source.context) else { return nil }
        return try? JSONDecoder().decode(Item.self, from: Data(source.address.utf8))
    }
    public static func isAudiobook(_ context: PlaybackHistoryContext) -> Bool { context.origin == origin }

    /// Where a chapter plays from, asked of its source each time (sound addresses expire).
    public static func channel(for item: Item, runtime: NovelRuntime = .shared, sources: NovelSources = .shared) async throws -> Channel {
        await sources.loaded()
        guard let source = sources.all.first(where: { $0.key == item.book.sourceKey }) else {
            throw TVError.unsupported(L10n.text("This book's source is no longer in your book sources."))
        }
        let sound = try await playable(runtime.audio(source, book: item.book, chapter: item.chapter))
        guard let url = URL(string: sound.url) ?? sound.url.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:)) else {
            throw TVError.unsupported(L10n.text("The chapter has no audio."))
        }
        // No history context: an audiobook's place goes to the Novels shelf, and a stream with a picture stays here.
        return Channel(name: item.book.name + " · " + item.chapter.title, group: source.name, url: url, headers: sound.headers)
    }
}

extension NovelListening {
    /// What the player is given for a chapter's sound: a Ximalaya track page (what its sources' chapters now name)
    /// becomes the web player's address for that track.
    public static func playable(_ sound: NovelAudio) async throws -> NovelAudio {
        guard let track = XimalayaAudio.track(in: sound.url) else { return sound }
        return NovelAudio(url: try await XimalayaAudio.sound(track: track).absoluteString, headers: [:])
    }
}

/// An audio source's chapter: where it plays from.
public struct NovelAudio: Codable, Hashable, Sendable {
    public var url: String
    public var headers: [String: String]
    public init(url: String, headers: [String: String]) { self.url = url; self.headers = headers }
}

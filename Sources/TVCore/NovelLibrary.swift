import Foundation

/// Where the Novels section keeps its files, and the viewer's bookshelf.
public enum NovelLibrary {
    public static var root: URL {
        #if os(tvOS)
        // tvOS apps have no persistent Application Support; Caches is what they keep.
        URL.cachesDirectory.appending(path: "com.tvbox.yingxia/Novels", directoryHint: .isDirectory)
        #else
        URL.applicationSupportDirectory.appending(path: "com.tvbox.yingxia/Novels", directoryHint: .isDirectory)
        #endif
    }
    /// Tables of contents and chapter texts, which can always be read again from the source.
    static var cache: URL { URL.cachesDirectory.appending(path: "com.tvbox.yingxia/NovelText", directoryHint: .isDirectory) }

    /// A book on the shelf, and where reading stopped in it.
    public struct ShelfBook: Codable, Hashable, Sendable, Identifiable {
        public var book: NovelBook
        public var added: Date
        public var chapterIndex: Int
        public var chapterTitle: String
        public var chapterCount: Int
        /// How far into the chapter, 0–1.
        public var position: Double
        /// For an audiobook, where in the chapter listening stopped, in seconds (#1130).
        public var seconds: Double?
        public var updated: Date
        /// Places the viewer marked (#1452), in reading order.
        public var bookmarks: [NovelBookmark]
        /// One shelf entry per title and author, whichever source it is read from.
        public var id: String { book.match }
        public init(book: NovelBook, added: Date = Date(), chapterIndex: Int = 0, chapterTitle: String = "", chapterCount: Int = 0, position: Double = 0,
                    updated: Date = Date(), bookmarks: [NovelBookmark] = []) {
            self.book = book; self.added = added; self.chapterIndex = chapterIndex; self.chapterTitle = chapterTitle
            self.chapterCount = chapterCount; self.position = position; self.updated = updated; self.bookmarks = bookmarks
        }
        /// Shelves saved before bookmarks have none.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            book = try c.decode(NovelBook.self, forKey: .book)
            added = ((try? c.decodeIfPresent(Date.self, forKey: .added)) ?? nil) ?? Date()
            chapterIndex = ((try? c.decodeIfPresent(Int.self, forKey: .chapterIndex)) ?? nil) ?? 0
            chapterTitle = ((try? c.decodeIfPresent(String.self, forKey: .chapterTitle)) ?? nil) ?? ""
            chapterCount = ((try? c.decodeIfPresent(Int.self, forKey: .chapterCount)) ?? nil) ?? 0
            position = ((try? c.decodeIfPresent(Double.self, forKey: .position)) ?? nil) ?? 0
            updated = ((try? c.decodeIfPresent(Date.self, forKey: .updated)) ?? nil) ?? added
            bookmarks = ((try? c.decodeIfPresent([NovelBookmark].self, forKey: .bookmarks)) ?? nil) ?? []
        }
        public var started: Bool { chapterIndex > 0 || position > 0 || !chapterTitle.isEmpty }

        /// Adds a bookmark, keeping them in reading order.
        public mutating func mark(_ bookmark: NovelBookmark) {
            bookmarks.removeAll { $0.id == bookmark.id }
            let at = bookmarks.firstIndex { ($0.chapterIndex, $0.position) > (bookmark.chapterIndex, bookmark.position) } ?? bookmarks.count
            bookmarks.insert(bookmark, at: at)
        }

        /// Reads on from another source's copy (#1450): the place and the bookmarks move to the same chapters there,
        /// found by title, else by number.
        public mutating func follow(_ book: NovelBook, chapters: [NovelChapter]) {
            self.book = book
            if let index = NovelChapterMatch.index(title: chapterTitle, index: chapterIndex, in: chapters) {
                chapterIndex = index; chapterTitle = chapters[index].title
            }
            for at in bookmarks.indices {
                guard let index = NovelChapterMatch.index(title: bookmarks[at].chapterTitle, index: bookmarks[at].chapterIndex, in: chapters) else { continue }
                bookmarks[at].chapterIndex = index; bookmarks[at].chapterTitle = chapters[index].title
            }
            bookmarks.sort { ($0.chapterIndex, $0.position) < ($1.chapterIndex, $1.position) }
            chapterCount = chapters.count
        }
    }

    /// Moves the shelf's entry for `old` to another source's copy (#1450), the place and bookmarks with it, where it stood.
    /// A shelf entry the new copy already made (reading it records it, and its author can differ) gives way to it.
    /// False when `old` isn't on the shelf.
    @discardableResult
    public static func switchSource(_ shelf: inout [ShelfBook], from old: NovelBook, to book: NovelBook, chapters: [NovelChapter]) -> Bool {
        guard let index = shelf.firstIndex(where: { $0.id == old.match }) else { return false }
        var entry = shelf.remove(at: index)
        entry.follow(book, chapters: chapters)
        shelf.removeAll { $0.id == entry.id }
        shelf.insert(entry, at: min(index, shelf.count))
        return true
    }

    public static func load<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        try? JSONDecoder().decode(type, from: Data(contentsOf: root.appendingPathComponent(name)))
    }
    public static func save<T: Encodable>(_ value: T, as name: String) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: root.appendingPathComponent(name), options: .atomic) }
    }
}

/// A place the viewer marked in a book: the chapter (its number and title, so it survives a change of source) and how
/// far into it, with the words there to recognise it by.
public struct NovelBookmark: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var chapterIndex: Int
    public var chapterTitle: String
    /// How far into the chapter, 0–1, as the shelf keeps the reading place.
    public var position: Double
    public var excerpt: String
    public var created: Date
    public init(id: UUID = UUID(), chapterIndex: Int, chapterTitle: String, position: Double, excerpt: String, created: Date = Date()) {
        self.id = id; self.chapterIndex = chapterIndex; self.chapterTitle = chapterTitle
        self.position = min(1, max(0, position)); self.excerpt = excerpt; self.created = created
    }
}

/// Finds a chapter in another source's table of contents: the same title (ignoring spaces and punctuation; the one
/// nearest the old number when several share it), else the same number.
public enum NovelChapterMatch {
    public static func key(_ title: String) -> String { title.lowercased().filter { $0.isLetter || $0.isNumber } }

    public static func index(title: String, index: Int, in chapters: [NovelChapter]) -> Int? {
        let wanted = key(title)
        if !wanted.isEmpty {
            let same = chapters.filter { !$0.isVolume && key($0.title) == wanted }
            if let nearest = same.min(by: { abs($0.index - index) < abs($1.index - index) }) { return nearest.index }
        }
        guard !chapters.isEmpty else { return nil }
        let at = min(max(0, index), chapters.count - 1)
        // A volume heading isn't read: the chapter after it.
        return chapters[at...].first { !$0.isVolume }?.index ?? chapters[..<at].last { !$0.isVolume }?.index
    }
}

/// One search result: the same book from every source that listed it, the first source's copy first.
public struct NovelSearchHit: Sendable, Identifiable, Hashable {
    public var books: [NovelBook]
    /// The first book's `match`, worked out once: search looks up every book every source answers with by it.
    public let id: String
    /// The first book's title and author as `match` reads them, for ranking.
    let name: String, author: String
    public var book: NovelBook { books[0] }
    public init(books: [NovelBook]) {
        self.books = books
        name = NovelBook.normalized(books[0].name)
        author = NovelBook.normalized(books[0].author)
        id = name + "|" + author
    }
}

/// Books from their sources, through NovelRuntime, with tables of contents and chapters kept on disk.
public actor NovelBooks {
    public static let shared = NovelBooks()
    private var reading: [String: Task<NovelContent, Error>] = [:]

    static func source(_ key: String) async throws -> NovelSource {
        await NovelSources.shared.loaded()
        guard let source = NovelSources.shared.source(key) else {
            throw TVError.unsupported(L10n.text("This book's source is no longer in your book source lists."))
        }
        return source
    }

    // MARK: Search

    /// Searches `sources` a few at a time; each source's answer arrives as it comes. Stops when the stream is dropped.
    public nonisolated static func search(_ keyword: String, in sources: [NovelSource], concurrency: Int = 16)
        -> AsyncStream<(source: NovelSource, result: Result<[NovelBook], Error>)> {
        AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: (NovelSource, Result<[NovelBook], Error>).self) { group in
                    var queue = sources[...]
                    func next() -> Bool {
                        guard let source = queue.popFirst() else { return false }
                        group.addTask {
                            do { return (source, .success(try await NovelRuntime.shared.search(source, keyword: keyword, page: 1))) }
                            catch { return (source, .failure(error)) }
                        }
                        return true
                    }
                    for _ in 0..<max(1, concurrency) where next() {}
                    while let (source, result) = await group.next() {
                        if Task.isCancelled { group.cancelAll(); break }
                        continuation.yield((source: source, result: result))
                        _ = next()
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Adds `found` to `hits`, joining books with the same title and author. Books whose name doesn't contain the
    /// keyword (some sources answer every search with their front page) go after the ones that do.
    public nonisolated static func merge(_ found: [NovelBook], into hits: inout [NovelSearchHit], keyword: String) {
        // This runs on the main thread after every source's answer. Each title is normalized once, not again for every
        // comparison: with a few thousand results from a few hundred sources that took seconds per answer, and the
        // watchdog ended the app (1b60dff9c5c8).
        let wanted = NovelBook.normalized(keyword)
        var position = Dictionary(hits.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        for book in found where !book.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !book.url.isEmpty {
            let hit = NovelSearchHit(books: [book])
            if let index = position[hit.id] {
                if !hits[index].books.contains(where: { $0.sourceKey == book.sourceKey }) { hits[index].books.append(book) }
            } else {
                position[hit.id] = hits.count
                hits.append(hit)
            }
        }
        func rank(_ hit: NovelSearchHit) -> Int {
            if hit.name == wanted { return 0 }
            if hit.name.hasPrefix(wanted) { return 1 }
            if hit.name.contains(wanted) || hit.author == wanted { return 2 }
            return 3
        }
        // Stable: within a rank, more sources first, then the order they arrived in.
        hits = hits.enumerated().map { (rank: rank($1), offset: $0, hit: $1) }.sorted { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            if a.hit.books.count != b.hit.books.count { return a.hit.books.count > b.hit.books.count }
            return a.offset < b.offset
        }.map(\.hit)
    }

    // MARK: Explore

    public func exploreKinds(_ sourceKey: String) async throws -> [NovelExploreKind] {
        try await NovelRuntime.shared.exploreKinds(Self.source(sourceKey))
    }
    public func explore(_ sourceKey: String, url: String, page: Int) async throws -> [NovelBook] {
        try await NovelRuntime.shared.explore(Self.source(sourceKey), url: url, page: page)
    }

    // MARK: Books

    /// The book's page: intro, cover, the table of contents' address.
    public func details(_ book: NovelBook) async throws -> NovelBook {
        let source = try await Self.source(book.sourceKey)
        var filled = try await NovelRuntime.shared.details(source, book: book)
        // Keep what the search found when the page leaves a field out.
        if filled.name.isEmpty { filled.name = book.name }
        if filled.author.isEmpty { filled.author = book.author }
        if filled.cover.isEmpty { filled.cover = book.cover }
        if filled.intro.isEmpty { filled.intro = book.intro }
        if filled.kind.isEmpty { filled.kind = book.kind }
        if filled.lastChapter.isEmpty { filled.lastChapter = book.lastChapter }
        if filled.url.isEmpty { filled.url = book.url }
        filled.sourceKey = book.sourceKey
        return filled
    }

    private static func folder(_ book: NovelBook) -> URL {
        NovelLibrary.cache.appendingPathComponent(PluginChecksum.sha256(Data(book.id.utf8)), isDirectory: true)
    }

    /// The table of contents: the saved copy unless `refresh`, else from the source (and saved).
    public func chapters(_ book: NovelBook, refresh: Bool = false) async throws -> [NovelChapter] {
        let file = Self.folder(book).appendingPathComponent("toc.json")
        if !refresh, let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([NovelChapter].self, from: data), !saved.isEmpty {
            return saved
        }
        let source = try await Self.source(book.sourceKey)
        do {
            var chapters = try await NovelRuntime.shared.chapters(source, book: book)
            for index in chapters.indices { chapters[index].index = index }
            guard !chapters.isEmpty else { throw TVError.unsupported(L10n.text("The source listed no chapters for this book.")) }
            try? FileManager.default.createDirectory(at: Self.folder(book), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(chapters) { try? data.write(to: file, options: .atomic) }
            return chapters
        } catch {
            // Offline: the saved copy is better than nothing.
            if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([NovelChapter].self, from: data), !saved.isEmpty { return saved }
            throw error
        }
    }

    private static func contentFile(_ book: NovelBook, _ chapter: NovelChapter) -> URL {
        folder(book).appendingPathComponent("\(chapter.index)-" + PluginChecksum.sha256(Data(chapter.url.utf8)).prefix(12) + ".json")
    }

    public func hasContent(_ book: NovelBook, _ chapter: NovelChapter) -> Bool {
        FileManager.default.fileExists(atPath: Self.contentFile(book, chapter).path)
    }

    /// A chapter's text, saved once read. `chapters` is the table of contents it belongs to (for the next chapter's
    /// address, which some sources' paging needs).
    public func content(_ book: NovelBook, chapters: [NovelChapter], index: Int, refresh: Bool = false) async throws -> NovelContent {
        guard chapters.indices.contains(index) else { throw TVError.unsupported(L10n.text("This chapter is not in the table of contents.")) }
        let chapter = chapters[index]
        let file = Self.contentFile(book, chapter)
        if !refresh, let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(NovelContent.self, from: data) { return saved }
        let key = file.path
        if let running = reading[key] { return try await running.value }
        let next = chapters[(index + 1)...].first { !$0.isVolume }
        let task = Task { () throws -> NovelContent in
            let source = try await Self.source(book.sourceKey)
            var content = try await NovelRuntime.shared.content(source, book: book, chapter: chapter, next: next)
            if content.title.isEmpty { content.title = chapter.title }
            guard !content.paragraphs.isEmpty else { throw TVError.unsupported(L10n.text("The source returned an empty chapter.")) }
            try? FileManager.default.createDirectory(at: Self.folder(book), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(content) { try? data.write(to: file, options: .atomic) }
            return content
        }
        reading[key] = task
        defer { reading[key] = nil }
        return try await task.value
    }

    /// Reads the next few chapters ahead, quietly, so turning to them is instant.
    public func prefetch(_ book: NovelBook, chapters: [NovelChapter], after index: Int, count: Int = 2) async {
        var fetched = 0
        for next in (index + 1)..<min(chapters.count, index + 1 + count * 2) where fetched < count {
            guard !chapters[next].isVolume else { continue }
            fetched += 1
            if hasContent(book, chapters[next]) { continue }
            _ = try? await content(book, chapters: chapters, index: next)
        }
    }

    /// Forgets a book's saved table of contents and chapters.
    public func clear(_ book: NovelBook) {
        try? FileManager.default.removeItem(at: Self.folder(book))
    }
}

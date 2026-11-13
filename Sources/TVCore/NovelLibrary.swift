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
        public var updated: Date
        /// One shelf entry per title and author, whichever source it is read from.
        public var id: String { book.match }
        public init(book: NovelBook, added: Date = Date(), chapterIndex: Int = 0, chapterTitle: String = "", chapterCount: Int = 0, position: Double = 0, updated: Date = Date()) {
            self.book = book; self.added = added; self.chapterIndex = chapterIndex; self.chapterTitle = chapterTitle
            self.chapterCount = chapterCount; self.position = position; self.updated = updated
        }
        public var started: Bool { chapterIndex > 0 || position > 0 || !chapterTitle.isEmpty }
    }

    public static func load<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        try? JSONDecoder().decode(type, from: Data(contentsOf: root.appendingPathComponent(name)))
    }
    public static func save<T: Encodable>(_ value: T, as name: String) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: root.appendingPathComponent(name), options: .atomic) }
    }
}

/// One search result: the same book from every source that listed it, the first source's copy first.
public struct NovelSearchHit: Sendable, Identifiable, Hashable {
    public var books: [NovelBook]
    public var id: String { books[0].match }
    public var book: NovelBook { books[0] }
    public init(books: [NovelBook]) { self.books = books }
}

/// Books from their sources, through NovelRuntime, with tables of contents and chapters kept on disk.
public actor NovelBooks {
    public static let shared = NovelBooks()
    private var reading: [String: Task<NovelContent, Error>] = [:]

    static func source(_ key: String) throws -> NovelSource {
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
        let wanted = NovelBook.normalized(keyword)
        for book in found where !book.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !book.url.isEmpty {
            if let index = hits.firstIndex(where: { $0.id == book.match }) {
                if !hits[index].books.contains(where: { $0.sourceKey == book.sourceKey }) { hits[index].books.append(book) }
            } else {
                hits.append(NovelSearchHit(books: [book]))
            }
        }
        func rank(_ hit: NovelSearchHit) -> Int {
            let name = NovelBook.normalized(hit.book.name)
            if name == wanted { return 0 }
            if name.hasPrefix(wanted) { return 1 }
            if name.contains(wanted) || NovelBook.normalized(hit.book.author) == wanted { return 2 }
            return 3
        }
        // Stable: within a rank, more sources first, then the order they arrived in.
        hits = hits.enumerated().sorted { a, b in
            let ra = rank(a.element), rb = rank(b.element)
            if ra != rb { return ra < rb }
            if a.element.books.count != b.element.books.count { return a.element.books.count > b.element.books.count }
            return a.offset < b.offset
        }.map(\.element)
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
        let source = try Self.source(book.sourceKey)
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
        let source = try Self.source(book.sourceKey)
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
            let source = try Self.source(book.sourceKey)
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

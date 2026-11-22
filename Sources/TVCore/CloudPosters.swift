import Foundation

/// Posters for a drive's folders and videos (#880, #1465): the TMDB work a folder's or file's name finds, for Cloud
/// Files' poster layout and a drive source's cards. Kept on disk by name, so a library's wall comes back at once; asked
/// one at a time and well under the Worker's per-address limit, only for the cards on screen.
public actor CloudPosters {
    public static let shared = CloudPosters()

    /// The work a name found.
    public struct Work: Codable, Hashable, Sendable {
        public let mediaType: TMDBMatch.MediaType
        public let id: Int
        public let name: String
        public let year: Int?
        public let poster: URL?
        public init(mediaType: TMDBMatch.MediaType, id: Int, name: String, year: Int?, poster: URL?) {
            self.mediaType = mediaType; self.id = id; self.name = name; self.year = year; self.poster = poster
        }
    }

    struct Entry: Codable {
        let work: Work?
        let saved: Date
    }

    private let cacheURL: URL
    private let search: @Sendable (String) async throws -> [TMDBMatch.SearchResult]
    private let spacing: Duration
    private var entries: [String: Entry]?
    private var running: [String: Task<Work?, Never>] = [:]
    private var nextStart = ContinuousClock.now
    private var writing: Task<Void, Never>?
    /// Entries kept; the oldest go first.
    private static let limit = 3000

    /// `spacing` is the least time between two searches: about 24 a minute, under the Worker's 60, which the title pages
    /// share.
    init(cacheURL: URL? = nil, spacing: Duration = .milliseconds(2500),
         search: @escaping @Sendable (String) async throws -> [TMDBMatch.SearchResult] = { try await TMDBMatch.search($0) }) {
        self.cacheURL = cacheURL ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "cloud-posters.json")
        self.spacing = spacing
        self.search = search
    }

    /// What is kept for the name, without asking: nil when it hasn't been asked (or should be asked again), `.some(nil)`
    /// when it found nothing.
    public func kept(_ name: MediaName) -> Work?? {
        guard name.isTitle, let entry = loadEntries()[Self.key(name)] else { return nil }
        // A find stands two months; "nothing" is asked again after a week.
        let keep: TimeInterval = entry.work == nil ? 7 * 86400 : 60 * 86400
        return Date().timeIntervalSince(entry.saved) < keep ? .some(entry.work) : nil
    }

    /// The work for the name, asking TMDB when nothing is kept. Nil when nothing fits, the name isn't a title, or the
    /// caller went away (its card scrolled off) before its turn.
    public func work(for name: MediaName) async -> Work? {
        guard name.isTitle, TMDBMatch.enabled else { return nil }
        if let kept = kept(name) { return kept }
        let key = Self.key(name)
        if let task = running[key] { return await task.value }
        // Waits its turn; a card that leaves the screen meanwhile gives its turn up.
        let start = max(ContinuousClock.now, nextStart)
        nextStart = start + spacing
        try? await Task.sleep(until: start, clock: .continuous)
        if Task.isCancelled { return nil }
        if let kept = kept(name) { return kept }
        if let task = running[key] { return await task.value }
        let search = self.search
        let task = Task<Work?, Never> { [weak self] in
            do {
                let found = Self.best(try await search(Self.query(name)), for: name)
                await self?.keep(found, for: key)
                return found
            } catch {
                // Too many requests or no network: nothing is kept, and the next search waits a minute.
                await self?.pause(error)
                return nil
            }
        }
        running[key] = task
        let found = await task.value
        running[key] = nil
        return found
    }

    private func pause(_ error: Error) {
        nextStart = max(nextStart, ContinuousClock.now + .seconds(60))
        Diagnostics.shared.record(.info, "files", "poster search paused: \(error.localizedDescription)")
    }

    private func keep(_ work: Work?, for key: String) {
        var entries = loadEntries()
        entries[key] = Entry(work: work, saved: Date())
        if entries.count > Self.limit {
            for old in entries.sorted(by: { $0.value.saved < $1.value.saved }).prefix(entries.count - Self.limit) { entries[old.key] = nil }
        }
        self.entries = entries
        // Written once a burst of finds settles, not after each.
        writing?.cancel()
        writing = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.write()
        }
    }

    private func write() {
        guard let entries else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(entries).write(to: cacheURL, options: .atomic)
    }

    private func loadEntries() -> [String: Entry] {
        if let entries { return entries }
        let value = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        entries = value
        return value
    }

    // MARK: Matching

    static func key(_ name: MediaName) -> String {
        [normalized(name.title), name.year.map(String.init) ?? "", name.isSeries ? "tv" : ""].joined(separator: "|")
    }

    /// The title alone: TMDB's search goes by words, and a year in the query hides works listed under another.
    static func query(_ name: MediaName) -> String { name.title }

    /// The result the name means, or nil when none is close enough to show as its poster: one whose name (or original
    /// name) is the title, in a year that fits; else, for a title that is only in Latin letters ("Sousou no Frieren",
    /// searched in Chinese), TMDB's first result when the year agrees or it is the only one.
    static func best(_ results: [TMDBMatch.SearchResult], for name: MediaName) -> Work? {
        let title = normalized(name.title)
        guard !title.isEmpty else { return nil }
        func yearScore(_ year: Int?) -> Int? {
            guard let wanted = name.year, let year else { return 0 }
            let gap = abs(wanted - year)
            return gap == 0 ? 2 : gap == 1 ? 1 : nil
        }
        var best: (score: Double, result: TMDBMatch.SearchResult)?
        for (index, result) in results.enumerated() {
            guard let years = yearScore(result.year) else { continue }
            let names = [result.name, result.originalName ?? ""].map(normalized).filter { !$0.isEmpty }
            let nameScore: Double
            if names.contains(title) { nameScore = 3 }
            else if title.count >= 2, names.contains(where: { $0.count >= 2 && ($0.hasPrefix(title) || title.hasPrefix($0)) }) { nameScore = 1 }
            else { continue }
            var score = nameScore + Double(years) - Double(index) * 0.1
            if name.isSeries { score += result.mediaType == .tv ? 1 : -1 }
            // A partial name needs a year that agrees, or it is any work that starts the same way.
            guard nameScore >= 3 || years > 0 else { continue }
            if best == nil || score > best!.score { best = (score, result) }
        }
        // A year in the name must agree; without one, only a lone result is taken.
        if best == nil, !name.title.contains(where: \.isCJK), let first = results.first,
           name.year.map { first.year == $0 } ?? (results.count == 1), !(name.isSeries && first.mediaType == .movie) {
            best = (0, first)
        }
        return best.map { Work(mediaType: $0.result.mediaType, id: $0.result.id, name: $0.result.name, year: $0.result.year, poster: $0.result.poster) }
    }

    /// Compared without case, spaces, punctuation or the difference between traditional and simplified characters.
    static func normalized(_ text: String) -> String {
        var value = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        value = value.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? value
        return String(value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}

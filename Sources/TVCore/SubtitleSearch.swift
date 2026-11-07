import CryptoKit
import Foundation

/// How long and how wide a subtitle search runs (#576 M2).
public struct SubtitleSearchPolicy: Sendable {
    /// Each source gets this long.
    public var perSource: Double = 3
    /// The whole search ends by this, whatever is still out.
    public var total: Double = 3
    /// Sources asked at once.
    public var parallel = 3
    /// The most results kept from one source.
    public var perSourceLimit = 20
    /// How long a source's results answer the same search again.
    public var cacheLifetime: TimeInterval = 30 * 60
    /// How long choosing a result may take: `resolve`, then the download.
    public var download: Double = 12
    public init() {}
}

/// A source to ask, with the viewer's values for it.
public struct SubtitleSearchSource: Sendable {
    public let provider: any SubtitleProvider
    public let credentials: [String: String]
    public init(_ provider: any SubtitleProvider, credentials: [String: String] = [:]) { self.provider = provider; self.credentials = credentials }
    var id: String { provider.manifest.id }
    var partition: String { SubtitleAccount.partition(provider: id, credentials: credentials) }
}

/// What a search has so far. A new one comes each time a source answers.
public struct SubtitleSearchProgress: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case searching
        case found(Int)
        case failed(SubtitleProviderError)
    }
    /// Best first, one of each file.
    public var candidates: [SubtitleCandidate] = []
    /// By source id.
    public var statuses: [String: Status] = [:]
    public var finished = false
    public init() {}
}

/// Asks the enabled sources side by side and merges what they answer: ranked for the video and the viewer's
/// languages, the same file from two sources shown once, results kept for half an hour per source and account.
public actor SubtitleSearch {
    public static let shared = SubtitleSearch()
    public let policy: SubtitleSearchPolicy
    private let files: SubtitleResourceCache
    private var cache: [String: (date: Date, candidates: [SubtitleCandidate])] = [:]
    /// Content digests of files downloaded, by candidate id: two results that are the same file are one.
    private var digests: [String: String] = [:]

    public init(policy: SubtitleSearchPolicy = SubtitleSearchPolicy(), files: SubtitleResourceCache = .shared) {
        self.policy = policy; self.files = files
    }

    /// The search's progress, ending with `finished`. Stopping the stream stops the search.
    public nonisolated func search(_ hint: SubtitleHint, sources: [SubtitleSearchSource]) -> AsyncStream<SubtitleSearchProgress> {
        AsyncStream { continuation in
            let task = Task { await self.run(hint, sources: sources) { continuation.yield($0) }; continuation.finish() }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The search, all at once (for tests and callers that don't show progress).
    public func results(_ hint: SubtitleHint, sources: [SubtitleSearchSource]) async -> SubtitleSearchProgress {
        var last = SubtitleSearchProgress()
        await run(hint, sources: sources) { last = $0 }
        return last
    }

    private func run(_ hint: SubtitleHint, sources: [SubtitleSearchSource], report: (SubtitleSearchProgress) -> Void) async {
        var progress = SubtitleSearchProgress()
        var found: [String: [SubtitleCandidate]] = [:]
        var waiting: [SubtitleSearchSource] = []
        let now = Date()
        for source in sources {
            // A source that needs a key the viewer hasn't given isn't asked.
            if source.provider.manifest.credentials.contains(where: { $0.required && (source.credentials[$0.key] ?? "").isEmpty }) {
                progress.statuses[source.id] = .failed(.authRequired)
                continue
            }
            let key = cacheKey(source, hint)
            if let hit = cache[key], now.timeIntervalSince(hit.date) < policy.cacheLifetime {
                found[source.id] = hit.candidates
                progress.statuses[source.id] = .found(hit.candidates.count)
            } else {
                cache[key] = nil
                waiting.append(source)
                progress.statuses[source.id] = .searching
            }
        }
        progress.candidates = rank(found, sources: sources, hint: hint)
        progress.finished = waiting.isEmpty
        report(progress)
        guard !waiting.isEmpty else { return }

        let deadline = ContinuousClock.now + .seconds(policy.total)
        let policy = policy
        await withTaskGroup(of: (SubtitleSearchSource, Result<[SubtitleCandidate], SubtitleProviderError>).self) { group in
            var queue = waiting.makeIterator()
            func next() -> Bool {
                guard let source = queue.next() else { return false }
                let left = Self.seconds(deadline - ContinuousClock.now)
                let seconds = min(policy.perSource, left)
                group.addTask {
                    guard seconds > 0.05 else { return (source, .failure(.timeout)) }
                    do {
                        let list = try await Self.race(seconds: seconds) { try await source.provider.search(hint, credentials: source.credentials, within: seconds) }
                        return (source, .success(list))
                    } catch let error as SubtitleProviderError {
                        return (source, .failure(error))
                    } catch is CancellationError {
                        return (source, .failure(.timeout))
                    } catch {
                        return (source, .failure(.failed(error.localizedDescription)))
                    }
                }
                return true
            }
            for _ in 0..<max(1, policy.parallel) { _ = next() }
            while let (source, result) = await group.next() {
                if Task.isCancelled { group.cancelAll(); return }
                switch result {
                case .success(let list):
                    let own = Array(rank([source.id: list], sources: [source], hint: hint).prefix(policy.perSourceLimit))
                    found[source.id] = own
                    cache[cacheKey(source, hint)] = (Date(), own)
                    progress.statuses[source.id] = .found(own.count)
                case .failure(.noResults):
                    found[source.id] = []
                    cache[cacheKey(source, hint)] = (Date(), [])
                    progress.statuses[source.id] = .found(0)
                case .failure(let error):
                    progress.statuses[source.id] = .failed(error)
                }
                _ = next()
                progress.candidates = rank(found, sources: sources, hint: hint)
                progress.finished = !progress.statuses.values.contains(.searching)
                report(progress)
            }
        }
        if !progress.finished {
            for (id, status) in progress.statuses where status == .searching { progress.statuses[id] = .failed(.timeout) }
            progress.finished = true
            report(progress)
        }
    }

    /// The chosen result as a document: from the cache, or resolved and downloaded. A signed address that has
    /// expired, or that the server refuses, is resolved once more.
    public func download(_ candidate: SubtitleCandidate, from source: SubtitleSearchSource) async throws -> SubtitleDocument {
        let key = source.partition + "/" + Self.digest(Data(candidate.id.utf8))
        if let cached = await files.data(for: key) {
            digests[candidate.id] = cached.digest
            return try Self.document(candidate, name: cached.name, data: cached.data, format: cached.format)
        }
        let seconds = policy.download
        var resource = try await Self.race(seconds: seconds) { try await source.provider.resolve(candidate, credentials: source.credentials, within: seconds) }
        var data: Data
        do {
            data = try await fetch(resource, source: source)
        } catch SubtitleProviderError.authExpired {
            resource = try await Self.race(seconds: seconds) { try await source.provider.resolve(candidate, credentials: source.credentials, within: seconds) }
            data = try await fetch(resource, source: source, again: true)
        }
        if data.starts(with: [0x52, 0x61, 0x72, 0x21]) || data.starts(with: [0x37, 0x7A, 0xBC, 0xAF]) {
            throw SubtitleProviderError.downloadFailed(L10n.text("It is a RAR or 7z archive; only ZIP archives and SRT, WebVTT and ASS files can be shown."))
        }
        let name = resource.name ?? candidate.title
        let format = resource.format ?? candidate.format
        let document: SubtitleDocument
        do { document = try Self.document(candidate, name: name, data: data, format: format) }
        catch { throw SubtitleProviderError.downloadFailed(error.localizedDescription) }
        let digest = await files.store(data, key: key, name: name, format: format)
        digests[candidate.id] = digest
        return document
    }

    /// A downloaded result as a document. A ZIP archive (a season's upload) shows its file for the result's episode,
    /// the best-named first (#576).
    static func document(_ candidate: SubtitleCandidate, name: String, data: Data, format: String?) throws -> SubtitleDocument {
        let episode = candidate.episode.map { "S\(candidate.season ?? 1)E\($0)" }
        return try SubtitleDocument.documents(id: candidate.id, name: name, language: candidate.language, data: data, format: format ?? "",
                                              video: episode, limit: 1)[0]
    }

    /// The resource's bytes. A refusal that a fresh address may cure becomes `authExpired` the first time.
    private func fetch(_ resource: SubtitleResource, source: SubtitleSearchSource, again: Bool = false) async throws -> Data {
        if let text = resource.text { return Data(text.utf8) }
        guard let url = resource.url else { throw SubtitleProviderError.downloadFailed(L10n.text("The source gave no file.")) }
        guard source.provider.manifest.allows(url) else { throw SubtitleProviderError.blocked(url.host() ?? "?") }
        if !again, let expires = resource.expires, expires < Date() { throw SubtitleProviderError.authExpired }
        do {
            return try await SubtitleFile.download(url, headers: resource.headers, limit: SubtitleFile.largest)
        } catch SubtitleLoadError.http(let status) where [401, 403, 410].contains(status) && !again {
            throw SubtitleProviderError.authExpired
        } catch SubtitleLoadError.http(429) {
            throw SubtitleProviderError.rateLimited(retryAfter: nil)
        } catch let error as SubtitleLoadError {
            throw SubtitleProviderError.downloadFailed(error.localizedDescription)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SubtitleProviderError.downloadFailed(error.localizedDescription)
        }
    }

    /// Forgets the results of a source (its key changed, or the viewer asked to search again).
    public func forget(_ provider: String? = nil) {
        guard let provider else { cache = [:]; return }
        cache = cache.filter { !$0.key.hasPrefix(provider + "|") }
    }

    private func cacheKey(_ source: SubtitleSearchSource, _ hint: SubtitleHint) -> String {
        source.id + "|" + source.partition + "|" + source.provider.manifest.version + "|" + hint.key
    }

    // MARK: Ranking

    /// Every source's results as one list: wrong episodes out, the rest scored, the same file once.
    func rank(_ found: [String: [SubtitleCandidate]], sources: [SubtitleSearchSource], hint: SubtitleHint) -> [SubtitleCandidate] {
        let order = Dictionary(sources.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        var best: [String: SubtitleCandidate] = [:]
        var sequence: [String: Int] = [:]
        var counter = 0
        for source in sources {
            for candidate in found[source.id] ?? [] {
                guard var scored = Self.score(candidate, hint: hint) else { continue }
                if scored.providerName.isEmpty { scored.providerName = source.provider.manifest.name }
                let identity = Self.identity(scored, digest: digests[scored.id])
                if let kept = best[identity], kept.score >= scored.score { continue }
                if best[identity] == nil { sequence[identity] = counter; counter += 1 }
                best[identity] = scored
            }
        }
        return best.sorted { lhs, rhs in
            if lhs.value.score != rhs.value.score { return lhs.value.score > rhs.value.score }
            let left = order[lhs.value.provider] ?? 0, right = order[rhs.value.provider] ?? 0
            if left != right { return left < right }
            return (sequence[lhs.key] ?? 0) < (sequence[rhs.key] ?? 0)
        }.map(\.value)
    }

    /// What makes two results one: the same file (by address or content) in the same language and version, with
    /// the same forced and SDH flags. Different versions of a file stay apart.
    static func identity(_ candidate: SubtitleCandidate, digest: String?) -> String {
        let file = digest.map { "sha:" + $0 } ?? candidate.url.map { "url:" + normalized($0) } ?? "id:" + candidate.id
        let version = candidate.title.lowercased().filter { $0.isLetter || $0.isNumber }
        return [file, candidate.language, version, candidate.forced ? "f" : "", candidate.hearingImpaired ? "h" : ""].joined(separator: "|")
    }

    /// An address without what signs it for a while (`expires`, `signature`, `token`), lowercased host.
    static func normalized(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        parts.fragment = nil
        if parts.scheme == "http" { parts.scheme = "https" }
        let signing: Set<String> = ["expires", "expire", "exp", "signature", "sig", "sign", "token", "auth", "key", "policy", "t", "e", "st"]
        let kept = (parts.queryItems ?? []).filter { item in
            let name = item.name.lowercased()
            return !signing.contains(name) && !name.hasPrefix("x-amz-") && !name.hasPrefix("x-goog-")
        }.sorted { $0.name < $1.name }
        parts.queryItems = kept.isEmpty ? nil : kept
        return parts.string ?? url.absoluteString
    }

    /// A result's score and reasons; nil for another episode.
    static func score(_ input: SubtitleCandidate, hint: SubtitleHint) -> SubtitleCandidate? {
        var candidate = input
        var score = 0
        var reasons: [SubtitleMatchReason] = []
        let named = SubtitleMatch.episode(candidate.title)
        if let wanted = hint.episode {
            let episode = candidate.episode ?? named?.number
            let season = candidate.season ?? (candidate.episode == nil ? named?.season : nil)
            if let episode, episode != wanted { return nil }
            if let season, let wantedSeason = hint.season, season != wantedSeason, candidate.season != nil || named != nil { return nil }
            if episode != nil { score += 40; reasons.append(.episode) }
        }
        if candidate.fileMatch { score += 100; reasons.insert(.file, at: 0) }
        if let index = hint.languages.firstIndex(where: { SubtitleLanguage.serves(candidate.language, $0) }) {
            score += max(10, 30 - 5 * index); reasons.append(.language)
        } else if !candidate.language.isEmpty {
            score -= 20
        }
        if let file = hint.fileName {
            let similarity = similarity(file, candidate.title)
            if similarity >= 0.6 { score += 20; reasons.append(.release) } else { score += Int(similarity * 15) }
        }
        if candidate.forced { score -= 10 }
        if candidate.hearingImpaired { score -= 3 }
        if let downloads = candidate.downloads, downloads > 0 {
            score += min(10, Int(log10(Double(downloads) + 1) * 3))
            if downloads >= 1000 { reasons.append(.popular) }
        }
        candidate.score = score
        candidate.reasons = reasons
        return candidate
    }

    /// How much two release names share (Jaccard over their words, extensions dropped).
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        func words(_ text: String) -> Set<String> {
            let base = text.lowercased().replacingOccurrences(of: #"\.(mkv|mp4|avi|ts|m2ts|srt|ass|ssa|vtt|sub)$"#, with: "", options: .regularExpression)
            return Set(base.split { !($0.isLetter || $0.isNumber) }.map(String.init))
        }
        let a = words(lhs), b = words(rhs)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }

    // MARK: Deadlines

    /// `work`'s answer, or `timeout` after `seconds`, whichever is first; it returns then even when `work` doesn't
    /// notice it was cancelled. Cancelling the caller cancels `work`.
    static func race<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let gate = RaceGate<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.begin(continuation, work: Task { do { gate.finish(.success(try await work())) } catch { gate.finish(.failure(error)) } })
                Task {
                    try? await Task.sleep(for: .seconds(seconds))
                    gate.finish(.failure(SubtitleProviderError.timeout))
                }
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
        }
    }

    static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// The first answer of a race; later ones are dropped and the work cancelled.
private final class RaceGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var work: Task<Void, Never>?
    private var early: Result<T, Error>?
    private var done = false

    func begin(_ continuation: CheckedContinuation<T, Error>, work: Task<Void, Never>) {
        let finished: Result<T, Error>? = lock.withLock {
            if let early { return early }
            self.continuation = continuation; self.work = work
            return nil
        }
        if let finished { work.cancel(); continuation.resume(with: finished) }
    }

    func finish(_ result: Result<T, Error>) {
        let (continuation, work): (CheckedContinuation<T, Error>?, Task<Void, Never>?) = lock.withLock {
            guard !done else { return (nil, nil) }
            done = true
            if self.continuation == nil { early = result; return (nil, nil) }
            defer { self.continuation = nil; self.work = nil }
            return (self.continuation, self.work)
        }
        work?.cancel()
        continuation?.resume(with: result)
    }
}

/// Downloaded subtitle files, kept on disk up to 100 MiB and dropped least recently used first. Each source and
/// account has its own folder; nothing is shared between them.
public actor SubtitleResourceCache {
    public static let shared = SubtitleResourceCache(folder: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SubtitleDownloads", isDirectory: true))

    struct Item: Codable {
        var size: Int
        var used: Date
        var digest: String
        var name: String
        var format: String?
    }

    private let folder: URL
    private let limit: Int
    private var index: [String: Item]
    private var indexFile: URL { folder.appendingPathComponent("index.json") }

    public init(folder: URL, limit: Int = 100 << 20) {
        self.folder = folder; self.limit = limit
        index = (try? JSONDecoder().decode([String: Item].self, from: Data(contentsOf: folder.appendingPathComponent("index.json")))) ?? [:]
    }

    var size: Int { index.values.reduce(0) { $0 + $1.size } }

    func data(for key: String) -> (data: Data, name: String, format: String?, digest: String)? {
        guard var item = index[key] else { return nil }
        guard let data = try? Data(contentsOf: file(key)) else { index[key] = nil; save(); return nil }
        item.used = Date()
        index[key] = item
        save()
        return (data, item.name, item.format, item.digest)
    }

    /// Keeps `data` and answers its digest.
    @discardableResult
    func store(_ data: Data, key: String, name: String, format: String?) -> String {
        let digest = SubtitleSearch.digest(data)
        let url = file(key)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard data.count <= limit, (try? data.write(to: url, options: .atomic)) != nil else { return digest }
        index[key] = Item(size: data.count, used: Date(), digest: digest, name: name, format: format)
        trim()
        save()
        return digest
    }

    /// Empties the cache.
    public func clear() {
        for key in index.keys { try? FileManager.default.removeItem(at: file(key)) }
        index = [:]
        save()
    }

    private func trim() {
        var total = size
        guard total > limit else { return }
        for (key, item) in index.sorted(by: { $0.value.used < $1.value.used }) {
            try? FileManager.default.removeItem(at: file(key))
            index[key] = nil
            total -= item.size
            if total <= limit { break }
        }
    }

    private func file(_ key: String) -> URL {
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        return folder.appendingPathComponent(parts.first ?? "_", isDirectory: true).appendingPathComponent((parts.last ?? key) + ".sub")
    }

    private func save() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(index) { try? data.write(to: indexFile, options: .atomic) }
    }
}

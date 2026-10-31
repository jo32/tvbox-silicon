import Foundation
import AVFoundation

/// Cloud-drive files streamed straight from the CDN address the plugin resolved. AVPlayer asks
/// for byte ranges through a resource loader; they are served from aligned chunks fetched over a
/// few parallel connections (drives throttle each connection), read a bounded window ahead.
/// The plugin's own proxy starts download threads for every range AVPlayer opens; on a 4K file
/// those exhausted the embedded JVM's threads and playback stalled at 0 bytes/s.
public enum CloudStreams {
    public static let scheme = "tvbox-cloud"

    public struct Source: Sendable {
        public let url: URL
        public let headers: [String: String]
        public let length: Int
        /// The drive's file name; its extension can be wrong (a 4K video named .mp3).
        public let name: String
        public init(url: URL, headers: [String: String], length: Int, name: String) {
            self.url = url; self.headers = headers; self.length = length; self.name = name
        }
    }

    /// A playable address for `source`. `refresh` resolves the file again when its CDN link expires. `parallel` caps
    /// the connections it reads ahead on; a proxy that downloads each request with its own threads wants one.
    public static func register(_ source: Source, parallel: Int? = nil, refresh: @escaping @Sendable () async -> Source?) -> URL {
        register(source, session: CloudByteStream.session, parallel: parallel ?? CloudByteStream.parallel, refresh: refresh)
    }
    static func register(_ source: Source, session: URLSession, parallel: Int = CloudByteStream.parallel,
                         refresh: @escaping @Sendable () async -> Source?) -> URL {
        CloudStreamStore.shared.add(CloudByteStream(source: source, session: session, parallel: parallel, refresh: refresh))
    }

    /// A drive's own HLS copy (Quark's and UC's transcoded videos), which AVPlayer reads itself. Its playlist and
    /// segments want the account's headers: without the cookies the CDN refuses every request (HTTP 412).
    public static func registerPlaylist(_ url: URL, headers: [String: String]) -> URL {
        CloudPlaylists.shared.add(url, headers: headers)
        return url
    }

    /// The headers a drive's HLS copy wants, for the Mac's HLS adapter and for downloads.
    public static func playlistHeaders(for url: URL) -> [String: String]? { CloudPlaylists.shared.headers(url) }

    public static func asset(for url: URL) -> AVURLAsset? {
        if let headers = CloudPlaylists.shared.headers(url) { return AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers]) }
        guard CloudStreamStore.shared.stream(url) != nil else { return nil }
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(CloudResourceLoader.shared, queue: CloudResourceLoader.shared.queue)
        return asset
    }

    /// Bytes received from the CDN and its host, for the player's speed readout.
    public static func transfer(for url: URL) -> (received: Int64, host: String?)? {
        guard let stream = CloudStreamStore.shared.stream(url) else { return nil }
        return (stream.counter.value, stream.host)
    }

    /// Whether the file is one AVFoundation can't open but `Remux` can (MKV, AVI, FLV, ...), judged from its
    /// first bytes. False when they can't be read: the player reports network failures itself.
    public static func needsRemux(_ url: URL) async -> Bool {
        guard let stream = CloudStreamStore.shared.stream(url), let head = await stream.head() else { return false }
        return Remux.handles(head)
    }

    /// The file's bytes for `Remux`, exactly as stored.
    public static func remuxSource(for url: URL) async -> RemuxSource? {
        guard let stream = CloudStreamStore.shared.stream(url) else { return nil }
        await stream.keepSampleEntries()
        return CloudRemuxSource(stream: stream)
    }

    /// The file a stream reads and the headers its CDN wants, for a download, which reads it itself.
    public static func source(for url: URL) async -> Source? {
        guard let stream = CloudStreamStore.shared.stream(url) else { return nil }
        return await stream.currentSource
    }

    public static func stop(_ url: URL) {
        CloudPlaylists.shared.remove(url)
        CloudResourceLoader.shared.cancel(url)
        if let stream = CloudStreamStore.shared.stream(url) { Task { await stream.clear() } }
    }

    /// HEVC that an MP4 tags `hev1` (Dolby Vision: `dvhe`) plays only its sound: AVFoundation decodes
    /// those sample entries inside HLS alone. Tagged `hvc1` (`dvh1`) the picture plays; the decoder
    /// settings are in the entry's configuration box either way. A sample entry is the tag after a
    /// plausible box size, then six reserved zero bytes and data reference 1, which media data
    /// practically never repeats. An entry split across two chunks stays as it is.
    static func playableSampleEntries(_ data: Data) -> Data {
        var result = data
        for (tag, playable) in [("hev1", "hvc1"), ("dvhe", "dvh1")] {
            var from = data.startIndex
            while let found = data.range(of: Data(tag.utf8), in: from..<data.endIndex) {
                from = found.upperBound
                let at = found.lowerBound
                guard at - 4 >= data.startIndex, found.upperBound + 8 <= data.endIndex else { continue }
                let size = data[at - 4..<at].reduce(0) { $0 << 8 | Int($1) }
                let reserved = data[found.upperBound..<found.upperBound + 6], reference = data[found.upperBound + 6..<found.upperBound + 8]
                guard (86..<65_536).contains(size), reserved.allSatisfy({ $0 == 0 }), reference.elementsEqual([0, 1]) else { continue }
                result.replaceSubrange(at..<found.upperBound, with: Data(playable.utf8))
            }
        }
        return result
    }

    /// The container AVFoundation should parse, from the file's first bytes rather than its name.
    static func contentType(_ head: Data, name: String) throws -> String {
        let bytes = [UInt8](head.prefix(16))
        if bytes.count >= 12, bytes[4...7] == [0x66, 0x74, 0x79, 0x70] {             // ftyp
            return bytes[8...11] == [0x71, 0x74, 0x20, 0x20] ? AVFileType.mov.rawValue : AVFileType.mp4.rawValue
        }
        if bytes.count >= 4, bytes[0...3] == [0x1A, 0x45, 0xDF, 0xA3] {                // Matroska/WebM
            throw TVError.unsupported(L10n.text("This video is an MKV file, which Apple devices can't play."))
        }
        if bytes.first == 0x47 { return "public.mpeg-2-transport-stream" }
        // Songs played from Cloud Files, known by their signature too.
        if let audio = audioType(bytes) { return audio }
        switch (name as NSString).pathExtension.lowercased() {
        case "mov": return AVFileType.mov.rawValue
        case "m4v": return AVFileType.m4v.rawValue
        case "ts": return "public.mpeg-2-transport-stream"
        default: return AVFileType.mp4.rawValue
        }
    }

    private static func audioType(_ bytes: [UInt8]) -> String? {
        guard bytes.count >= 12 else { return nil }
        func text(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }
        if text(0..<4) == "fLaC" { return "org.xiph.flac" }
        if text(0..<4) == "RIFF", text(8..<12) == "WAVE" { return AVFileType.wav.rawValue }
        if text(0..<4) == "FORM", text(8..<12) == "AIFF" { return AVFileType.aiff.rawValue }
        if bytes[0] == 0xFF, bytes[1] & 0xF6 == 0xF0 { return "public.aac-audio" }      // ADTS
        if text(0..<3) == "ID3" || (bytes[0] == 0xFF && bytes[1] & 0xE0 == 0xE0) { return AVFileType.mp3.rawValue }
        return nil
    }
}

final class CloudCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Int64 = 0
    var value: Int64 { lock.withLock { total } }
    func add(_ count: Int) { lock.withLock { total += Int64(count) } }
}

private final class CloudStreamStore: @unchecked Sendable {
    static let shared = CloudStreamStore()
    private let lock = NSLock()
    private var streams: [URL: CloudByteStream] = [:]
    private var order: [URL] = []

    func add(_ stream: CloudByteStream) -> URL {
        let url = URL(string: "\(CloudStreams.scheme)://\(UUID().uuidString.lowercased())/video")!
        let retired: [(URL, CloudByteStream)] = lock.withLock {
            streams[url] = stream; order.append(url)
            var old: [(URL, CloudByteStream)] = []
            while order.count > 3 { let first = order.removeFirst(); if let value = streams.removeValue(forKey: first) { old.append((first, value)) } }
            return old
        }
        for (old, stream) in retired { CloudResourceLoader.shared.cancel(old); Task { await stream.clear() } }
        return url
    }
    func stream(_ url: URL) -> CloudByteStream? { lock.withLock { streams[url] } }
}

actor CloudByteStream {
    static let chunkSize = 2 << 20
    /// Connections at once. Drives cap each connection, so a 4K bitrate needs several.
    static let parallel = 6
    /// How far ahead of the bytes AVPlayer is reading the stream fetches on its own.
    static let readAhead = 8
    static let cacheChunks = 24

    nonisolated let counter = CloudCounter()
    nonisolated let host: String?
    private var source: CloudStreams.Source
    private let refresh: @Sendable () async -> CloudStreams.Source?
    private var lastRefresh: Date?
    private var cache: [Int: Data] = [:]
    private var recent: [Int] = []
    private var inflight: [Int: Task<Data, Error>] = [:]
    /// Where AVPlayer is reading. A file whose audio sits far from its video is read in two
    /// places at once; a jump away from all of them is a seek.
    private var readers: [Int] = []
    /// How many reads wait on each chunk; a seek never cancels a chunk someone still needs.
    private var waiting: [Int: Int] = [:]
    private var rate: (since: Date, bytes: Int) = (Date(), 0)
    private var type: String?
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = parallel + 2
        configuration.timeoutIntervalForRequest = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    private let session: URLSession
    /// Connections reading ahead at once, `parallel` unless the source needs fewer.
    private let connections: Int
    /// Whether `playableSampleEntries` retags the bytes: for AVPlayer's own MP4 reading, not for `Remux`.
    private var rewritesSampleEntries: Bool

    init(source: CloudStreams.Source, session: URLSession = CloudByteStream.session, parallel: Int = CloudByteStream.parallel,
         rewritesSampleEntries: Bool = true, refresh: @escaping @Sendable () async -> CloudStreams.Source?) {
        self.source = source; self.session = session; self.refresh = refresh; host = source.url.host()
        connections = max(1, parallel)
        self.rewritesSampleEntries = rewritesSampleEntries
        sourceLength = source.length
    }

    var length: Int { source.length }
    var currentSource: CloudStreams.Source { source }
    nonisolated let sourceLength: Int
    private var chunks: Int { (source.length + Self.chunkSize - 1) / Self.chunkSize }

    func contentType() async throws -> String {
        if let type { return type }
        let value = try CloudStreams.contentType(try await chunk(0), name: source.name)
        type = value
        Diagnostics.shared.record(.info, "cloud.stream", "open host=\(host ?? "-") length=\(source.length) type=\(value)")
        return value
    }

    func head() async -> Data? { try? await chunk(0).prefix(16) }

    /// From now on the bytes stay as stored; chunks already retagged are fetched again.
    func keepSampleEntries() {
        guard rewritesSampleEntries else { return }
        rewritesSampleEntries = false
        cache.removeAll(); recent.removeAll()
    }

    /// Up to `count` bytes at `offset`, never past the chunk that holds it.
    func read(at offset: Int, count: Int) async throws -> Data {
        guard offset >= 0, offset < source.length, count > 0 else { throw TVError.unsupported("Invalid range") }
        let index = offset / Self.chunkSize
        let near = { (reader: Int) in index >= reader - 1 && index <= reader + Self.readAhead + 1 }
        if let current = readers.firstIndex(where: near) { readers[current] = index }
        else {
            if !readers.isEmpty { Diagnostics.shared.record(.debug, "cloud.stream", "reader at=\(index) others=\(readers)") }
            readers.append(index)
            // Keep the two most recent positions (video and audio); a third means the user seeked.
            if readers.count > 2 {
                readers.removeFirst(readers.count - 2)
                let windows = readers.map { $0 - 1...$0 + Self.readAhead }
                for (key, task) in inflight where waiting[key, default: 0] == 0 && !windows.contains(where: { $0.contains(key) }) {
                    task.cancel(); inflight[key] = nil
                }
            }
        }
        let bytes = try await chunk(index)
        prefetch(after: index)
        let start = offset - index * Self.chunkSize
        // A copy, not a slice: AVFoundation misread slices of a cached chunk as damaged media.
        return Data(bytes[start..<min(bytes.count, start + count)])
    }

    private func chunk(_ index: Int) async throws -> Data {
        if let data = cache[index] {
            recent.removeAll { $0 == index }; recent.append(index)
            return data
        }
        waiting[index, default: 0] += 1
        defer { waiting[index, default: 1] -= 1; if waiting[index] == 0 { waiting[index] = nil } }
        return try await (inflight[index] ?? start(index)).value
    }

    private func prefetch(after index: Int) {
        let last = min(chunks - 1, index + Self.readAhead)
        guard index < last else { return }
        for next in index + 1...last where cache[next] == nil && inflight[next] == nil {
            guard inflight.count < connections else { break }
            _ = start(next)
        }
    }

    private func start(_ index: Int) -> Task<Data, Error> {
        let task = Task { try await self.download(index) }
        inflight[index] = task
        return task
    }

    private func download(_ index: Int) async throws -> Data {
        defer { inflight[index] = nil }
        let first = index * Self.chunkSize, last = min(source.length, first + Self.chunkSize) - 1
        var attempt = 0
        while true {
            try Task.checkCancellation()
            attempt += 1
            let current = source
            var request = URLRequest(url: current.url)
            current.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
            request.setValue("bytes=\(first)-\(last)", forHTTPHeaderField: "Range")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                // The signed address expired, or the drive wants a fresh session: resolve once more.
                if [401, 403, 404, 410].contains(status), attempt <= 2, await renew() { continue }
                guard status == 206,
                      let range = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"),
                      let match = range.firstMatch(of: /^bytes (\d+)-(\d+)\/(\d+)$/),
                      Int(match.1) == first, Int(match.2) == last, data.count == last - first + 1 else {
                    Diagnostics.shared.record(.error, "cloud.stream", "chunk=\(index) status=\(status) bytes=\(data.count)")
                    throw TVError.http(status == 200 ? 416 : status)
                }
                counter.add(data.count)
                rate.bytes += data.count
                if Date().timeIntervalSince(rate.since) >= 10 {
                    let seconds = Date().timeIntervalSince(rate.since)
                    Diagnostics.shared.record(.debug, "cloud.stream", "rate bytesPerSecond=\(Int(Double(rate.bytes) / seconds)) readers=\(readers) inflight=\(inflight.count)")
                    rate = (Date(), 0)
                }
                let playable = rewritesSampleEntries ? CloudStreams.playableSampleEntries(data) : data
                cache[index] = playable
                recent.removeAll { $0 == index }; recent.append(index)
                while recent.count > Self.cacheChunks { cache[recent.removeFirst()] = nil }
                return playable
            } catch let error as URLError where error.code != .cancelled && attempt < 3 {
                Diagnostics.shared.record(.debug, "cloud.stream", "chunk=\(index) retry \(error.code.rawValue)")
                try await Task.sleep(for: .milliseconds(400 * attempt))
            }
        }
    }

    private func renew() async -> Bool {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < 10 { return true }
        lastRefresh = Date()
        guard let next = await refresh(), next.length == source.length else {
            Diagnostics.shared.record(.error, "cloud.stream", "refresh failed")
            return false
        }
        source = next
        Diagnostics.shared.record(.info, "cloud.stream", "refreshed host=\(next.url.host() ?? "-")")
        return true
    }

    func clear() {
        for task in inflight.values { task.cancel() }
        inflight.removeAll(); cache.removeAll(); recent.removeAll(); readers.removeAll(); waiting.removeAll()
    }
}

/// AVFoundation calls this delegate on `queue`; the request table has its own lock. Responding
/// and finishing never happen while holding the queue: AVFoundation can be waiting to deliver a
/// cancel on that queue while holding its request lock, and responding there deadlocked playback.
private final class CloudResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let shared = CloudResourceLoader()
    let queue = DispatchQueue(label: "tvbox.cloud.loader")
    private final class Pending: @unchecked Sendable {
        let url: URL; let request: AVAssetResourceLoadingRequest; var task: Task<Void, Never>?
        init(url: URL, request: AVAssetResourceLoadingRequest) { self.url = url; self.request = request }
    }
    private let lock = NSLock()
    private var pending: [ObjectIdentifier: Pending] = [:]
    /// The newest request per stream. AVFoundation cancels an older request (reading from the
    /// start) when it jumps to the moov at the end, and tells the delegate a moment later; bytes
    /// handed to the old request in between made it report the movie as damaged.
    private var sequence = 0
    private var newest: [URL: Int] = [:]

    /// The request, if it still wants data.
    private func active(_ id: ObjectIdentifier) -> AVAssetResourceLoadingRequest? {
        guard let request = lock.withLock({ pending[id]?.request }), !request.isCancelled else { return nil }
        return request
    }

    func resourceLoader(_ loader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = request.request.url, let stream = CloudStreamStore.shared.stream(url) else { return false }
        let id = ObjectIdentifier(request)
        let entry = Pending(url: url, request: request)
        var seen = lock.withLock {
            sequence += 1; newest[url] = sequence; pending[id] = entry
            return sequence
        }
        let offset = request.dataRequest.map { max($0.requestedOffset, $0.currentOffset) }
        let length = request.dataRequest?.requestedLength ?? 0
        let toEnd = request.dataRequest?.requestsAllDataToEndOfResource ?? false
        let task = Task { [weak self] in
            do {
                let type = try await stream.contentType()
                let total = await stream.length
                guard let self, let request = self.active(id) else { return }
                request.contentInformationRequest?.contentType = type
                request.contentInformationRequest?.contentLength = Int64(total)
                request.contentInformationRequest?.isByteRangeAccessSupported = true
                if let offset {
                    guard offset >= 0, offset <= Int64(total), length >= 0 else { throw TVError.unsupported("Invalid range") }
                    var at = Int(offset)
                    let end = toEnd ? total : min(total, at + length)
                    while at < end {
                        try Task.checkCancellation()
                        let bytes = try await stream.read(at: at, count: end - at)
                        // Small pieces, like AVFoundation's own HTTP loader: a cancelled request
                        // stops within one piece instead of receiving a whole chunk.
                        var piece = bytes.startIndex
                        while piece < bytes.endIndex {
                            let latest = self.lock.withLock { self.newest[url] ?? 0 }
                            if latest > seen {
                                // A newer request may be about to cancel this one: let that land first.
                                seen = latest
                                try await Task.sleep(for: .milliseconds(150))
                            }
                            try Task.checkCancellation()
                            let next = min(bytes.endIndex, piece + 256 << 10)
                            guard let request = self.active(id) else { return }
                            request.dataRequest?.respond(with: bytes.subdata(in: piece..<next))
                            piece = next
                        }
                        at += bytes.count
                    }
                }
                self.finish(id, error: nil)
            } catch {
                // A seek or a closed player cancels the request (URLError -999 too): not a failure.
                Diagnostics.shared.failure("cloud.stream", "request failed offset=\(offset ?? -1)", error)
                self?.finish(id, error: error)
            }
        }
        lock.withLock { entry.task = task }
        return true
    }

    private func finish(_ id: ObjectIdentifier, error: Error?) {
        guard let value = lock.withLock({ pending.removeValue(forKey: id) }), !value.request.isCancelled else { return }
        if let error { value.request.finishLoading(with: error) } else { value.request.finishLoading() }
    }
    func resourceLoader(_ loader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        lock.withLock { pending.removeValue(forKey: ObjectIdentifier(request)) }?.task?.cancel()
    }
    func cancel(_ url: URL) {
        let stopped: [Pending] = lock.withLock {
            newest[url] = nil
            let ids = pending.keys.filter { pending[$0]?.url == url }
            return ids.compactMap { pending.removeValue(forKey: $0) }
        }
        for value in stopped {
            value.task?.cancel()
            if !value.request.isCancelled { value.request.finishLoading(with: CancellationError()) }
        }
    }
}

/// The drives' HLS copies being played, with their headers. The last few are kept: an address that is never
/// stopped (the Mac plays it through its HLS adapter) doesn't pile up.
final class CloudPlaylists: @unchecked Sendable {
    static let shared = CloudPlaylists()
    private let lock = NSLock()
    private var entries: [(url: URL, headers: [String: String])] = []

    func add(_ url: URL, headers: [String: String]) {
        lock.withLock {
            entries.removeAll { $0.url == url }
            entries.append((url, headers))
            if entries.count > 8 { entries.removeFirst(entries.count - 8) }
        }
    }
    func headers(_ url: URL) -> [String: String]? { lock.withLock { entries.last { $0.url == url }?.headers } }
    func remove(_ url: URL) { lock.withLock { entries.removeAll { $0.url == url } } }
}

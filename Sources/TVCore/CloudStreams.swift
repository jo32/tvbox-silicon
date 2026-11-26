import Foundation
import os
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
        /// Headers made afresh for every request, for a server that signs each one with the time (飞牛影视's `Authx`).
        public let freshHeaders: (@Sendable (URL) -> [String: String])?
        public init(url: URL, headers: [String: String], length: Int, name: String,
                    freshHeaders: (@Sendable (URL) -> [String: String])? = nil) {
            self.url = url; self.headers = headers; self.length = length; self.name = name; self.freshHeaders = freshHeaders
        }
    }

    /// A playable address for `source`. `refresh` resolves the file again when its CDN link expires. `parallel` caps
    /// the connections it reads ahead on; a proxy that downloads each request with its own threads wants one.
    /// `renewal`, when `refresh` gives nothing new (the same expired link, or none), asks the source for the episode
    /// again (`LinkRenewal`): a plugin that keeps the links it gave answers a fresh one only then.
    public static func register(_ source: Source, parallel: Int? = nil, renewal: (@Sendable () async -> Source?)? = nil,
                                refresh: @escaping @Sendable () async -> Source?) -> URL {
        register(source, session: CloudByteStream.session, parallel: parallel ?? CloudByteStream.parallel, renewal: renewal, refresh: refresh)
    }
    static func register(_ source: Source, session: URLSession, parallel: Int = CloudByteStream.parallel,
                         renewal: (@Sendable () async -> Source?)? = nil, refresh: @escaping @Sendable () async -> Source?) -> URL {
        CloudStreamStore.shared.add(CloudByteStream(source: source, session: session, parallel: parallel, refresh: refresh, renewal: renewal))
    }

    /// Whether `url` plays a drive's transcoded copy rather than the file (Quark and UC give free accounts no large
    /// originals): lower in resolution, and without the file's subtitles or other sound tracks (#1343, #1345).
    public static func isDriveCopy(_ url: URL) -> Bool { copies.withLock { $0.contains(url) } }
    static func markCopy(_ url: URL) -> URL {
        copies.withLock { _ = $0.insert(url) }
        return url
    }
    private static let copies = OSAllocatedUnfairLock<Set<URL>>(initialState: [])

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

    /// Whether the drive has brought in at least three times what playback eats since its first bytes: enough to
    /// start playing without first building a cushion.
    public static func keepsUp(_ url: URL) async -> Bool {
        guard let stream = CloudStreamStore.shared.stream(url), let needed = await stream.playbackBytesPerSecond,
              let since = await stream.firstBytes else { return false }
        let seconds = Date().timeIntervalSince(since)
        return seconds >= 1 && Double(stream.counter.value) / seconds >= 3 * needed
    }

    /// Bytes received from the CDN and its host, for the player's speed readout.
    public static func transfer(for url: URL) -> (received: Int64, host: String?)? {
        guard let stream = CloudStreamStore.shared.stream(url) else { return nil }
        return (stream.counter.value, stream.host)
    }

    /// Seconds of video already cached ahead of AVPlayer's reads in memory (#2175).
    public static func bufferedAhead(for url: URL) -> Double {
        CloudStreamStore.shared.stream(url)?.bufferedAhead.withLock { $0 } ?? 0
    }

    /// Whether the file is one AVFoundation can't open but `Remux` can (MKV, AVI, FLV, disc images, ...), judged from its
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

    /// The video's length in seconds, once the player knows it: sizes the read-ahead to the video's bitrate.
    public static func setDuration(_ seconds: Double, for url: URL) {
        guard let stream = CloudStreamStore.shared.stream(url) else { return }
        Task { await stream.setDuration(seconds) }
    }

    public static func stop(_ url: URL) {
        copies.withLock { _ = $0.remove(url) }
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

/// One range request's response and bytes, in order, for `CloudByteStream.download`.
private final class CloudFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Event: Sendable { case response(URLResponse), data(Data), done(Error?) }
    private let sink: AsyncStream<Event>.Continuation
    init(_ sink: AsyncStream<Event>.Continuation) { self.sink = sink }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        sink.yield(.response(response))
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) { sink.yield(.data(data)) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        sink.yield(.done(error))
        sink.finish()
    }
}

extension CloudStreams {
    /// Where an MP4's index (moov) is, from the file's first bytes: the top-level boxes' sizes lead there. When the
    /// media (`mdat`) comes first, everything after it. Nil when the boxes can't be followed.
    static func indexRange(_ head: Data, length: Int) -> Range<Int>? {
        let bytes = [UInt8](head.prefix(4096))
        var at = 0
        while at + 8 <= bytes.count {
            var size = bytes[at..<at + 4].reduce(0) { $0 << 8 | Int($1) }
            let type = String(decoding: bytes[at + 4..<at + 8], as: UTF8.self)
            if size == 1 {
                guard at + 16 <= bytes.count else { return nil }
                size = bytes[at + 8..<at + 16].reduce(0) { $0 << 8 | Int($1) }
            }
            if type == "moov" { return at..<(size == 0 ? length : min(length, at + size)) }
            guard size >= 8, at + size < length else { return nil }
            if type == "mdat" { return at + size..<length }
            at += size
        }
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
    /// Chunks fetched without a refusal before a stream a drive held to fewer connections tries one more.
    static let probeAfter = 64
    /// In a burst (`burst`), a chunk is fetched in up to this many pieces at once.
    static let piecesPerChunk = 4
    /// A burst lasts until the reader has this many seconds of bytes ahead of it, or `burstLimit` passed.
    static let burstSeconds: Double = 6
    static let burstLimit: TimeInterval = 12

    nonisolated let counter = CloudCounter()
    nonisolated let host: String?
    /// Seconds of cached bytes ahead of the player's latest read, readable without hopping onto the actor (#2175).
    nonisolated let bufferedAhead = OSAllocatedUnfairLock<Double>(initialState: 0)
    private var lastReadEnd: Int?
    private var source: CloudStreams.Source
    private let refresh: @Sendable () async -> CloudStreams.Source?
    /// The episode resolved again, when `refresh` gives no new link (`CloudStreams.register`).
    private let renewal: (@Sendable () async -> CloudStreams.Source?)?
    /// When the address was last resolved again, and whether that gave a new one.
    private var lastRefresh: (date: Date, renewed: Bool)?
    /// Refreshes that failed in a row: each waits longer before the next (`refreshWait`).
    private var refreshFailures = 0
    /// The refresh under way, which every chunk refused meanwhile waits for.
    private var renewing: Task<Bool, Never>?
    /// Downloads that failed in a row on this stream: while it lasts, a new request waits a little first (`holdUntil`), so
    /// a reader asking again at once (AVPlayer, FFmpeg) doesn't turn a dead link into a storm of requests.
    private var streak = FailureStreak(threshold: 2, base: CloudByteStream.retryBase * 2, ceiling: 15)
    private var holdUntil: Date?
    /// The first wait before a dropped connection or a server's passing error (502, a timeout) is tried again.
    nonisolated(unsafe) static var retryBase = 0.5
    private var cache: [Int: Data] = [:]
    private var recent: [Int] = []
    private var inflight: [Int: Task<Data, Error>] = [:]
    /// Once the player has read the file's index (`setDuration`), a chunk's bytes go to it as they arrive instead of
    /// when all 2 MB are in: a seek then waits for the drive's first bytes, not a whole chunk from each connection.
    private var progressive = false
    /// Where an MP4's index (moov) is, from its first boxes. Chunks clear of it go to the player as they arrive even
    /// before it has read the index: nothing in them is retagged (`playableSampleEntries`).
    private var indexBytes: Range<Int>?
    /// The bytes of chunks still arriving, by the download that is filling them.
    private var partial: [Int: (download: UUID, bytes: Data)] = [:]
    /// Reads waiting for more of a chunk that is arriving.
    private var arrivals: [Int: [CheckedContinuation<Void, Never>]] = [:]
    /// Where AVPlayer is reading. A file whose audio sits far from its video is read in two
    /// places at once; a jump away from all of them is a seek. On the iPhone AVPlayer also reads one
    /// place on two overlapping requests, the newer starting a few chunks behind the older (issue #433).
    private var readers: [Int] = []
    /// How many reads wait on each chunk; a seek never cancels a chunk someone still needs.
    private var waiting: [Int: Int] = [:]
    private var rate: (since: Date, bytes: Int) = (Date(), 0)
    /// How far ahead to read and how much to keep: the old fixed numbers until the video's bitrate is known (#702).
    private var readAheadChunks = CloudBufferPlan.fallback.readAhead
    private var cacheLimit = CloudBufferPlan.fallback.cacheChunks
    /// What playback consumes, once the player has told the duration.
    private var bytesPerSecond: Double?
    /// What playback reads per second on average, once the player knows the duration.
    var playbackBytesPerSecond: Double? { bytesPerSecond }
    /// When the drive first answered with bytes.
    private(set) var firstBytes: Date?
    /// The drive has refused a connection on this stream: it is not asked for more than it gave.
    private var refusedEver = false
    /// The most connections this stream may grow to, from `mostConnections`, when it falls behind playback.
    private let ceiling: Int
    private var growth: (since: Date, bytes: Int) = (Date(), 0)
    /// The speed before the last connection was added, and the count it had: the next sample says whether it helped.
    private var trial: (speed: Double, from: Int)?
    /// Another connection brought nothing: the drive or the network is the limit, and no more are tried.
    private var settled = false
    private var type: String?
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = max(parallel, CloudDevice.maxConnections) + 2
        configuration.timeoutIntervalForRequest = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    private let session: URLSession
    /// Connections reading ahead at once: `parallel` unless the source needs fewer, or the drive refused more.
    private var connections: Int
    private var mostConnections: Int
    /// Whether the current address has sent bytes. A refusal after that is the drive capping connections, not a dead link.
    private var served = false
    private var sinceRefusal = 0
    /// Whether `playableSampleEntries` retags the bytes: for AVPlayer's own MP4 reading, not for `Remux`.
    private var rewritesSampleEntries: Bool
    /// When the stream opened or the player jumped elsewhere, until the reader has a few seconds of bytes ahead: it
    /// reads on up to `ceiling` connections, and the chunks it starts come in pieces on several at once. Then it drops
    /// back to `connections`. The picture comes sooner; a steady stream stays kind to the drive. Not for a stream held
    /// to fewer connections (a bundle's proxy), nor once the drive refused one.
    private var burst: Date?
    private let burstable: Bool
    /// Connections the pieces of chunks use besides each chunk's own.
    private var pieceConnections = 0

    init(source: CloudStreams.Source, session: URLSession = CloudByteStream.session, parallel: Int = CloudByteStream.parallel,
         rewritesSampleEntries: Bool = true, refresh: @escaping @Sendable () async -> CloudStreams.Source?,
         renewal: (@Sendable () async -> CloudStreams.Source?)? = nil) {
        self.source = source; self.session = session; self.refresh = refresh; self.renewal = renewal; host = source.url.host()
        connections = max(1, parallel)
        mostConnections = connections
        ceiling = connections > 1 ? max(connections, CloudDevice.maxConnections) : 1
        self.rewritesSampleEntries = rewritesSampleEntries
        sourceLength = source.length
        burstable = parallel >= CloudByteStream.parallel
        burst = burstable ? Date() : nil
    }

    var length: Int { source.length }
    var currentSource: CloudStreams.Source { source }
    nonisolated let sourceLength: Int
    private var chunks: Int { (source.length + Self.chunkSize - 1) / Self.chunkSize }

    func contentType() async throws -> String {
        if let type { return type }
        // Its first bytes say what it is: no need to wait for the rest of the chunk.
        let head = try await arrived(0, past: 4095)
        fetchIndexEarly()
        let value = try CloudStreams.contentType(head, name: source.name)
        type = value
        // The first chunk says exactly where the index is, when it doesn't fit in the last chunk: ask for all of it now.
        indexBytes = CloudStreams.indexRange(head, length: source.length)
        if let range = indexBytes, range.lowerBound >= Self.chunkSize, !range.isEmpty {
            let first = range.lowerBound / Self.chunkSize
            for index in first...min(chunks - 1, (range.upperBound - 1) / Self.chunkSize, first + 3) where cache[index] == nil && inflight[index] == nil {
                _ = start(index)
            }
        }
        Diagnostics.shared.record(.info, "cloud.stream", "open host=\(host ?? "-") length=\(source.length) type=\(value)")
        return value
    }

    func head() async -> Data? {
        let head = try? await arrived(0, past: DiscImage.headLength - 1).prefix(DiscImage.headLength)
        fetchIndexEarly()
        return head
    }

    /// An MP4's index (moov) is often at its end, and the player reads nothing else until it has it: ask for that chunk
    /// once the first bytes came, not a whole chunk's download later. Not before: a drive that caps connections
    /// refuses one past its limit, and before it served any bytes that reads as a refused link.
    private func fetchIndexEarly() {
        guard chunks > 3, ["mp4", "m4v", "mov"].contains((source.name as NSString).pathExtension.lowercased()),
              cache[chunks - 1] == nil, inflight[chunks - 1] == nil else { return }
        _ = start(chunks - 1)
    }

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
        let ahead = readAheadChunks
        let near = { (reader: Int) in index >= reader - ahead && index <= reader + ahead + 1 }
        if let current = readers.firstIndex(where: near) { readers[current] = max(readers[current], index) }
        else {
            if !readers.isEmpty { Diagnostics.shared.record(.debug, "cloud.stream", "reader at=\(index) others=\(readers)") }
            readers.append(index)
            beginBurst()
            // Keep the two most recent positions (video and audio); a third means the user seeked.
            if readers.count > 2 {
                readers.removeFirst(readers.count - 2)
                let windows = readers.map { $0 - ahead...$0 + ahead }
                for (key, task) in inflight where waiting[key, default: 0] == 0 && !windows.contains(where: { $0.contains(key) }) {
                    task.cancel(); inflight[key] = nil
                }
            }
        }
        lastReadEnd = offset
        updateBufferedAhead()
        let start = offset - index * Self.chunkSize
        let bytes = try await available(index, from: start)
        considerEndingBurst(at: index)
        // Not for a reader dropped while this one waited (the player jumped elsewhere): that would fetch again the
        // chunks the jump let go.
        if readers.contains(where: near) { prefetch(after: index) }
        // A copy, not a slice: AVFoundation misread slices of a cached chunk as damaged media.
        let result = Data(bytes[start..<min(bytes.count, start + count)])
        lastReadEnd = offset + result.count
        updateBufferedAhead()
        return result
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

    /// The chunk, or as much of it as has arrived when that reaches past `offset` (progressive streams).
    private func available(_ index: Int, from offset: Int) async throws -> Data {
        let bytes = index * Self.chunkSize..<(index + 1) * Self.chunkSize
        let clear = progressive || !rewritesSampleEntries || indexBytes.map { !$0.overlaps(bytes) } == true
        guard clear, cache[index] == nil else { return try await chunk(index) }
        return try await arrived(index, past: offset)
    }

    /// The chunk's bytes so far once they reach past `offset`, or the whole chunk.
    private func arrived(_ index: Int, past offset: Int) async throws -> Data {
        waiting[index, default: 0] += 1
        defer { waiting[index, default: 1] -= 1; if waiting[index] == 0 { waiting[index] = nil } }
        let task = inflight[index] ?? start(index)
        while true {
            if let data = cache[index] {
                recent.removeAll { $0 == index }; recent.append(index)
                return data
            }
            if let part = partial[index]?.bytes, part.count > offset { return part }
            // Finished without a chunk (failed, or the stream was cleared): its error.
            if inflight[index] == nil { return try await task.value }
            await withCheckedContinuation { arrivals[index, default: []].append($0) }
        }
    }

    private func wake(_ index: Int) {
        for waiter in arrivals.removeValue(forKey: index) ?? [] { waiter.resume() }
    }

    private func prefetch(after index: Int) {
        let last = min(chunks - 1, index + readAheadChunks)
        guard index < last else { return }
        for next in index + 1...last where cache[next] == nil && inflight[next] == nil {
            guard inflight.count + pieceConnections < budget else { break }
            _ = start(next)
        }
    }

    /// Connections reading at once: more in a burst.
    private var budget: Int { burst == nil ? connections : max(connections, ceiling) }

    private func beginBurst() {
        guard burstable, !refusedEver else { return }
        burst = Date()
    }

    /// A burst ends once the reader has `burstSeconds` of bytes ahead (three chunks before the bitrate is known) after
    /// the player read the index, or when it ran `burstLimit`.
    private func considerEndingBurst(at index: Int) {
        guard let began = burst else { return }
        let target = bytesPerSecond.map { Int($0 * Self.burstSeconds) } ?? 3 * Self.chunkSize
        var ahead = 0, next = index + 1
        while ahead < target, next < chunks, let data = cache[next] { ahead += data.count; next += 1 }
        let elapsed = Date().timeIntervalSince(began)
        guard progressive && (ahead >= target || next >= chunks) || elapsed > Self.burstLimit else { return }
        burst = nil
        Diagnostics.shared.record(.debug, "cloud.stream", "burst over after \(String(format: "%.1f", elapsed)) s ahead=\(ahead) connections=\(connections)")
    }

    /// The rest of chunk bytes `range` after its first piece, each piece on a connection of its own, while a burst has
    /// connections to spare. Only once the address has served bytes: a drive that caps connections refuses one past its
    /// limit, and before that a refusal reads as a dead link.
    private func split(_ range: ClosedRange<Int>) -> [(range: Range<Int>, task: Task<Data?, Never>)] {
        guard burst != nil, served, !refusedEver, range.count >= Self.chunkSize / 4 else { return [] }
        let count = min(Self.piecesPerChunk, 1 + budget - inflight.count - pieceConnections)
        guard count >= 2 else { return [] }
        let size = (range.count + count - 1) / count
        return (1..<count).compactMap { k in
            let lower = range.lowerBound + k * size, upper = min(range.upperBound + 1, lower + size)
            guard lower < upper else { return nil }
            pieceConnections += 1
            return (lower..<upper, Task { await self.piece(lower..<upper) })
        }
    }

    /// Bytes `range` on a connection of their own, for a chunk fetched in pieces. Nil unless they all came: the chunk's
    /// own connection then asks for them.
    private func piece(_ range: Range<Int>) async -> Data? {
        defer { pieceConnections -= 1 }
        let current = source
        var request = URLRequest(url: current.url)
        current.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        current.freshHeaders?(current.url).forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (events, sink) = AsyncStream.makeStream(of: CloudFetch.Event.self)
        let task = session.dataTask(with: request)
        task.delegate = CloudFetch(sink)
        var bytes = Data(), status = 0, flowing = false
        bytes.reserveCapacity(range.count)
        await withTaskCancellationHandler {
            task.resume()
            for await event in events {
                switch event {
                case .response(let response):
                    status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    let answer = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range")?.firstMatch(of: /^bytes (\d+)-(\d+)\/(\d+)$/)
                    flowing = status == 206 && answer.flatMap { Int($0.1) } == range.lowerBound && answer.flatMap { Int($0.2) } == range.upperBound - 1
                    if !flowing { task.cancel() }
                case .data(let data):
                    guard flowing else { continue }
                    bytes.append(data)
                    counter.add(data.count)
                case .done: continue
                }
            }
        } onCancel: { task.cancel() }
        // The drive objects to the extra connections (115 answers 403 past a few): no more bursts on this stream.
        if [403, 429, 503].contains(status), !refusedEver {
            refusedEver = true; burst = nil
            Diagnostics.shared.record(.debug, "cloud.stream", "piece refused status=\(status); no more pieces")
        }
        guard flowing, !Task.isCancelled, bytes.count == range.count else { return nil }
        return bytes
    }

    private func start(_ index: Int) -> Task<Data, Error> {
        let task = Task {
            do {
                let data = try await self.download(index)
                self.succeeded()
                return data
            } catch {
                if !TransientRetry.isCancellation(error) { self.failed(index, error) }
                throw error
            }
        }
        inflight[index] = task
        return task
    }

    private func succeeded() {
        holdUntil = nil
        if let run = streak.succeed() { Diagnostics.shared.record(.info, "cloud.stream", "reads again after \(run) failed host=\(host ?? "-")") }
    }

    /// A chunk failed for good: reported once per run of failures, and the next request waits a little.
    private func failed(_ index: Int, _ error: Error) {
        let (report, wait) = streak.fail()
        if wait > 0 { holdUntil = Date().addingTimeInterval(wait) }
        if report { Diagnostics.shared.failure("cloud.stream", "chunk=\(index) failed run=\(streak.count) host=\(host ?? "-")", error) }
    }

    /// Waits out `holdUntil`, if the stream is in a run of failures.
    private func holdOff() async throws {
        guard let until = holdUntil, until > Date() else { return }
        try await Task.sleep(for: .seconds(until.timeIntervalSinceNow))
    }

    /// Chunk `index`, its bytes kept in `partial` as they arrive for reads that want them before the rest.
    private func download(_ index: Int) async throws -> Data {
        let id = UUID()
        partial[index] = (id, Data())
        partial[index]?.bytes.reserveCapacity(Self.chunkSize)
        // A cancelled download was already let go, and the chunk may be on its way again in another.
        defer {
            if !Task.isCancelled { inflight[index] = nil }
            if partial[index]?.download == id { partial[index] = nil }
            wake(index)
        }
        let first = index * Self.chunkSize, last = min(source.length, first + Self.chunkSize) - 1
        var attempt = 0, cut = 0, refusals = 0
        // Dropped connections and a server's passing errors (502, 504...) are tried again, a little later each time.
        var transient = Backoff(base: Self.retryBase, ceiling: 4, attempts: 4)
        try await holdOff()
        func received() -> Int { partial[index]?.download == id ? partial[index]?.bytes.count ?? 0 : 0 }
        // In a burst the rest of the chunk comes in pieces on connections of their own while this one reads its start.
        var pieces = split(first...last)
        defer { for piece in pieces { piece.task.cancel() } }
        while true {
            try Task.checkCancellation()
            attempt += 1
            let current = source, from = first + received()
            let stop = pieces.first.map { $0.range.lowerBound - 1 } ?? last
            var request = URLRequest(url: current.url)
            current.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
            current.freshHeaders?(current.url).forEach { request.setValue($1, forHTTPHeaderField: $0) }
            request.setValue("bytes=\(from)-\(stop)", forHTTPHeaderField: "Range")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            do {
                let (events, sink) = AsyncStream.makeStream(of: CloudFetch.Event.self)
                let task = session.dataTask(with: request)
                task.delegate = CloudFetch(sink)
                var status = 0, end: Int?, body = Data(), failure: Error?, flowing = false
                try await withTaskCancellationHandler {
                    task.resume()
                    for await event in events {
                        switch event {
                        case .response(let response):
                            status = (response as? HTTPURLResponse)?.statusCode ?? 0
                            let range = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range")?.firstMatch(of: /^bytes (\d+)-(\d+)\/(\d+)$/)
                            end = range.flatMap { Int($0.2) }
                            flowing = status == 206 && range.flatMap { Int($0.1) } == from && (end ?? .max) <= stop
                            if flowing { served = true; firstBytes = firstBytes ?? Date() }
                        case .data(let data):
                            guard flowing else { if body.count < 4096 { body.append(data) }; continue }
                            guard partial[index]?.download == id else { task.cancel(); continue }
                            partial[index]?.bytes.append(data)
                            counter.add(data.count)
                            wake(index)
                        case .done(let error): failure = error
                        }
                    }
                    try Task.checkCancellation()
                } onCancel: { task.cancel() }
                if let failure { throw failure }
                // The signed address expired, or the drive wants a fresh session: resolve once more.
                if [401, 403, 404, 410].contains(status), attempt <= 2, await renew() { continue }
                // 115 answers 403 to connections past a few at once on a link it is serving (issue #312). Failing the
                // read made FFmpeg lose its place in the file: read on fewer connections and ask again.
                if [403, 429, 503].contains(status), served, refusals < 6 {
                    refusals += 1
                    refused(index, status: status, body: body)
                    try await Task.sleep(for: .milliseconds(250 * refusals))
                    continue
                }
                // A gateway's or a busy server's answer (502 with no bytes ended 3,067 reads of one install in a week):
                // later, the same request usually gets the bytes.
                if !flowing, TransientRetry.transientStatuses.contains(status), let wait = transient.next() {
                    Diagnostics.shared.record(.debug, "cloud.stream", "chunk=\(index) status=\(status); again in \(wait) s")
                    try await Task.sleep(for: .seconds(wait))
                    continue
                }
                var got = received()
                guard flowing, let end, got > from - first else {
                    // A drive sometimes answers a range with no bytes, or fewer than it says: the next try gets them.
                    if status == 206, cut < 2 {
                        cut += 1
                        Diagnostics.shared.record(.debug, "cloud.stream", "chunk=\(index) short answer bytes=\(got) end=\(end.map(String.init) ?? "-"); again")
                        try await Task.sleep(for: .milliseconds(300 * cut))
                        continue
                    }
                    Diagnostics.shared.record(streak.count == 0 ? .error : .debug, "cloud.stream", "chunk=\(index) status=\(status) bytes=\(got)")
                    throw TVError.http(status == 200 ? 416 : status)
                }
                rate.bytes += got - (from - first); growth.bytes += got - (from - first)
                // This connection reached the next pieces: their bytes follow, or, for one that failed, this connection asks.
                while let next = pieces.first, first + got >= next.range.lowerBound {
                    pieces.removeFirst()
                    let bytes = await withTaskCancellationHandler { await next.task.value } onCancel: { next.task.cancel() }
                    try Task.checkCancellation()
                    if let bytes, partial[index]?.download == id, first + received() == next.range.lowerBound {
                        partial[index]?.bytes.append(bytes)
                        rate.bytes += bytes.count; growth.bytes += bytes.count
                        wake(index)
                    }
                    got = received()
                }
                // A drive that sends part of the range at a time, or a connection cut short: ask for the rest.
                if first + got <= last { attempt = 0; transient.reset(); continue }
                if Date().timeIntervalSince(rate.since) >= 10 {
                    let seconds = Date().timeIntervalSince(rate.since)
                    Diagnostics.shared.record(.debug, "cloud.stream", "rate bytesPerSecond=\(Int(Double(rate.bytes) / seconds)) readers=\(readers) inflight=\(inflight.count)")
                    rate = (Date(), 0)
                }
                considerMoreConnections()
                if connections < mostConnections {
                    sinceRefusal += 1
                    if sinceRefusal >= Self.probeAfter { connections += 1; sinceRefusal = 0 }
                }
                let bytes = partial[index]?.bytes ?? Data()
                partial[index] = nil
                let playable = rewritesSampleEntries ? CloudStreams.playableSampleEntries(bytes) : bytes
                cache[index] = playable
                recent.removeAll { $0 == index }; recent.append(index)
                while recent.count > cacheLimit { cache[recent.removeFirst()] = nil }
                updateBufferedAhead()
                return playable
            } catch let error as URLError where error.code != .cancelled && (attempt < 3 || TransientRetry.isTransient(error)) {
                // A loopback proxy (a CatPawOpen bundle's) refuses once iOS took back the suspended app's sockets, and
                // listens again on a new port: ask where (#485). Only a new address is tried at once, and only in the
                // first three tries: a refresh shared with other chunks answers its earlier outcome for a while, and
                // a proxy that refuses on its new port too waits like any other dropped connection.
                if error.code == .cannotConnectToHost, attempt < 3, ["127.0.0.1", "localhost"].contains(current.url.host() ?? ""),
                   await renew(), source.url != current.url { continue }
                guard let wait = transient.next() else { throw error }
                Diagnostics.shared.record(.debug, "cloud.stream", "chunk=\(index) retry \(error.code.rawValue) kept=\(received()) in \(wait) s")
                try await Task.sleep(for: .seconds(wait))
            }
        }
    }

    /// The drive refused chunk `index` while others were being read: read ahead on no more than those.
    private func refused(_ index: Int, status: Int, body: Data) {
        connections = max(1, min(connections - 1, inflight.count - 1))
        burst = nil
        sinceRefusal = 0
        refusedEver = true; trial = nil
        let text = String(decoding: body.prefix(120), as: UTF8.self).replacingOccurrences(of: "\n", with: " ")
        Diagnostics.shared.record(.debug, "cloud.stream", "chunk=\(index) refused status=\(status) body=\(text) connections=\(connections); again")
    }

    /// The player knows how long the video is: the bytes it consumes each second decide how far ahead to read and keep.
    func setDuration(_ seconds: Double) {
        guard seconds.isFinite, seconds > 1, source.length > 0 else { return }
        bytesPerSecond = Double(source.length) / seconds
        progressive = true
        let plan = CloudBufferPlan.make(length: source.length, duration: seconds, budget: CloudDevice.cacheBudget, chunkSize: Self.chunkSize)
        readAheadChunks = plan.readAhead; cacheLimit = plan.cacheChunks
        growth = (Date(), 0)
        updateBufferedAhead()
        Diagnostics.shared.record(.info, "cloud.stream", "plan bitrate=\(Int(bytesPerSecond ?? 0) * 8 / 1000)kbps readAhead=\(plan.readAhead) chunks (~\(Int(plan.seconds)) s) cache=\(plan.cacheChunks) chunks connections=\(connections)...\(ceiling) device=\(CloudDevice.current.label)")
    }

    /// Every few seconds: if reading flat out on all the connections still brings in less than twice what playback eats,
    /// and the drive has not objected to the number so far, try one more.
    private func considerMoreConnections() {
        let elapsed = Date().timeIntervalSince(growth.since)
        guard elapsed >= 4 else { return }
        let received = growth.bytes
        growth = (Date(), 0)
        let speed = Double(received) / elapsed
        if let earlier = trial {
            trial = nil
            // Under 15% more with the extra connection (a drive that caps the whole account, a slow network): keep the
            // old count. A thinner stream is kinder to the drive and to the battery.
            if speed < earlier.speed * 1.15 {
                connections = earlier.from; mostConnections = earlier.from; settled = true
                Diagnostics.shared.record(.debug, "cloud.stream", "more connections did not help (\(Int(earlier.speed)) to \(Int(speed)) B/s): back to \(earlier.from)")
                return
            }
        }
        guard let bytesPerSecond, !settled, !refusedEver, connections == mostConnections, mostConnections < ceiling,
              inflight.count >= connections, speed < 2 * bytesPerSecond else { return }
        trial = (speed, connections)
        connections += 1; mostConnections += 1
        Diagnostics.shared.record(.debug, "cloud.stream", "behind playback (\(Int(Double(received) / elapsed)) B/s of \(Int(bytesPerSecond)) needed): connections=\(connections)")
    }

    /// How long after a refresh its outcome stands for every chunk refused meanwhile: 10 s after one that renewed the
    /// link; after failures, 10 s, 20 s, 40 s... up to 5 minutes, so a link that can't be renewed isn't asked for every
    /// 10 s while the player keeps reading (149 installs logged "refresh failed" 2,400 times in a week).
    static func refreshWait(failures: Int) -> TimeInterval {
        failures == 0 ? 10 : min(300, 10 * pow(2, Double(failures - 1)))
    }

    private func renew() async -> Bool {
        // Chunks refused together share one refresh, and its outcome.
        if let renewing { return await renewing.value }
        if let lastRefresh, Date().timeIntervalSince(lastRefresh.date) < Self.refreshWait(failures: refreshFailures) { return lastRefresh.renewed }
        let task = Task { await self.resolveAgain() }
        renewing = task
        let renewed = await task.value
        renewing = nil
        return renewed
    }

    /// A new link for the same file: from `refresh`, else from the episode resolved again (`renewal`). The same link
    /// again doesn't count: a plugin's proxy that kept the expired one answers it, and the drive refuses it again.
    private func resolveAgain() async -> Bool {
        let old = source
        var reason = "none"
        func usable(_ next: CloudStreams.Source?) -> CloudStreams.Source? {
            guard let next else { return nil }
            if next.url == old.url && next.headers == old.headers { reason = "same link"; return nil }
            if next.length != old.length { reason = "length \(next.length) not \(old.length)"; return nil }
            return next
        }
        var next = usable(await refresh())
        if next == nil, let renewal {
            Diagnostics.shared.record(.info, "cloud.stream", "refresh gave \(reason); asking the source again host=\(host ?? "-")")
            next = usable(await renewal())
        }
        guard let next else {
            refreshFailures += 1
            lastRefresh = (Date(), false)
            // Once per doubling, so a link that stays dead is reported, not counted out request by request.
            if refreshFailures & (refreshFailures - 1) == 0 {
                Diagnostics.shared.record(.error, "cloud.stream", "refresh failed reason=\(reason) renewal=\(renewal != nil) failures=\(refreshFailures) host=\(host ?? "-")")
            }
            return false
        }
        refreshFailures = 0
        lastRefresh = (Date(), true)
        source = next
        served = false
        Diagnostics.shared.record(.info, "cloud.stream", "refreshed host=\(next.url.host() ?? "-")")
        return true
    }

    /// Contiguous bytes already in memory past `lastReadEnd`, converted to seconds at the file's average bitrate.
    private func updateBufferedAhead() {
        guard let end = lastReadEnd, let bytesPerSecond, bytesPerSecond > 0 else {
            bufferedAhead.withLock { $0 = 0 }
            return
        }
        var bytes = 0
        var index = end / Self.chunkSize
        var offset = end - index * Self.chunkSize
        while index < chunks {
            if let data = cache[index] {
                bytes += max(0, data.count - offset)
                index += 1
                offset = 0
            } else if let part = partial[index]?.bytes {
                bytes += max(0, part.count - offset)
                break
            } else {
                break
            }
        }
        let seconds = Double(bytes) / bytesPerSecond
        bufferedAhead.withLock { $0 = seconds }
    }

    func clear() {
        for task in inflight.values { task.cancel() }
        inflight.removeAll(); cache.removeAll(); recent.removeAll(); readers.removeAll(); waiting.removeAll(); partial.removeAll()
        lastReadEnd = nil
        bufferedAhead.withLock { $0 = 0 }
        for index in Array(arrivals.keys) { wake(index) }
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

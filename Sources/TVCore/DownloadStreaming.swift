import Foundation

/// Playing a download before it has finished (#1264). The player reads the download through the loopback server
/// (`LocalMediaServer`): what is on disk comes from disk, and a piece that isn't there yet is fetched from the
/// source then and there. A running download keeps such a piece and carries on from where the player is, so the
/// two never fetch the same piece twice.
///
/// HLS plays from the plan's playlist and its `parts/` files. A file fetched in ranges plays as
/// `<id>/play.<extension>`, read chunk by chunk from `parts/media.part`. A file whose server sends no ranges and
/// Bilibili's DASH halves wait until they are whole (`TransferPlan.streams`).
enum DownloadStream {
    /// The name an unfinished file is asked for by.
    static let filePrefix = "play."
    /// Requests made for the player at once, beside the download's own connections.
    static let fetches = 6
    /// A chunk fetched for the player comes over this many connections at once, each with a share of it: hosts that
    /// slow every connection down would otherwise keep the player waiting for the whole chunk on one.
    static let shares = 4
    static let smallestShare = 1 << 20

    private static let state = State()
    /// What fetches for the player. Its connections are its own: a download's session shares eight per host among
    /// every download from that host, and the player's requests would wait behind them.
    static var session: URLSession {
        get { state.lock.withLock { state.session } }
        set { state.lock.withLock { state.session = newValue } }
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var running: [String: LiveTransfer] = [:]
        var served: [String: Date] = [:]
        var plans: [String: (modified: Date, plan: TransferPlan)] = [:]
        /// Pieces being fetched, and whether it is for the player.
        var held: [String: Bool] = [:]
        var fetching = 0
        var session: URLSession = {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 30
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpMaximumConnectionsPerHost = DownloadStream.fetches
            return URLSession(configuration: configuration)
        }()
    }

    private static func key(_ folder: URL) -> String { folder.standardizedFileURL.path }

    // MARK: Running transfers

    static func began(_ live: LiveTransfer, in folder: URL) { state.lock.withLock { state.running[key(folder)] = live } }
    static func ended(_ live: LiveTransfer, in folder: URL) {
        state.lock.withLock { if state.running[key(folder)] === live { state.running[key(folder)] = nil } }
    }

    /// The download's plan as it stands: a running transfer's own, else the one saved beside it.
    static func plan(in folder: URL) -> (plan: TransferPlan, live: LiveTransfer?)? {
        let key = key(folder)
        if let live = state.lock.withLock({ state.running[key] }), let plan = live.plan { return (plan, live) }
        let file = folder.appending(path: "plan.json")
        guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
        if let cached = state.lock.withLock({ state.plans[key] }), cached.modified == modified { return (cached.plan, nil) }
        guard let data = try? Data(contentsOf: file), let plan = try? JSONDecoder().decode(TransferPlan.self, from: data) else { return nil }
        state.lock.withLock { state.plans[key] = (modified, plan) }
        return (plan, nil)
    }

    /// The loopback address that plays the unfinished download in `folder`; nil when it has to be whole first.
    static func address(in folder: URL, root: URL) async throws -> URL? {
        guard let plan = plan(in: folder)?.plan, plan.streams else { return nil }
        touch(folder)
        let name = plan.kind == .hls ? "index.m3u8" : filePrefix + (plan.fileExtension ?? "mp4")
        return try await LocalMediaServer.shared.address(of: folder.appending(path: name), root: root)
    }

    /// Whether the player read from this download in the last minute. Its finished file is then left as it is:
    /// rewrapping an MKV as an MP4 would take the file away from under the player (`DownloadLibrary.rewrap` does it
    /// on the next play instead).
    static func isPlaying(_ folder: URL) -> Bool {
        state.lock.withLock { state.served[key(folder)] }.map { Date().timeIntervalSince($0) < 60 } ?? false
    }
    static func touch(_ folder: URL) { state.lock.withLock { state.served[key(folder)] = Date() } }

    // MARK: What the server asks

    /// An unfinished file download asked for as `<id>/play.<extension>`.
    static func file(_ url: URL) -> PendingFile? {
        guard url.lastPathComponent.hasPrefix(filePrefix) else { return nil }
        let folder = url.deletingLastPathComponent()
        guard let plan = plan(in: folder)?.plan, plan.kind == .file, let file = plan.files.first, let length = file.length, length > 0 else { return nil }
        return PendingFile(folder: folder, length: length, fileExtension: plan.fileExtension ?? "mp4")
    }

    /// A file the server doesn't have: an unfinished HLS download's playlist, or one of its pieces, fetched now
    /// and kept for the download.
    static func missing(_ url: URL) async -> Data? {
        let parent = url.deletingLastPathComponent()
        if url.lastPathComponent == "index.m3u8" {
            guard let plan = plan(in: parent)?.plan, plan.kind == .hls, let playlist = plan.playlist else { return nil }
            touch(parent)
            return Data(playlist.utf8)
        }
        guard parent.lastPathComponent == "parts" else { return nil }
        do { return try await part("parts/" + url.lastPathComponent, in: parent.deletingLastPathComponent()) }
        catch {
            if !(error is CancellationError) { Diagnostics.shared.failure("download", "play piece \(url.lastPathComponent)", error) }
            return nil
        }
    }

    private static func part(_ name: String, in folder: URL) async throws -> Data {
        guard plan(in: folder)?.plan.kind == .hls else { throw TVError.invalidURL }
        touch(folder)
        let target = folder.appending(path: name)
        return try await exclusive(target.path, forPlayer: true) {
            // The download got to it first.
            if let data = try? Data(contentsOf: target) { return data }
            var data = try await fetched(in: folder) { plan, live in
                guard let part = plan.parts.first(where: { $0.name == name }) else { throw TVError.invalidURL }
                live?.follow(part: name)
                return ([part.url], part.range)
            }
            if plan(in: folder)?.plan.parts.first(where: { $0.name == name })?.transportStream == true { data = MediaPayload.transportStream(data) }
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: target, options: .atomic)
            return data
        }
    }

    /// How long the player's first read waits for a chunk the download is in the middle of before it fetches the
    /// chunk itself: a download's four chunks arrive together, seconds apart on a slow host, and a video that was
    /// just opened or moved elsewhere shouldn't sit through that. Reads after the first wait, so playing on through
    /// a download fetches nothing twice.
    static let patience = Duration.milliseconds(1500)

    /// One chunk of an unfinished file, from the source. A running download writes it into its file and marks it.
    fileprivate static func chunk(_ chunk: Int, in folder: URL, impatient: Bool = false) async throws -> Data {
        let target = folder.appending(path: "parts/media.part")
        return try await exclusive(target.path + "#\(chunk)", forPlayer: true, patience: impatient ? patience : nil) {
            guard let file = plan(in: folder)?.plan.files.first else { throw TVError.invalidURL }
            let range = file.range(chunk)
            // The download got to it first.
            if file.done.contains(chunk), let data = try? bytes(of: target, range) { return data }
            plan(in: folder)?.live?.follow(chunk: chunk + 1)
            let began = Date()
            let count = max(1, min(shares, range.count / smallestShare)), size = Int64((range.count + count - 1) / count)
            let pieces = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                for index in 0..<count {
                    let low = range.lowerBound + Int64(index) * size
                    let share = low...min(range.upperBound, low + size - 1)
                    group.addTask {
                        let data = try await fetched(in: folder) { plan, _ in
                            guard let file = plan.files.first else { throw TVError.invalidURL }
                            return (file.urls, share)
                        }
                        guard data.count == share.count else { throw TransferError.incomplete }
                        return (index, data)
                    }
                }
                var pieces: [Int: Data] = [:]
                for try await (index, data) in group { pieces[index] = data }
                return pieces
            }
            let data = (0..<count).reduce(into: Data(capacity: range.count)) { $0.append(pieces[$1] ?? Data()) }
            guard data.count == range.count else { throw TransferError.incomplete }
            let kept = plan(in: folder)?.live?.keep(data, at: range.lowerBound, chunk: chunk) ?? false
            Diagnostics.shared.record(.debug, "download", "chunk for the player index=\(chunk) shares=\(count) kept=\(kept) ms=\(Int(began.timeIntervalSinceNow * -1000))")
            return data
        }
    }

    /// Fetches what `piece` names from the plan as it stands. Links that have expired are tried again a few times
    /// while the download runs, since it renews them when it meets the same refusal.
    private static func fetched(in folder: URL, piece: @Sendable (TransferPlan, LiveTransfer?) throws -> (urls: [URL], range: ClosedRange<Int64>?)) async throws -> Data {
        var attempt = 0
        while true {
            guard let current = plan(in: folder) else { throw TVError.invalidURL }
            let wanted = try piece(current.plan, current.live)
            let transfer = Transfer(folder: folder, meter: DownloadMeter(), session: session, resolve: { throw CancellationError() }, note: { _ in })
            do {
                return try await limited { try await transfer.get(wanted.urls, headers: current.plan.headers, range: wanted.range, counts: false).0 }
            } catch TransferError.expired(let status) {
                attempt += 1
                guard current.live != nil, attempt < 5 else { throw TransferError.expired(status) }
                try await Task.sleep(for: .seconds(3))
            }
        }
    }

    static func bytes(of file: URL, _ range: ClosedRange<Int64>) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(range.lowerBound))
        let data = try handle.read(upToCount: range.count) ?? Data()
        guard data.count == range.count else { throw TransferError.incomplete }
        return data
    }

    // MARK: One fetch per piece

    /// Runs `body` while nothing else holds `piece`: the download and the player each look again for the piece
    /// once the other is done with it, rather than fetch it twice.
    /// With `patience`, `body` runs anyway once the download has held the piece that long; a piece another of the
    /// player's requests is fetching is always waited for.
    static func exclusive<T: Sendable>(_ piece: String, forPlayer: Bool = false, patience: Duration? = nil, _ body: () async throws -> T) async throws -> T {
        let began = ContinuousClock.now
        var holds = true
        while true {
            let holder = state.lock.withLock { () -> Bool? in
                if let holder = state.held[piece] { return holder }
                state.held[piece] = forPlayer
                return nil
            }
            guard let holder else { break }
            if let patience, !holder, began.duration(to: .now) >= patience { holds = false; break }
            try await Task.sleep(for: .milliseconds(40))
        }
        defer { if holds { state.lock.withLock { state.held[piece] = nil } } }
        return try await body()
    }

    private static func limited<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        while !state.lock.withLock({ () -> Bool in
            guard state.fetching < fetches else { return false }
            state.fetching += 1
            return true
        }) { try await Task.sleep(for: .milliseconds(40)) }
        defer { state.lock.withLock { state.fetching -= 1 } }
        return try await body()
    }
}

extension TransferPlan {
    /// Whether the download can play before it is whole: HLS, or one file its server sends in ranges.
    var streams: Bool { kind == .hls ? playlist != nil : kind == .file && files.count == 1 && files[0].ranged && (files[0].length ?? 0) > 0 }
}

/// What a running transfer shares with the player: its plan as it fills, the file it writes into, and the order
/// of what is left to fetch.
final class LiveTransfer: @unchecked Sendable {
    private let lock = NSLock()
    private var box: PlanBox?
    private var writer: FileWriter?
    private var chunks: WorkQueue<Int>?
    private var parts: WorkQueue<TransferPlan.Part>?

    var plan: TransferPlan? { lock.withLock { box }?.plan }

    func fetching(_ box: PlanBox, parts: WorkQueue<TransferPlan.Part>) { lock.withLock { self.box = box; self.parts = parts } }
    /// A plan of one file is the only one the player reads chunk by chunk.
    func fetching(_ box: PlanBox, writer: FileWriter, chunks: WorkQueue<Int>) {
        lock.withLock { self.box = box; self.writer = writer; self.chunks = chunks }
    }
    func stopped() { lock.withLock { writer = nil; chunks = nil; parts = nil } }

    /// The download goes on from where the player is.
    func follow(chunk: Int) { lock.withLock { chunks }?.advance(to: chunk) { $0 } }
    func follow(part name: String) { lock.withLock { parts }?.advance(to: name) { $0.name } }

    /// A chunk fetched for the player goes into the download's file; false when the download isn't writing it now.
    func keep(_ data: Data, at offset: Int64, chunk: Int) -> Bool {
        let (box, writer) = lock.withLock { (self.box, self.writer) }
        guard let box, let writer, box.plan.kind == .file, (try? writer.write(data, at: UInt64(offset))) != nil else { return false }
        box.mark(0, chunk: chunk)
        return true
    }
}

/// An unfinished file download as the player reads it: one per request.
final class PendingFile: @unchecked Sendable {
    let folder: URL
    let length: Int64
    let fileExtension: String
    /// The chunk last fetched for this request, when no running download kept it.
    private var fetched: (chunk: Int, data: Data)?
    /// Whether nothing has been fetched for this request yet (`DownloadStream.patience`).
    private var opening = true

    init(folder: URL, length: Int64, fileExtension: String) { self.folder = folder; self.length = length; self.fileExtension = fileExtension }

    /// The bytes from the start of `range` to its end or the end of their chunk, whichever comes first.
    func read(_ range: ClosedRange<Int64>) async throws -> Data {
        DownloadStream.touch(folder)
        let chunk = Int(range.lowerBound / Transfer.chunk)
        let start = Int64(chunk) * Transfer.chunk
        let wanted = range.lowerBound...min(range.upperBound, start + Transfer.chunk - 1, length - 1)
        if let fetched, fetched.chunk == chunk { return slice(fetched.data, wanted, from: start) }
        if DownloadStream.plan(in: folder)?.plan.files.first?.done.contains(chunk) == true,
           let data = try? DownloadStream.bytes(of: folder.appending(path: "parts/media.part"), wanted) { return data }
        // Finished meanwhile: the file has its final name.
        let whole = folder.appending(path: "media." + fileExtension)
        if FileManager.default.fileExists(atPath: whole.path) { return try DownloadStream.bytes(of: whole, wanted) }
        let data = try await DownloadStream.chunk(chunk, in: folder, impatient: opening)
        opening = false
        fetched = (chunk, data)
        return slice(data, wanted, from: start)
    }

    private func slice(_ data: Data, _ range: ClosedRange<Int64>, from start: Int64) -> Data {
        let low = Int(range.lowerBound - start), high = min(Int(range.upperBound - start) + 1, data.count)
        return low < high ? Data(data[data.startIndex + low..<data.startIndex + high]) : Data()
    }
}

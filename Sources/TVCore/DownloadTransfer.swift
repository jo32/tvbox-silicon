import Foundation

/// How one download's media is laid out, saved beside it as `plan.json`: a stopped download
/// reads it back and fetches only what is missing.
struct TransferPlan: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case file, hls, dash }
    /// A file fetched in fixed-size ranges, several at once; `done` lists the finished ranges.
    struct RemoteFile: Codable, Sendable {
        /// Mirrors, tried in order.
        var urls: [URL]
        var name: String
        var length: Int64?
        /// False when the server ignores ranges: the file then comes in one request and starts over if stopped.
        var ranged: Bool
        var done: Set<Int> = []
        /// DASH: the initialization section and `sidx` index, which describe the file as HLS byte ranges.
        var initialization: ClosedRange<Int>?
        var index: ClosedRange<Int>?
        var chunks: Int {
            guard ranged, let length, length > 0 else { return 1 }
            return Int((length + Transfer.chunk - 1) / Transfer.chunk)
        }
        func range(_ index: Int) -> ClosedRange<Int64> {
            let start = Int64(index) * Transfer.chunk
            return start...min(start + Transfer.chunk, length ?? 0) - 1
        }
        /// Bytes already on disk for the finished ranges.
        var saved: Int64 { ranged ? done.reduce(0) { $0 + Int64(range($1).count) } : 0 }
    }
    /// One HLS segment, key or initialization section, saved whole under `name`.
    struct Part: Codable, Sendable {
        var url: URL
        var range: ClosedRange<Int64>?
        var name: String
        /// MPEG-TS that some hosts disguise behind an image header.
        var transportStream: Bool
    }
    var kind: Kind
    var headers: [String: String]
    var files: [RemoteFile] = []
    var parts: [Part] = []
    /// The local HLS playlist, naming `parts` by their file names.
    var playlist: String?
    var fileExtension: String?
    var quality: Int?
    /// DASH: the master playlist's EXT-X-STREAM-INF attributes.
    var streamInfo: String?
    var label: String?
    var cid: String?
    var duration: Double?
    var expected: Int64? {
        guard kind != .hls else { return nil }
        let lengths = files.map(\.length)
        return lengths.contains(nil) ? nil : lengths.reduce(0) { $0 + ($1 ?? 0) }
    }
}

enum TransferError: LocalizedError, Equatable {
    /// The address answered 401/403/404/410: links from most sources expire, so the episode is resolved again.
    case expired(Int)
    case http(Int)
    case live, protected, notMedia, rangeLost, incomplete, noSpace(needed: Int64, available: Int64)
    var retriable: Bool {
        switch self {
        case .http(let status): status == 429 || status >= 500 || status == 0
        case .incomplete: true
        default: false
        }
    }
    var errorDescription: String? {
        switch self {
        case .expired(let status): L10n.text("The video link stopped working (HTTP %lld) and could not be renewed. Try again later.", status)
        case .http(let status): L10n.text("The server returned HTTP %lld.", status)
        case .live: L10n.text("Live streams can't be downloaded.")
        case .protected: L10n.text("This video is protected and can't be downloaded.")
        case .notMedia: L10n.text("This link didn't return a video.")
        case .rangeLost: L10n.text("The server stopped allowing resumed downloads. Retry to start again.")
        case .incomplete: L10n.text("The server closed the connection early.")
        case .noSpace(let needed, let available):
            L10n.text("Not enough storage: this needs %@ more, and %@ is free.", Self.size(needed), Self.size(available))
        }
    }
    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

/// What a running transfer reports beyond byte counts.
enum TransferNote: Sendable {
    case prepared(TransferPlan)
    case finishing
}

/// Fetches one download into its folder. Every finished piece is on disk under its final name (or
/// marked in `plan.json`), so cancelling at any point loses at most the pieces in flight.
struct Transfer: Sendable {
    static let chunk: Int64 = 4 << 20
    /// Connections per download. Parallel ranges get past per-connection throttling on CDNs.
    static let connections = 4
    let folder: URL
    let meter: DownloadMeter
    let session: URLSession
    let resolve: @Sendable () async throws -> Channel
    let note: @Sendable (TransferNote) async -> Void

    private var planFile: URL { folder.appending(path: "plan.json") }

    /// Downloads everything and returns the playable file's path inside the folder.
    func run() async throws -> String {
        try FileManager.default.createDirectory(at: folder.appending(path: "parts"), withIntermediateDirectories: true)
        var plan: TransferPlan
        if let data = try? Data(contentsOf: planFile), let saved = try? JSONDecoder().decode(TransferPlan.self, from: data) { plan = saved }
        else { plan = try await prepare(try await resolve()); try save(plan) }
        var renewals = 0
        while finishedFile(plan) == nil {
            try Task.checkCancellation()
            try begin(plan)
            await note(.prepared(plan))
            let box = PlanBox(plan, file: planFile)
            do {
                try await fetch(box)
                plan = box.plan
                try save(plan)
                break
            } catch TransferError.expired(let status) {
                plan = box.plan
                try? save(plan)
                guard renewals < 2 else { throw TransferError.expired(status) }
                renewals += 1
                Diagnostics.shared.record(.info, "download", "renewing link status=\(status) folder=\(folder.lastPathComponent)")
                plan = try await renew(plan)
                try save(plan)
            } catch {
                try? save(box.plan)
                throw error
            }
        }
        await note(.finishing)
        return try await finish(plan)
    }

    // MARK: Planning

    /// Works out what the resolved address is: Bilibili DASH, an HLS playlist, or a plain file.
    func prepare(_ channel: Channel) async throws -> TransferPlan {
        if let dash = BilibiliStreams.files(for: channel.url) { return try await prepare(dash) }
        if channel.url.scheme == BilibiliStreams.scheme { throw TVError.unsupported(L10n.text("This playback has expired. Open the video again.")) }
        var headers = channel.headers
        if !headers.keys.contains(where: { $0.lowercased() == "user-agent" }) { headers["User-Agent"] = HTTPClient.userAgent }
        let (head, response) = try await get([channel.url], headers: headers, range: 0...65_535, limit: 65_536, counts: false)
        let base = response.url ?? channel.url
        if Self.isPlaylist(head) {
            var text = String(decoding: head, as: UTF8.self)
            if Self.total(response).map({ $0 > Int64(head.count) }) ?? (head.count >= 65_536) {
                text = String(decoding: try await get([channel.url], headers: headers, counts: false).0, as: UTF8.self)
            }
            return try await prepareHLS(text, base: base, headers: headers)
        }
        let mime = response.mimeType?.lowercased() ?? ""
        if mime.hasPrefix("text/html") || mime.hasPrefix("application/json") { throw TransferError.notMedia }
        let ranged = response.statusCode == 206
        let length = ranged ? Self.total(response) : (response.expectedContentLength > 0 ? response.expectedContentLength : nil)
        let file = TransferPlan.RemoteFile(urls: [base], name: "media.part", length: length, ranged: ranged && length != nil)
        return TransferPlan(kind: .file, headers: headers, files: [file], fileExtension: Self.fileExtension(base, mime: mime, head: head))
    }

    private func prepare(_ dash: DashFiles) async throws -> TransferPlan {
        var files: [TransferPlan.RemoteFile] = []
        let halves = [("video.m4s", dash.video, dash.videoInitialization, dash.videoIndex), ("audio.m4s", dash.audio, dash.audioInitialization, dash.audioIndex)]
        for (name, urls, initialization, index) in halves where !urls.isEmpty {
            let (_, response) = try await get(urls, headers: Bilibili.mediaHeaders, range: 0...0, limit: 1, counts: false)
            guard response.statusCode == 206, let length = Self.total(response) else { throw TransferError.rangeLost }
            // Keep the mirror that answered first.
            let first = response.url.flatMap { answered in urls.first { $0.host() == answered.host() } }
            files.append(.init(urls: first.map { [$0] + urls.filter { $0 != first } } ?? urls, name: name, length: length, ranged: true,
                               initialization: initialization, index: index))
        }
        return TransferPlan(kind: .dash, headers: Bilibili.mediaHeaders, files: files, quality: dash.quality,
                            streamInfo: dash.streamInfo, label: dash.label, cid: dash.cid, duration: dash.duration)
    }

    private func prepareHLS(_ playlist: String, base: URL, headers: [String: String]) async throws -> TransferPlan {
        var text = playlist, base = base, label: String?
        // A master playlist: take the best variant (by bandwidth), which may itself be a master.
        for _ in 0..<3 {
            guard let best = HLS.variants(text, base: base).max(by: { $0.bandwidth < $1.bandwidth }) else { break }
            label = best.height.map { "\($0)P" } ?? label
            let (data, response) = try await get([best.url], headers: headers, counts: false)
            guard Self.isPlaylist(data) else { throw TransferError.notMedia }
            text = String(decoding: data, as: UTF8.self); base = response.url ?? best.url
        }
        let local = try HLS.localize(text, base: base)
        return TransferPlan(kind: .hls, headers: headers, parts: local.parts, playlist: local.playlist, label: label)
    }

    /// Resolves the episode again after its links expired and carries the progress over when the
    /// media is the same (same sizes, same segment count); otherwise starts it over.
    private func renew(_ old: TransferPlan) async throws -> TransferPlan {
        let channel = try await resolve()
        var plan: TransferPlan
        if old.kind == .dash, let dash = BilibiliStreams.files(for: channel.url, quality: old.quality) { plan = try await prepare(dash) }
        else { plan = try await prepare(channel) }
        if plan.kind == old.kind {
            switch plan.kind {
            case .file, .dash:
                if plan.files.count == old.files.count, zip(plan.files, old.files).allSatisfy({ $0.length == $1.length && $0.ranged && $1.ranged }) {
                    for index in plan.files.indices { plan.files[index].done = old.files[index].done }
                    return plan
                }
            case .hls:
                if plan.parts.count == old.parts.count, plan.playlist == old.playlist { return plan }
            }
        }
        Diagnostics.shared.record(.info, "download", "renewed media differs; starting over folder=\(folder.lastPathComponent)")
        try? FileManager.default.removeItem(at: folder.appending(path: "parts"))
        try FileManager.default.createDirectory(at: folder.appending(path: "parts"), withIntermediateDirectories: true)
        return plan
    }

    /// A file download already moved into place (or rewrapped): the app quit while it was finishing.
    private func finishedFile(_ plan: TransferPlan) -> String? {
        guard plan.kind == .file, !FileManager.default.fileExists(atPath: folder.appending(path: "parts").appending(path: plan.files[0].name).path) else { return nil }
        return ["media." + (plan.fileExtension ?? "mp4"), DownloadLibrary.rewrappedName].first { FileManager.default.fileExists(atPath: folder.appending(path: $0).path) }
    }

    private func save(_ plan: TransferPlan) throws {
        try JSONEncoder().encode(plan).write(to: planFile, options: .atomic)
    }

    /// Counts what is already on disk and checks there is room for the rest.
    private func begin(_ plan: TransferPlan) throws {
        let saved: Int64, done: Int, total: Int
        switch plan.kind {
        case .file, .dash:
            saved = plan.files.reduce(0) { $0 + $1.saved }
            done = plan.files.reduce(0) { $0 + ($1.ranged ? $1.done.count : 0) }
            total = plan.files.reduce(0) { $0 + $1.chunks }
        case .hls:
            let present = plan.parts.compactMap { part -> Int64? in
                (try? folder.appending(path: part.name).resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            }
            saved = present.reduce(0, +); done = present.count; total = plan.parts.count
        }
        meter.reset(received: saved, parts: done, total: total, expected: plan.expected)
        if let expected = plan.expected, let free = DownloadLibrary.availableCapacity(at: folder) {
            let needed = expected - saved
            if needed > free { throw TransferError.noSpace(needed: needed, available: free) }
        }
    }

    // MARK: Fetching

    private func fetch(_ box: PlanBox) async throws {
        let plan = box.plan
        switch plan.kind {
        case .file, .dash:
            for index in plan.files.indices { try await fetch(file: index, box: box) }
        case .hls:
            let pending = plan.parts.filter { !FileManager.default.fileExists(atPath: folder.appending(path: $0.name).path) }
            let queue = WorkQueue(pending)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<min(Self.connections, pending.count) {
                    group.addTask {
                        while let part = queue.next() {
                            try Task.checkCancellation()
                            var (data, _) = try await get([part.url], headers: plan.headers, range: part.range)
                            if part.transportStream { data = MediaPayload.transportStream(data) }
                            let target = folder.appending(path: part.name)
                            try Self.writing { try data.write(to: target, options: .atomic) }
                            meter.finishedPart()
                        }
                    }
                }
                try await group.waitForAll()
            }
        }
    }

    private func fetch(file index: Int, box: PlanBox) async throws {
        let file = box.plan.files[index], headers = box.plan.headers
        let target = folder.appending(path: "parts").appending(path: file.name)
        guard file.ranged, let length = file.length else {
            // No ranges: one request into a fresh file.
            try? FileManager.default.removeItem(at: target)
            FileManager.default.createFile(atPath: target.path, contents: nil)
            let writer = try FileWriter(target)
            let before = meter.received
            do {
                _ = try await get(file.urls, headers: headers, sink: { data in try writer.append(data) })
            } catch {
                meter.add(before - meter.received)
                throw error
            }
            try writer.close()
            box.markWhole(index)
            meter.finishedPart()
            return
        }
        if !FileManager.default.fileExists(atPath: target.path) {
            // A fresh file: earlier marks would point at missing bytes.
            box.reset(index)
            FileManager.default.createFile(atPath: target.path, contents: nil)
        }
        let writer = try FileWriter(target)
        defer { try? writer.close() }
        try writer.truncate(length)
        let pending = (0..<file.chunks).filter { !box.plan.files[index].done.contains($0) }
        let queue = WorkQueue(pending)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<min(Self.connections, pending.count) {
                group.addTask {
                    while let chunk = queue.next() {
                        try Task.checkCancellation()
                        let range = file.range(chunk)
                        let (data, _) = try await get(box.plan.files[index].urls, headers: headers, range: range)
                        guard data.count == range.count else { meter.add(-Int64(data.count)); throw TransferError.incomplete }
                        try writer.write(data, at: UInt64(range.lowerBound))
                        box.mark(index, chunk: chunk)
                        meter.finishedPart()
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    /// Fetches one address (trying mirrors, retrying network failures with a pause) into memory, or into `sink`.
    /// Throws `expired` only when every mirror refused, since renewing the link is then the way on.
    func get(_ urls: [URL], headers: [String: String], range: ClosedRange<Int64>? = nil, limit: Int? = nil,
             counts: Bool = true, sink: (@Sendable (Data) throws -> Void)? = nil) async throws -> (Data, HTTPURLResponse) {
        var failure: Error = TransferError.http(0)
        for attempt in 0..<3 {
            if attempt > 0 { try await Task.sleep(for: .seconds(2 * attempt)) }
            var refused = 0
            for url in urls {
                do { return try await once(url, headers: headers, range: range, limit: limit, counts: counts, sink: sink) }
                catch let error as TransferError {
                    failure = error
                    if case .expired = error { refused += 1; continue }
                    if !error.retriable { throw error }
                } catch let error as URLError where error.code == .cancelled {
                    throw CancellationError()
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as URLError where [.notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotConnectToHost,
                                                     .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed, .badServerResponse].contains(error.code) {
                    failure = error
                } catch { throw error }
            }
            if refused == urls.count { throw failure }
        }
        throw failure
    }

    private func once(_ url: URL, headers: [String: String], range: ClosedRange<Int64>?, limit: Int?, counts: Bool,
                      sink: (@Sendable (Data) throws -> Void)?) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: 30)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range") }
        let collector = Collector(limit: limit)
        let meter = counts ? meter : nil
        let receiver = Receiver(accept: { response in
            switch response.statusCode {
            case 206: nil
            // A probe accepts the whole file; a range request answered with it can't be resumed from there.
            case 200..<300: range == nil || limit != nil ? nil : TransferError.rangeLost
            case 401, 403, 404, 410: TransferError.expired(response.statusCode)
            default: TransferError.http(response.statusCode)
            }
        }, sink: { data in
            if let sink { try sink(data) } else { collector.append(data) }
            meter?.add(Int64(data.count)); collector.count(data.count)
            return !collector.full
        })
        do {
            let response = try await receiver.run(session.dataTask(with: request))
            return (collector.data, response)
        } catch {
            meter?.add(-collector.received)
            throw error
        }
    }

    // MARK: Finishing

    private func finish(_ plan: TransferPlan) async throws -> String {
        let parts = folder.appending(path: "parts")
        switch plan.kind {
        case .file:
            if let name = finishedFile(plan) {
                try? FileManager.default.removeItem(at: parts)
                return await DownloadLibrary.rewrap(name, in: folder)
            }
            let name = "media." + (plan.fileExtension ?? "mp4")
            try? FileManager.default.removeItem(at: folder.appending(path: name))
            try FileManager.default.moveItem(at: parts.appending(path: plan.files[0].name), to: folder.appending(path: name))
            try? FileManager.default.removeItem(at: parts)
            return await DownloadLibrary.rewrap(name, in: folder)
        case .hls:
            try Self.writing { try Data((plan.playlist ?? "").utf8).write(to: folder.appending(path: "index.m3u8"), options: .atomic) }
            return "index.m3u8"
        case .dash:
            // The halves stay as downloaded and play as HLS byte ranges, as they stream: re-muxing HEVC
            // into MP4 tags it `hev1`, which AVPlayer only plays inside HLS.
            var master = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS"]
            for (position, file) in plan.files.enumerated() {
                guard let initialization = file.initialization, let range = file.index else { throw TransferError.notMedia }
                let handle = try FileHandle(forReadingFrom: parts.appending(path: file.name))
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(range.lowerBound))
                let sidx = try handle.read(upToCount: range.count) ?? Data()
                let index = try SegmentIndex(sidx: sidx, at: range.lowerBound, initialization: initialization, url: URL(string: "parts/" + file.name)!)
                let name = position == 0 ? "video.m3u8" : "audio.m3u8"
                try Self.writing { try Data(BilibiliStreams.media(index).utf8).write(to: folder.appending(path: name), options: .atomic) }
                if position == 1 { master.append("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"Audio\",DEFAULT=YES,AUTOSELECT=YES,URI=\"audio.m3u8\"") }
            }
            master += ["#EXT-X-STREAM-INF:" + (plan.streamInfo ?? "BANDWIDTH=1"), "video.m3u8"]
            try Self.writing { try Data((master.joined(separator: "\n") + "\n").utf8).write(to: folder.appending(path: "index.m3u8"), options: .atomic) }
            return "index.m3u8"
        }
    }

    // MARK: Helpers

    static func isPlaylist(_ data: Data) -> Bool {
        String(decoding: data.prefix(64), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))).hasPrefix("#EXTM3U")
    }
    /// The full length from `Content-Range: bytes a-b/total`.
    static func total(_ response: HTTPURLResponse) -> Int64? {
        (response.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last).flatMap { Int64($0) }
    }
    static func fileExtension(_ url: URL, mime: String, head: Data = Data()) -> String {
        // The first bytes win over the name: cloud drives serve 4K MP4s named .mp3 from CDN addresses without one.
        let bytes = [UInt8](head.prefix(12))
        if bytes.count >= 12, bytes[4...7] == [0x66, 0x74, 0x79, 0x70] { return bytes[8...11] == [0x71, 0x74, 0x20, 0x20] ? "mov" : "mp4" }
        if bytes.count >= 4, bytes[0...3] == [0x1A, 0x45, 0xDF, 0xA3] { return "mkv" }
        // Songs: music hosts often serve FLAC and MP3 from addresses without an extension.
        if bytes.count >= 4, bytes[0...3] == [0x66, 0x4C, 0x61, 0x43] { return "flac" }
        if bytes.count >= 3, bytes[0...2] == [0x49, 0x44, 0x33] { return "mp3" }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] & 0xF6 == 0xF0 { return "aac" }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] & 0xE0 == 0xE0 { return "mp3" }
        let known = ["mp4", "m4v", "mov", "mkv", "webm", "flv", "avi", "ts", "mp3", "m4a", "aac", "flac"]
        let named = url.pathExtension.lowercased()
        if known.contains(named) { return named }
        switch mime {
        case "video/x-matroska": return "mkv"
        case "video/webm": return "webm"
        case "video/mp2t": return "ts"
        case "video/x-flv": return "flv"
        case "audio/mpeg": return "mp3"
        case "audio/flac", "audio/x-flac": return "flac"
        case "audio/mp4", "audio/x-m4a": return "m4a"
        default: return "mp4"
        }
    }
    /// Turns a full disk into a clear message.
    static func writing<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch {
            let error = error as NSError
            if (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError) || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOSPC)) {
                throw TransferError.noSpace(needed: 0, available: DownloadLibrary.availableCapacity(at: URL.temporaryDirectory) ?? 0)
            }
            throw error
        }
    }
}

/// HLS playlists: picking a variant, and rewriting a media playlist to local files.
enum HLS {
    struct Variant { let bandwidth: Int; let height: Int?; let url: URL }

    static func variants(_ text: String, base: URL) -> [Variant] {
        var result: [Variant] = []
        var pending: [String: String]?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF:") { pending = attributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count))) }
            else if let fields = pending, !line.isEmpty, !line.hasPrefix("#") {
                if let url = URL(string: line, relativeTo: base)?.absoluteURL {
                    let height = fields["RESOLUTION"]?.split(separator: "x").last.flatMap { Int($0) }
                    result.append(Variant(bandwidth: Int(fields["BANDWIDTH"] ?? "") ?? 0, height: height, url: url))
                }
                pending = nil
            }
        }
        return result
    }

    /// The playlist with every key, initialization section and segment pointed at a file under `parts/`,
    /// and those files' remote addresses. Byte ranges become whole files.
    static func localize(_ text: String, base: URL) throws -> (playlist: String, parts: [TransferPlan.Part]) {
        guard text.contains("#EXT-X-ENDLIST") else { throw TransferError.live }
        var lines: [String] = [], parts: [TransferPlan.Part] = []
        var named: [String: String] = [:]
        var pendingRange: (length: Int64, offset: Int64?)?
        var ends: [URL: Int64] = [:]
        var segments = 0
        func resolve(_ value: String) throws -> URL {
            guard let url = URL(string: value, relativeTo: base)?.absoluteURL, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw TransferError.protected }
            return url
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXT-X-KEY:") {
                let fields = attributes(String(line.dropFirst("#EXT-X-KEY:".count)))
                guard let method = fields["METHOD"], method != "NONE" else { lines.append(line); continue }
                // AES-128 keys are plain files; SAMPLE-AES and FairPlay need a key server at play time.
                guard method == "AES-128", let uri = fields["URI"] else { throw TransferError.protected }
                let url = try resolve(uri)
                let name = named[url.absoluteString] ?? {
                    let name = "parts/key-\(named.count).key"
                    parts.append(.init(url: url, range: nil, name: name, transportStream: false))
                    return name
                }()
                named[url.absoluteString] = name
                lines.append(line.replacingOccurrences(of: "URI=\"\(uri)\"", with: "URI=\"\(name)\""))
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let fields = attributes(String(line.dropFirst("#EXT-X-MAP:".count)))
                guard let uri = fields["URI"] else { continue }
                let url = try resolve(uri)
                let range = fields["BYTERANGE"].flatMap(byteRange).map { value -> ClosedRange<Int64> in
                    let start = value.offset ?? 0
                    return start...start + value.length - 1
                }
                let key = url.absoluteString + (range.map { "#\($0)" } ?? "")
                let name = named[key] ?? {
                    let name = "parts/init-\(named.count).\(segmentExtension(url, fallback: "mp4"))"
                    parts.append(.init(url: url, range: range, name: name, transportStream: false))
                    return name
                }()
                named[key] = name
                lines.append("#EXT-X-MAP:URI=\"\(name)\"")
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingRange = byteRange(String(line.dropFirst("#EXT-X-BYTERANGE:".count)))
            } else if line.hasPrefix("#") {
                lines.append(line)
            } else {
                let url = try resolve(line)
                var range: ClosedRange<Int64>?
                if let pending = pendingRange {
                    let start = pending.offset ?? ends[url] ?? 0
                    range = start...start + pending.length - 1
                    ends[url] = start + pending.length
                }
                pendingRange = nil
                let fileExtension = segmentExtension(url, fallback: "ts")
                let name = String(format: "parts/%05d.", segments) + fileExtension
                segments += 1
                parts.append(.init(url: url, range: range, name: name, transportStream: fileExtension == "ts"))
                lines.append(name)
            }
        }
        guard segments > 0 else { throw TransferError.notMedia }
        return (lines.joined(separator: "\n") + "\n", parts)
    }

    /// Segment files keep a real media extension; disguised ones (.png, .jpg, none) are MPEG-TS.
    private static func segmentExtension(_ url: URL, fallback: String) -> String {
        let value = url.pathExtension.lowercased()
        return ["ts", "m4s", "mp4", "m4a", "m4v", "aac", "mp3", "cmfv", "cmfa", "vtt", "webvtt"].contains(value) ? value : fallback
    }
    /// `length[@offset]`, from EXT-X-BYTERANGE or a BYTERANGE attribute.
    private static func byteRange(_ text: String) -> (length: Int64, offset: Int64?)? {
        let fields = text.split(separator: "@")
        guard let length = fields.first.flatMap({ Int64($0) }), length > 0 else { return nil }
        return (length, fields.count > 1 ? Int64(fields[1]) : nil)
    }
    /// An attribute list (`KEY=value,KEY="quoted, value"`).
    static func attributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for match in text.matches(of: /([A-Z0-9-]+)=("[^"]*"|[^,]*)/) {
            var value = String(match.2)
            if value.hasPrefix("\"") { value = String(value.dropFirst().dropLast()) }
            result[String(match.1)] = value
        }
        return result
    }
}

/// Byte and piece counts for one running download, read by the library once a second.
final class DownloadMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64 = 0, parts = 0, total = 0, expectedBytes: Int64?
    var received: Int64 { lock.withLock { bytes } }
    var snapshot: (received: Int64, parts: Int, total: Int, expected: Int64?) { lock.withLock { (bytes, parts, total, expectedBytes) } }
    func add(_ count: Int64) { lock.withLock { bytes += count } }
    func finishedPart() { lock.withLock { parts += 1 } }
    func reset(received: Int64, parts: Int, total: Int, expected: Int64?) {
        lock.withLock { bytes = received; self.parts = parts; self.total = total; expectedBytes = expected }
    }
}

/// The plan with finished ranges marked as they land, written to disk every few seconds.
final class PlanBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TransferPlan
    private let file: URL
    private var saved = Date()
    init(_ plan: TransferPlan, file: URL) { value = plan; self.file = file }
    var plan: TransferPlan { lock.withLock { value } }
    func mark(_ file: Int, chunk: Int) {
        let snapshot: TransferPlan? = lock.withLock {
            value.files[file].done.insert(chunk)
            guard Date().timeIntervalSince(saved) > 3 else { return nil }
            saved = Date()
            return value
        }
        if let snapshot { try? JSONEncoder().encode(snapshot).write(to: self.file, options: .atomic) }
    }
    func markWhole(_ file: Int) { lock.withLock { value.files[file].done = [0] } }
    func reset(_ file: Int) { lock.withLock { value.files[file].done = [] } }
}

final class WorkQueue<Item: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Item]
    private var position = 0
    init(_ items: [Item]) { self.items = items }
    func next() -> Item? {
        lock.withLock {
            guard position < items.count else { return nil }
            defer { position += 1 }
            return items[position]
        }
    }
}

/// Writes ranges into one file from several connections.
final class FileWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    init(_ url: URL) throws { handle = try FileHandle(forWritingTo: url) }
    func truncate(_ length: Int64) throws {
        try lock.withLock {
            if try handle.seekToEnd() != UInt64(length) { try handle.truncate(atOffset: UInt64(length)) }
        }
    }
    func write(_ data: Data, at offset: UInt64) throws {
        try Transfer.writing { try lock.withLock { try handle.seek(toOffset: offset); try handle.write(contentsOf: data) } }
    }
    func append(_ data: Data) throws {
        try Transfer.writing { try lock.withLock { try handle.seekToEnd(); try handle.write(contentsOf: data) } }
    }
    func close() throws { try lock.withLock { try handle.close() } }
}

/// A response body gathered in memory, up to an optional limit.
final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var counted: Int64 = 0
    private let limit: Int?
    init(limit: Int?) { self.limit = limit }
    var data: Data { lock.withLock { limit.map { Data(buffer.prefix($0)) } ?? buffer } }
    var received: Int64 { lock.withLock { counted } }
    var full: Bool { lock.withLock { limit.map { buffer.count >= $0 } ?? false } }
    func append(_ data: Data) { lock.withLock { buffer.append(data) } }
    func count(_ bytes: Int) { lock.withLock { counted += Int64(bytes) } }
}

/// Runs one data task, handing its body to `sink` as it arrives (progress counts every packet,
/// not whole responses). `sink` returns false to stop early with what it has.
final class Receiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let accept: @Sendable (HTTPURLResponse) -> Error?
    private let sink: @Sendable (Data) throws -> Bool
    private var continuation: CheckedContinuation<HTTPURLResponse, Error>?
    private var response: HTTPURLResponse?
    private var failure: Error?
    private var stoppedEarly = false
    init(accept: @escaping @Sendable (HTTPURLResponse) -> Error?, sink: @escaping @Sendable (Data) throws -> Bool) {
        self.accept = accept; self.sink = sink
    }

    func run(_ task: URLSessionDataTask) async throws -> HTTPURLResponse {
        task.delegate = self
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { self.continuation = continuation }
                task.resume()
            }
        } onCancel: { task.cancel() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            lock.withLock { failure = TransferError.http(0) }; completionHandler(.cancel); return
        }
        let refusal = accept(http)
        lock.withLock { self.response = http; failure = refusal }
        completionHandler(refusal == nil ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            if try !sink(data) { lock.withLock { stoppedEarly = true }; dataTask.cancel() }
        } catch {
            lock.withLock { failure = error }; dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, response, failure, early) = lock.withLock { () -> (CheckedContinuation<HTTPURLResponse, Error>?, HTTPURLResponse?, Error?, Bool) in
            defer { self.continuation = nil }
            return (self.continuation, self.response, self.failure, stoppedEarly)
        }
        if early, let response { continuation?.resume(returning: response) }
        else if let failure { continuation?.resume(throwing: failure) }
        else if let error { continuation?.resume(throwing: error) }
        else if let response {
            let expected = response.expectedContentLength
            // Compressed bodies arrive decoded, so only plain ones can be checked against their length.
            if response.value(forHTTPHeaderField: "Content-Encoding") == nil, expected > 0, task.countOfBytesReceived < expected { continuation?.resume(throwing: TransferError.incomplete) }
            else { continuation?.resume(returning: response) }
        } else { continuation?.resume(throwing: TransferError.http(0)) }
    }
}

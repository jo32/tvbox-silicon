import Foundation

/// Fragmented CENC MP4s (an ftyp, a moov without samples, a sidx, then moof/mdat pairs), as the
/// web player's episodes come. Each fragment is one entry of `samples`; it plays as one HLS segment
/// (`HongguoFragmentSession`), decrypted from its own moof's senc.
extension HongguoStreamIndex {
    struct Fragmented: Sendable {
        /// Per-sample IV size of each protected track, by track ID.
        let ivSizes: [Int: Int]
        /// trex default sample sizes, by track ID.
        let defaultSizes: [Int: Int]
    }

    init(fragmentedMovie original: Data, at offset: Int, length: Int, segmentIndex: Data, at indexOffset: Int) throws {
        var metadata = original
        let root = try MP4.require(MP4.boxes(metadata, 0..<metadata.count), "moov")
        guard root.start == 0, root.end == metadata.count, offset >= 0, offset <= length - metadata.count else { throw MP4.Failure.invalid }
        let entries = try MP4.children(metadata, root)
        var ivSizes: [Int: Int] = [:], defaultSizes: [Int: Int] = [:]
        for track in entries where track.type == "trak" {
            let parts = try MP4.children(metadata, track)
            let tkhd = try MP4.require(parts, "tkhd")
            guard tkhd.size >= tkhd.header + 24, metadata[tkhd.body] <= 1 else { throw MP4.Failure.invalid }
            let id = try MP4.integer(metadata, tkhd.body + (metadata[tkhd.body] == 1 ? 20 : 12))
            let mdia = try MP4.require(parts, "mdia")
            let minf = try MP4.require(MP4.children(metadata, mdia), "minf")
            let table = try MP4.require(MP4.children(metadata, minf), "stbl")
            let stsd = try MP4.require(MP4.children(metadata, table), "stsd")
            guard stsd.size >= stsd.header + 8 else { throw MP4.Failure.invalid }
            // Packagers with a clear lead list an encv and a plain avc1; both end up plain.
            for description in try MP4.boxes(metadata, stsd.body + 8..<stsd.end) where description.type == "encv" || description.type == "enca" {
                let extra = description.type == "encv" ? 78 : 28
                guard description.size >= description.header + extra else { throw MP4.Failure.invalid }
                if description.type == "enca", try MP4.integer(metadata, description.body + 8, 2) != 0 { throw MP4.Failure.invalid }
                let sinf = try MP4.require(MP4.boxes(metadata, description.body + extra..<description.end), "sinf")
                let protection = try MP4.children(metadata, sinf)
                let frma = try MP4.require(protection, "frma"), schm = try MP4.require(protection, "schm")
                guard frma.size >= frma.header + 4, schm.size >= schm.header + 12,
                      String(decoding: metadata[schm.body + 4..<schm.body + 8], as: UTF8.self) == "cenc" else { throw MP4.Failure.invalid }
                let schi = try MP4.require(protection, "schi"), tenc = try MP4.require(MP4.children(metadata, schi), "tenc")
                guard tenc.size >= tenc.header + 24, metadata[tenc.body] == 0, metadata[tenc.body + 6] == 1 else { throw MP4.Failure.invalid }
                let ivSize = Int(metadata[tenc.body + 7])
                guard ivSize == 8 || ivSize == 16, ivSizes[id] == nil || ivSizes[id] == ivSize else { throw MP4.Failure.invalid }
                ivSizes[id] = ivSize
                metadata.replaceSubrange(description.start + 4..<description.start + 8, with: metadata[frma.body..<frma.body + 4])
                metadata.replaceSubrange(sinf.start + 4..<sinf.start + 8, with: Data("free".utf8))
            }
        }
        if let mvex = entries.first(where: { $0.type == "mvex" }) {
            for trex in try MP4.children(metadata, mvex) where trex.type == "trex" {
                guard trex.size >= trex.header + 24 else { throw MP4.Failure.invalid }
                defaultSizes[try MP4.integer(metadata, trex.body + 4)] = try MP4.integer(metadata, trex.body + 16)
            }
        }
        guard !ivSizes.isEmpty else { throw MP4.Failure.invalid }

        // sidx: one level of references to moof/mdat pairs.
        let sidx = try MP4.require(MP4.boxes(segmentIndex, 0..<segmentIndex.count), "sidx")
        guard sidx.start == 0, sidx.end == segmentIndex.count, sidx.size >= sidx.header + 24 else { throw MP4.Failure.invalid }
        let version = segmentIndex[sidx.body]
        guard version <= 1 else { throw MP4.Failure.invalid }
        var p = sidx.body + 8
        let timescale = try MP4.integer(segmentIndex, p); p += 4
        let width = version == 0 ? 4 : 8
        let earliest = try MP4.integer(segmentIndex, p, width), first = try MP4.integer(segmentIndex, p + width, width); p += 2 * width
        let count = try MP4.integer(segmentIndex, p + 2, 2); p += 4
        guard timescale > 0, count > 0, p + count * 12 <= sidx.end else { throw MP4.Failure.invalid }
        var at = indexOffset + sidx.size + first, ticks = earliest
        var samples: [Sample] = []
        for i in 0..<count {
            let reference = try MP4.integer(segmentIndex, p + i * 12), duration = try MP4.integer(segmentIndex, p + i * 12 + 4)
            let size = reference & 0x7fff_ffff
            guard reference >> 31 == 0, size >= 16, size <= 64 << 20, at <= length - size else { throw MP4.Failure.invalid }
            samples.append(Sample(bytes: at..<at + size, time: Double(ticks) / Double(timescale),
                                  endTime: Double(ticks + duration) / Double(timescale), iv: nil, encrypted: []))
            at += size; ticks += duration
        }
        guard offset + metadata.count <= samples[0].bytes.lowerBound else { throw MP4.Failure.invalid }
        self.length = length; movieRange = offset..<offset + metadata.count
        movie = metadata; self.samples = samples
        duration = samples.last?.endTime ?? 0
        fragmented = Fragmented(ivSizes: ivSizes, defaultSizes: defaultSizes)
    }

    /// One fragment's moof, with its encryption boxes hidden, and the encrypted samples of its mdat.
    struct FragmentPart: Sendable {
        let range: Range<Int>
        let moof: Data
        let samples: [Sample]
    }

    /// Reads a fragment's moof (which starts at `fragment.lowerBound`): sample ranges, IVs and subsamples come
    /// from its trun and senc.
    static func parseFragment(_ original: Data, fragment: Range<Int>, tracks: Fragmented) throws -> FragmentPart {
        var data = original
        let moof = try MP4.require(MP4.boxes(data, 0..<data.count), "moof")
        guard moof.start == 0, moof.end == data.count else { throw MP4.Failure.invalid }
        let start = fragment.lowerBound
        var result: [Sample] = []
        for traf in try MP4.children(data, moof) where traf.type == "traf" {
            let entries = try MP4.children(data, traf)
            let tfhd = try MP4.require(entries, "tfhd")
            guard tfhd.size >= tfhd.header + 8 else { throw MP4.Failure.invalid }
            let flags = try MP4.integer(data, tfhd.body) & 0xff_ffff, track = try MP4.integer(data, tfhd.body + 4)
            // A clear-lead fragment, or a clear track, has no senc.
            guard let ivSize = tracks.ivSizes[track], let senc = entries.first(where: { $0.type == "senc" }) else { continue }
            var p = tfhd.body + 8
            var base = start
            if flags & 0x1 != 0 { base = try MP4.integer(data, p, 8); p += 8 }
            if flags & 0x2 != 0 { p += 4 }
            if flags & 0x8 != 0 { p += 4 }
            var defaultSize = tracks.defaultSizes[track] ?? 0
            if flags & 0x10 != 0 { defaultSize = try MP4.integer(data, p); p += 4 }
            guard p <= tfhd.end else { throw MP4.Failure.invalid }
            var samples: [Range<Int>] = []
            for trun in entries where trun.type == "trun" {
                guard trun.size >= trun.header + 8 else { throw MP4.Failure.invalid }
                let runFlags = try MP4.integer(data, trun.body) & 0xff_ffff, count = try MP4.integer(data, trun.body + 4)
                var q = trun.body + 8
                var at = samples.last?.upperBound ?? base
                if runFlags & 0x1 != 0 {
                    let raw = try MP4.integer(data, q); q += 4
                    at = base + (raw >= 1 << 31 ? raw - (1 << 32) : raw)
                }
                if runFlags & 0x4 != 0 { q += 4 }
                let fields = [0x100, 0x200, 0x400, 0x800].filter { runFlags & $0 != 0 }.count
                guard count <= 100_000, q + count * fields * 4 <= trun.end else { throw MP4.Failure.invalid }
                for _ in 0..<count {
                    if runFlags & 0x100 != 0 { q += 4 }
                    var size = defaultSize
                    if runFlags & 0x200 != 0 { size = try MP4.integer(data, q); q += 4 }
                    if runFlags & 0x400 != 0 { q += 4 }
                    if runFlags & 0x800 != 0 { q += 4 }
                    guard size > 0, size <= 8 << 20, at >= start + moof.end, at <= fragment.upperBound - size else { throw MP4.Failure.invalid }
                    samples.append(at..<at + size); at += size
                }
            }
            guard senc.size >= senc.header + 8 else { throw MP4.Failure.invalid }
            let sencFlags = try MP4.integer(data, senc.body) & 0xff_ffff
            guard sencFlags == 0 || sencFlags == 2, try MP4.integer(data, senc.body + 4) == samples.count else { throw MP4.Failure.invalid }
            var cursor = senc.body + 8
            for sample in samples {
                guard cursor <= senc.end - ivSize else { throw MP4.Failure.invalid }
                var iv = Data(data[cursor..<cursor + ivSize]); cursor += ivSize
                if ivSize == 8 { iv.append(Data(count: 8)) }
                var ranges = [0..<sample.count]
                if sencFlags == 2 {
                    guard cursor <= senc.end - 2 else { throw MP4.Failure.invalid }
                    let subsamples = try MP4.integer(data, cursor, 2); cursor += 2
                    guard cursor <= senc.end - subsamples * 6 else { throw MP4.Failure.invalid }
                    ranges = []
                    var used = 0
                    for _ in 0..<subsamples {
                        let clear = try MP4.integer(data, cursor, 2), encrypted = try MP4.integer(data, cursor + 2); cursor += 6
                        guard clear <= sample.count - used, encrypted <= sample.count - used - clear else { throw MP4.Failure.invalid }
                        used += clear
                        if encrypted > 0 { ranges.append(used..<used + encrypted) }
                        used += encrypted
                    }
                    guard used == sample.count else { throw MP4.Failure.invalid }
                }
                result.append(Sample(bytes: sample, time: 0, endTime: 0, iv: iv, encrypted: ranges))
            }
            guard cursor == senc.end else { throw MP4.Failure.invalid }
            for box in entries {
                var hide = ["senc", "saio", "saiz"].contains(box.type)
                if box.type == "sbgp" || box.type == "sgpd", box.size >= box.header + 8 {
                    hide = String(decoding: data[box.body + 4..<box.body + 8], as: UTF8.self) == "seig"
                }
                if hide { data.replaceSubrange(box.start + 4..<box.start + 8, with: Data("free".utf8)) }
            }
        }
        result.sort { $0.bytes.lowerBound < $1.bytes.lowerBound }
        for i in result.indices.dropFirst() where result[i - 1].bytes.upperBound > result[i].bytes.lowerBound { throw MP4.Failure.invalid }
        return FragmentPart(range: start..<start + data.count, moof: data, samples: result)
    }

    /// Decrypts the samples of `part` that lie wholly inside `data` (which starts at file offset `offset`).
    static func decrypt(_ data: inout Data, at offset: Int, part: FragmentPart, key: Data) throws {
        let range = offset..<offset + data.count
        for sample in part.samples where sample.bytes.overlaps(range) {
            guard let iv = sample.iv, range.lowerBound <= sample.bytes.lowerBound, range.upperBound >= sample.bytes.upperBound else { throw MP4.Failure.invalid }
            let local = sample.bytes.lowerBound - offset..<sample.bytes.upperBound - offset
            var bytes = Data(data[local])
            try MP4.crypt(&bytes, key: key, iv: iv, ranges: sample.encrypted)
            data.replaceSubrange(local, with: bytes)
        }
    }
}

/// A fragmented episode as VOD HLS: the initialization segment is the ftyp and the clear moov, each media
/// segment one decrypted fragment. The next fragment is fetched while one plays.
final class HongguoFragmentSession: SegmentedStream, @unchecked Sendable {
    let id = UUID().uuidString.lowercased()
    let copiesHDR = false
    let master: String
    private let media: String
    private let count: Int
    private let stream: HongguoByteStream
    private let lock = NSLock()
    private var fetches: [Int: Task<Data, Error>] = [:]
    private var closed = false

    init(stream: HongguoByteStream, index: HongguoStreamIndex) {
        self.stream = stream
        count = index.samples.count
        let spans = index.samples.map { max(0.001, $0.endTime - $0.time) }
        let rate = zip(index.samples, spans).map { Double($0.bytes.count) * 8 / $1 }.max() ?? 2_000_000
        master = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-STREAM-INF:BANDWIDTH=\(Int(rate))", "0.m3u8"].joined(separator: "\n") + "\n"
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(max(1, Int((spans.max() ?? 1).rounded(.up))))",
                     "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-MAP:URI=\"0-0.mp4\""]
        for (i, span) in spans.enumerated() {
            lines.append(String(format: "#EXTINF:%.3f,", span))
            lines.append("0-\(i).m4s")
        }
        lines.append("#EXT-X-ENDLIST")
        media = lines.joined(separator: "\n") + "\n"
    }

    func playlist(_ track: Int) async -> String? { track == 0 ? media : nil }

    func initialization(track: Int, index: Int) async throws -> Data {
        guard track == 0, index == 0 else { throw TVError.unsupported("no such initialization") }
        return try await stream.initialization()
    }

    func segment(track: Int, index: Int) async throws -> Data {
        guard track == 0, (0..<count).contains(index), let task = fetch(index) else { throw TVError.unsupported("no such segment") }
        _ = fetch(index + 1)
        // Finished segments stay while near the playhead (the player may ask again); a seek leaves the rest behind.
        let stale = lock.withLock { () -> [Task<Data, Error>] in
            let old = fetches.filter { $0.key < index - 2 || $0.key > index + 3 }
            old.keys.forEach { fetches[$0] = nil }
            return Array(old.values)
        }
        stale.forEach { $0.cancel() }
        let started = Date()
        let data = try await task.value
        Diagnostics.shared.record(.debug, "hongguo.stream", "segment \(index) bytes=\(data.count) waited=\(Int(Date().timeIntervalSince(started) * 1000))ms")
        return data
    }

    private func fetch(_ index: Int) -> Task<Data, Error>? {
        guard (0..<count).contains(index) else { return nil }
        return lock.withLock {
            if closed { return nil }
            if let task = fetches[index] { return task }
            let stream = stream
            let task = Task { try await stream.fragment(index) }
            fetches[index] = task
            return task
        }
    }

    func close() {
        let tasks = lock.withLock { () -> [Task<Data, Error>] in
            closed = true
            defer { fetches = [:] }
            return Array(fetches.values)
        }
        tasks.forEach { $0.cancel() }
        let stream = stream
        Task { await stream.clear() }
    }
}

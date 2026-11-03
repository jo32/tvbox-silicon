import Foundation
import CommonCrypto

/// Prepares the encrypted MP4s returned by Hongguo's app API on every Apple platform.
/// Only small metadata and one sample at a time are held in memory. Keeping box sizes unchanged
/// preserves chunk offsets, unlike removing protection boxes and rebuilding the whole movie.
enum HongguoMP4 {
    enum Failure: Error { case invalid }
    struct Box {
        let start: Int
        let size: Int
        let header: Int
        let type: String
        var body: Int { start + header }
        var end: Int { start + size }
    }
    static func integer(_ data: Data, _ at: Int, _ count: Int = 4) throws -> Int {
        guard at >= 0, (1...8).contains(count), at <= data.count - count else { throw Failure.invalid }
        var result: UInt64 = 0
        for byte in data[at..<at + count] { result = (result << 8) | UInt64(byte) }
        guard result <= Int.max else { throw Failure.invalid }
        return Int(result)
    }
    static func boxes(_ data: Data, _ range: Range<Int>) throws -> [Box] {
        guard range.lowerBound >= 0, range.upperBound <= data.count else { throw Failure.invalid }
        var at = range.lowerBound, result: [Box] = []
        while at < range.upperBound {
            guard at <= range.upperBound - 8 else { throw Failure.invalid }
            var size = try integer(data, at), header = 8
            if size == 1 { size = try integer(data, at + 8, 8); header = 16 }
            if size == 0 { size = range.upperBound - at }
            guard size >= header, size <= range.upperBound - at else { throw Failure.invalid }
            result.append(Box(start: at, size: size, header: header, type: String(decoding: data[at + 4..<at + 8], as: UTF8.self)))
            at += size
        }
        return result
    }
    static func children(_ data: Data, _ box: Box) throws -> [Box] { try boxes(data, box.body..<box.end) }
    static func require(_ boxes: [Box], _ type: String) throws -> Box {
        guard let box = boxes.first(where: { $0.type == type }) else { throw Failure.invalid }
        return box
    }
    static func read(_ handle: FileHandle, at: Int, count: Int) throws -> Data {
        try handle.seek(toOffset: UInt64(at))
        guard let data = try handle.read(upToCount: count), data.count == count else { throw Failure.invalid }
        return data
    }

    static func decrypt(file: URL, key: Data) throws {
        guard key.count == 16 else { throw Failure.invalid }
        let handle = try FileHandle(forUpdating: file)
        defer { try? handle.close() }
        let length = Int(try handle.seekToEnd())
        guard length > 16, length <= 512 * 1024 * 1024 else { throw Failure.invalid }
        var at = 0, movie: Box?, media: [Range<Int>] = []
        while at < length {
            let header = try read(handle, at: at, count: min(16, length - at))
            guard header.count >= 8 else { throw Failure.invalid }
            var size = try integer(header, 0), headSize = 8
            if size == 1 { size = try integer(header, 8, 8); headSize = 16 }
            if size == 0 { size = length - at }
            guard size >= headSize, size <= length - at else { throw Failure.invalid }
            let type = String(decoding: header[4..<8], as: UTF8.self)
            if type == "moof" { throw Failure.invalid } // This adapter handles the API's nonfragmented cenc MP4s.
            if type == "moov" { guard movie == nil else { throw Failure.invalid }; movie = Box(start: at, size: size, header: headSize, type: type) }
            if type == "mdat" { media.append(at + headSize..<at + size) }
            at += size
        }
        guard let movie, movie.size <= 16 * 1024 * 1024, !media.isEmpty else { throw Failure.invalid }
        var metadata = try read(handle, at: movie.start, count: movie.size)
        let root = Box(start: 0, size: metadata.count, header: movie.header, type: "moov")
        var protectedTracks = 0
        for track in try children(metadata, root) where track.type == "trak" {
            let mdia = try require(children(metadata, track), "mdia")
            let minf = try require(children(metadata, mdia), "minf")
            let table = try require(children(metadata, minf), "stbl")
            let entries = try children(metadata, table)
            let stsd = try require(entries, "stsd")
            guard stsd.size >= stsd.header + 8 else { throw Failure.invalid }
            let descriptions = try boxes(metadata, stsd.body + 8..<stsd.end)
            let encrypted = descriptions.filter { $0.type == "encv" || $0.type == "enca" }
            if encrypted.isEmpty { continue }
            guard descriptions.count == 1, encrypted.count == 1, let sample = encrypted.first else { throw Failure.invalid }
            let extra = sample.type == "encv" ? 78 : 28
            guard sample.size >= sample.header + extra else { throw Failure.invalid }
            if sample.type == "enca", try integer(metadata, sample.body + 8, 2) != 0 { throw Failure.invalid }
            let sinf = try require(boxes(metadata, sample.body + extra..<sample.end), "sinf")
            let protection = try children(metadata, sinf)
            let frma = try require(protection, "frma"), schm = try require(protection, "schm")
            guard frma.size >= frma.header + 4, schm.size >= schm.header + 12,
                  String(decoding: metadata[schm.body + 4..<schm.body + 8], as: UTF8.self) == "cenc" else { throw Failure.invalid }
            let schi = try require(protection, "schi"), tenc = try require(children(metadata, schi), "tenc")
            guard tenc.size >= tenc.header + 24, metadata[tenc.body] == 0, metadata[tenc.body + 6] == 1 else { throw Failure.invalid }
            let ivSize = Int(metadata[tenc.body + 7])
            guard ivSize == 8 || ivSize == 16 else { throw Failure.invalid }
            // Per-sample key overrides require a different key-selection protocol.
            for group in entries where group.type == "sgpd" {
                guard group.size >= group.header + 8,
                      String(decoding: metadata[group.body + 4..<group.body + 8], as: UTF8.self) != "seig" else { throw Failure.invalid }
            }
            try decryptSamples(handle, metadata: metadata, entries: entries, ivSize: ivSize, key: key, media: media)
            metadata.replaceSubrange(sample.start + 4..<sample.start + 8, with: metadata[frma.body..<frma.body + 4])
            for box in entries.filter({ ["senc", "saio", "saiz"].contains($0.type) }) + [sinf] {
                metadata.replaceSubrange(box.start + 4..<box.start + 8, with: Data("free".utf8))
            }
            protectedTracks += 1
        }
        guard protectedTracks > 0 else { throw Failure.invalid }
        try Task.checkCancellation()
        try handle.seek(toOffset: UInt64(movie.start)); try handle.write(contentsOf: metadata)
    }

    private static func decryptSamples(_ handle: FileHandle, metadata: Data, entries: [Box], ivSize: Int, key: Data, media: [Range<Int>]) throws {
        let sizeBox = try require(entries, "stsz"), chunkMap = try require(entries, "stsc"), encryption = try require(entries, "senc")
        let offsets = try entries.first(where: { $0.type == "co64" }) ?? require(entries, "stco")
        let sampleSize = try integer(metadata, sizeBox.body + 4), count = try integer(metadata, sizeBox.body + 8)
        let chunkCount = try integer(metadata, offsets.body + 4), rowCount = try integer(metadata, chunkMap.body + 4)
        let offsetWidth = offsets.type == "co64" ? 8 : 4
        guard (1...2_000_000).contains(count), (1...count).contains(chunkCount), (1...chunkCount).contains(rowCount),
              offsets.size >= offsets.header + 8 + chunkCount * offsetWidth,
              chunkMap.size >= chunkMap.header + 8 + rowCount * 12,
              sizeBox.size >= sizeBox.header + 12 + (sampleSize == 0 ? count * 4 : 0),
              try integer(metadata, encryption.body + 4) == count else { throw Failure.invalid }
        let flags = try integer(metadata, encryption.body)
        guard flags == 0 || flags == 2 else { throw Failure.invalid }
        var rows: [(first: Int, samples: Int)] = []
        for i in 0..<rowCount {
            let p = chunkMap.body + 8 + i * 12
            let first = try integer(metadata, p), samples = try integer(metadata, p + 4)
            guard first > (rows.last?.first ?? 0), first <= chunkCount, samples > 0, samples <= count,
                  try integer(metadata, p + 8) == 1 else { throw Failure.invalid }
            rows.append((first, samples))
        }
        guard rows[0].first == 1 else { throw Failure.invalid }
        var row = 0, index = 0, cursor = encryption.body + 8
        for chunk in 1...chunkCount {
            if row + 1 < rows.count, chunk == rows[row + 1].first { row += 1 }
            var offset = try integer(metadata, offsets.body + 8 + (chunk - 1) * offsetWidth, offsetWidth)
            for _ in 0..<rows[row].samples {
                try Task.checkCancellation()
                guard index < count, cursor <= encryption.end - ivSize else { throw Failure.invalid }
                let size = try sampleSize == 0 ? integer(metadata, sizeBox.body + 12 + index * 4) : sampleSize
                guard size > 0, size <= 8 * 1024 * 1024,
                      media.contains(where: { offset >= $0.lowerBound && offset <= $0.upperBound - size }) else { throw Failure.invalid }
                var iv = Data(metadata[cursor..<cursor + ivSize]); cursor += ivSize
                if ivSize == 8 { iv.append(Data(count: 8)) }
                var ranges: [Range<Int>] = []
                if flags == 2 {
                    guard cursor <= encryption.end - 2 else { throw Failure.invalid }
                    let subsamples = try integer(metadata, cursor, 2); cursor += 2
                    guard cursor <= encryption.end - subsamples * 6 else { throw Failure.invalid }
                    var used = 0
                    for _ in 0..<subsamples {
                        let clear = try integer(metadata, cursor, 2), encrypted = try integer(metadata, cursor + 2); cursor += 6
                        guard clear <= size - used, encrypted <= size - used - clear else { throw Failure.invalid }
                        used += clear
                        if encrypted > 0 { ranges.append(used..<used + encrypted) }
                        used += encrypted
                    }
                    guard used == size else { throw Failure.invalid }
                } else { ranges = [0..<size] }
                var bytes = try read(handle, at: offset, count: size)
                try crypt(&bytes, key: key, iv: iv, ranges: ranges)
                try handle.seek(toOffset: UInt64(offset)); try handle.write(contentsOf: bytes)
                offset += size; index += 1
            }
        }
        guard index == count, cursor == encryption.end else { throw Failure.invalid }
    }

    static func crypt(_ data: inout Data, key: Data, iv: Data, ranges: [Range<Int>]) throws {
        var cryptor: CCCryptorRef?
        let status = key.withUnsafeBytes { k in iv.withUnsafeBytes { v in
            CCCryptorCreateWithMode(CCOperation(kCCDecrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                                   v.baseAddress, k.baseAddress, key.count, nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
        } }
        guard status == kCCSuccess, let cryptor else { throw Failure.invalid }
        defer { CCCryptorRelease(cryptor) }
        for range in ranges {
            var output = Data(count: range.count), moved = 0
            let status = output.withUnsafeMutableBytes { out in data.withUnsafeBytes { input in
                CCCryptorUpdate(cryptor, input.baseAddress!.advanced(by: range.lowerBound), range.count, out.baseAddress, range.count, &moved)
            } }
            guard status == kCCSuccess, moved == range.count else { throw Failure.invalid }
            data.replaceSubrange(range, with: output)
        }
    }
}

actor HongguoMedia {
    // Complete-file preparation is only for explicit offline downloads. Playback uses HongguoStreams.
    static let shared = HongguoMedia()
    private let server = LocalMediaServer()
    private let root = URL.cachesDirectory.appending(path: "com.tvbox.yingxia/HongguoMedia")

    func prepare(url: URL, backups: [URL] = [], key: String, headers: [String: String], http: HTTPClient) async throws -> URL {
        guard key.count == 32, key.allSatisfy(\.isHexDigit) else { throw HongguoMP4.Failure.invalid }
        let bytes = stride(from: 0, to: 32, by: 2).compactMap { offset -> UInt8? in
            let start = key.index(key.startIndex, offsetBy: offset)
            return UInt8(key[start..<key.index(start, offsetBy: 2)], radix: 16)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        prune()
        let target = root.appending(path: UUID().uuidString + ".mp4")
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: target) } }
        // The backups are the same file on other CDN nodes; try them in turn.
        let candidates = [url] + backups
        for (index, candidate) in candidates.enumerated() {
            do {
                try await download(candidate, headers: headers, http: http, to: target)
                break
            } catch {
                if error is CancellationError || Task.isCancelled || index + 1 == candidates.count { throw error }
                Diagnostics.shared.record(.info, "hongguo.media", "node \(index) failed (\(error.localizedDescription)); trying backup \(index + 1) of \(backups.count)")
            }
        }
        try HongguoMP4.decrypt(file: target, key: Data(bytes))
        let address = try await server.address(of: target, root: root)
        complete = true
        return address
    }

    private func download(_ url: URL, headers: [String: String], http: HTTPClient, to target: URL) async throws {
        var request = URLRequest(url: url, timeoutInterval: 90)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        var (temporary, response) = try await http.session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        if (response as? HTTPURLResponse)?.statusCode == 403 {
            try? FileManager.default.removeItem(at: temporary)
            try Task.checkCancellation()
            request.setValue(HongguoStreams.mediaReferer, forHTTPHeaderField: "Referer")
            (temporary, response) = try await http.session.download(for: request)
        }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw HongguoMP4.Failure.invalid }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: target)
    }

    private func prune() {
        // Recent files may still be playing or being copied into the download library.
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        let files = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys))) ?? [])
            .compactMap { url -> (URL, Date, Int)? in
                guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
                return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
            }.sorted { $0.1 < $1.1 }
        var total = files.reduce(0) { $0 + $1.2 }
        for (file, date, size) in files where Date().timeIntervalSince(date) > 3600 {
            if total > 512 * 1024 * 1024 || Date().timeIntervalSince(date) > 24 * 3600 {
                try? FileManager.default.removeItem(at: file); total -= size
            }
        }
    }
}

import Foundation

/// The sample tables are small even when the media is large. They let a range reader decrypt
/// just the samples intersecting a player's request, including a seek into the middle of a GOP.
struct CENCIndex: Sendable {
    struct Sample: Sendable {
        let bytes: Range<Int>
        let time: Double
        let endTime: Double
        let iv: Data?
        let encrypted: [Range<Int>]
    }
    let length: Int
    let movieRange: Range<Int>
    let movie: Data
    let samples: [Sample]
    let duration: Double
    /// Set for fragmented files, where each entry of `samples` is a whole moof/mdat fragment.
    let fragmented: Fragmented?
    typealias MP4 = CENCBoxes

    init(movie original: Data, at offset: Int, length: Int, media: [Range<Int>]) throws {
        var metadata = original
        let root = try MP4.require(MP4.boxes(metadata, 0..<metadata.count), "moov")
        guard root.start == 0, root.end == metadata.count, offset >= 0,
              offset <= length - metadata.count else { throw MP4.Failure.invalid }
        var samples: [Sample] = []
        var protectedTracks = 0
        for track in try MP4.children(metadata, root) where track.type == "trak" {
            let mdia = try MP4.require(MP4.children(metadata, track), "mdia")
            let mdhd = try MP4.require(MP4.children(metadata, mdia), "mdhd")
            guard mdhd.size >= mdhd.header + 20, metadata[mdhd.body] <= 1 else { throw MP4.Failure.invalid }
            let timescale = try MP4.integer(metadata, mdhd.body + (metadata[mdhd.body] == 1 ? 20 : 12))
            guard timescale > 0 else { throw MP4.Failure.invalid }
            let minf = try MP4.require(MP4.children(metadata, mdia), "minf")
            let table = try MP4.require(MP4.children(metadata, minf), "stbl")
            let entries = try MP4.children(metadata, table)
            let stsd = try MP4.require(entries, "stsd")
            guard stsd.size >= stsd.header + 8 else { throw MP4.Failure.invalid }
            let descriptions = try MP4.boxes(metadata, stsd.body + 8..<stsd.end)
            guard descriptions.count == 1, let description = descriptions.first else { throw MP4.Failure.invalid }
            var ivSize: Int?
            let protected = description.type == "encv" || description.type == "enca"
            if protected {
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
                ivSize = Int(metadata[tenc.body + 7])
                guard ivSize == 8 || ivSize == 16 else { throw MP4.Failure.invalid }
                for group in entries where group.type == "sgpd" {
                    guard group.size >= group.header + 8,
                          String(decoding: metadata[group.body + 4..<group.body + 8], as: UTF8.self) != "seig" else { throw MP4.Failure.invalid }
                }
                metadata.replaceSubrange(description.start + 4..<description.start + 8, with: metadata[frma.body..<frma.body + 4])
                metadata.replaceSubrange(sinf.start + 4..<sinf.start + 8, with: Data("free".utf8))
                protectedTracks += 1
            }
            samples += try Self.trackSamples(metadata, entries: entries, timescale: timescale, ivSize: ivSize, media: media)
            if protected {
                for box in entries where ["senc", "saio", "saiz"].contains(box.type) {
                    metadata.replaceSubrange(box.start + 4..<box.start + 8, with: Data("free".utf8))
                }
            }
        }
        guard protectedTracks > 0, !samples.isEmpty else { throw MP4.Failure.invalid }
        samples.sort { $0.bytes.lowerBound < $1.bytes.lowerBound }
        for i in 1..<samples.count where samples[i - 1].bytes.upperBound > samples[i].bytes.lowerBound { throw MP4.Failure.invalid }
        self.length = length; movieRange = offset..<offset + metadata.count
        movie = metadata; self.samples = samples
        duration = samples.map(\.endTime).max() ?? 0
        fragmented = nil
    }

    private static func trackSamples(_ data: Data, entries: [MP4.Box], timescale: Int, ivSize: Int?, media: [Range<Int>]) throws -> [Sample] {
        let sizes = try MP4.require(entries, "stsz"), map = try MP4.require(entries, "stsc"), timing = try MP4.require(entries, "stts")
        let offsets = try entries.first { $0.type == "co64" } ?? MP4.require(entries, "stco")
        let encryption = ivSize == nil ? nil : try MP4.require(entries, "senc")
        let fixedSize = try MP4.integer(data, sizes.body + 4), count = try MP4.integer(data, sizes.body + 8)
        let chunks = try MP4.integer(data, offsets.body + 4), rowCount = try MP4.integer(data, map.body + 4)
        let width = offsets.type == "co64" ? 8 : 4
        let timeRows = try MP4.integer(data, timing.body + 4)
        guard (1...1_000_000).contains(count), (1...count).contains(chunks), (1...chunks).contains(rowCount),
              offsets.size >= offsets.header + 8 + chunks * width,
              map.size >= map.header + 8 + rowCount * 12,
              sizes.size >= sizes.header + 12 + (fixedSize == 0 ? count * 4 : 0),
              (1...count).contains(timeRows), timing.size >= timing.header + 8 + timeRows * 8 else { throw MP4.Failure.invalid }
        var durations: [Int] = []
        durations.reserveCapacity(count)
        for i in 0..<timeRows {
            let p = timing.body + 8 + i * 8
            let run = try MP4.integer(data, p), duration = try MP4.integer(data, p + 4)
            guard run > 0, run <= count - durations.count, duration > 0 else { throw MP4.Failure.invalid }
            durations.append(contentsOf: repeatElement(duration, count: run))
        }
        guard durations.count == count else { throw MP4.Failure.invalid }
        var rows: [(first: Int, samples: Int)] = []
        for i in 0..<rowCount {
            let p = map.body + 8 + i * 12
            let first = try MP4.integer(data, p), samples = try MP4.integer(data, p + 4)
            guard first > (rows.last?.first ?? 0), first <= chunks, samples > 0, samples <= count,
                  try MP4.integer(data, p + 8) == 1 else { throw MP4.Failure.invalid }
            rows.append((first, samples))
        }
        guard rows[0].first == 1 else { throw MP4.Failure.invalid }
        let flags = try encryption.map { try MP4.integer(data, $0.body) } ?? 0
        if let encryption {
            guard flags == 0 || flags == 2, try MP4.integer(data, encryption.body + 4) == count else { throw MP4.Failure.invalid }
        }
        var row = 0, index = 0, cursor = (encryption?.body ?? 0) + 8
        var ticks: Int64 = 0
        var result: [Sample] = []
        result.reserveCapacity(count)
        for chunk in 1...chunks {
            if row + 1 < rows.count, chunk == rows[row + 1].first { row += 1 }
            var offset = try MP4.integer(data, offsets.body + 8 + (chunk - 1) * width, width)
            for _ in 0..<rows[row].samples {
                guard index < count else { throw MP4.Failure.invalid }
                let size = try fixedSize == 0 ? MP4.integer(data, sizes.body + 12 + index * 4) : fixedSize
                guard size > 0, size <= 8 << 20,
                      media.contains(where: { offset >= $0.lowerBound && offset <= $0.upperBound - size }) else { throw MP4.Failure.invalid }
                var iv: Data?, ranges: [Range<Int>] = []
                if let ivSize, let encryption {
                    guard cursor <= encryption.end - ivSize else { throw MP4.Failure.invalid }
                    iv = Data(data[cursor..<cursor + ivSize]); cursor += ivSize
                    if ivSize == 8 { iv!.append(Data(count: 8)) }
                    if flags == 2 {
                        guard cursor <= encryption.end - 2 else { throw MP4.Failure.invalid }
                        let subsamples = try MP4.integer(data, cursor, 2); cursor += 2
                        guard cursor <= encryption.end - subsamples * 6 else { throw MP4.Failure.invalid }
                        var used = 0
                        for _ in 0..<subsamples {
                            let clear = try MP4.integer(data, cursor, 2), encrypted = try MP4.integer(data, cursor + 2); cursor += 6
                            guard clear <= size - used, encrypted <= size - used - clear else { throw MP4.Failure.invalid }
                            used += clear
                            if encrypted > 0 { ranges.append(used..<used + encrypted) }
                            used += encrypted
                        }
                        guard used == size else { throw MP4.Failure.invalid }
                    } else { ranges = [0..<size] }
                }
                let time = Double(ticks) / Double(timescale)
                ticks += Int64(durations[index])
                result.append(Sample(bytes: offset..<offset + size, time: time, endTime: Double(ticks) / Double(timescale), iv: iv, encrypted: ranges))
                offset += size; index += 1
            }
        }
        guard index == count, encryption == nil || cursor == encryption!.end else { throw MP4.Failure.invalid }
        return result
    }

    /// Binary search keeps each small range read independent of the episode's total sample count.
    func samples(in range: Range<Int>) -> ArraySlice<Sample> {
        var low = 0, high = samples.count
        while low < high {
            let middle = (low + high) / 2
            if samples[middle].bytes.upperBound <= range.lowerBound { low = middle + 1 } else { high = middle }
        }
        let start = low
        while low < samples.count, samples[low].bytes.lowerBound < range.upperBound { low += 1 }
        return samples[start..<low]
    }

    func expanded(_ range: Range<Int>) -> Range<Int> {
        let covered = samples(in: range)
        return min(range.lowerBound, covered.first?.bytes.lowerBound ?? range.lowerBound)..<max(range.upperBound, covered.last?.bytes.upperBound ?? range.upperBound)
    }

    func decrypt(_ original: Data, at offset: Int, key: Data) throws -> Data {
        var output = original
        let range = offset..<offset + original.count
        for sample in samples(in: range) {
            guard let iv = sample.iv else { continue }
            guard range.lowerBound <= sample.bytes.lowerBound, range.upperBound >= sample.bytes.upperBound else { throw MP4.Failure.invalid }
            let local = sample.bytes.lowerBound - offset..<sample.bytes.upperBound - offset
            var bytes = Data(output[local])
            try MP4.crypt(&bytes, key: key, iv: iv, ranges: sample.encrypted)
            output.replaceSubrange(local, with: bytes)
        }
        let lower = max(range.lowerBound, movieRange.lowerBound), upper = min(range.upperBound, movieRange.upperBound)
        if lower < upper {
            output.replaceSubrange(lower - offset..<upper - offset, with: movie[lower - movieRange.lowerBound..<upper - movieRange.lowerBound])
        }
        return output
    }
}

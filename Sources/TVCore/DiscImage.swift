import Foundation

/// Blu-ray and DVD disc images (.iso) played through the repackager (issue #538). The image's UDF file system is
/// read where the image lies (a drive's file, a link, a saved file), the disc's main title is picked, and its clips
/// reach FFmpeg as one stream: MPEG transport (Blu-ray .m2ts) or program stream (DVD .VOB). There are no menus:
/// a Blu-ray plays its longest playlist and a DVD its largest title set, as Infuse does. The clips of a Blu-ray
/// playlist each keep their own clock; their timestamps are moved on as they are read, so the title plays as one
/// clock from start to end, as the disc's player plays it.
public enum DiscImage {
    /// Bytes from a file's start that `handles` looks at: the system area and the first volume descriptor.
    public static let headLength = 32_768 + 2_048

    /// Whether a file starting with these bytes is a disc image: ISO 9660 ("CD001") or UDF ("BEA01") volume
    /// recognition after the 32 KB system area.
    public static func handles(_ head: Data) -> Bool {
        guard head.count >= 32_774 else { return false }
        let start = head.startIndex + 32_769
        return ["CD001", "BEA01"].contains(String(decoding: head[start..<start + 5], as: UTF8.self))
    }

    public static func handles(name: String) -> Bool { (name as NSString).pathExtension.lowercased() == "iso" }

    /// Why a disc image doesn't play.
    public enum Failure: LocalizedError, Equatable, Sendable {
        case noVideo, encrypted, unreadable
        public var errorDescription: String? {
            switch self {
            case .noVideo: L10n.text("This disc image holds no Blu-ray or DVD video.")
            case .encrypted: L10n.text("This Blu-ray disc image is still encrypted (AACS). Only decrypted disc images play.")
            case .unreadable: L10n.text("This disc image's file system can't be read.")
            }
        }
    }

    /// The disc's main title as one stream for the repackager, or nil when `source` isn't a disc image.
    static func title(_ source: RemuxSource) async throws -> RemuxSource? {
        guard source.length > Int64(headLength) else { return nil }
        let head = [UInt8](try await DiscRead.fully(source, at: 32_768, count: 8))
        guard head.count == 8, ["CD001", "BEA01"].contains(String(decoding: head[1..<6], as: UTF8.self)) else { return nil }
        let began = Date()
        let volume: UDFVolume
        do { volume = try await UDFVolume(source) }
        catch let error as Failure { throw error }
        catch is CancellationError { throw CancellationError() }
        catch {
            Diagnostics.shared.record(.warning, "remux", "disc image unreadable \(error)")
            throw Failure.unreadable
        }
        var found = try await bluray(volume)
        if found == nil { found = try await dvd(volume) }
        guard let title = found else { throw Failure.noVideo }
        Diagnostics.shared.record(.info, "remux", "disc image \(title.summary) parts=\(title.parts.count) size=\(title.length) ms=\(Int(Date().timeIntervalSince(began) * 1000))")
        return title
    }

    // MARK: - Blu-ray

    /// A clip of a Blu-ray playlist: the clip's name and where it plays, in 45 kHz ticks of the clip's own clock.
    struct PlayItem: Equatable {
        var clip: String
        var start: Int64, end: Int64
    }

    /// The play items of a Blu-ray playlist (`BDMV/PLAYLIST/*.mpls`); nil when it isn't one.
    static func playItems(_ data: Data) -> [PlayItem]? {
        let bytes = [UInt8](data)
        guard bytes.count >= 20, String(decoding: bytes[0..<4], as: UTF8.self) == "MPLS" else { return nil }
        func u16(_ at: Int) -> Int { Int(bytes[at]) << 8 | Int(bytes[at + 1]) }
        func u32(_ at: Int) -> Int64 { Int64(bytes[at]) << 24 | Int64(bytes[at + 1]) << 16 | Int64(bytes[at + 2]) << 8 | Int64(bytes[at + 3]) }
        let list = Int(u32(8))
        guard list + 10 <= bytes.count else { return nil }
        let count = u16(list + 6)
        var items: [PlayItem] = [], at = list + 10
        for _ in 0..<count {
            guard at + 22 <= bytes.count else { return nil }
            let length = u16(at)
            let clip = String(decoding: bytes[at + 2..<at + 7], as: UTF8.self)
            items.append(PlayItem(clip: clip, start: u32(at + 14), end: u32(at + 18)))
            at += 2 + length
        }
        return items
    }

    /// The disc's longest playlist, its clips one after the other. Among playlists as long, the one with fewer
    /// clips: a disc that hides its title among decoys repeats clips in them.
    static func bluray(_ volume: UDFVolume) async throws -> DiscTitle? {
        guard let bdmv = try await volume.child(of: volume.root, named: "BDMV", directory: true),
              let playlists = try await volume.child(of: bdmv.icb, named: "PLAYLIST", directory: true),
              let streams = try await volume.child(of: bdmv.icb, named: "STREAM", directory: true) else { return nil }
        var clips: [String: UDFVolume.Entry] = [:]
        for entry in try await volume.list(streams.icb) where !entry.directory { clips[entry.name.uppercased()] = entry }
        var best: (name: String, items: [PlayItem], duration: Int64)?
        for entry in try await volume.list(playlists.icb).sorted(by: { $0.name < $1.name })
        where !entry.directory && entry.name.uppercased().hasSuffix(".MPLS") {
            try Task.checkCancellation()
            guard let node = try? await volume.node(entry.icb), node.length < 1 << 20,
                  let items = playItems(try await volume.contents(node)), !items.isEmpty,
                  items.allSatisfy({ clips["\($0.clip).M2TS"] != nil && $0.end > $0.start }) else { continue }
            let duration = items.reduce(0) { $0 + $1.end - $1.start }
            if let best, duration < best.duration || (duration == best.duration && items.count >= best.items.count) { continue }
            best = (entry.name, items, duration)
        }
        guard let best else { return nil }
        var parts: [DiscTitle.Part] = []
        var position: Int64 = 0, clock = best.items[0].start
        for item in best.items {
            guard let entry = clips["\(item.clip).M2TS"] else { return nil }
            let node = try await volume.node(entry.icb)
            // 90 kHz, as in the stream: what moves this clip's clock to where the previous clip ended.
            parts.append(DiscTitle.Part(start: position, length: node.length, extents: node.extents, shift: 2 * (clock - item.start)))
            position += node.length
            clock += item.end - item.start
        }
        let title = DiscTitle(base: volume.source, parts: parts, packets: true,
                              summary: "blu-ray playlist=\(best.name) clips=\(best.items.count) s=\(best.duration / 45_000)")
        // AACS marks every protected packet in its arrival header; a decrypted image clears the marks.
        let first = try await title.read(at: 0, count: 192)
        if first.count == 192, first[first.startIndex] & 0xC0 != 0 { throw Failure.encrypted }
        return title
    }

    // MARK: - DVD

    /// The largest title set of `VIDEO_TS`, its VOB files (`VTS_nn_1.VOB` on; `_0` is the menu) one after the other.
    static func dvd(_ volume: UDFVolume) async throws -> DiscTitle? {
        guard let folder = try await volume.child(of: volume.root, named: "VIDEO_TS", directory: true) else { return nil }
        var sets: [Int: [(part: Int, node: UDFVolume.Node)]] = [:]
        for entry in try await volume.list(folder.icb) where !entry.directory {
            let name = entry.name.uppercased()
            guard name.count == 12, name.hasPrefix("VTS_"), name.hasSuffix(".VOB"),
                  let set = Int(name.dropFirst(4).prefix(2)), let part = Int(name.dropFirst(7).prefix(1)), part > 0 else { continue }
            sets[set, default: []].append((part, try await volume.node(entry.icb)))
        }
        guard let (set, files) = sets.max(by: { $0.value.reduce(0) { $0 + $1.node.length } < $1.value.reduce(0) { $0 + $1.node.length } }) else { return nil }
        var parts: [DiscTitle.Part] = [], position: Int64 = 0
        for file in files.sorted(by: { $0.part < $1.part }) {
            parts.append(DiscTitle.Part(start: position, length: file.node.length, extents: file.node.extents, shift: 0))
            position += file.node.length
        }
        return DiscTitle(base: volume.source, parts: parts, packets: false, summary: "dvd title-set=\(set)")
    }
}

enum DiscRead {
    /// `count` bytes at `offset`, fewer only at the end of the source.
    static func fully(_ source: RemuxSource, at offset: Int64, count: Int) async throws -> Data {
        var data = Data()
        while data.count < count {
            let chunk = try await source.read(at: offset + Int64(data.count), count: count - data.count)
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        return data
    }
}

/// A disc's title: pieces of the image read as one file. A Blu-ray's clips are MPEG transport streams of 192-byte
/// packets; each clip's timestamps (PES PTS and DTS, PCR) are moved by its `shift` as they are read.
struct DiscTitle: RemuxSource {
    struct Part: Sendable {
        /// Where the part starts in the title, and its length.
        var start: Int64, length: Int64
        var extents: [UDFVolume.Extent]
        /// 90 kHz ticks added to the part's timestamps.
        var shift: Int64
    }
    let base: RemuxSource
    let parts: [Part]
    /// Whether the parts are 192-byte transport packets whose timestamps may move.
    let packets: Bool
    let summary: String
    var length: Int64 { parts.last.map { $0.start + $0.length } ?? 0 }
    var transfer: (received: Int64, host: String?)? { base.transfer }
    func close() async { await base.close() }

    static let packet: Int64 = 192

    func read(at offset: Int64, count: Int) async throws -> Data {
        guard offset >= 0, offset < length, count > 0 else { return Data() }
        var low = 0, high = parts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if parts[middle].start <= offset { low = middle } else { high = middle - 1 }
        }
        let part = parts[low]
        let local = offset - part.start
        guard packets, part.shift != 0 else { return try await piece(part, at: local, count: min(Int64(count), part.length - local)) }
        // Whole packets around the bytes asked for, so each timestamp is moved whole.
        let first = local - local % Self.packet
        let wanted = min(Int64(count), 1 << 20)
        let end = min(part.length, (local + wanted + Self.packet - 1) / Self.packet * Self.packet)
        var data = Data()
        while first + Int64(data.count) < end {
            let chunk = try await piece(part, at: first + Int64(data.count), count: end - first - Int64(data.count))
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        var bytes = [UInt8](data)
        Self.shift(&bytes, by: part.shift)
        let skip = Int(local - first)
        guard skip < bytes.count else { return Data() }
        return Data(bytes[skip..<min(bytes.count, skip + Int(wanted))])
    }

    /// Bytes of one part at `local`, from one extent of the image (fewer than `count` at its end).
    private func piece(_ part: Part, at local: Int64, count: Int64) async throws -> Data {
        var start: Int64 = 0
        for extent in part.extents {
            if local < start + extent.length {
                let within = local - start
                let size = Int(min(count, extent.length - within))
                guard let offset = extent.offset else { return Data(count: size) }
                return try await base.read(at: offset + within, count: size)
            }
            start += extent.length
        }
        return Data()
    }

    /// Adds `shift` (90 kHz, modulo 2^33) to the PCR, OPCR, PTS and DTS of each whole 192-byte packet in `bytes`.
    static func shift(_ bytes: inout [UInt8], by shift: Int64) {
        let wrap: Int64 = 1 << 33
        func moved(_ value: Int64) -> Int64 { ((value + shift) % wrap + wrap) % wrap }
        func clockReference(_ at: Int) {
            let base = Int64(bytes[at]) << 25 | Int64(bytes[at + 1]) << 17 | Int64(bytes[at + 2]) << 9 | Int64(bytes[at + 3]) << 1 | Int64(bytes[at + 4]) >> 7
            let value = moved(base)
            bytes[at] = UInt8(value >> 25 & 0xFF); bytes[at + 1] = UInt8(value >> 17 & 0xFF)
            bytes[at + 2] = UInt8(value >> 9 & 0xFF); bytes[at + 3] = UInt8(value >> 1 & 0xFF)
            bytes[at + 4] = UInt8(value << 7 & 0x80) | bytes[at + 4] & 0x7F
        }
        func timestamp(_ at: Int) {
            let value = moved(Int64(bytes[at] >> 1 & 0x07) << 30 | Int64(bytes[at + 1]) << 22 | Int64(bytes[at + 2] >> 1) << 15
                              | Int64(bytes[at + 3]) << 7 | Int64(bytes[at + 4] >> 1))
            bytes[at] = bytes[at] & 0xF0 | UInt8(value >> 29 & 0x0E) | 1
            bytes[at + 1] = UInt8(value >> 22 & 0xFF)
            bytes[at + 2] = UInt8(value >> 14 & 0xFE) | 1
            bytes[at + 3] = UInt8(value >> 7 & 0xFF)
            bytes[at + 4] = UInt8(value << 1 & 0xFE) | 1
        }
        var packet = 0
        while packet + 192 <= bytes.count {
            defer { packet += 192 }
            let ts = packet + 4
            guard bytes[ts] == 0x47 else { continue }
            let control = bytes[ts + 3] >> 4 & 0x03
            var payload = ts + 4
            if control & 0x02 != 0 {
                let field = Int(bytes[ts + 4])
                payload = ts + 5 + field
                if field >= 7 {
                    let flags = bytes[ts + 5]
                    if flags & 0x10 != 0 { clockReference(ts + 6) }
                    if flags & 0x08 != 0, field >= (flags & 0x10 != 0 ? 13 : 7) { clockReference(ts + (flags & 0x10 != 0 ? 12 : 6)) }
                }
            }
            // The start of a PES packet, with its header in this packet.
            guard control & 0x01 != 0, bytes[ts + 1] & 0x40 != 0, payload + 14 <= ts + 188,
                  bytes[payload] == 0, bytes[payload + 1] == 0, bytes[payload + 2] == 1 else { continue }
            // Streams whose PES header has no timestamps: program stream map, padding, private 2, ECM, EMM, DSM-CC, H.222.1 E, directory.
            guard ![0xBC, 0xBE, 0xBF, 0xF0, 0xF1, 0xF2, 0xF8, 0xFF].contains(bytes[payload + 3]), bytes[payload + 6] & 0xC0 == 0x80 else { continue }
            let flags = bytes[payload + 7] >> 6
            if flags & 0x02 != 0 { timestamp(payload + 9) }
            if flags == 0x03, payload + 19 <= ts + 188 { timestamp(payload + 14) }
        }
    }
}

/// A UDF file system (ECMA-167; UDF 1.02 on DVDs, 2.50 with a metadata partition on Blu-ray discs), read through
/// `source` a block at a time.
struct UDFVolume: Sendable {
    /// Bytes of a file in the image; no `offset` for bytes allocated but not recorded (zeros).
    struct Extent: Equatable, Sendable { var offset: Int64?; var length: Int64 }
    struct Address: Hashable, Sendable { var block: UInt32; var partition: UInt16 }
    struct Entry: Sendable { var name: String; var directory: Bool; var icb: Address }
    struct Node: Sendable {
        var directory: Bool
        var length: Int64
        var extents: [Extent]
        /// Contents recorded inside the entry itself.
        var embedded: Data?
    }
    enum Problem: Error { case missing(String), unsupported(String) }

    private enum Map: Sendable { case physical(start: Int64), metadata(extents: [Extent]) }

    static let sector: Int64 = 2048
    let source: RemuxSource
    let blockSize: Int64
    private let maps: [Map]
    let root: Address

    init(_ source: RemuxSource) async throws {
        self.source = source
        var anchor = try await Self.descriptor(source, at: 256 * Self.sector, count: Int(Self.sector))
        if Self.tag(anchor) != 2 {
            anchor = try await Self.descriptor(source, at: (source.length / Self.sector - 1) * Self.sector, count: Int(Self.sector))
        }
        guard Self.tag(anchor) == 2 else { throw DiscImage.Failure.noVideo }
        let sequenceLength = min(Int64(Self.u32(anchor, 16)), 64 * Self.sector)
        let sequence = try await Self.descriptor(source, at: Int64(Self.u32(anchor, 20)) * Self.sector, count: Int(sequenceLength))
        var partitions: [UInt16: Int64] = [:]
        var volume: [UInt8]?
        var at = 0
        while at + Int(Self.sector) <= sequence.count {
            let descriptor = Array(sequence[at..<at + Int(Self.sector)])
            at += Int(Self.sector)
            switch Self.tag(descriptor) {
            case 5: partitions[Self.u16(descriptor, 22)] = Int64(Self.u32(descriptor, 188))
            case 6: if volume == nil { volume = descriptor }
            case 8: at = sequence.count
            default: break
            }
        }
        guard let volume else { throw Problem.missing("logical volume") }
        blockSize = Int64(Self.u32(volume, 212))
        guard [512, 1024, 2048, 4096].contains(blockSize) else { throw Problem.unsupported("block size \(blockSize)") }
        // The partition maps follow the descriptor; one longer than a block isn't read.
        var maps: [Map] = [], next = 440
        for _ in 0..<min(Int(Self.u32(volume, 268)), 8) {
            guard next + 2 <= volume.count else { break }
            let type = volume[next], size = Int(volume[next + 1])
            guard size > 0, next + size <= volume.count else { break }
            if type == 1 {
                guard let start = partitions[Self.u16(volume, next + 4)] else { throw Problem.missing("partition") }
                maps.append(.physical(start: start * blockSize))
            } else if type == 2 {
                let kind = String(decoding: volume[next + 5..<next + 28], as: UTF8.self)
                guard let start = partitions[Self.u16(volume, next + 38)] else { throw Problem.missing("partition") }
                if kind.hasPrefix("*UDF Metadata Partition") {
                    maps.append(.metadata(extents: []))
                    // The metadata file: where the metadata partition's blocks lie in the physical partition.
                    let location = Self.u32(volume, next + 40)
                    let physical = UDFVolume(source: source, blockSize: blockSize, maps: [.physical(start: start * blockSize)], root: Address(block: 0, partition: 0))
                    let file = try await physical.node(Address(block: location, partition: 0))
                    maps[maps.count - 1] = .metadata(extents: file.extents)
                } else if kind.hasPrefix("*UDF Sparable Partition") {
                    maps.append(.physical(start: start * blockSize))
                } else { throw Problem.unsupported(kind.trimmingCharacters(in: .controlCharacters)) }
            } else { throw Problem.unsupported("partition map \(type)") }
            next += size
        }
        self.maps = maps
        let fileSet = Address(block: Self.u32(volume, 252), partition: Self.u16(volume, 256))
        let partial = UDFVolume(source: source, blockSize: blockSize, maps: maps, root: fileSet)
        let set = try await partial.block(fileSet)
        guard Self.tag(set) == 256 else { throw Problem.missing("file set") }
        root = Address(block: Self.u32(set, 404), partition: Self.u16(set, 408))
    }

    private init(source: RemuxSource, blockSize: Int64, maps: [Map], root: Address) {
        self.source = source; self.blockSize = blockSize; self.maps = maps; self.root = root
    }

    /// The image bytes of `length` bytes from `address`; a metadata partition's may lie in several places.
    func extents(_ address: Address, length: Int64) throws -> [Extent] {
        guard maps.indices.contains(Int(address.partition)) else { throw Problem.missing("partition \(address.partition)") }
        switch maps[Int(address.partition)] {
        case .physical(let start): return [Extent(offset: start + Int64(address.block) * blockSize, length: length)]
        case .metadata(let file):
            var result: [Extent] = [], position = Int64(address.block) * blockSize, remaining = length, start: Int64 = 0
            for extent in file where remaining > 0 {
                defer { start += extent.length }
                guard position < start + extent.length else { continue }
                let within = position - start, size = min(remaining, extent.length - within)
                result.append(Extent(offset: extent.offset.map { $0 + within }, length: size))
                position += size; remaining -= size
            }
            guard remaining == 0 else { throw Problem.missing("metadata block \(address.block)") }
            return result
        }
    }

    func block(_ address: Address) async throws -> [UInt8] {
        var bytes: [UInt8] = []
        for extent in try extents(address, length: blockSize) {
            guard let offset = extent.offset else { bytes += [UInt8](repeating: 0, count: Int(extent.length)); continue }
            bytes += try await Self.descriptor(source, at: offset, count: Int(extent.length))
        }
        return bytes
    }

    /// The file or directory whose (extended) file entry is at `icb`.
    func node(_ icb: Address) async throws -> Node {
        let entry = try await block(icb)
        let header: Int
        switch Self.tag(entry) {
        case 261: header = 176
        case 266: header = 216
        default: throw Problem.missing("file entry at \(icb.block)")
        }
        let length = Int64(Self.u64(entry, 56))
        let attributes = Int(Self.u32(entry, header - 8)), descriptors = Int(Self.u32(entry, header - 4))
        let start = header + attributes
        guard start + descriptors <= entry.count else { throw Problem.unsupported("file entry size") }
        let directory = entry[27] == 4
        let kind = Self.u16(entry, 34) & 0x07
        if kind == 3 { return Node(directory: directory, length: length, extents: [], embedded: Data(entry[start..<start + descriptors])) }
        var extents: [Extent] = []
        var area = Array(entry[start..<start + descriptors]), hops = 0
        scan: while true {
            let size = kind == 0 ? 8 : kind == 1 ? 16 : 20
            var at = 0
            while at + size <= area.count {
                defer { at += size }
                let raw = Self.u32(area, at), type = raw >> 30, bytes = Int64(raw & 0x3FFF_FFFF)
                if bytes == 0 { break scan }
                let address: Address
                switch kind {
                case 0: address = Address(block: Self.u32(area, at + 4), partition: icb.partition)
                case 1: address = Address(block: Self.u32(area, at + 4), partition: Self.u16(area, at + 8))
                default: address = Address(block: Self.u32(area, at + 12), partition: Self.u16(area, at + 16))
                }
                if type == 3 {
                    // The descriptors go on in an allocation extent descriptor.
                    hops += 1
                    guard hops < 64 else { throw Problem.unsupported("allocation chain") }
                    let next = try await block(address)
                    guard Self.tag(next) == 258 else { throw Problem.missing("allocation extent") }
                    area = Array(next[24..<min(next.count, 24 + Int(Self.u32(next, 20)))])
                    continue scan
                }
                if type == 0 { extents += try self.extents(address, length: bytes) }
                else { extents.append(Extent(offset: nil, length: bytes)) }
            }
            break
        }
        // The last extent may run past the end of the file.
        var total: Int64 = 0
        extents = extents.compactMap { extent in
            defer { total += extent.length }
            guard total < length else { return nil }
            return Extent(offset: extent.offset, length: min(extent.length, length - total))
        }
        return Node(directory: directory, length: min(length, total), extents: extents, embedded: nil)
    }

    /// A small file's or directory's bytes.
    func contents(_ node: Node) async throws -> Data {
        if let embedded = node.embedded { return embedded.prefix(Int(node.length)) }
        var data = Data()
        for extent in node.extents {
            guard let offset = extent.offset else { data.append(Data(count: Int(extent.length))); continue }
            data.append(try await DiscRead.fully(source, at: offset, count: Int(extent.length)))
        }
        return data
    }

    /// The files and folders of the directory at `icb`.
    func list(_ icb: Address) async throws -> [Entry] {
        let node = try await node(icb)
        guard node.length < 16 << 20 else { throw Problem.unsupported("directory size") }
        let bytes = [UInt8](try await contents(node))
        var entries: [Entry] = [], at = 0
        while at + 38 <= bytes.count, Self.u16(bytes, at) == 257 {
            let characteristics = bytes[at + 18], nameLength = Int(bytes[at + 19]), use = Int(Self.u16(bytes, at + 36))
            let name = at + 38 + use
            guard name + nameLength <= bytes.count else { break }
            // Not deleted, not the parent.
            if characteristics & 0x0C == 0, nameLength > 0 {
                entries.append(Entry(name: Self.name(Array(bytes[name..<name + nameLength])), directory: characteristics & 0x02 != 0,
                                     icb: Address(block: Self.u32(bytes, at + 24), partition: Self.u16(bytes, at + 28))))
            }
            at += (38 + use + nameLength + 3) & ~3
        }
        return entries
    }

    func child(of directory: Address, named name: String, directory wanted: Bool) async throws -> Entry? {
        try await list(directory).first { $0.directory == wanted && $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// A file identifier: OSTA compressed Unicode, 8 or 16 bits a character.
    static func name(_ bytes: [UInt8]) -> String {
        guard let kind = bytes.first else { return "" }
        let rest = bytes.dropFirst()
        if kind == 16 || kind == 255 {
            let units = stride(from: rest.startIndex, to: rest.endIndex - 1, by: 2).map { UInt16(rest[$0]) << 8 | UInt16(rest[$0 + 1]) }
            return String(decoding: units, as: UTF16.self)
        }
        return String(rest.map { Character(Unicode.Scalar($0)) })
    }

    private static func descriptor(_ source: RemuxSource, at offset: Int64, count: Int) async throws -> [UInt8] {
        guard offset >= 0, offset + Int64(count) <= source.length else { throw Problem.missing("bytes at \(offset)") }
        return [UInt8](try await DiscRead.fully(source, at: offset, count: count))
    }

    static func tag(_ bytes: [UInt8]) -> UInt16 { bytes.count >= 16 ? u16(bytes, 0) : 0 }
    static func u16(_ bytes: [UInt8], _ at: Int) -> UInt16 { UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 }
    static func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(bytes[at + $1]) << (8 * $1) } }
    static func u64(_ bytes: [UInt8], _ at: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(bytes[at + $1]) << (8 * $1) } }
}

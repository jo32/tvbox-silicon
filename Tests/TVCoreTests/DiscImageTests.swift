import Foundation
import Testing
@testable import TVCore

struct DiscImageTests {
    @Test func discImagesAreKnownByTheirVolumeRecognition() {
        var head = Data(count: DiscImage.headLength)
        #expect(!DiscImage.handles(head) && !Remux.handles(head))
        head.replaceSubrange(32_769..<32_774, with: Data("CD001".utf8))
        #expect(DiscImage.handles(head) && Remux.handles(head))
        head.replaceSubrange(32_769..<32_774, with: Data("BEA01".utf8))
        #expect(DiscImage.handles(head))
        #expect(!DiscImage.handles(head.prefix(16)))
        #expect(DiscImage.handles(name: "Movie.2019.BluRay.ISO") && !DiscImage.handles(name: "movie.mkv"))
        #expect(CloudFile.kind(of: "movie.iso") == .video && CloudFile.playsOriginal("movie.iso"))
    }

    @Test func playlistsListTheirClips() {
        let items = [DiscImage.PlayItem(clip: "00055", start: 27_000_000, end: 27_450_000),
                     DiscImage.PlayItem(clip: "00056", start: 900, end: 45_900)]
        #expect(DiscImage.playItems(DiscFixtures.playlist(items)) == items)
        #expect(DiscImage.playItems(Data("MOBJ0200".utf8) + Data(count: 40)) == nil)
    }

    /// A Blu-ray's longest playlist plays, its clips one after the other, each clip's clock moved on to where the
    /// previous clip ended. Read through both layouts discs use: UDF 2.50 with a metadata partition, and 1.02.
    @Test(arguments: [true, false]) func bluRayPlaysItsLongestPlaylist(metadata: Bool) async throws {
        let clip = try DiscFixtures.clip()
        let times = DiscFixtures.timestamps(clip)
        let first = try #require(times.min()), last = try #require(times.max())
        // In 45 kHz ticks, as playlists count: the clip plays from its first picture to past its last.
        let start = first / 2, end = (last + 3_600) / 2
        let image = UDFImageBuilder(metadata: metadata, files: [
            .init(path: "BDMV/index.bdmv", data: Data("INDX0200".utf8)),
            .init(path: "BDMV/PLAYLIST/00000.mpls", data: DiscFixtures.playlist([.init(clip: "00001", start: start, end: end)])),
            .init(path: "BDMV/PLAYLIST/00800.mpls", data: DiscFixtures.playlist([.init(clip: "00001", start: start, end: end),
                                                                                 .init(clip: "00002", start: start, end: end)])),
            .init(path: "BDMV/STREAM/00001.m2ts", data: clip, pieces: 3),
            .init(path: "BDMV/STREAM/00002.m2ts", data: clip, pieces: 2),
        ]).build()
        let title = try #require(try await DiscImage.title(MemorySource(image)) as? DiscTitle)
        #expect(title.parts.count == 2 && title.length == Int64(clip.count * 2))
        #expect(title.summary.contains("00800.mpls"))

        // Read in odd pieces, as FFmpeg's buffer meets packets anywhere.
        var whole = Data()
        while whole.count < Int(title.length) { whole += try await title.read(at: Int64(whole.count), count: 1_000 + whole.count % 777) }
        #expect(whole.count == clip.count * 2)
        #expect(whole.prefix(clip.count) == clip)
        let shift = 2 * (end - start)
        #expect(DiscFixtures.timestamps(whole.suffix(clip.count)) == times.map { $0 + shift })
        // A read that starts inside a packet sees the same bytes.
        let inside = try await title.read(at: Int64(clip.count + 1_000), count: 500)
        #expect(inside == whole.subdata(in: clip.count + 1_000..<clip.count + 1_500))
    }

    @Test func dvdPlaysItsLargestTitleSet() async throws {
        let parts = (1...3).map { index in Data((0..<5_000 + index).map { UInt8(truncatingIfNeeded: $0 * index) }) }
        let image = UDFImageBuilder(metadata: false, files: [
            .init(path: "VIDEO_TS/VIDEO_TS.VOB", data: Data(count: 9_000)),
            .init(path: "VIDEO_TS/VTS_01_0.VOB", data: Data(count: 9_000)),
            .init(path: "VIDEO_TS/VTS_01_2.VOB", data: parts[1], pieces: 2),
            .init(path: "VIDEO_TS/VTS_01_1.VOB", data: parts[0]),
            .init(path: "VIDEO_TS/VTS_01_3.VOB", data: parts[2]),
            .init(path: "VIDEO_TS/VTS_02_1.VOB", data: Data(count: 12_000)),
        ]).build()
        let title = try #require(try await DiscImage.title(MemorySource(image)) as? DiscTitle)
        #expect(title.summary == "dvd title-set=1")
        var whole = Data()
        while whole.count < Int(title.length) { whole += try await title.read(at: Int64(whole.count), count: 4_096) }
        #expect(whole == parts.reduce(Data(), +))
    }

    @Test func unplayableImagesSayWhy() async throws {
        #expect(try await DiscImage.title(MemorySource(Data(count: 300_000))) == nil)
        let empty = UDFImageBuilder(metadata: true, files: [.init(path: "DATA/readme.txt", data: Data("hello".utf8))]).build()
        await #expect(throws: DiscImage.Failure.noVideo) { try await DiscImage.title(MemorySource(empty)) }
        var clip = try DiscFixtures.clip()
        clip[0] |= 0xC0
        let encrypted = UDFImageBuilder(metadata: true, files: [
            .init(path: "BDMV/PLAYLIST/00000.mpls", data: DiscFixtures.playlist([.init(clip: "00000", start: 0, end: 90_000)])),
            .init(path: "BDMV/STREAM/00000.m2ts", data: clip),
        ]).build()
        await #expect(throws: DiscImage.Failure.encrypted) { try await DiscImage.title(MemorySource(encrypted)) }
    }
}

extension RemuxTests {
    /// The disc's title plays through the repackager as long as its two clips together.
    @Test func bluRayImagePlaysThroughTheRepackager() async throws {
        let clip = try DiscFixtures.clip()
        let times = DiscFixtures.timestamps(clip)
        let first = try #require(times.min()), last = try #require(times.max())
        let start = first / 2, end = (last + 3_600) / 2
        let image = UDFImageBuilder(metadata: true, files: [
            .init(path: "BDMV/PLAYLIST/00001.mpls", data: DiscFixtures.playlist([.init(clip: "00010", start: start, end: end),
                                                                                 .init(clip: "00011", start: start, end: end)])),
            .init(path: "BDMV/STREAM/00010.m2ts", data: clip),
            .init(path: "BDMV/STREAM/00011.m2ts", data: clip, pieces: 2),
        ]).build()
        let master = try await Remux.open(MemorySource(image))
        defer { Remux.stop(master) }
        let text = String(decoding: try await URLSession.shared.data(from: master).0, as: UTF8.self)
        let video = try #require(text.split(separator: "\n").first { !$0.hasPrefix("#") && !$0.isEmpty })
        let playlist = String(decoding: try await URLSession.shared.data(from: URL(string: String(video), relativeTo: master)!).0, as: UTF8.self)
        let seconds = playlist.split(separator: "\n").filter { $0.hasPrefix("#EXTINF:") }
            .compactMap { Double($0.dropFirst(8).split(separator: ",")[0]) }.reduce(0, +)
        let clipSeconds = Double(2 * (end - start)) / 90_000
        #expect(abs(seconds - 2 * clipSeconds) < 0.5, "\(seconds) s for two clips of \(clipSeconds) s")
    }
}

/// A file in memory, read as the repackager reads a drive's file.
struct MemorySource: RemuxSource {
    let data: Data
    init(_ data: Data) { self.data = data }
    var length: Int64 { Int64(data.count) }
    func read(at offset: Int64, count: Int) async throws -> Data {
        guard offset < length else { return Data() }
        let start = data.startIndex + Int(offset)
        // At most 64 KB at a time, as a network source hands them out.
        return data.subdata(in: start..<min(data.endIndex, start + min(count, 65_536)))
    }
    var transfer: (received: Int64, host: String?)? { nil }
    func close() async {}
}

enum DiscFixtures {
    /// A Blu-ray clip: the HEVC transport stream fixture in 192-byte packets, each after a 4-byte arrival header.
    static func clip() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "remux-hevc-ts-0", withExtension: "ts", subdirectory: "Fixtures"))
        let stream = try Data(contentsOf: url)
        var clip = Data()
        for packet in stride(from: 0, to: stream.count - 187, by: 188) {
            clip += Data([0, 0, 0, 0]) + stream.subdata(in: packet..<packet + 188)
        }
        return clip
    }

    /// The PTS of each PES packet that starts in `clip` (192-byte packets).
    static func timestamps(_ clip: Data) -> [Int64] {
        let bytes = [UInt8](clip)
        var times: [Int64] = []
        for packet in stride(from: 0, to: bytes.count - 191, by: 192) {
            let ts = packet + 4
            guard bytes[ts] == 0x47, bytes[ts + 1] & 0x40 != 0 else { continue }
            let control = bytes[ts + 3] >> 4 & 3
            guard control & 1 != 0 else { continue }
            let payload = control & 2 != 0 ? ts + 5 + Int(bytes[ts + 4]) : ts + 4
            guard payload + 14 <= ts + 188, bytes[payload] == 0, bytes[payload + 1] == 0, bytes[payload + 2] == 1,
                  bytes[payload + 7] & 0x80 != 0 else { continue }
            let at = payload + 9
            times.append(Int64(bytes[at] >> 1 & 7) << 30 | Int64(bytes[at + 1]) << 22 | Int64(bytes[at + 2] >> 1) << 15
                         | Int64(bytes[at + 3]) << 7 | Int64(bytes[at + 4] >> 1))
        }
        return times
    }

    /// An MPLS playlist with these play items (each with room after its times, as real ones have).
    static func playlist(_ items: [DiscImage.PlayItem]) -> Data {
        func u16(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
        func u32(_ value: Int64) -> [UInt8] { [24, 16, 8, 0].map { UInt8(value >> $0 & 0xFF) } }
        var list: [UInt8] = [0, 0] + u16(items.count) + u16(0)
        for item in items {
            var body = Array(item.clip.utf8) + Array("M2TS".utf8) + [0x00, 0x01, 0x00] + u32(item.start) + u32(item.end)
            body += [UInt8](repeating: 0, count: 30)
            list += u16(body.count) + body
        }
        var data = Array("MPLS0200".utf8) + u32(40) + u32(0) + u32(0) + [UInt8](repeating: 0, count: 20)
        data += u32(Int64(list.count)) + list
        return Data(data)
    }
}

/// Small UDF images laid out as discs record them: UDF 2.50 with a metadata partition and extended file entries
/// (Blu-ray), or UDF 1.02 with one partition (DVD). Files may lie in several pieces, apart from each other.
struct UDFImageBuilder {
    struct File {
        var path: String
        var data: Data
        var pieces = 1
    }
    var metadata: Bool
    var files: [File]

    private static let block = 2048
    private final class Folder {
        let name: String
        weak var parent: Folder?
        var folders: [Folder] = []
        var files: [Int] = []
        var entry = 0, contents = 0
        init(name: String, parent: Folder?) { self.name = name; self.parent = parent }
    }

    func build() -> Data {
        let block = Self.block
        let revision = metadata ? 0x0250 : 0x0102
        let version: UInt16 = metadata ? 3 : 2
        // The tree.
        let root = Folder(name: "", parent: nil)
        var folders = [root]
        for (index, file) in files.enumerated() {
            var folder = root
            for name in file.path.split(separator: "/").dropLast().map(String.init) {
                if let next = folder.folders.first(where: { $0.name == name }) { folder = next; continue }
                let next = Folder(name: name, parent: folder)
                folder.folders.append(next); folders.append(next)
                folder = next
            }
            folder.files.append(index)
        }
        // Blocks of the partition that holds the file system (the metadata partition on Blu-ray).
        var next = 2
        for folder in folders { folder.entry = next; folder.contents = next + 1; next += 2 }
        var fileEntries: [Int] = []
        for _ in files { fileEntries.append(next); next += 1 }
        let systemBlocks = next
        let reserved = metadata ? (systemBlocks + 31) / 32 * 32 : 0
        // File data in the physical partition, each piece a block apart from the next.
        var data = metadata ? 2 + 2 * reserved : systemBlocks
        var pieces: [[(block: Int, length: Int)]] = []
        for file in files {
            let blocks = max(1, (file.data.count + block - 1) / block)
            let each = (blocks + file.pieces - 1) / file.pieces
            var list: [(block: Int, length: Int)] = [], offset = 0
            while offset < file.data.count || list.isEmpty {
                let length = min(each * block, file.data.count - offset)
                list.append((data, length))
                data += (length + block - 1) / block + 1
                offset += length
            }
            pieces.append(list)
        }
        let partitionStart = 257, partitionLength = data
        let sectors = partitionStart + partitionLength + 1
        var image = [UInt8](repeating: 0, count: sectors * block)

        func put(_ bytes: [UInt8], _ at: Int) { image.replaceSubrange(at..<at + bytes.count, with: bytes) }
        func le16(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
        func le32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8(value >> (8 * $0) & 0xFF) } }
        func le64(_ value: Int) -> [UInt8] { (0..<8).map { UInt8(value >> (8 * $0) & 0xFF) } }
        func set(_ d: inout [UInt8], _ at: Int, _ bytes: [UInt8]) { d.replaceSubrange(at..<at + bytes.count, with: bytes) }
        func padded(_ text: String, _ count: Int) -> [UInt8] { Array((Array(text.utf8) + [UInt8](repeating: 0, count: count)).prefix(count)) }
        func dstring(_ text: String, _ count: Int) -> [UInt8] {
            var bytes = padded("\u{8}" + text, count)
            bytes[count - 1] = UInt8(1 + text.utf8.count)
            return bytes
        }
        func regid(_ id: String, _ suffix: [UInt8]) -> [UInt8] { [0] + padded(id, 23) + Array((suffix + [UInt8](repeating: 0, count: 8)).prefix(8)) }
        let udfSuffix = le16(revision)
        let charset = [UInt8(0)] + padded("OSTA Compressed Unicode", 63)
        let stamp = le16(0x1000) + le16(2026) + [11, 7, 12, 0, 0, 0, 0, 0]
        let implementation = regid("*Yingxia Tests", [])
        func crc(_ bytes: ArraySlice<UInt8>) -> Int {
            var value: UInt16 = 0
            for byte in bytes {
                value ^= UInt16(byte) << 8
                for _ in 0..<8 { value = value & 0x8000 != 0 ? value << 1 ^ 0x1021 : value << 1 }
            }
            return Int(value)
        }
        func seal(_ d: inout [UInt8], _ id: Int, _ location: Int) {
            set(&d, 0, le16(id) + le16(Int(version)) + [0, 0] + le16(1) + le16(crc(d[16...])) + le16(d.count - 16) + le32(location))
            d[4] = UInt8(d[0..<16].enumerated().reduce(0) { $1.offset == 4 ? $0 : ($0 + Int($1.element)) } & 0xFF)
        }
        func descriptor(_ id: Int, _ location: Int, _ size: Int = 512, _ fill: (inout [UInt8]) -> Void) -> [UInt8] {
            var d = [UInt8](repeating: 0, count: size)
            fill(&d)
            seal(&d, id, location)
            return d
        }
        func longAD(_ length: Int, _ block: Int, _ partition: Int) -> [UInt8] { le32(length) + le32(block) + le16(partition) + [0, 0, 0, 0, 0, 0] }
        let systemPartition = metadata ? 1 : 0
        var unique = 16

        // Volume recognition.
        for (index, id) in ["BEA01", metadata ? "NSR03" : "NSR02", "TEA01"].enumerated() { put([0] + Array(id.utf8) + [1], (16 + index) * block) }

        // Volume descriptors, the main sequence at 32 and its reserve at 48.
        for base in [32, 48] {
            put(descriptor(1, base) { d in
                set(&d, 16, le32(1)); set(&d, 24, dstring("YINGXIA_TEST", 32)); set(&d, 56, le16(1) + le16(1) + le16(2) + le16(3) + le32(1) + le32(1))
                set(&d, 72, dstring("0123ABCDYingxia", 128)); set(&d, 200, charset); set(&d, 264, charset)
                set(&d, 376, stamp); set(&d, 388, implementation)
            }, base * block)
            put(descriptor(4, base + 1) { d in
                set(&d, 16, le32(2)); set(&d, 20, regid("*UDF LV Info", udfSuffix)); set(&d, 52, charset)
                set(&d, 116, dstring("YINGXIA_TEST", 128)); set(&d, 352, implementation)
            }, (base + 1) * block)
            put(descriptor(5, base + 2) { d in
                set(&d, 16, le32(3)); set(&d, 20, le16(1)); set(&d, 22, le16(0)); set(&d, 24, regid(metadata ? "+NSR03" : "+NSR02", []))
                set(&d, 184, le32(1)); set(&d, 188, le32(partitionStart)); set(&d, 192, le32(partitionLength)); set(&d, 196, implementation)
            }, (base + 2) * block)
            put(descriptor(6, base + 3) { d in
                set(&d, 16, le32(4)); set(&d, 20, charset); set(&d, 84, dstring("YINGXIA_TEST", 128)); set(&d, 212, le32(block))
                set(&d, 216, regid("*OSTA UDF Compliant", udfSuffix)); set(&d, 248, longAD(block, 0, systemPartition))
                var maps = [UInt8(1), 6] + le16(1) + le16(0)
                if metadata {
                    var map = [UInt8](repeating: 0, count: 64)
                    map[0] = 2; map[1] = 64
                    set(&map, 4, regid("*UDF Metadata Partition", udfSuffix)); set(&map, 36, le16(1) + le16(0))
                    set(&map, 40, le32(0) + le32(1) + le32(-1) + le32(32) + le16(1))
                    maps += map
                }
                set(&d, 264, le32(maps.count) + le32(metadata ? 2 : 1)); set(&d, 272, implementation)
                set(&d, 432, le32(2 * block) + le32(64)); set(&d, 440, maps)
            }, (base + 3) * block)
            put(descriptor(7, base + 4) { d in set(&d, 16, le32(5)) }, (base + 4) * block)
            put(descriptor(8, base + 5) { _ in }, (base + 5) * block)
        }
        // Logical volume integrity: closed.
        put(descriptor(9, 64, 80 + 8 + 46) { d in
            set(&d, 16, stamp); set(&d, 28, le32(1)); set(&d, 40, le64(16 + files.count + folders.count))
            set(&d, 72, le32(1) + le32(46) + le32(0) + le32(partitionLength))
            set(&d, 88, implementation + le32(files.count) + le32(folders.count) + le16(revision) + le16(revision) + le16(revision))
        }, 64 * block)
        put(descriptor(8, 65) { _ in }, 65 * block)
        // Anchors at 256 and at the last sector.
        for sector in [256, sectors - 1] {
            put(descriptor(2, sector) { d in set(&d, 16, le32(16 * block) + le32(32) + le32(16 * block) + le32(48)) }, sector * block)
        }

        // The file system's partition, block by block.
        var system = [UInt8](repeating: 0, count: max(systemBlocks, reserved) * block)
        func place(_ bytes: [UInt8], _ blockNumber: Int) { system.replaceSubrange(blockNumber * block..<blockNumber * block + bytes.count, with: bytes) }
        func entry(_ location: Int, type: UInt8, length: Int, descriptors: [UInt8], long: Bool, id: Int) -> [UInt8] {
            let header = metadata ? 216 : 176
            return descriptor(metadata ? 266 : 261, location, header + descriptors.count) { d in
                set(&d, 16, le32(0) + le16(4) + le16(0) + le16(1)); d[27] = type; set(&d, 34, le16(long ? 1 : 0))
                set(&d, 36, le32(-1) + le32(-1) + le32(0x14A5) + le16(1))
                set(&d, 56, le64(length))
                let blocks = (length + block - 1) / block
                if metadata {
                    set(&d, 64, le64(length) + le64(blocks)); set(&d, 80, stamp); set(&d, 92, stamp); set(&d, 104, stamp); set(&d, 116, stamp)
                    set(&d, 128, le32(1)); set(&d, 168, implementation); set(&d, 200, le64(id)); set(&d, 212, le32(descriptors.count))
                } else {
                    set(&d, 64, le64(blocks)); set(&d, 72, stamp); set(&d, 84, stamp); set(&d, 96, stamp)
                    set(&d, 108, le32(1)); set(&d, 128, implementation); set(&d, 160, le64(id)); set(&d, 172, le32(descriptors.count))
                }
                set(&d, header, descriptors)
            }
        }
        place(descriptor(256, 0) { d in
            set(&d, 16, stamp); set(&d, 28, le16(3) + le16(3) + le32(1) + le32(1)); set(&d, 48, charset)
            set(&d, 112, dstring("YINGXIA_TEST", 128)); set(&d, 240, charset); set(&d, 304, dstring("YINGXIA_TEST", 32))
            set(&d, 400, longAD(block, root.entry, systemPartition)); set(&d, 416, regid("*OSTA UDF Compliant", udfSuffix))
        }, 0)
        place(descriptor(8, 1) { _ in }, 1)
        for folder in folders {
            func identifier(_ name: String, directory: Bool, parent: Bool, entry: Int) -> [UInt8] {
                let nameBytes = name.isEmpty ? [] : [UInt8(8)] + Array(name.utf8)
                let size = (38 + nameBytes.count + 3) & ~3
                // The tag's location is the block the identifier starts in.
                return descriptor(257, folder.contents, size) { d in
                    set(&d, 16, le16(1)); d[18] = (directory ? 2 : 0) | (parent ? 8 : 0); d[19] = UInt8(nameBytes.count)
                    set(&d, 20, longAD(block, entry, systemPartition)); set(&d, 38, nameBytes)
                }
            }
            var listing = identifier("", directory: true, parent: true, entry: (folder.parent ?? folder).entry)
            for child in folder.folders { listing += identifier(child.name, directory: true, parent: false, entry: child.entry) }
            for index in folder.files {
                listing += identifier(String(files[index].path.split(separator: "/").last!), directory: false, parent: false, entry: fileEntries[index])
            }
            precondition(listing.count <= block)
            place(listing, folder.contents)
            var id = 0
            if folder !== root { unique += 1; id = unique }
            place(entry(folder.entry, type: 4, length: listing.count, descriptors: le32(listing.count) + le32(folder.contents), long: false, id: id), folder.entry)
        }
        for (index, file) in files.enumerated() {
            // File data lies in the physical partition (map 0).
            let descriptors = pieces[index].flatMap { longAD($0.length, $0.block, 0) }
            unique += 1
            place(entry(fileEntries[index], type: 5, length: file.data.count, descriptors: descriptors, long: true, id: unique), fileEntries[index])
            var offset = 0
            for piece in pieces[index] {
                put([UInt8](file.data.subdata(in: offset..<offset + piece.length)), (partitionStart + piece.block) * block)
                offset += piece.length
            }
        }
        if metadata {
            // The metadata file and its mirror, each pointing at its own copy, in the physical partition.
            for (location, type, copy) in [(0, UInt8(250), 2), (1, UInt8(251), 2 + reserved)] {
                put(entry(location, type: type, length: reserved * block, descriptors: le32(reserved * block) + le32(copy), long: false, id: 0),
                    (partitionStart + location) * block)
                put(system, (partitionStart + copy) * block)
            }
        } else {
            put(system, partitionStart * block)
        }
        return Data(image)
    }
}

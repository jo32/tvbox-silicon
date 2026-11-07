import Compression
import Foundation

/// ZIP archives of subtitles (#576): a season's files, or one file zipped by a subtitle site. An archive is only
/// read in memory, never unpacked to disk. Its directory is listed first and checked as a whole against hard limits
/// (size, entry count, inflated size, compression ratio, paths); then each subtitle file is inflated on its own with
/// Apple's Compression (raw DEFLATE), stopping the moment it grows past what its entry declared.
public enum SubtitleArchive {
    public struct Limits: Sendable {
        /// The archive itself, compressed.
        public var archive = SubtitleFile.largest
        /// Entries in its directory, of any kind.
        public var entries = 500
        /// One subtitle file, inflated: what a subtitle file may be.
        public var entry = SubtitleFile.largest
        /// The subtitle files together, inflated.
        public var total = 32 << 20
        /// Inflated bytes per compressed byte. Subtitles deflate 3 to 10 times; a bomb thousands of times.
        public var ratio = 100
        public init() {}
    }

    /// A subtitle file inside an archive.
    public struct Entry: Sendable, Hashable {
        /// Its path inside the archive, with `/` between folders.
        public let path: String
        /// Its file name, without the folders.
        public var name: String { path.split(separator: "/").last.map(String.init) ?? path }
        let method: UInt16, crc: UInt32, compressedSize: Int, size: Int, offset: Int
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case damaged, tooLarge, tooManyEntries, unsafePath, nested, encrypted, unsupported, noSubtitles, noneForEpisode

        public var errorDescription: String? {
            switch self {
            case .damaged: L10n.text("The archive is damaged.")
            case .tooLarge: L10n.text("The archive unpacks to more than subtitles need.")
            case .tooManyEntries: L10n.text("The archive holds too many files.")
            case .unsafePath: L10n.text("The archive has a file outside its own folder.")
            case .nested: L10n.text("The archive holds only other archives.")
            case .encrypted: L10n.text("The archive is protected by a password.")
            case .unsupported: L10n.text("The archive uses a kind of ZIP that isn't supported.")
            case .noSubtitles: L10n.text("The archive holds no SRT, WebVTT or ASS files.")
            case .noneForEpisode: L10n.text("None of the archive's files is for this episode.")
            }
        }
    }

    /// Whether the bytes are a ZIP archive (its first local file header, or an empty archive's directory end).
    public static func isArchive(_ data: Data) -> Bool {
        data.starts(with: [0x50, 0x4B, 0x03, 0x04]) || data.starts(with: [0x50, 0x4B, 0x05, 0x06])
    }

    /// Whether a file name is a ZIP archive's.
    public static func isArchive(name: String) -> Bool { (name as NSString).pathExtension.lowercased() == "zip" }

    static let subtitleExtensions: Set<String> = ["srt", "ass", "ssa", "vtt"]
    static let archiveExtensions: Set<String> = ["zip", "rar", "7z", "gz", "tgz", "tar", "bz2", "xz", "lzma", "zst", "cab"]

    /// The archive's subtitle files, in its order. The whole directory is checked first: a path that leaves the
    /// archive's folder, or sizes past `limits`, refuse the archive rather than the entry.
    public static func entries(_ data: Data, limits: Limits = Limits()) throws -> [Entry] {
        guard data.count <= limits.archive else { throw Failure.tooLarge }
        let bytes = [UInt8](data)
        guard let end = directoryEnd(bytes) else { throw Failure.damaged }
        let count = Int(u16(bytes, end + 10)), size = Int(u32(bytes, end + 12)), start = Int(u32(bytes, end + 16))
        // ZIP64 (sizes past 4 GiB, more than 65535 entries) has no place in a subtitle archive.
        if count == 0xFFFF || u32(bytes, end + 12) == 0xFFFF_FFFF || u32(bytes, end + 16) == 0xFFFF_FFFF { throw Failure.unsupported }
        guard count <= limits.entries else { throw Failure.tooManyEntries }
        guard start >= 0, size >= 0, start + size <= end else { throw Failure.damaged }
        var found: [Entry] = []
        var position = start, total = 0
        var nested = false, encrypted = false, unsupported = false
        for _ in 0..<count {
            guard position + 46 <= start + size, u32(bytes, position) == 0x0201_4B50 else { throw Failure.damaged }
            let flags = u16(bytes, position + 8), method = u16(bytes, position + 10)
            let crc = u32(bytes, position + 16)
            let compressed = Int(u32(bytes, position + 20)), inflated = Int(u32(bytes, position + 24))
            let nameLength = Int(u16(bytes, position + 28)), extra = Int(u16(bytes, position + 30)), comment = Int(u16(bytes, position + 32))
            let offset = Int(u32(bytes, position + 42))
            let nameStart = position + 46
            guard nameStart + nameLength + extra + comment <= start + size else { throw Failure.damaged }
            let path = Self.path(Array(bytes[nameStart..<nameStart + nameLength]), utf8: flags & 0x800 != 0)
            position = nameStart + nameLength + extra + comment
            guard safe(path) else { throw Failure.unsafePath }
            if compressed == 0xFFFF_FFFF || inflated == 0xFFFF_FFFF || offset == 0xFFFF_FFFF { throw Failure.unsupported }
            if path.hasSuffix("/") { continue }
            let name = path.split(separator: "/").last.map(String.init) ?? path
            // macOS keeps resource forks beside each file in a __MACOSX folder, named ._file.srt.
            if path.hasPrefix("__MACOSX/") || name.hasPrefix("._") { continue }
            let ext = (name as NSString).pathExtension.lowercased()
            if archiveExtensions.contains(ext) { nested = true; continue }
            guard subtitleExtensions.contains(ext) else { continue }
            if flags & 0x1 != 0 { encrypted = true; continue }
            guard method == 0 || method == 8 else { unsupported = true; continue }
            guard inflated <= limits.entry else { throw Failure.tooLarge }
            // A small file may compress very well; past 64 KiB, a ratio no text reaches is a bomb.
            if inflated > 64 << 10, inflated > compressed * limits.ratio { throw Failure.tooLarge }
            if method == 0, compressed != inflated { throw Failure.damaged }
            total += inflated
            guard total <= limits.total else { throw Failure.tooLarge }
            guard offset + 30 <= start, offset + 30 + compressed <= start else { throw Failure.damaged }
            found.append(Entry(path: path, method: method, crc: crc, compressedSize: compressed, size: inflated, offset: offset))
        }
        if found.isEmpty {
            if nested { throw Failure.nested }
            if encrypted { throw Failure.encrypted }
            if unsupported { throw Failure.unsupported }
            throw Failure.noSubtitles
        }
        return found
    }

    /// One subtitle file's bytes. Inflating stops as soon as it passes the size its entry declared (or `limits.entry`),
    /// and the result must match the entry's CRC-32.
    public static func extract(_ entry: Entry, from data: Data, limits: Limits = Limits()) throws -> Data {
        let bytes = [UInt8](data)
        guard entry.offset + 30 <= bytes.count, u32(bytes, entry.offset) == 0x0403_4B50 else { throw Failure.damaged }
        let begin = entry.offset + 30 + Int(u16(bytes, entry.offset + 26)) + Int(u16(bytes, entry.offset + 28))
        // Sizes come from the directory: a local header written before its data (a data descriptor) says 0.
        guard begin + entry.compressedSize <= bytes.count else { throw Failure.damaged }
        let stored = Data(bytes[begin..<begin + entry.compressedSize])
        let limit = min(entry.size, limits.entry)
        let output: Data
        switch entry.method {
        case 0: output = stored
        case 8: output = try inflate(stored, limit: limit)
        default: throw Failure.unsupported
        }
        guard output.count == entry.size else { throw Failure.damaged }
        guard crc32(output) == entry.crc else { throw Failure.damaged }
        return output
    }

    /// Raw DEFLATE (ZIP's method 8), refusing more than `limit` bytes of output.
    static func inflate(_ input: Data, limit: Int) throws -> Data {
        guard !input.isEmpty else { return Data() }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw Failure.damaged }
        defer { compression_stream_destroy(stream) }
        let chunk = 64 << 10
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        var output = Data()
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { throw Failure.damaged }
            stream.pointee.src_ptr = base
            stream.pointee.src_size = raw.count
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = chunk
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                guard status != COMPRESSION_STATUS_ERROR else { throw Failure.damaged }
                let produced = chunk - stream.pointee.dst_size
                output.append(buffer, count: produced)
                guard output.count <= limit else { throw Failure.tooLarge }
                if status == COMPRESSION_STATUS_END { break }
                // Input used up without the stream's end: cut short.
                if produced == 0, stream.pointee.src_size == 0 { throw Failure.damaged }
            }
        }
        return output
    }

    /// The end-of-directory record: within the last 64 KiB (its comment can be that long).
    private static func directoryEnd(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        var index = bytes.count - 22
        let lowest = max(0, bytes.count - 22 - 0xFFFF)
        while index >= lowest {
            if bytes[index] == 0x50, u32(bytes, index) == 0x0605_4B50, index + 22 + Int(u16(bytes, index + 20)) <= bytes.count { return index }
            index -= 1
        }
        return nil
    }

    /// A name is UTF-8 when its flag says so; otherwise many archives made on Chinese systems use GB 18030, and the
    /// rest the old DOS code page, read here as Latin-1.
    static func path(_ raw: [UInt8], utf8: Bool) -> String {
        let data = Data(raw)
        let text = utf8 ? String(decoding: data, as: UTF8.self)
            : String(data: data, encoding: .utf8) ?? SubtitleEncoding.gb18030.foundation.flatMap { String(data: data, encoding: $0) }
                ?? String(data: data, encoding: .isoLatin1) ?? ""
        return text.replacingOccurrences(of: "\\", with: "/")
    }

    /// Whether a path stays inside the archive's folder: not absolute, no drive letter, no `..` and no NUL.
    static func safe(_ path: String) -> Bool {
        if path.isEmpty || path.hasPrefix("/") || path.contains("\0") { return false }
        if path.wholeMatch(of: /[A-Za-z]:.*/) != nil { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    private static func u16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        guard at >= 0, at + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        guard at >= 0, at + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    /// ZIP's CRC-32 (IEEE 802.3).
    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

extension SubtitleDocument {
    /// A subtitle file's documents: the file itself, or each subtitle file of a ZIP archive that belongs to `video`,
    /// best first (`SubtitleMatch`), at most `limit`. Each archived file's id is the archive's with its path after `#`.
    public static func documents(id: String, name: String, language: String = "", data: Data, format: String = "", video: String? = nil,
                                 limit: Int = 8) throws -> [SubtitleDocument] {
        guard SubtitleArchive.isArchive(data) else {
            return [try SubtitleDocument(id: id, name: name, language: language, data: data, format: format)]
        }
        let entries = try SubtitleArchive.entries(data)
        let order = SubtitleMatch.order(entries.map(\.name), video: video ?? "")
        guard !order.isEmpty else { throw SubtitleArchive.Failure.noneForEpisode }
        var documents: [SubtitleDocument] = [], failure: Error?
        for index in order.prefix(limit) {
            let entry = entries[index]
            do {
                let bytes = try SubtitleArchive.extract(entry, from: data)
                documents.append(try SubtitleDocument(id: id + "#" + entry.path, name: entry.name,
                                                      language: SubtitleMatch.language(entry.name).isEmpty ? language : "", data: bytes))
            } catch {
                failure = failure ?? error
            }
        }
        guard !documents.isEmpty else { throw failure ?? SubtitleArchive.Failure.noSubtitles }
        Diagnostics.shared.record(.info, "subtitles", "archive entries=\(entries.count) shown=\(documents.count)")
        return documents
    }
}

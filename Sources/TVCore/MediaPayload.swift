import Foundation

public enum MediaPayload {
    /// Some HLS hosts disguise MPEG-TS segments as pictures: a small PNG, JPEG, GIF, BMP or WebP comes first, and the
    /// file is named `.png` or `.jpg`. FFmpeg skips to the first packet; AVPlayer may not (one behind a GIF never
    /// starts: its "G" is the packet sync byte). The bytes before the first of five packets in a row go. Regular
    /// images and media remain untouched.
    public static func transportStream(_ data: Data) -> Data {
        guard data.count >= 188 * 5, let limit = imagePrefixLimit(data) else { return data }
        // A real transport stream that happens to start like an image header is left alone.
        if (0..<5).allSatisfy({ data[data.startIndex + $0 * 188] == 0x47 }) { return data }
        let bytes = [UInt8](data.prefix(limit + 188 * 5))
        let end = min(limit, bytes.count - 188 * 4)
        guard end > 1 else { return data }
        for offset in 1..<end where (0..<5).allSatisfy({ bytes[offset + $0 * 188] == 0x47 }) {
            return Data(data.dropFirst(offset))
        }
        return data
    }

    /// How far into the bytes a disguising image may reach, when they start with one.
    private static func imagePrefixLimit(_ data: Data) -> Int? {
        let head = [UInt8](data.prefix(12))
        guard head.count == 12 else { return nil }
        let png: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        if head.starts(with: png) { return 64 << 10 }
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return 64 << 10 }                  // JPEG
        if head.starts(with: Array("GIF8".utf8)) { return 64 << 10 }
        if head.starts(with: Array("BM".utf8)) { return 64 << 10 }
        if head.starts(with: Array("RIFF".utf8)), Array(head[8..<12]) == Array("WEBP".utf8) { return 64 << 10 }
        return nil
    }
}

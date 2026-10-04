import Foundation

public enum MediaPayload {
    /// Some HLS hosts prefix MPEG-TS with a tiny image. Require five packet syncs
    /// before discarding anything; regular images and media remain untouched.
    public static func transportStream(_ data: Data) -> Data {
        let png: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard data.starts(with: png), data.count >= 188 * 5 else { return data }
        let bytes = [UInt8](data.prefix(8192))
        let limit = min(4096, bytes.count - 188 * 4)
        for offset in 8..<limit where (0..<5).allSatisfy({ bytes[offset + $0 * 188] == 0x47 }) {
            return Data(data.dropFirst(offset))
        }
        return data
    }
}

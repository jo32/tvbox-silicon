import Foundation

/// Limit allocation-heavy native catalog decoding to one worker. Network limits alone do not bound
/// nesting or the number of tiny values. Strings and their escaped quotes are opaque to this scan.
enum CatalogResponseParser {
    /// Arrays, objects and elements in one answer. A category page has hundreds and a home answer with long filter
    /// lists tens of thousands; only a pathological answer of tiny values within the 20 MB download limit gets here.
    static let maximumElements = 1_000_000
    static let maximumDepth = 64
    private static let worker = Worker()
    static func decode(_ data: Data, maximumBytes: Int = 20_000_000) async throws -> [String: JSONValue] {
        try Task.checkCancellation()
        return try await worker.decode(data, maximumBytes: maximumBytes)
    }
    /// Decode the same normalized bytes we scan. JSONDecoder recognizes UTF-16/32 too; a UTF-8
    /// byte scan of those encodings can mistake a code unit's low byte for a quote or bracket.
    private static func normalized(_ data: Data, maximumBytes: Int) throws -> Data {
        guard data.count <= maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
        let prefix = Array(data.prefix(4))
        let encoding: String.Encoding
        let skip: Int
        if prefix.starts(with: [0, 0, 0xFE, 0xFF]) { encoding = .utf32BigEndian; skip = 4 }
        else if prefix.starts(with: [0xFF, 0xFE, 0, 0]) { encoding = .utf32LittleEndian; skip = 4 }
        else if prefix.starts(with: [0xFE, 0xFF]) { encoding = .utf16BigEndian; skip = 2 }
        else if prefix.starts(with: [0xFF, 0xFE]) { encoding = .utf16LittleEndian; skip = 2 }
        else if prefix.count == 4, prefix[0] == 0, prefix[1] == 0, prefix[2] == 0 { encoding = .utf32BigEndian; skip = 0 }
        else if prefix.count == 4, prefix[1] == 0, prefix[2] == 0, prefix[3] == 0 { encoding = .utf32LittleEndian; skip = 0 }
        else if prefix.count >= 2, prefix[0] == 0 { encoding = .utf16BigEndian; skip = 0 }
        else if prefix.count >= 2, prefix[1] == 0 { encoding = .utf16LittleEndian; skip = 0 }
        else {
            // UTF-8: the scan rejects a raw NUL, so JSONDecoder can't take it for another encoding after the scan.
            return data
        }
        let body = data.dropFirst(skip)
        let unitWidth = encoding == .utf32BigEndian || encoding == .utf32LittleEndian ? 4 : 2
        guard body.count.isMultiple(of: unitWidth), let text = String(data: body, encoding: encoding),
              !text.utf8.contains(0) else { throw URLError(.cannotDecodeContentData) }
        guard text.utf8.count <= maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
        return Data(text.utf8)
    }

    private static func validate(_ data: Data, maximumBytes: Int) throws {
        guard data.count <= maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var depth = 0, elements = 0, quoted = false, escaped = false
            for index in bytes.indices {
                if index & 0xFFFFF == 0 { try Task.checkCancellation() }
                let byte = bytes[index]
                if byte == 0 { throw URLError(.cannotDecodeContentData) }
                if quoted {
                    if escaped { escaped = false }
                    else if byte == 92 { escaped = true }
                    else if byte == 34 { quoted = false }
                    continue
                }
                switch byte {
                case 34: quoted = true
                case 91, 123:
                    depth += 1; elements += 1
                    guard depth <= maximumDepth, elements <= maximumElements else { throw URLError(.dataLengthExceedsMaximum) }
                case 93, 125: depth -= 1
                case 44:
                    elements += 1
                    guard elements <= maximumElements else { throw URLError(.dataLengthExceedsMaximum) }
                default: break
                }
            }
        }
        // JSONDecoder still validates syntax: this is a complexity gate, not a second parser.
    }
    private actor Worker {
        func decode(_ data: Data, maximumBytes: Int) throws -> [String: JSONValue] {
            try Task.checkCancellation()
            let data = try normalized(data, maximumBytes: maximumBytes)
            try validate(data, maximumBytes: maximumBytes)
            let value = try JSONDecoder().decode([String: JSONValue].self, from: data)
            try Task.checkCancellation()
            return value
        }
    }
}

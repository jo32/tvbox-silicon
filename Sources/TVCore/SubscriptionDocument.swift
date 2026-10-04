import Foundation

/// Compatibility belongs at the subscription boundary, not in API response decoding.
enum SubscriptionDocument {
    static func decode(_ data: Data) throws -> [String: JSONValue] {
        if let value = try? JSONDecoder().decode([String: JSONValue].self, from: data) { return value }
        var bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        let first = bytes.first(where: { !whitespace($0) })
        if first != 123 && first != 91 && first != 47 && first != 35 {
            // TVBox image envelopes end in an eight-character marker and **base64.
            // Decode bytes rather than UTF-8: the image prefix can be arbitrary binary.
            if let start = envelopeStart(bytes) {
                let payload = bytes[start...].filter { !whitespace($0) }
                guard let decoded = Data(base64Encoded: Data(payload)) else { throw TVError.invalidConfiguration }
                bytes = [UInt8](decoded)
                if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
            }
        }
        let prefix = String(decoding: bytes.prefix(256), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if prefix.hasPrefix("<!doctype html") || prefix.hasPrefix("<html") {
            throw TVError.unsupported(L10n.text("The subscription server returned a web page instead of a configuration."))
        }
        if prefix.hasPrefix("2423") {
            throw TVError.unsupported(L10n.text("This subscription uses an encrypted configuration that is not supported yet."))
        }
        return try JSONDecoder().decode([String: JSONValue].self, from: Data(normalize(bytes)))
    }

    private static func whitespace(_ byte: UInt8) -> Bool { [9, 10, 13, 32].contains(byte) }

    private static func envelopeStart(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 10 else { return nil }
        func alphanumeric(_ b: UInt8) -> Bool { (48...57).contains(b) || (65...90).contains(b) || (97...122).contains(b) }
        for i in 8..<(bytes.count - 1) where bytes[i] == 42 && bytes[i + 1] == 42 {
            if bytes[(i - 8)..<i].allSatisfy(alphanumeric) { return i + 2 }
        }
        return nil
    }

    private static func normalize(_ input: [UInt8]) throws -> [UInt8] {
        var bytes = input
        var i = 0
        var quoted = false
        while i < bytes.count {
            if quoted {
                if bytes[i] == 92 { i += 2; continue }
                if bytes[i] == 34 { quoted = false }
                i += 1; continue
            }
            if bytes[i] == 34 { quoted = true; i += 1; continue }
            let next = i + 1 < bytes.count ? bytes[i + 1] : 0
            if bytes[i] == 35 || (bytes[i] == 47 && next == 47) {
                while i < bytes.count && bytes[i] != 10 && bytes[i] != 13 { bytes[i] = 32; i += 1 }
            } else if bytes[i] == 47 && next == 42 {
                bytes[i] = 32; bytes[i + 1] = 32; i += 2
                var closed = false
                while i < bytes.count {
                    if bytes[i] == 42 && i + 1 < bytes.count && bytes[i + 1] == 47 {
                        bytes[i] = 32; bytes[i + 1] = 32; i += 2; closed = true; break
                    }
                    if bytes[i] != 10 && bytes[i] != 13 { bytes[i] = 32 }
                    i += 1
                }
                guard closed else { throw TVError.invalidConfiguration }
            } else { i += 1 }
        }
        // Remove trailing commas only outside strings, after comments became whitespace.
        i = 0; quoted = false
        while i < bytes.count {
            if quoted {
                if bytes[i] == 92 { i += 2; continue }
                if bytes[i] == 34 { quoted = false }
            } else if bytes[i] == 34 { quoted = true }
            else if bytes[i] == 44 {
                var end = i + 1
                while end < bytes.count && whitespace(bytes[end]) { end += 1 }
                if end < bytes.count && (bytes[end] == 93 || bytes[end] == 125) { bytes[i] = 32 }
            }
            i += 1
        }
        return bytes
    }
}

import Foundation

/// HLS playlists that players built on FFmpeg or ExoPlayer open and AVPlayer refuses, made acceptable. Each case was
/// tried against AVPlayer: text before `#EXTM3U` (a PHP notice) or no `#EXTM3U` at all fails with -1002 "unsupported
/// URL"; a missing or too small `#EXT-X-TARGETDURATION`, or a variant without `BANDWIDTH`, with -12642; a malformed
/// `CODECS` list with -15517; a space or Chinese character in a segment's address goes out unencoded, and the server
/// answers 400; two renditions of one group with the same name are a parse error. Only what is wrong changes: a
/// well-formed playlist comes back as it was (`HLSProxy` serves the result).
public enum HLSSanitizer {
    public struct Result: Equatable {
        public let text: String
        /// What was repaired, for the log: `header`, `target-duration`, `bandwidth`, `codecs`, `media-names`, `uri-encoding`.
        public let fixes: [String]
    }

    /// The text of a playlist, or nil when the bytes are something else: an HTML or JSON page, a video. A playlist in
    /// GB 18030 (some Chinese servers) is read as such; a UTF-8 byte order mark goes.
    public static func text(_ data: Data) -> String? {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        let head = bytes.prefix(1024)
        // A playlist is text: a NUL among its first bytes is a video or an image.
        guard !head.isEmpty, !head.contains(0), head.range(of: Data("#EXT".utf8)) != nil else { return nil }
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        guard let text = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: gb18030) else { return nil }
        return text.contains("#EXTM3U") || text.contains("#EXTINF") || text.contains("#EXT-X-STREAM-INF") ? text : nil
    }

    public static func sanitize(_ original: String) -> Result {
        var fixes: [String] = []
        func fixed(_ name: String) { if !fixes.contains(name) { fixes.append(name) } }
        var lines = original.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        if lines.first?.hasPrefix("\u{FEFF}") == true { lines[0].removeFirst() }
        // Whatever a script printed before the playlist, or a playlist that never says it is one.
        if let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#EXTM3U") }) {
            if start > 0 || lines[start] != lines[start].trimmingCharacters(in: .whitespaces) {
                if lines[..<start].contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) || lines[start].first?.isWhitespace == true { fixed("header") }
                lines.removeFirst(start)
                lines[0] = lines[0].trimmingCharacters(in: .whitespaces)
            }
        } else {
            lines.insert("#EXTM3U", at: 0)
            fixed("header")
        }

        let master = lines.contains { $0.hasPrefix("#EXT-X-STREAM-INF") }
        var longest = 0.0, target: (index: Int, value: Int)?, segments = 0
        var renditions: [String: Set<String>] = [:]
        for index in lines.indices {
            let line = lines[index]
            let value = line.trimmingCharacters(in: .whitespaces)
            if value.isEmpty { continue }
            if !value.hasPrefix("#") {
                // An address: a space, a Chinese character or a `|` in it is sent as it is, and the server refuses it.
                let encoded = encodeAddress(value)
                if encoded != line { lines[index] = encoded; if encoded != value { fixed("uri-encoding") } }
                if !master { segments += 1 }
                continue
            }
            var tag = line
            if value.hasPrefix("#EXTINF:") {
                longest = max(longest, Double(value.dropFirst(8).prefix { $0 != "," }.trimmingCharacters(in: .whitespaces)) ?? 0)
            } else if value.hasPrefix("#EXT-X-TARGETDURATION:") {
                target = (index, Int(Double(value.dropFirst(22).trimmingCharacters(in: .whitespaces)) ?? 0))
            } else if value.hasPrefix("#EXT-X-STREAM-INF:") {
                if attribute("BANDWIDTH", in: tag) == nil {
                    tag = value.replacingOccurrences(of: "#EXT-X-STREAM-INF:", with: "#EXT-X-STREAM-INF:BANDWIDTH=\(estimatedBandwidth(tag)),")
                    fixed("bandwidth")
                }
                if let codecs = attribute("CODECS", in: tag), !validCodecs(codecs) {
                    tag = removing("CODECS", from: tag)
                    fixed("codecs")
                }
            } else if value.hasPrefix("#EXT-X-MEDIA:"), let name = attribute("NAME", in: tag) {
                let group = "\(attribute("TYPE", in: tag) ?? "")|\(attribute("GROUP-ID", in: tag) ?? "")"
                var unique = name, count = 1
                while renditions[group, default: []].contains(unique) { count += 1; unique = "\(name) \(count)" }
                renditions[group, default: []].insert(unique)
                if unique != name { tag = replacing("NAME", in: tag, with: unique); fixed("media-names") }
            }
            if let address = attribute("URI", in: tag) {
                let encoded = encodeAddress(address)
                if encoded != address { tag = replacing("URI", in: tag, with: encoded); fixed("uri-encoding") }
            }
            if tag != line { lines[index] = tag }
        }
        // Every segment must fit the target duration, rounded (RFC 8216 4.3.3.1); one longer, or none given, fails.
        if !master, segments > 0 {
            let needed = max(1, Int(longest.rounded()))
            if let target, target.value < needed {
                lines[target.index] = "#EXT-X-TARGETDURATION:\(Int(longest.rounded(.up)))"
                fixed("target-duration")
            } else if target == nil {
                lines.insert("#EXT-X-TARGETDURATION:\(max(1, Int(longest.rounded(.up))))", at: 1)
                fixed("target-duration")
            }
        }
        if fixes.isEmpty { return Result(text: original, fixes: []) }
        var text = lines.joined(separator: "\n")
        if !text.hasSuffix("\n") { text += "\n" }
        return Result(text: text, fixes: fixes)
    }

    /// RFC 3986's characters; anything else in an address is percent-encoded, as ExoPlayer and FFmpeg send it.
    private static let addressCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%")
    static func encodeAddress(_ address: String) -> String {
        let value = address.trimmingCharacters(in: .whitespaces)
        guard value.unicodeScalars.contains(where: { !addressCharacters.contains($0) || $0 == "%" }) else { return value }
        // A `%` that doesn't start an escape is a character of its own.
        var result = ""
        let scalars = Array(value.unicodeScalars)
        for (index, scalar) in scalars.enumerated() {
            if scalar == "%", index + 2 < scalars.count, scalars[index + 1].properties.isASCIIHexDigit, scalars[index + 2].properties.isASCIIHexDigit {
                result += "%"
            } else if scalar != "%", addressCharacters.contains(scalar) {
                result.unicodeScalars.append(scalar)
            } else {
                result += String(scalar).utf8.map { String(format: "%%%02X", $0) }.joined()
            }
        }
        return result
    }

    /// A codec list AVPlayer can read: four-character codes, each with its own parameters after a dot.
    static func validCodecs(_ list: String) -> Bool {
        let codecs = list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return !codecs.isEmpty && codecs.allSatisfy { $0.range(of: "^[A-Za-z0-9-]{4}(\\.[A-Za-z0-9.]+)?$", options: .regularExpression) != nil }
    }

    /// A guess at a variant's bandwidth from its resolution: AVPlayer only needs one, to order the variants.
    private static func estimatedBandwidth(_ tag: String) -> Int {
        guard let resolution = attribute("RESOLUTION", in: tag), let height = Int(resolution.split(separator: "x").last ?? "") else { return 2_000_000 }
        return max(500_000, height * 4_000)
    }

    /// An attribute's value in a tag's list, without its quotes.
    static func attribute(_ name: String, in tag: String) -> String? {
        guard let range = attributeRange(name, in: tag) else { return nil }
        let value = String(tag[range])
        return value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 ? String(value.dropFirst().dropLast()) : value
    }

    /// Where an attribute's value is, quotes included: `NAME=` only counts after `:` or `,`, so `NAME` is not found in `GROUP-NAME`.
    private static func attributeRange(_ name: String, in tag: String) -> Range<String.Index>? {
        guard let colon = tag.firstIndex(of: ":") else { return nil }
        var index = tag.index(after: colon)
        while index < tag.endIndex {
            var end = index
            var quoted = false
            while end < tag.endIndex, quoted || tag[end] != "," {
                if tag[end] == "\"" { quoted.toggle() }
                end = tag.index(after: end)
            }
            let pair = tag[index..<end]
            if let equals = pair.firstIndex(of: "="), pair[pair.startIndex..<equals].trimmingCharacters(in: .whitespaces) == name {
                return tag.index(after: equals)..<end
            }
            index = end < tag.endIndex ? tag.index(after: end) : end
        }
        return nil
    }

    private static func replacing(_ name: String, in tag: String, with value: String) -> String {
        guard let range = attributeRange(name, in: tag) else { return tag }
        var result = tag
        result.replaceSubrange(range, with: "\"\(value)\"")
        return result
    }

    private static func removing(_ name: String, from tag: String) -> String {
        guard let range = attributeRange(name, in: tag) else { return tag }
        // The whole `NAME=value` pair, with the comma after it (or, for the last one, the comma before it).
        var start = range.lowerBound
        while start > tag.startIndex, ![",", ":"].contains(tag[tag.index(before: start)]) { start = tag.index(before: start) }
        var end = range.upperBound
        if end < tag.endIndex, tag[end] == "," { end = tag.index(after: end) }
        else if start > tag.startIndex, tag[tag.index(before: start)] == "," { start = tag.index(before: start) }
        var result = tag
        result.removeSubrange(start..<end)
        return result
    }
}

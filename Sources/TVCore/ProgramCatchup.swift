import Foundation

/// An M3U provider's explicit replay declaration. Each alternate line keeps its own template and retention.
public struct ChannelCatchup: Codable, Hashable, Sendable {
    public let mode: String
    public let source: String
    public let days: Int?
    public let replace: String?
    /// IANA name from catchup-timezone; without one, `(b)`/`(e)` times are the device's local time, as a playlist's
    /// `playseek=${(b)yyyyMMddHHmmss}` means.
    public let timeZone: String?
    public init(mode: String = "default", source: String, days: Int? = nil, replace: String? = nil, timeZone: String? = nil) {
        self.mode = mode; self.source = source; self.days = days; self.replace = replace; self.timeZone = timeZone
    }
    public var zone: TimeZone? { timeZone.flatMap(TimeZone.init(identifier:)) ?? (timeZone == nil ? TimeZone.current : nil) }
}

/// Marks the generated address as a finite programme, independently of URL extension or playlist/group name.
/// The original channel identity lets the open guide return to live without putting live lines in replay fallback.
public struct ProgrammeReplay: Codable, Hashable, Sendable {
    public let channelID: String
    public let title: String
    public let start: Date
    public let end: Date
}

public enum ProgramCatchup {
    public static func supports(_ channel: Channel) -> Bool {
        channel.lines.indices.contains { supports(channel, line: $0) }
    }

    public static func supports(_ channel: Channel, line index: Int) -> Bool {
        guard channel.replay == nil, channel.lines.indices.contains(index) else { return false }
        let line = channel.lines[index]
        guard !isRecording(line.url), let spec = line.catchup, spec.days.map({ $0 > 0 }) ?? true else { return false }
        let sample = Programme(title: "", start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 3600))
        return resolve(spec, live: line.url, programme: sample) != nil
    }

    /// Only ended programmes inside the declared retention are offered. Re-evaluate at the instant of selection.
    public static func replay(_ channel: Channel, programme: Programme, line: Int = 0, now: Date = Date()) -> Channel? {
        guard channel.replay == nil, channel.lines.indices.contains(line),
              programme.start.timeIntervalSince1970.isFinite, programme.end.timeIntervalSince1970.isFinite,
              now.timeIntervalSince1970.isFinite, programme.end > programme.start, programme.end <= now else { return nil }
        let live = channel.lines[line]
        guard !isRecording(live.url), let spec = live.catchup else { return nil }
        if let days = spec.days, days <= 0 || now.timeIntervalSince(programme.start) > Double(days) * 86400 { return nil }
        guard let address = resolve(spec, live: live.url, programme: programme) else { return nil }
        let headers = inherited(live.headers, from: live.url, to: address)
        var replay = Channel(name: channel.name + " · " + programme.title, group: channel.group, url: address, logo: channel.logo, headers: headers)
        replay.guideID = channel.guideID
        replay.replay = ProgrammeReplay(channelID: channel.id, title: programme.title, start: programme.start, end: programme.end)
        return replay
    }

    /// Keep history only for explicitly supported channels, with a bounded guide/UI horizon.
    public static func lookback(for channels: [Channel]) -> TimeInterval {
        let days = channels.flatMap { channel in
            channel.lines.indices.filter { supports(channel, line: $0) }.compactMap { channel.lines[$0].catchup }
        }.map { min(31, max(0, $0.days ?? 7)) }.max() ?? 0
        return max(3600, Double(days) * 86400)
    }

    private static func isRecording(_ url: URL) -> Bool {
        ["mp4", "mkv", "mov", "avi", "m4v", "webm", "mp3", "m4a"].contains(url.pathExtension.lowercased())
    }
    private static let placeholders = try! NSRegularExpression(pattern: #"\$?\{([^{}]+)\}"#)
    private static let datePattern = try! NSRegularExpression(pattern: #"^(?:yyyy|MM|dd|HH|mm|ss|[-_:.T/])+$"#)

    private static func resolve(_ spec: ChannelCatchup, live: URL, programme: Programme) -> URL? {
        var source = spec.source
        guard !source.isEmpty, source.utf8.count <= 16384, live.absoluteString.utf8.count <= 32768,
              encoded(source, allowed: .urlQueryAllowed) != nil, let zone = spec.zone else { return nil }
        let matches = placeholders.matches(in: source, range: NSRange(source.startIndex..., in: source))
        guard matches.count <= 64 else { return nil }
        for match in matches.reversed() {
            guard let tag = Range(match.range(at: 1), in: source), let whole = Range(match.range, in: source),
                  let value = render(String(source[tag]), programme: programme, zone: zone) else { return nil }
            source.replaceSubrange(whole, with: value)
        }
        guard !source.contains("{"), !source.contains("}") else { return nil }
        let address: URL?
        switch spec.mode.lowercased() {
        case "default": address = URL(string: source, relativeTo: live)?.absoluteURL
        case "append":
            guard source.hasPrefix("?") || source.hasPrefix("&"), var parts = URLComponents(url: live, resolvingAgainstBaseURL: true) else { return nil }
            if let replace = spec.replace, !replace.isEmpty {
                guard replace.utf8.count <= 2048 else { return nil }
                let pair = replace.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2, !pair[0].isEmpty else { return nil }
                // Literal path replacement must never rewrite a hostname or bytes covered by a query signature.
                let pieces = parts.percentEncodedPath.components(separatedBy: String(pair[0]))
                guard pieces.reduce(0, { $0 + $1.utf8.count }) + (pieces.count - 1) * pair[1].utf8.count <= 32768 else { return nil }
                let path = pieces.joined(separator: String(pair[1]))
                guard let encoded = encoded(path, allowed: .urlPathAllowed) else { return nil }
                parts.percentEncodedPath = encoded
            }
            let query = parts.percentEncodedQuery ?? ""
            let suffix = String(source.dropFirst())
            guard !suffix.contains("#"), let encoded = encoded(suffix, allowed: .urlQueryAllowed) else { return nil }
            parts.percentEncodedQuery = query + (query.isEmpty || query.hasSuffix("&") ? "" : "&") + encoded
            address = parts.url
        default: return nil
        }
        guard let address, address.absoluteString.utf8.count <= 65536,
              ["http", "https"].contains(address.scheme?.lowercased() ?? ""), address.host != nil else { return nil }
        return address
    }

    /// URLComponents' percentEncoded setters trap on malformed '%' input. Validate provider escapes first,
    /// preserving already encoded bytes and their case instead of decoding/re-encoding signatures.
    private static func encoded(_ text: String, allowed: CharacterSet) -> String? {
        let bytes = Array(text.utf8)
        for index in bytes.indices where bytes[index] == 37 {
            guard index + 2 < bytes.count, bytes[(index + 1)...(index + 2)].allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }) else { return nil }
        }
        return text.addingPercentEncoding(withAllowedCharacters: allowed.union(CharacterSet(charactersIn: "%")))
    }

    private static func render(_ token: String, programme: Programme, zone: TimeZone) -> String? {
        // Avoid trapping on corrupt dates or unbounded XMLTV values when converting to Int64.
        func timestamp(_ value: TimeInterval) -> String? {
            guard value.isFinite, value >= -62_135_596_800, value < 253_402_300_800 else { return nil }
            return String(Int64(value))
        }
        switch token {
        case "utc", "utc:timestamp", "start": return timestamp(programme.start.timeIntervalSince1970)
        case "utcend", "utcend:timestamp", "end": return timestamp(programme.end.timeIntervalSince1970)
        case "duration": return timestamp(programme.end.timeIntervalSince(programme.start))
        default: break
        }
        guard token.hasPrefix("(b)") || token.hasPrefix("(e)") else { return nil }
        let date = token.hasPrefix("(b)") ? programme.start : programme.end
        guard timestamp(date.timeIntervalSince1970) != nil else { return nil }
        let format = String(token.dropFirst(3))
        if format == "timestamp" { return timestamp(date.timeIntervalSince1970) }
        guard format.utf8.count <= 64, datePattern.firstMatch(in: format, range: NSRange(format.startIndex..., in: format)) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = format.replacingOccurrences(of: "T", with: "'T'")
        return formatter.string(from: date)
    }

    private static func inherited(_ headers: [String: String], from: URL, to: URL) -> [String: String] {
        func port(_ url: URL) -> Int? { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        let sameOrigin = from.scheme?.lowercased() == to.scheme?.lowercased() && from.host?.lowercased() == to.host?.lowercased() && port(from) == port(to)
        return headers.filter { key, _ in
            let key = key.lowercased()
            if key == "host" { return false }
            return sameOrigin || ["user-agent", "accept", "accept-language"].contains(key)
        }
    }
}

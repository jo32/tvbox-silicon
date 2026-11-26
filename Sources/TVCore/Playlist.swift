import Foundation

public enum Playlist {
    /// `origin`: where relative addresses resolve; nil for a list with no address of its own (`LoopbackPlaylist`), whose
    /// relative addresses are dropped.
    public static func parse(_ text: String, origin: URL?, headers: [String: String] = [:]) throws -> [Channel] {
        // TVBox's JSON live format reads as the TXT lines it stands for.
        if let lines = jsonLines(text) { return try parse(lines, origin: origin, headers: headers) }
        var result: [Channel] = [], seen = Set<String>()
        // Channel addresses this app can't play (rtmp://, rtsp://, P2P), to say so when nothing else is left.
        var otherSchemes = Set<String>()
        // Relative channel addresses in a list without an address of its own: nothing to resolve them against.
        var unresolved = 0
        // Where each named channel is in `result`, by group and name: the same channel again is another line of it.
        var named: [String: Int] = [:]
        var name: String?, logo: URL?, guideID: String?, group = "", entryHeaders = headers
        var defaults: [String: String] = [:], catchup: ChannelCatchup?
        let lines = text.replacingOccurrences(of: "\u{FEFF}", with: "").components(separatedBy: .newlines)
        let m3u = lines.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#EXTINF:") }
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#EXTM3U") {
                defaults = catchupAttributes(in: line)
            } else if line.hasPrefix("#EXTINF:") {
                // Commas inside quoted attributes are not the title separator.
                var quoted = false
                let separator = line.indices.first { i in
                    if line[i] == "\"" { quoted.toggle() }
                    return line[i] == "," && !quoted
                }
                name = separator.map { String(line[line.index(after: $0)...]) } ?? L10n.text("Unnamed channel")
                group = attribute("group-title", in: line) ?? ""
                logo = attribute("tvg-logo", in: line).flatMap { try? WebAddress.resolve($0, relativeTo: origin) }
                guideID = [attribute("tvg-id", in: line), attribute("tvg-name", in: line)]
                    .compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
                entryHeaders = headers
                let declaration = separator.map { String(line[..<$0]) } ?? line
                let attributes = defaults.merging(catchupAttributes(in: declaration)) { _, entry in entry }
                catchup = catchupDeclaration(attributes)
                // APTV-style playlists put the headers on the entry itself; some servers answer only that user agent (#995).
                if let agent = attribute("http-user-agent", in: line), !agent.isEmpty { entryHeaders["User-Agent"] = agent }
                if let referrer = attribute("http-referrer", in: line) ?? attribute("http-referer", in: line), !referrer.isEmpty {
                    entryHeaders["Referer"] = referrer
                }
            } else if line.hasPrefix("#EXTGRP:") {
                group = String(line.dropFirst(8))
            } else if line.hasPrefix("#EXTVLCOPT:") {
                let option = line.dropFirst(11).split(separator: "=", maxSplits: 1).map(String.init)
                if option.count == 2 {
                    if option[0] == "http-user-agent" { entryHeaders["User-Agent"] = option[1] }
                    if option[0] == "http-referrer" { entryHeaders["Referer"] = option[1] }
                }
            } else if !line.hasPrefix("#") {
                var address = line
                if !m3u {
                    let parts = line.split(separator: ",", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { continue }
                    if parts[1].trimmingCharacters(in: .whitespaces) == "#genre#" { group = parts[0]; continue }
                    name = parts[0]; address = parts[1]; entryHeaders = headers
                }
                let lines = addresses(address).compactMap { Self.channelLine($0, headers: entryHeaders, origin: origin, catchup: catchup) }
                guard let first = lines.first else {
                    if let scheme = address.firstMatch(of: /^\s*([A-Za-z][A-Za-z0-9+.-]*):\/\//)?.1.lowercased(), !["http", "https"].contains(scheme) {
                        otherSchemes.insert(scheme)
                    } else if origin == nil, !address.contains("://") { unresolved += 1 }
                    name = nil; catchup = nil; continue
                }
                if let name, let at = named[group + "|" + name] {
                    // The same channel again in its group: another line of it, as TVBox players treat it (#679).
                    for line in lines where line.url != result[at].url && !result[at].alternates.contains(where: { $0.url == line.url }) {
                        result[at].alternates.append(line)
                    }
                } else {
                    var channel = Channel(name: name ?? first.url.lastPathComponent, group: group, url: first.url, logo: logo, headers: first.headers)
                    channel.guideID = guideID
                    channel.catchup = first.catchup
                    for line in lines.dropFirst() where line.url != channel.url && !channel.alternates.contains(where: { $0.url == line.url }) {
                        channel.alternates.append(line)
                    }
                    if seen.insert(channel.id).inserted {
                        if let name { named[group + "|" + name] = result.count }
                        result.append(channel)
                    }
                }
                name = nil; logo = nil; guideID = nil; catchup = nil; entryHeaders = headers
            }
        }
        guard result.isEmpty else { return result }
        if !otherSchemes.isEmpty {
            let schemes = otherSchemes.sorted().prefix(4).map { $0 + "://" }.joined(separator: ", ")
            throw TVError.unsupported(L10n.text("This playlist only has %@ channels, which Apple's player can't play.", schemes))
        }
        if unresolved > 0 { throw TVError.unsupported(L10n.text("This playlist's channel addresses are relative to the Android player that served it, so they can't be opened here.")) }
        let start = text.prefix(512).lowercased()
        if start.contains("<!doctype") || start.contains("<html") {
            throw TVError.unsupported(L10n.text("The playlist address returned a web page instead of a playlist. Its host may be offline."))
        }
        throw TVError.emptyPlaylist
    }

    /// A playlist's text: UTF-8, as most are. A few bad bytes stay as replacement characters, as on Android
    /// players (OkHttp decodes that way), so the channels still load; a list in GBK/GB18030 decodes as that.
    public static func text(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        let lossy = String(decoding: data, as: UTF8.self)
        if lossy.unicodeScalars.lazy.filter({ $0 == "\u{FFFD}" }).count > 8 {
            let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
            if let text = String(data: data, encoding: gb18030) { return text }
        }
        return lossy
    }

    /// TVBox's JSON live list, `[{"group":…,"channels":[{"name":…,"urls":[…]}]}]` (FongMi also writes
    /// `name`/`channel`), as `group,#genre#` and `name,url#url` lines; nil for anything else.
    static func jsonLines(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        guard trimmed.hasPrefix("[") || trimmed.hasPrefix("{"), let value = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)) else { return nil }
        let groups = value.array ?? value.object?["lives"]?.array ?? []
        var lines: [String] = []
        for group in groups {
            guard let fields = group.object, let channels = (fields["channels"] ?? fields["channel"])?.array else { continue }
            lines.append(((fields["group"] ?? fields["name"])?.string ?? "").replacingOccurrences(of: ",", with: " ") + ",#genre#")
            for channel in channels {
                guard let item = channel.object, let name = item["name"]?.string else { continue }
                let urls = (item["urls"]?.array ?? []).compactMap(\.string).filter { $0.contains("://") }
                if !urls.isEmpty { lines.append(name.replacingOccurrences(of: ",", with: " ") + "," + urls.joined(separator: "#")) }
            }
        }
        return lines.contains { !$0.hasSuffix(",#genre#") } ? lines.joined(separator: "\n") : nil
    }
    /// The XMLTV guide an M3U's header names, `#EXTM3U x-tvg-url="…"` (or `url-tvg`); the first when it lists several
    /// (#802).
    public static func guideAddress(in text: String) -> String? {
        let header = text.prefix(4096).replacingOccurrences(of: "\u{FEFF}", with: "").components(separatedBy: .newlines)
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#EXTM3U") }
        guard let header, let value = attribute("x-tvg-url", in: header) ?? attribute("url-tvg", in: header) else { return nil }
        return value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }

    /// TVBox lists a channel's lines in one entry, `url1#url2`. A `#` that doesn't start another address is the
    /// address's own (a fragment).
    static func addresses(_ text: String) -> [String] {
        let pieces = text.components(separatedBy: "#").map { $0.trimmingCharacters(in: .whitespaces) }
        return pieces.count > 1 && pieces.allSatisfy({ $0.contains("://") }) ? pieces : [text]
    }

    /// An address with the entry's headers, and its own after a `|` (`url|User-Agent=…&Referer=…`). A line's name
    /// after a `$` (`url$高清`) is dropped.
    private static func channelLine(_ address: String, headers: [String: String], origin: URL?, catchup: ChannelCatchup?) -> ChannelLine? {
        let parts = address.split(separator: "|", maxSplits: 1).map(String.init)
        guard var first = parts.first else { return nil }
        if let dollar = first.lastIndex(of: "$"), !first[first.index(after: dollar)...].contains(where: { "/=&?".contains($0) }) {
            first = String(first[..<dollar])
        }
        guard let url = try? WebAddress.resolve(first, relativeTo: origin) else { return nil }
        var headers = headers
        if parts.count == 2 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 { headers[kv[0]] = kv[1].removingPercentEncoding ?? kv[1] }
            }
        }
        return ChannelLine(url: url, headers: headers, catchup: catchup)
    }

    private static func catchupAttributes(in text: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: ["catchup", "catchup-source", "catchup-days", "catchup-replace", "catchup-timezone"].compactMap { key in
            attribute(key, in: text, exact: true).map { (key, $0) }
        })
    }
    private static func catchupDeclaration(_ attributes: [String: String]) -> ChannelCatchup? {
        guard let source = attributes["catchup-source"], !source.isEmpty else { return nil }
        // An explicitly malformed/zero retention disables replay instead of silently becoming unlimited.
        let days = attributes["catchup-days"].map { Int($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
        return ChannelCatchup(mode: attributes["catchup"] ?? "default", source: source, days: days,
                              replace: attributes["catchup-replace"], timeZone: attributes["catchup-timezone"])
    }

    private static func attribute(_ key: String, in text: String, exact: Bool = false) -> String? {
        guard let regex = try? NSRegularExpression(pattern: (exact ? "(?:^|\\s)" : "") + NSRegularExpression.escapedPattern(for: key) + "=\"([^\"]*)\""),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

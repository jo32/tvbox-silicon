import Foundation

public enum Playlist {
    public static func parse(_ text: String, origin: URL, headers: [String: String] = [:]) throws -> [Channel] {
        var result: [Channel] = [], seen = Set<String>()
        var name: String?, logo: URL?, group = "", entryHeaders = headers
        let lines = text.replacingOccurrences(of: "\u{FEFF}", with: "").components(separatedBy: .newlines)
        let m3u = lines.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#EXTINF:") }
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#EXTINF:") {
                // Commas inside quoted attributes are not the title separator.
                var quoted = false
                let separator = line.indices.first { i in
                    if line[i] == "\"" { quoted.toggle() }
                    return line[i] == "," && !quoted
                }
                name = separator.map { String(line[line.index(after: $0)...]) } ?? L10n.text("Unnamed channel")
                group = attribute("group-title", in: line) ?? ""
                logo = attribute("tvg-logo", in: line).flatMap { try? WebAddress.resolve($0, relativeTo: origin) }
                entryHeaders = headers
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
                let parts = address.split(separator: "|", maxSplits: 1).map(String.init)
                guard let first = parts.first, let url = try? WebAddress.resolve(first, relativeTo: origin) else { name = nil; continue }
                if parts.count == 2 {
                    for pair in parts[1].split(separator: "&") {
                        let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                        if kv.count == 2 { entryHeaders[kv[0]] = kv[1].removingPercentEncoding ?? kv[1] }
                    }
                }
                let channel = Channel(name: name ?? url.lastPathComponent, group: group, url: url, logo: logo, headers: entryHeaders)
                if seen.insert(channel.id).inserted { result.append(channel) }
                name = nil; logo = nil; entryHeaders = headers
            }
        }
        guard !result.isEmpty else { throw TVError.emptyPlaylist }
        return result
    }
    private static func attribute(_ key: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: key) + "=\"([^\"]*)\""),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

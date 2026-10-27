import Foundation

/// A subtitle file a source offers beside its video: a CatVod play result's `subs`, which cloud-drive
/// plugins fill with the .srt and .ass files in the film's folder.
public struct ExternalSubtitle: Hashable, Sendable {
    public let name: String
    public let url: URL
    /// The source's language code; often empty.
    public let language: String
    /// The source's MIME type (`application/x-subrip`, `text/x-ssa`, `text/vtt`); often empty.
    public let format: String
    public init(name: String, url: URL, language: String = "", format: String = "") {
        self.name = name; self.url = url; self.language = language; self.format = format
    }

    /// `[{"name", "url", "lang", "format"}]`; entries without an HTTP address are left out.
    static func parse(_ value: JSONValue?) -> [ExternalSubtitle] {
        (value?.array ?? []).compactMap { item in
            guard let fields = item.object, let address = fields["url"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            let name = fields["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ExternalSubtitle(name: name.isEmpty ? url.lastPathComponent : name, url: url,
                                    language: fields["lang"]?.string ?? "", format: fields["format"]?.string ?? "")
        }
    }
}

/// SubRip, WebVTT and ASS/SSA files read into cues, for the subtitles of a repackaged stream (`Remux`).
enum SubtitleFile {
    struct Track: Sendable, Equatable {
        var name: String
        var language: String
        /// Microseconds from the start of the video.
        var cues: [RemuxPlan.Cue]
    }

    /// Larger files are not subtitles.
    static let largest = 8 << 20

    /// The files' cues, fetched together. One that fails, holds no cues or isn't there within `timeout` is left out.
    static func load(_ subtitles: [ExternalSubtitle], headers: [String: String], session: URLSession = .shared,
                     timeout: Duration = .seconds(8)) async -> [Track] {
        let wanted = Array(subtitles.prefix(8))
        guard !wanted.isEmpty else { return [] }
        return await withTaskGroup(of: (Int, Track?)?.self) { group in
            for (index, subtitle) in wanted.enumerated() {
                group.addTask { (index, await fetch(subtitle, headers: headers, session: session)) }
            }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            var loaded: [Int: Track] = [:], remaining = wanted.count
            while remaining > 0, let next = await group.next() {
                guard let (index, track) = next else {
                    Diagnostics.shared.record(.warning, "subtitles", "\(remaining) of \(wanted.count) files not loaded in time")
                    break
                }
                remaining -= 1
                loaded[index] = track
            }
            group.cancelAll()
            return wanted.indices.compactMap { loaded[$0] }
        }
    }

    private static func fetch(_ subtitle: ExternalSubtitle, headers: [String: String], session: URLSession) async -> Track? {
        var request = URLRequest(url: subtitle.url, timeoutInterval: 8)
        // A plugin's loopback proxy wants none; a drive's CDN wants the video's.
        if !["127.0.0.1", "localhost"].contains(subtitle.url.host() ?? "") { headers.forEach { request.setValue($1, forHTTPHeaderField: $0) } }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status), data.count <= largest else {
                Diagnostics.shared.record(.warning, "subtitles", "file host=\(subtitle.url.host() ?? "-") status=\(status) bytes=\(data.count)")
                return nil
            }
            let cues = Self.cues(data, format: subtitle.format)
            Diagnostics.shared.record(.info, "subtitles", "file format=\(subtitle.format.isEmpty ? "-" : subtitle.format) bytes=\(data.count) cues=\(cues.count)")
            return cues.isEmpty ? nil : Track(name: subtitle.name, language: subtitle.language, cues: cues)
        } catch {
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                Diagnostics.shared.record(.warning, "subtitles", "file host=\(subtitle.url.host() ?? "-") \(error.localizedDescription)")
            }
            return nil
        }
    }

    /// The cues of a subtitle file, in order. The format comes from its contents; `format` (a MIME type) only
    /// breaks a tie.
    static func cues(_ data: Data, format: String = "") -> [RemuxPlan.Cue] {
        let text = Self.text(data)
        let ass = text.contains("[Events]") || text.range(of: #"(?m)^Dialogue:"#, options: .regularExpression) != nil
            || (format.contains("ssa") && !text.contains("-->"))
        let cues = ass ? assCues(text) : timedCues(text, webVTT: text.hasPrefix("WEBVTT"))
        return cues.sorted { $0.start < $1.start }
    }

    /// The file's text: by its byte order mark, else UTF-8, else GB 18030 or Big5, which Chinese subtitles often use.
    static func text(_ data: Data) -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: data.dropFirst(3), as: UTF8.self) }
        if data.starts(with: [0xFF, 0xFE]), let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) { return text }
        if data.starts(with: [0xFE, 0xFF]), let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) { return text }
        if let text = String(data: data, encoding: .utf8) { return text }
        for encoding in [CFStringEncodings.GB_18030_2000, .big5] {
            let value = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
            if let text = String(data: data, encoding: value) { return text }
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// SubRip and WebVTT: a timing line, then the cue's text up to a blank line. Numbers and cue names before
    /// the timing line, and WebVTT's NOTE and STYLE blocks, have no timing line and are passed over.
    private static func timedCues(_ text: String, webVTT: Bool) -> [RemuxPlan.Cue] {
        var cues: [RemuxPlan.Cue] = []
        var current: (start: Int64, end: Int64)?
        var lines: [String] = []
        func flush() {
            if let timing = current, let value = RemuxPlan.cueText(Data(lines.joined(separator: "\n").utf8), codec: webVTT ? "webvtt" : "subrip") {
                cues.append(RemuxPlan.Cue(start: timing.start, end: max(timing.end, timing.start), text: value))
            }
            current = nil; lines = []
        }
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n") {
            if line.contains("-->"), let match = line.firstMatch(of: timing) {
                flush()
                current = (time(match.1), time(match.2))
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else if current != nil {
                lines.append(line)
            }
        }
        flush()
        return cues
    }

    /// ASS and SSA: each Dialogue line of [Events], its fields named by the Format line before it.
    private static func assCues(_ text: String) -> [RemuxPlan.Cue] {
        var fields = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
        var cues: [RemuxPlan.Cue] = []
        for raw in text.replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Format:") {
                let names = line.dropFirst("Format:".count).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                if names.last == "text" { fields = names }
                continue
            }
            guard line.hasPrefix("Dialogue:"), let start = fields.firstIndex(of: "start"), let end = fields.firstIndex(of: "end") else { continue }
            let values = line.dropFirst("Dialogue:".count).split(separator: ",", maxSplits: fields.count - 1, omittingEmptySubsequences: false)
            guard values.count == fields.count,
                  let from = String(values[start]).firstMatch(of: clock), let to = String(values[end]).firstMatch(of: clock) else { continue }
            // FFmpeg's ASS event, which `cueText` reads: ReadOrder, Layer, Style, Name, margins, Effect, then Text.
            guard let value = RemuxPlan.cueText(Data(("0,0,,,0,0,0,," + values[values.count - 1]).utf8), codec: "ass") else { continue }
            let (first, last) = (time(from.output), time(to.output))
            cues.append(RemuxPlan.Cue(start: first, end: max(last, first), text: value))
        }
        return cues
    }

    /// `01:02:03,456`, `02:03.456` (WebVTT) or `1:02:03.45` (ASS).
    nonisolated(unsafe) private static let clock = /(?:\d+:)?\d{1,2}:\d{1,2}(?:[.,]\d{1,3})?/
    nonisolated(unsafe) private static let timing = /^\s*((?:\d+:)?\d{1,2}:\d{1,2}(?:[.,]\d{1,3})?)\s*-->\s*((?:\d+:)?\d{1,2}:\d{1,2}(?:[.,]\d{1,3})?)/

    /// Microseconds of a clock time.
    static func time(_ value: Substring) -> Int64 {
        let parts = value.split(whereSeparator: { $0 == "." || $0 == "," })
        let clock = parts[0].split(separator: ":").compactMap { Int64($0) }
        let seconds = clock.reduce(0) { $0 * 60 + $1 }
        var fraction: Int64 = 0
        if parts.count > 1 {
            let digits = String(parts[1].prefix(3))
            fraction = (Int64(digits) ?? 0) * [1, 100, 10, 1][digits.count]
        }
        return (seconds * 1000 + fraction) * 1000
    }
}

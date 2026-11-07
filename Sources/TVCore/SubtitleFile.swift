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
        /// The address it came from.
        var source: URL? = nil
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
        do {
            let data = try await download(subtitle.url, headers: headers, session: session)
            let cues = Self.cues(data, format: subtitle.format)
            Diagnostics.shared.record(.info, "subtitles", "file format=\(subtitle.format.isEmpty ? "-" : subtitle.format) bytes=\(data.count) cues=\(cues.count)")
            return cues.isEmpty ? nil : Track(name: subtitle.name, language: subtitle.language, cues: cues, source: subtitle.url)
        } catch {
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                Diagnostics.shared.record(.warning, "subtitles", "file host=\(subtitle.url.host() ?? "-") \(error.localizedDescription)")
            }
            return nil
        }
    }

    /// A subtitle file's bytes, counted as they arrive: one that grows past `limit` is dropped then, not once it has
    /// all been held in memory. A Content-Length over the limit is refused before the body.
    static func download(_ url: URL, headers: [String: String], session: URLSession = .shared, limit: Int = largest) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 8)
        // A plugin's loopback proxy wants none; a drive's CDN wants the video's.
        if !["127.0.0.1", "localhost"].contains(url.host() ?? "") { headers.forEach { request.setValue($1, forHTTPHeaderField: $0) } }
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { bytes.task.cancel(); throw SubtitleLoadError.http(status) }
        guard response.expectedContentLength <= Int64(limit) else { bytes.task.cancel(); throw SubtitleLoadError.tooLarge }
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        var chunk = [UInt8](); chunk.reserveCapacity(64 << 10)
        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count == 64 << 10 {
                data.append(contentsOf: chunk); chunk.removeAll(keepingCapacity: true)
                if data.count > limit { bytes.task.cancel(); throw SubtitleLoadError.tooLarge }
            }
        }
        data.append(contentsOf: chunk)
        guard data.count <= limit else { throw SubtitleLoadError.tooLarge }
        return data
    }

    /// The cues of a subtitle file, in order. The format comes from its contents; `format` (a MIME type) only
    /// breaks a tie.
    static func cues(_ data: Data, format: String = "") -> [RemuxPlan.Cue] {
        let text = Self.text(data)
        return cues(text: text, format: Self.format(text, hint: format))
    }

    static func cues(text: String, format: SubtitleDocument.Format) -> [RemuxPlan.Cue] {
        let cues = bccCues(text) ?? (format.isStyled ? assCues(text) : timedCues(text, webVTT: format == .vtt))
        return cues.sorted { $0.start < $1.start }
    }

    /// The file's format by its contents; a MIME type or file name only breaks a tie.
    static func format(_ text: String, hint: String = "", name: String = "") -> SubtitleDocument.Format {
        let named = (hint + " " + name.lowercased())
        let ass = text.contains("[Events]") || text.range(of: #"(?m)^Dialogue:"#, options: .regularExpression) != nil
            || ((named.contains("ssa") || named.contains("ass")) && !text.contains("-->"))
        if ass { return text.contains("[V4 Styles]") || named.hasSuffix(".ssa") ? .ssa : .ass }
        return text.hasPrefix("WEBVTT") ? .vtt : .srt
    }

    /// The file's text: by its byte order mark, else UTF-8, else Shift-JIS when it reads as Japanese, else GB 18030
    /// or Big5, which Chinese subtitles often use.
    static func text(_ data: Data) -> String {
        text(data, encoding: .automatic) ?? String(decoding: data, as: UTF8.self)
    }

    /// The file's text in `encoding`; nil when the bytes aren't text in it.
    static func text(_ data: Data, encoding: SubtitleEncoding) -> String? {
        if let chosen = encoding.foundation {
            var bytes = data
            if chosen == .utf8, data.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = data.dropFirst(3) }
            if chosen == .utf16LittleEndian, data.starts(with: [0xFF, 0xFE]) { bytes = data.dropFirst(2) }
            if chosen == .utf16BigEndian, data.starts(with: [0xFE, 0xFF]) { bytes = data.dropFirst(2) }
            return String(data: bytes, encoding: chosen)
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: data.dropFirst(3), as: UTF8.self) }
        if data.starts(with: [0xFF, 0xFE]), let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) { return text }
        if data.starts(with: [0xFE, 0xFF]), let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) { return text }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .shiftJIS), japanese(text) { return text }
        for encoding in [SubtitleEncoding.gb18030, .big5] {
            if let value = encoding.foundation, let text = String(data: data, encoding: value) { return text }
        }
        return nil
    }

    /// Japanese writes much of every sentence in kana. Chinese bytes read as Shift-JIS come out as half-width katakana
    /// and kanji, almost never as full-width kana, so a fifth of the letters being kana tells the two apart.
    static func japanese(_ text: String) -> Bool {
        var letters = 0, kana = 0
        for scalar in text.unicodeScalars where scalar.value > 0x7F {
            letters += 1
            if (0x3041...0x30FF).contains(scalar.value) { kana += 1 }
        }
        return letters > 0 && kana * 5 >= letters
    }

    /// Bilibili's subtitles (BCC): JSON whose `body` holds `{from, to, content}` in seconds. Nil for any other text.
    static func bccCues(_ text: String) -> [RemuxPlan.Cue]? {
        guard text.first(where: { !$0.isWhitespace }) == "{", text.contains("\"body\""),
              let json = try? JSONDecoder().decode([String: JSONValue].self, from: Data(text.utf8)),
              let body = json["body"]?.array else { return nil }
        return body.compactMap { item in
            guard let line = item.object, let from = line["from"]?.double, let to = line["to"]?.double,
                  let content = line["content"]?.string, !content.isEmpty else { return nil }
            // Cue text is WebVTT's: its markup characters are escaped.
            let escaped = content.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            return RemuxPlan.Cue(start: Int64(from * 1_000_000), end: Int64(max(from, to) * 1_000_000), text: escaped)
        }
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

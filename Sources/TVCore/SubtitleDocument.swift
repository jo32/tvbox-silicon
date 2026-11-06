import Foundation

/// A subtitle file the app shows over the picture itself (#576): one a source offers beside a video that AVPlayer
/// plays directly (an MP4, an HLS stream), or one the viewer adds while watching. Its cues are kept whole, with the
/// file's bytes, so another text encoding can read it again.
public struct SubtitleDocument: Sendable, Identifiable, Equatable {
    public enum Format: String, Sendable, CaseIterable {
        case srt, vtt, ass, ssa
        /// ASS and SSA lose their styling, positions and effects here: they show as plain lines (#576 M1).
        public var isStyled: Bool { self == .ass || self == .ssa }
    }

    public struct Cue: Sendable, Equatable {
        /// Microseconds from the start of the video, in the file's own clock (before `SubtitleTiming`).
        public var start: Int64, end: Int64
        /// Plain text: the file's markup is gone, its line breaks kept.
        public var text: String
        public init(start: Int64, end: Int64, text: String) { self.start = start; self.end = end; self.text = text }
    }

    /// Stable for the same file at the same address: the selection and its timing follow it.
    public let id: String
    public let name: String
    /// The language the source or the file name gives; often empty.
    public let language: String
    public let format: Format
    public let encoding: SubtitleEncoding
    /// In order of start.
    public let cues: [Cue]
    /// The file as it came, for reading again with another encoding.
    public let data: Data
    /// The latest end among cues up to each index, so a lookup knows how far back a long cue can reach.
    private let reach: [Int64]

    public init(id: String, name: String, language: String = "", data: Data, format hint: String = "", encoding: SubtitleEncoding = .automatic) throws {
        guard data.count <= SubtitleFile.largest else { throw SubtitleLoadError.tooLarge }
        let text = SubtitleFile.text(data, encoding: encoding)
        guard let text else { throw SubtitleLoadError.undecodable }
        let format = SubtitleFile.format(text, hint: hint, name: name)
        let cues = SubtitleFile.cues(text: text, format: format).compactMap { cue -> Cue? in
            let plain = Self.plain(cue.text)
            return plain.isEmpty ? nil : Cue(start: cue.start, end: max(cue.end, cue.start), text: plain)
        }
        guard !cues.isEmpty else { throw SubtitleLoadError.empty }
        self.id = id; self.name = name; self.data = data; self.encoding = encoding; self.format = format
        self.language = language.isEmpty ? SubtitleMatch.language(name) : language
        self.cues = cues
        var latest = Int64.min
        reach = cues.map { latest = max(latest, $0.end); return latest }
    }

    /// The same file read with another encoding.
    public func reading(as encoding: SubtitleEncoding) throws -> SubtitleDocument {
        try SubtitleDocument(id: id, name: name, language: language, data: data, format: format.rawValue, encoding: encoding)
    }

    /// The cues on screen at `time` (microseconds, the file's clock), oldest first.
    public func texts(at time: Int64) -> [String] {
        // The last cue starting at or before `time`; earlier ones still showing are found by walking back while one
        // of them could still reach it.
        var low = 0, high = cues.count
        while low < high {
            let middle = (low + high) / 2
            if cues[middle].start <= time { low = middle + 1 } else { high = middle }
        }
        var index = low - 1, showing: [String] = []
        while index >= 0, reach[index] > time {
            if cues[index].end > time { showing.append(cues[index].text) }
            index -= 1
        }
        return showing.reversed()
    }

    /// WebVTT cue text (what `RemuxPlan.cueText` makes) as plain text.
    static func plain(_ text: String) -> String {
        text.replacing(/<[^>]*>/, with: "")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func == (lhs: SubtitleDocument, rhs: SubtitleDocument) -> Bool {
        lhs.id == rhs.id && lhs.encoding == rhs.encoding && lhs.cues.count == rhs.cues.count
    }
}

/// Why a subtitle file couldn't be shown, in words the player's menu can give.
public enum SubtitleLoadError: Error, Equatable, LocalizedError {
    case tooLarge
    case http(Int)
    case undecodable
    case empty
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .tooLarge: L10n.text("The file is too large to be subtitles.")
        case .http(let status): L10n.text("The server answered %@.", String(status))
        case .undecodable: L10n.text("The text couldn't be read. Try another encoding.")
        case .empty: L10n.text("No subtitles were found in the file.")
        case .unreadable: L10n.text("The file couldn't be opened.")
        }
    }
}

/// The text encodings a subtitle file can be read with. `automatic` goes by the byte order mark, then UTF-8, then
/// Shift-JIS when the text reads as Japanese, then GB 18030 and Big5.
public enum SubtitleEncoding: String, Sendable, CaseIterable, Identifiable, Codable {
    case automatic, utf8, gb18030, big5, shiftJIS, utf16LE, utf16BE
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: L10n.text("Automatic")
        case .utf8: "UTF-8"
        case .gb18030: L10n.text("Simplified Chinese (GB 18030)")
        case .big5: L10n.text("Traditional Chinese (Big5)")
        case .shiftJIS: L10n.text("Japanese (Shift-JIS)")
        case .utf16LE: "UTF-16 LE"
        case .utf16BE: "UTF-16 BE"
        }
    }

    var foundation: String.Encoding? {
        func core(_ encoding: CFStringEncodings) -> String.Encoding {
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
        }
        switch self {
        case .automatic: return nil
        case .utf8: return .utf8
        case .gb18030: return core(.GB_18030_2000)
        case .big5: return core(.big5)
        case .shiftJIS: return .shiftJIS
        case .utf16LE: return .utf16LittleEndian
        case .utf16BE: return .utf16BigEndian
        }
    }
}

/// Moves a subtitle file's clock onto the video's (#576): `display = source × scale + delay`. The delay may be
/// negative, since the whole file is at hand; `scale` corrects a file made for another frame rate's cut.
public struct SubtitleTiming: Codable, Equatable, Sendable {
    /// Seconds later (positive) or earlier.
    public var delay: Double = 0
    public var scale: Double = 1
    public static let delays: ClosedRange<Double> = -30...30
    public static let step: Double = 0.5

    public init(delay: Double = 0, scale: Double = 1) {
        self.delay = min(max(delay.isFinite ? delay : 0, Self.delays.lowerBound), Self.delays.upperBound)
        self.scale = scale.isFinite && scale > 0.5 && scale < 2 ? scale : 1
    }

    public var isIdentity: Bool { delay == 0 && scale == 1 }

    /// The file's time (microseconds) shown at video time `seconds`.
    public func source(at seconds: Double) -> Int64 {
        let value = (seconds - delay) / scale * 1_000_000
        return value.isFinite ? Int64(value.rounded()) : 0
    }

    /// A file timed for one frame rate's cut, played against another's: the subtitle's rate, then the video's.
    public struct Rate: Sendable, Hashable, Identifiable {
        public let from: String, to: String
        public let scale: Double
        public var id: String { from + ">" + to }
        public var title: String { from + " → " + to }
    }
    /// 23.976 is 24000/1001 exactly.
    public static let rates: [Rate] = {
        let film = 24000.0 / 1001.0
        let pairs: [(String, Double, String, Double)] = [("23.976", film, "24", 24), ("24", 24, "23.976", film),
                                                          ("25", 25, "23.976", film), ("23.976", film, "25", 25),
                                                          ("25", 25, "24", 24), ("24", 24, "25", 25)]
        // Frame n is at n/from in the file and at n/to in the video.
        return pairs.map { Rate(from: $0.0, to: $0.2, scale: $0.1 / $0.3) }
    }()

    public var rate: Rate? { Self.rates.first { abs($0.scale - scale) < 1e-9 } }

    public var title: String {
        delay == 0 ? L10n.text("In sync") : String(format: "%+.1f s", delay)
    }
}

/// Each show's subtitle timing, remembered (#576): the next episode of the same show keeps it until reset.
public enum SubtitleTimingStore {
    static let key = "subtitleTimings"
    static let limit = 200

    public static func load(scope: String?, _ defaults: UserDefaults = .standard) -> SubtitleTiming {
        guard let scope, let saved = all(defaults)[scope] else { return SubtitleTiming() }
        return SubtitleTiming(delay: saved.delay, scale: saved.scale)
    }

    public static func save(_ timing: SubtitleTiming, scope: String?, _ defaults: UserDefaults = .standard) {
        guard let scope else { return }
        var timings = all(defaults)
        if timing.isIdentity { timings[scope] = nil } else { timings[scope] = Saved(delay: timing.delay, scale: timing.scale, at: Date().timeIntervalSince1970) }
        if timings.count > limit {
            for old in timings.sorted(by: { $0.value.at < $1.value.at }).prefix(timings.count - limit) { timings[old.key] = nil }
        }
        defaults.set(try? JSONEncoder().encode(timings), forKey: key)
    }

    private struct Saved: Codable { var delay: Double, scale: Double, at: Double }
    private static func all(_ defaults: UserDefaults) -> [String: Saved] {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: Saved].self, from: $0) } ?? [:]
    }
}

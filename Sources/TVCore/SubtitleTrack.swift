import Foundation

/// A subtitle file fetched and parsed into cues the player can draw itself.
///
/// 映匣 hands subtitles to `AVPlayer`, which draws them on the video layer: the track is selectable
/// but its size, opacity and position are fixed. One (`com.ios151.one`) instead draws its own
/// subtitle layer — `SubtitleOverlayView` plus a draggable bubble — which is why its captions can be
/// moved and resized. This type is the missing middle: it turns the subtitle files a source already
/// offers (`ExternalSubtitle`) into timed text, without changing how anything is drawn yet.
///
/// The parser is `SubtitleFile`, which already reads SubRip, WebVTT and ASS for the remuxer. This
/// only publishes it: the remuxer's types are internal to their feature, and a player needs a small
/// stable surface — a track of cues and a lookup by time.
public struct SubtitleTrack: Identifiable, Sendable {

    /// One line of dialogue, in microseconds from the start of the video.
    ///
    /// Microseconds because that is what the existing parser produces and what `CMTime` uses at its
    /// natural scale; converting to seconds at the boundary would invite rounding drift on a long
    /// film.
    public struct Cue: Sendable, Equatable {
        public let start: Int64
        public let end: Int64
        public let text: String
        public init(start: Int64, end: Int64, text: String) {
            self.start = start; self.end = end; self.text = text
        }
        /// Whether this cue is on screen at `time` (microseconds).
        public func covers(_ time: Int64) -> Bool { time >= start && time < end }
    }

    public let name: String
    public let language: String
    public let cues: [Cue]
    /// Stable across launches, for remembering a chosen track.
    public var id: String { name + "|" + language }

    public init(name: String, language: String = "", cues: [Cue]) {
        self.name = name; self.language = language; self.cues = cues
    }

    /// The cue on screen at `time`, if any.
    ///
    /// A binary search would be faster, but a feature-length film has a few thousand cues and this
    /// is called about once a second; a linear scan is honest and cannot be wrong about ordering.
    /// ASS files in the wild are sometimes not sorted despite what the parser guarantees.
    public func cue(at time: Int64) -> Cue? {
        cues.first { $0.covers(time) }
    }

    /// The cue on screen at `seconds`, for a value from `AVPlayer.currentTime()`.
    public func cue(atSeconds seconds: Double) -> Cue? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return cue(at: Int64(seconds * 1_000_000))
    }

    public var isEmpty: Bool { cues.isEmpty }

    // MARK: 装载

    public enum LoadError: Error, Equatable, Sendable {
        /// The file was larger than a subtitle could be, or the request failed.
        case unavailable
        /// The file parsed but held no timed lines.
        case empty
    }

    /// Fetches and parses one subtitle file.
    ///
    /// `format` comes from the source's MIME hint and is only a tie-breaker: the parser sniffs ASS by
    /// its `[Events]` section and WebVTT by its `WEBVTT` header, so a wrong hint rarely matters.
    public static func load(_ subtitle: ExternalSubtitle, headers: [String: String] = [:]) async throws -> SubtitleTrack {
        var request = URLRequest(url: subtitle.url)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count <= SubtitleFile.largest else { throw LoadError.unavailable }
        return try make(data: data, name: subtitle.name, language: subtitle.language, format: subtitle.format)
    }

    /// Parses bytes already in hand, for a subtitle that arrived inside a container or a cache.
    public static func make(data: Data, name: String, language: String = "", format: String = "") throws -> SubtitleTrack {
        let parsed = SubtitleFile.cues(data, format: format)
        guard !parsed.isEmpty else { throw LoadError.empty }
        return SubtitleTrack(
            name: name,
            language: language,
            cues: parsed.map { Cue(start: $0.start, end: $0.end, text: $0.text) }
        )
    }

    /// Every subtitle the source offered, loaded together; the ones that fail are left out rather
    /// than failing the whole set, because one broken file should not hide the others.
    public static func loadAll(_ subtitles: [ExternalSubtitle], headers: [String: String] = [:]) async -> [SubtitleTrack] {
        await withTaskGroup(of: (Int, SubtitleTrack?).self) { group in
            for (index, subtitle) in subtitles.enumerated() {
                group.addTask { (index, try? await load(subtitle, headers: headers)) }
            }
            var loaded: [(index: Int, track: SubtitleTrack)] = []
            for await (index, track) in group {
                if let track { loaded.append((index, track)) }
            }
            // Keep the source's order by the input index, so the list does not reshuffle as
            // responses arrive, and two same-named tracks (different languages) cannot trade places.
            return loaded.sorted { $0.index < $1.index }.map(\.track)
        }
    }
}

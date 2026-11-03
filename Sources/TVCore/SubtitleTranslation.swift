import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// Translates subtitle lines on the device. The app provides one where Apple's Translation framework runs (iPhone,
/// iPad and Mac, from iOS 18 and macOS 15), and the repackager (`Remux`) then offers a foreign-language text subtitle
/// a translated twin in the player's Subtitles menu. Nothing is translated until that twin is chosen; then each
/// segment is translated as AVPlayer asks for it, a little ahead of the picture.
public protocol SubtitleTranslating: Sendable {
    /// The language subtitles are translated into: the app's.
    var target: Locale.Language { get }
    /// Whether the device translates `source` into `target`, now or once the languages are downloaded.
    func supports(_ source: Locale.Language) async -> Bool
    /// The lines in `target`, one for each, in order.
    func translate(_ lines: [String], from source: Locale.Language) async throws -> [String]
}

public enum SubtitleTranslation {
    /// The device's translator, set by the app at launch where it has one.
    public static var translator: (any SubtitleTranslating)? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: (any SubtitleTranslating)?

    /// The most twins one file gets: one for each of its subtitle languages, in their order.
    static let most = 2
    /// How long a segment waits for its translation before it is served as it was: AVPlayer waits for it too.
    static let patience: Duration = .seconds(8)

    /// The subtitle tracks a twin translates, with their languages: the first text subtitle of each language other
    /// than `target`'s (the default one first), leaving out forced subtitles. A track's language is its tag, else
    /// what `detected` found its words to be in.
    static func sources(_ tracks: [RemuxPlan.Track], detected: [Int: Locale.Language], target: Locale.Language) -> [(track: Int, language: Locale.Language)] {
        var chosen: [(track: Int, language: Locale.Language)] = []
        let subtitles = tracks.indices.filter { tracks[$0].kind == .subtitle && tracks[$0].stream.codec != codec && !tracks[$0].stream.isForced }
        for index in subtitles.sorted(by: { (tracks[$0].stream.isDefault ? 0 : 1, $0) < (tracks[$1].stream.isDefault ? 0 : 1, $1) }) {
            guard let language = RemuxPlan.languageTag(tracks[index].stream.language).map(Locale.Language.init(identifier:)) ?? detected[index],
                  let code = language.languageCode, code != target.languageCode,
                  !chosen.contains(where: { $0.language.languageCode == code }) else { continue }
            chosen.append((index, language))
        }
        return chosen.prefix(most).sorted { $0.track < $1.track }
    }

    /// The codec name of a twin's track.
    static let codec = "translated"

    /// The language most of the cues' words are in, when that is clear.
    static func detect(_ cues: [RemuxPlan.Cue]) -> Locale.Language? {
        #if canImport(NaturalLanguage)
        let sample = cues.prefix(80).map { plain($0.text) }.joined(separator: "\n")
        guard sample.count >= 20 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let (language, probability) = recognizer.languageHypotheses(withMaximum: 1).first, probability >= 0.6,
              language != .undetermined else { return nil }
        return Locale.Language(identifier: language.rawValue)
        #else
        return nil
        #endif
    }

    /// A cue's words without WebVTT markup: tags dropped, entities read.
    static func plain(_ text: String) -> String {
        text.replacing(/<[^>]*>/, with: "")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Translated words as WebVTT cue text.
    static func cueText(_ words: String) -> String? {
        let text = words.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\r\n", with: "\n").replacing(/\n{2,}/, with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// The cues in the translator's language, timed as they were. When it fails, or takes longer than `patience`,
    /// they keep their words, and `translated` is false.
    static func translate(_ cues: [RemuxPlan.Cue], from source: Locale.Language, with translator: any SubtitleTranslating,
                          patience: Duration = patience) async -> (cues: [RemuxPlan.Cue], translated: Bool, error: String?) {
        let lines = cues.map { plain($0.text).trimmingCharacters(in: .whitespacesAndNewlines) }
        let wanted = lines.indices.filter { !lines[$0].isEmpty }
        guard !wanted.isEmpty else { return (cues, true, nil) }
        let outcome: Result<[String], Error>? = await withTaskGroup(of: Result<[String], Error>?.self) { group in
            group.addTask {
                do { return .success(try await translator.translate(wanted.map { lines[$0] }, from: source)) } catch { return .failure(error) }
            }
            group.addTask { try? await Task.sleep(for: patience); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        switch outcome {
        case .success(let words) where words.count == wanted.count:
            var translated = cues
            for (position, index) in wanted.enumerated() {
                if let text = cueText(words[position]) { translated[index].text = text }
            }
            return (translated, true, nil)
        case .success(let words): return (cues, false, "lines=\(wanted.count) answers=\(words.count)")
        case .failure(let error): return (cues, false, error.localizedDescription)
        case nil: return (cues, false, "no answer in \(patience)")
        }
    }

    /// The name a twin goes by in the Subtitles menu: "Chinese (Translated from English)".
    static func name(target: Locale.Language, source: Locale.Language) -> String {
        let locale = Locale(identifier: L10n.resolvedLanguage())
        let targetName = locale.localizedString(forIdentifier: target.minimalIdentifier) ?? target.minimalIdentifier
        let sourceName = source.languageCode.flatMap { locale.localizedString(forLanguageCode: $0.identifier) } ?? source.minimalIdentifier
        return L10n.text("%@ (Translated from %@)", targetName, sourceName)
    }
}

#if canImport(Speech) && canImport(AVFoundation)
import Foundation
import AVFoundation
import Speech

/// Builds subtitles from a video's own audio track, on the device.
///
/// This is the answer to a specific and common failure: a file arrives with no subtitles at all.
/// Until now the options were to find another source or watch without them. Rex solves it with
/// downloadable recognition models and a memory-aware model ladder
/// (`settings.subtitle.audio.footer`: recognition runs on device, and when memory is short it falls
/// back to a smaller model for the same language before giving up). That ladder exists because the
/// models are large — which is exactly why this implementation does **not** ship its own.
///
/// Instead it uses `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true` and
/// `addsPunctuation = true`. The consequences, stated plainly because they decide whether the
/// feature is usable at all:
///
/// * **No download, no sideload, no model matrix.** The OS already carries the models and manages
///   their storage; `supportsOnDeviceRecognition` says whether this device has the language.
/// * **No network.** Recognition never leaves the phone, which is the only version of this feature
///   that is acceptable for a private library.
/// * **The language must be installed.** When it is not, the error says so instead of silently
///   sending audio to a server — the default `requiresOnDeviceRecognition = false` behaviour is
///   precisely what must be avoided here.
/// * **Timing is approximate.** `SFTranscriptionSegment` gives a duration per segment, not a frame
///   accurate boundary. Cues are built by accumulating durations and are then normalised against
///   the track's real length, because a cumulative drift over two hours is otherwise visible.
///
/// The result is a normal `SubtitleTrack`, so it feeds the same overlay, the same styling and the
/// same translator as a downloaded subtitle. Nothing downstream knows or cares where it came from.
@available(iOS 17.0, macOS 14.0, tvOS 17.0, *)
public struct SpeechSubtitles: Sendable {

    public enum Failure: Error, Sendable, Equatable {
        /// The OS has no on-device model for this language.
        case languageUnavailable(String)
        /// Microphone or speech permission was refused.
        case notAuthorized
        /// The asset has no audio track, or it could not be read.
        case noAudio
        /// Recognition produced nothing.
        case empty
        case cancelled
        /// The transcriber failed; carries the description.
        case failed(String)
    }

    /// A recognised span, copied out of `SFTranscriptionSegment`.
    ///
    /// `SFTranscriptionSegment` is a reference type that is not `Sendable`, so it cannot cross the
    /// actor boundary out of the recognition callback. Copying the three fields that matter into a
    /// value type is the fix, and it also keeps the rest of this file free of Speech types.
    struct Span: Sendable {
        let text: String
        let start: Double
        let duration: Double
    }

    public init() {}

    /// Whether this device can recognise `language` without a network.
    ///
    /// Checked before starting, because the difference between "on-device" and "sent to a server"
    /// is the whole point of the feature and a silent upgrade to the latter would be a bug.
    public static func canRecogniseOnDevice(_ language: String) -> Bool {
        guard let recogniser = SFSpeechRecognizer(locale: Locale(identifier: language)) else { return false }
        return recogniser.supportsOnDeviceRecognition
    }

    /// The languages this device can handle on device.
    public static func availableLanguages(from candidates: [String]) -> [String] {
        candidates.filter { canRecogniseOnDevice($0) }
    }

    /// Transcribes `asset` and returns a subtitle track.
    ///
    /// `hint` seeds recognition with names that are in the title (character names, places) because
    /// speech recognisers otherwise spell them phonetically; it is the same reason a human subtitler
    /// reads the script first.
    public func transcribe(asset: AVAsset,
                           language: String,
                           name: String,
                           hint: [String] = [],
                           progress: (@Sendable (Double) -> Void)? = nil) async throws -> SubtitleTrack {
        guard Self.canRecogniseOnDevice(language) else { throw Failure.languageUnavailable(language) }
        guard let recogniser = SFSpeechRecognizer(locale: Locale(identifier: language)) else {
            throw Failure.languageUnavailable(language)
        }
        guard recogniser.isAvailable else { throw Failure.languageUnavailable(language) }

        try await Self.requestAuthorization()

        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        let total = duration.isFinite && duration > 0 ? duration : 0

        let request = SFSpeechURLRecognitionRequest(url: (asset as? AVURLAsset)?.url ?? URL(fileURLWithPath: "/dev/null"))
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.taskHint = .dictation
        if !hint.isEmpty { request.contextualStrings = hint }

        let spans = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[Span], Error>) in
            var finished = false
            recogniser.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let error {
                    finished = true
                    continuation.resume(throwing: Failure.failed(error.localizedDescription))
                    return
                }
                guard let result, result.isFinal else { return }
                finished = true
                progress?(1)
                continuation.resume(returning: result.bestTranscription.segments.map {
                    Span(text: $0.substring, start: $0.timestamp, duration: $0.duration)
                })
            }
        }

        guard !spans.isEmpty else { throw Failure.empty }
        return Self.makeTrack(segments: spans, duration: total, name: name, language: language)
    }

    /// Turns recognised segments into cues.
    ///
    /// Segments carry `timestamp` (absolute) on most platforms; where they do not, durations are
    /// accumulated. Either way the last cue's end is stretched to the asset duration when the two
    /// disagree, so the subtitles do not stop a minute before the film does.
    static func makeTrack(segments: [Span], duration: Double,
                          name: String, language: String) -> SubtitleTrack {
        var cues: [SubtitleTrack.Cue] = []
        var cursor: Double = 0

        for segment in segments {
            let start = segment.start.isFinite && segment.start > 0 ? segment.start : cursor
            let length = segment.duration.isFinite && segment.duration > 0 ? segment.duration : 0.8
            let end = start + length
            cursor = end
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            cues.append(SubtitleTrack.Cue(
                start: Int64((start * 1_000_000).rounded()),
                end: Int64((end * 1_000_000).rounded()),
                text: text
            ))
        }

        // Close the gap to the real duration by stretching the final cue only. Adjusting all of them
        // proportionally would move every line away from the speech it belongs to.
        if duration > 0, let last = cues.last, Double(last.end) / 1_000_000 < duration - 2 {
            cues[cues.count - 1] = SubtitleTrack.Cue(
                start: last.start,
                end: Int64((duration * 1_000_000).rounded()),
                text: last.text
            )
        }

        return SubtitleTrack(name: name, language: language, cues: cues)
    }

    static func requestAuthorization() async throws {
        let speech = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else { throw Failure.notAuthorized }
    }
}
#endif

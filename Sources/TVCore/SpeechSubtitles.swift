// Speech recognition is unavailable on tvOS: the framework ships, but `SFSpeechRecognizer`,
// `SFSpeechURLRecognitionRequest` and the authorization status are all marked unavailable there, so
// the target has never compiled with this file. Watch on the TV still plays; it just cannot build
// subtitles from a video's audio, which is a phone-and-Mac feature.
#if canImport(Speech) && canImport(AVFoundation) && !os(tvOS)
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

    /// Where the viewer's chosen recognition language is stored.
    ///
    /// Shared by the settings page that offers the choice and the player that uses it, so the phone
    /// recognises in the language that was picked rather than in whatever the system prefers.
    public static let preferredLanguageKey = SpeechSubtitlePreference.key

    /// The language to recognise in, given what the viewer picked and what this device supports.
    ///
    /// The preference comes first, then the phone's own languages — an empty answer means this
    /// device has no model at all and the item should not be offered.
    public static func preferredLanguage(stored: String) -> String? {
        availableLanguages(from: SpeechSubtitlePreference.candidates(stored: stored)).first
    }

    /// Transcribes `asset` and returns a subtitle track.
    ///
    /// `hint` seeds recognition with names that are in the title (character names, places) because
    /// speech recognisers otherwise spell them phonetically; it is the same reason a human subtitler
    /// reads the script first.
    ///
    /// The audio is pulled through `asset` itself, then recognised in slices. Both details are
    /// load-bearing:
    ///
    /// * **Through the asset, not through the URL.** `SFSpeechURLRecognitionRequest` fetches the
    ///   address itself and carries none of the player's headers, so every source behind a Referer
    ///   check answered it with an error page — which recognition reads as silence, after a full
    ///   download. The asset already knows the headers; exporting from it keeps them.
    /// * **In slices.** One recognition task is good for about a minute of audio. A 45-minute
    ///   episode handed over whole ended early, at whatever the service's cap was, and the request
    ///   asked for final results only, so nothing usable came back at all. Slices are ~55 seconds,
    ///   and each one's timestamps are shifted by where it started.
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

        // Getting the sound off the network is the slow half and the recogniser cannot start until
        // it is done, so it gets its own slice of the progress bar rather than a long 0%.
        progress?(0.02)
        let sound = try await Self.soundFile(from: asset)
        defer { try? FileManager.default.removeItem(at: sound) }
        progress?(0.12)

        let duration = (try? await AVURLAsset(url: sound).load(.duration)).map(CMTimeGetSeconds) ?? 0
        let total = duration.isFinite && duration > 0 ? duration : 0
        let slices = Self.slices(duration: total)
        guard !slices.isEmpty else { throw Failure.noAudio }

        var spans: [Span] = []
        for (index, range) in slices.enumerated() {
            try Task.checkCancellation()
            let piece = try await Self.slice(sound, range: range)
            defer { try? FileManager.default.removeItem(at: piece) }
            let found = try await Self.recognise(piece, recogniser: recogniser, hint: hint)
            let offset = range.start.seconds
            spans += found.map { Span(text: $0.text, start: $0.start + offset, duration: $0.duration) }
            progress?(0.12 + 0.88 * Double(index + 1) / Double(slices.count))
        }

        guard !spans.isEmpty else { throw Failure.empty }
        return Self.makeTrack(segments: spans, duration: total, name: name, language: language)
    }

    // MARK: - Getting the sound

    /// Exports the asset's sound track to a local file.
    ///
    /// Two presets are tried because they fail on different things: AppleM4A re-encodes and handles
    /// odd sample rates, while passthrough keeps a codec the recogniser accepts but refuses some
    /// fragmented streams. Whatever comes out, the file is local, so nothing downstream has to
    /// authenticate again.
    static func soundFile(from asset: AVAsset) async throws -> URL {
        let output = FileManager.default.temporaryDirectory
            .appending(path: "speech-\(UUID().uuidString).m4a")
        if (try? await export(asset, to: output, preset: AVAssetExportPresetAppleM4A)) != nil,
           FileManager.default.fileExists(atPath: output.path) {
            return output
        }
        try? FileManager.default.removeItem(at: output)
        if (try? await export(asset, to: output, preset: AVAssetExportPresetPassthrough)) != nil,
           FileManager.default.fileExists(atPath: output.path) {
            return output
        }
        throw Failure.failed(L10n.text("This video's sound could not be read on this device."))
    }

    /// One 55-second piece of the exported file, as its own file.
    static func slice(_ file: URL, range: CMTimeRange) async throws -> URL {
        let output = FileManager.default.temporaryDirectory
            .appending(path: "speech-\(UUID().uuidString).m4a")
        try await export(AVURLAsset(url: file), to: output,
                         preset: AVAssetExportPresetAppleM4A, range: range)
        return output
    }

    /// Runs one export and waits for it, turning a failed export into a thrown error.
    ///
    /// Cancellation actually stops the export. Without it a viewer who leaves the player mid-way
    /// kept a session writing a 40-minute file until it finished on its own, and the `await` below
    /// never came back — the subscription leaked and the temp file stayed on disk.
    static func export(_ asset: AVAsset,
                       to url: URL,
                       preset: String,
                       range: CMTimeRange? = nil) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw Failure.failed(L10n.text("This video's sound could not be read on this device."))
        }
        session.outputURL = url
        session.outputFileType = .m4a
        session.shouldOptimizeForNetworkUse = false
        if let range { session.timeRange = range }

        let once = Once()
        let handle = ExportHandle(session)
        try await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                once.arm { continuation.resume() }
                session.exportAsynchronously { once.fire() }
            }
            try Task.checkCancellation()
        } onCancel: {
            handle.cancel()
            once.fire()
        }

        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw Failure.failed(session.error?.localizedDescription
                                 ?? L10n.text("This video's sound could not be read on this device."))
        }
    }

    /// Even slices of `duration`, because one recognition task only takes about a minute.
    ///
    /// Slice boundaries land on silence about as often as on a word; an overlap would recognise the
    /// same sentence twice and duplicate the cue, so they butt up against each other instead, and a
    /// word split across the seam is the accepted cost.
    ///
    /// Two edge cases decide the shape. A clip shorter than one slice is one slice — not zero, which
    /// is what a loop that only runs while `start + length < duration` produces. And a final scrap
    /// under a quarter second is folded into the piece before it: the muxer refuses a fragment that
    /// short, and one failed slice fails the whole transcription, so dropping the scrap costs a word
    /// at worst while keeping it costs every subtitle after it.
    static func slices(duration: Double, length: Double = 55) -> [CMTimeRange] {
        guard duration.isFinite, duration > 0, length > 0 else { return [] }
        func tick(_ seconds: Double) -> CMTime {
            CMTime(seconds: seconds, preferredTimescale: 1_000_000)
        }
        guard duration > length else {
            return [CMTimeRange(start: .zero, duration: tick(duration))]
        }

        var cuts: [Double] = []
        var start: Double = 0
        while start + length < duration {
            start += length
            cuts.append(start)
        }
        if let last = cuts.last, duration - last <= 0.25 { cuts.removeLast() }
        cuts.append(duration)

        var edges: [Double] = [0]
        edges.append(contentsOf: cuts)
        return zip(edges, edges.dropFirst()).map { CMTimeRange(start: tick($0), end: tick($1)) }
    }

    /// One recognition task over one local file.
    ///
    /// The completion handler arrives on a queue of the framework's choosing and cancellation comes
    /// from another one, so the "have we answered yet?" state lives behind a lock in `Relay` rather
    /// than in a captured `var` — and cancelling the surrounding task now cancels the recognition
    /// task and answers, instead of leaving a continuation that never resumed.
    static func recognise(_ file: URL,
                          recogniser: SFSpeechRecognizer,
                          hint: [String]) async throws -> [Span] {
        let request = SFSpeechURLRecognitionRequest(url: file)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.taskHint = .dictation
        if !hint.isEmpty { request.contextualStrings = hint }

        let relay = Relay<[Span]>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[Span], Error>) in
                relay.arm(continuation)
                relay.attach(recogniser.recognitionTask(with: request) { result, error in
                    if let error {
                        // A cancelled task reports `kAFAssistantErrorDomain 216`; that is the
                        // cancellation we asked for, not a reason to show an error.
                        if (error as NSError).code == 216 {
                            relay.finish(.failure(CancellationError()))
                        } else {
                            relay.finish(.failure(Failure.failed(error.localizedDescription)))
                        }
                        return
                    }
                    guard let result, result.isFinal else { return }
                    relay.finish(.success(result.bestTranscription.segments.map {
                        Span(text: $0.substring, start: $0.timestamp, duration: $0.duration)
                    }))
                })
            }
        } onCancel: {
            relay.cancel()
        }
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

/// Carries an export session into the cancellation handler.
///
/// `AVAssetExportSession` is not `Sendable` and never will be, but cancellation arrives on whatever
/// thread cancelled the task, and all it needs to do is ask the session to stop.
final class ExportHandle: @unchecked Sendable {
    private let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
    func cancel() { session.cancelExport() }
}

/// Runs one piece of work exactly once, whichever thread gets there first.
///
/// `AVAssetExportSession` reports completion on a queue of its own and is cancelled from another,
/// so a captured `var done = false` would be read and written from two threads at once. The lock
/// also covers the ordering: an export can finish before the continuation has been registered, and
/// the late registration then has to run immediately instead of waiting forever.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?
    private var used = false

    func arm(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        if used {
            lock.unlock()
            action()
            return
        }
        self.action = action
        lock.unlock()
    }

    func fire() {
        lock.lock()
        guard !used else {
            lock.unlock()
            return
        }
        used = true
        let action = self.action
        self.action = nil
        lock.unlock()
        action?()
    }
}

/// Answers one continuation exactly once, from either the recogniser's callback or a cancellation.
///
/// Kept separate from `Once` because the answer carries a value, and because cancellation has to
/// hang on to the recognition task so it can be stopped — otherwise a viewer who backs out of the
/// player leaves the recogniser running to the end of the clip.
final class Relay<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pending: Result<Value, Error>?
    private var task: SFSpeechRecognitionTask?

    func arm(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let pending {
            lock.unlock()
            continuation.resume(with: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func attach(_ task: SFSpeechRecognitionTask) {
        lock.lock()
        let finished = continuation == nil && pending != nil
        if !finished { self.task = task }
        lock.unlock()
        if finished { task.cancel() }
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard let continuation else {
            if pending == nil { pending = result }
            lock.unlock()
            return
        }
        self.continuation = nil
        self.task = nil
        lock.unlock()
        continuation.resume(with: result)
    }

    func cancel() {
        lock.lock()
        let task = self.task
        self.task = nil
        lock.unlock()
        task?.cancel()
        finish(.failure(CancellationError()))
    }
}
#endif

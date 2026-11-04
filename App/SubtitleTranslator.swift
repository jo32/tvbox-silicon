import SwiftUI
import TVCore
#if canImport(Translation) && !os(tvOS)
import Translation
#endif

extension View {
    /// Hosts the device's subtitle translation (`OnDeviceSubtitleTranslator`) while the player is up: Apple's
    /// Translation only translates inside a view, and it asks there to download a language the first time. Nothing
    /// runs until a translated subtitle is chosen.
    @ViewBuilder func subtitleTranslation() -> some View {
        #if canImport(Translation) && !os(tvOS)
        if #available(iOS 18.0, macOS 15.0, *) { modifier(SubtitleTranslationHost()) } else { self }
        #else
        self
        #endif
    }
}

enum SubtitleTranslationSetup {
    /// Gives the repackager the device's translator where Apple's Translation runs (iOS 18 and macOS 15 on; not on
    /// Apple TV), into the language the app is shown in.
    static func install() {
        #if canImport(Translation) && !os(tvOS)
        if #available(iOS 18.0, macOS 15.0, *) {
            SubtitleTranslation.translator = OnDeviceSubtitleTranslator(target: Locale.Language(identifier: L10n.resolvedLanguage()))
        }
        #endif
    }
}

#if canImport(Translation) && !os(tvOS)
/// Apple's on-device Translation, for the translated subtitles the repackager offers (`SubtitleTranslating`).
@available(iOS 18.0, macOS 15.0, *)
struct OnDeviceSubtitleTranslator: SubtitleTranslating {
    let target: Locale.Language

    func supports(_ source: Locale.Language) async -> Bool {
        await LanguageAvailability().status(from: source, to: target) != .unsupported
    }

    func translate(_ lines: [String], from source: Locale.Language) async throws -> [String] {
        try await SubtitleTranslationQueue.shared.translate(lines, from: source, to: target)
    }
}

/// The repackager's requests, in order, for the session the player's view holds (`subtitleTranslation()`). A session
/// translates one pair of languages, so a request in another pair starts a new one once this one has nothing left.
@available(iOS 18.0, macOS 15.0, *)
@MainActor @Observable final class SubtitleTranslationQueue {
    static let shared = SubtitleTranslationQueue()
    /// The pair the view's session translates; nil until the first request.
    private(set) var configuration: TranslationSession.Configuration?
    @ObservationIgnored private var jobs: [Job] = []
    @ObservationIgnored private var wake: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var serving = false
    /// Pairs that failed lately (a language download declined, say), with when: their requests fail at once for a
    /// while instead of asking again for every segment.
    @ObservationIgnored private var failed: [String: Date] = [:]
    private static let pause: TimeInterval = 120

    private struct Job: Sendable {
        let id: UUID, source: Locale.Language, target: Locale.Language, lines: [String]
        let continuation: CheckedContinuation<[String], Error>
        var pair: String { "\(source.minimalIdentifier)>\(target.minimalIdentifier)" }
    }

    nonisolated func translate(_ lines: [String], from source: Locale.Language, to target: Locale.Language) async throws -> [String] {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task { @MainActor in self.add(Job(id: id, source: source, target: target, lines: lines, continuation: continuation)) }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    private func add(_ job: Job) {
        if let when = failed[job.pair], Date().timeIntervalSince(when) < Self.pause {
            return job.continuation.resume(throwing: TVError.unsupported("translation paused after a failure"))
        }
        jobs.append(job)
        if !serving, configuration?.source != job.source || configuration?.target != job.target {
            configuration = TranslationSession.Configuration(source: job.source, target: job.target)
        }
        wake?.resume()
        wake = nil
    }

    private func cancel(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    /// Runs inside the view's `translationTask` for as long as there is work in the session's languages. It stays off
    /// the main actor, which holds only the queue: the session is the task's, and Translation works it elsewhere.
    nonisolated func serve(_ session: TranslationSession) async {
        guard let (source, target) = await begin() else { return }
        while !Task.isCancelled {
            switch await next(source: source, target: target) {
            case .job(let job):
                do {
                    let requests = job.lines.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
                    var lines = job.lines
                    for response in try await session.translations(from: requests) {
                        if let index = response.clientIdentifier.flatMap(Int.init), lines.indices.contains(index) { lines[index] = response.targetText }
                    }
                    job.continuation.resume(returning: lines)
                } catch {
                    job.continuation.resume(throwing: error)
                    // The others in this pair would fail the same way.
                    if !(error is CancellationError), !Task.isCancelled { await fail(job.pair, error) }
                }
            case .elsewhere: return await end()
            case .none: await waitForWork()
            }
        }
        await end()
    }

    private enum Next { case job(Job), elsewhere, none }

    private func begin() -> (Locale.Language?, Locale.Language?)? {
        guard let configuration else { return nil }
        serving = true
        return (configuration.source, configuration.target)
    }

    private func end() { serving = false }

    private func next(source: Locale.Language?, target: Locale.Language?) -> Next {
        if let index = jobs.firstIndex(where: { $0.source == source && $0.target == target }) { return .job(jobs.remove(at: index)) }
        guard let next = jobs.first else { return .none }
        // Another pair of languages: a session of its own.
        configuration = TranslationSession.Configuration(source: next.source, target: next.target)
        return .elsewhere
    }

    private func fail(_ pair: String, _ error: any Error) {
        failed[pair] = Date()
        for other in jobs where other.pair == pair { other.continuation.resume(throwing: error) }
        jobs.removeAll { $0.pair == pair }
    }

    private func waitForWork() async {
        guard jobs.isEmpty else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { wake = $0 }
        } onCancel: {
            Task { @MainActor in self.wake?.resume(); self.wake = nil }
        }
    }
}

@available(iOS 18.0, macOS 15.0, *)
private struct SubtitleTranslationHost: ViewModifier {
    @State private var queue = SubtitleTranslationQueue.shared
    func body(content: Content) -> some View {
        content.translationTask(queue.configuration) { @Sendable [queue] session in await queue.serve(session) }
    }
}
#endif

// MARK: - AI translation as the repackager's translator

/// Makes the AI translator usable through the same `SubtitleTranslating` seam the device's
/// Translation uses, so the repackager offers an AI-translated twin with no change on its side.
///
/// The two are not competitors; they fail in opposite places. Apple's Translation is free and
/// offline but only covers the language pairs iOS ships (Rex's own footer lists twelve and says so).
/// An OpenAI-compatible service covers any pair — including the source's own dialect — for the price
/// of an API key and a network round trip per batch of cues.
///
/// `supports` answers true for any pair: the service is not consulted ahead of time because asking
/// would cost a request per language just to render a menu. A wrong key surfaces on the first real
/// translation, as a failed twin the viewer can ignore.
struct AITranslatorAdapter: SubtitleTranslating {
    let configuration: SubtitleTranslator.Configuration
    let target: Locale.Language

    init(configuration: SubtitleTranslator.Configuration) {
        self.configuration = configuration
        // The protocol asks for the language in the app's own term; the configuration already
        // holds the BCP-47 string the service expects.
        self.target = Locale.Language(identifier: configuration.targetLanguage)
    }

    func supports(_ source: Locale.Language) async -> Bool {
        // Anything but the target itself is worth offering.
        source.languageCode != target.languageCode
    }

    func translate(_ lines: [String], from source: Locale.Language) async throws -> [String] {
        // Build a track from the lines so the batching and the count check are the ones already
        // written, then read the text back out in the same order.
        let cues = lines.enumerated().map { index, text in
            SubtitleTrack.Cue(start: Int64(index) * 1_000_000,
                              end: Int64(index + 1) * 1_000_000,
                              text: text)
        }
        let track = SubtitleTrack(name: "lines", language: source.minimalIdentifier, cues: cues)
        let translated = try await SubtitleTranslator().translate(track, configuration: configuration)
        return translated.cues.map(\.text)
    }
}

extension SubtitleTranslationSetup {
    /// Prefers a configured AI service over the device's translation, when the viewer has filled one
    /// in. Falls back to whatever `install()` already set, so an unconfigured app behaves as before.
    ///
    /// Called after `install()`: the AI configuration, when present, replaces the device translator.
    @MainActor
    static func installAI(configuration: SubtitleTranslator.Configuration?) {
        guard let configuration, configuration.isComplete else { return }
        SubtitleTranslation.translator = AITranslatorAdapter(configuration: configuration)
    }
}

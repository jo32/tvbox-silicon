import Foundation

/// Translates subtitles with an OpenAI-compatible chat API.
///
/// 映匣 shows whatever language the source shipped. When that is not a language the viewer reads,
/// the only options used to be "watch it anyway" or "find another source". Rex answers this by
/// sending each cue to a model with the lines around it for context; the wording of its own default
/// prompt is the useful part, and is reproduced here:
///
/// > Translate meaning, tone, register, humor, slang, and implied subjects using nearby subtitle
/// > context.
///
/// That is why this sends a window of cues rather than one cue at a time. A single line has no
/// antecedent for "it", no way to tell a name from a noun, and no register to match. A window of
/// six either side fixes most of that without the cost of sending the whole file.
///
/// The API shape is the one every Chinese provider now speaks: a `POST` to
/// `{base}/chat/completions` with `messages` and a JSON reply. Rex ships presets for 豆包 / GLM /
/// Kimi / 通义千问 / 硅基流动; the same five are listed here because a preset that fills in the
/// base URL is the difference between a working feature and a form nobody can complete.
///
/// Deliberately not included: token accounting, model downloads, or a fallback to on-device
/// translation. Those belong to the caller.
public struct SubtitleTranslator: Sendable {

    /// A provider preset: enough to build a request without asking the viewer for a URL.
    public struct Provider: Identifiable, Sendable, Hashable {
        public let name: String
        /// The base the `/chat/completions` path is appended to.
        public let baseURL: String
        /// A model that is cheap enough for subtitles and good enough for prose.
        public let model: String
        public var id: String { name }

        /// Rex's five, in its own order.
        public static let known: [Provider] = [
            Provider(name: "Doubao", baseURL: "https://ark.cn-beijing.volces.com/api/v3", model: ""),
            Provider(name: "GLM", baseURL: "https://open.bigmodel.cn/api/paas/v4", model: "glm-4-flash"),
            Provider(name: "Kimi", baseURL: "https://api.moonshot.cn/v1", model: "moonshot-v1-8k"),
            Provider(name: "Qwen", baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen-turbo"),
            Provider(name: "SiliconFlow", baseURL: "https://api.siliconflow.cn/v1", model: "Qwen/Qwen2.5-7B-Instruct"),
        ]
    }

    /// What to send. Everything except `apiKey` has a usable default.
    public struct Configuration: Sendable {
        public var baseURL: String
        public var model: String
        public var apiKey: String
        /// The language to translate into, as the model should name it.
        public var targetLanguage: String
        /// Extra instructions, appended to the built-in rules. Empty by default.
        public var extraInstructions: String
        /// How many cues on each side to send as context.
        public var contextWindow: Int

        public init(baseURL: String, model: String, apiKey: String, targetLanguage: String,
                    extraInstructions: String = "", contextWindow: Int = 6) {
            self.baseURL = baseURL
            self.model = model
            self.apiKey = apiKey
            self.targetLanguage = targetLanguage
            self.extraInstructions = extraInstructions
            self.contextWindow = max(0, contextWindow)
        }

        public init(provider: Provider, apiKey: String, targetLanguage: String,
                    extraInstructions: String = "", contextWindow: Int = 6) {
            self.init(baseURL: provider.baseURL, model: provider.model, apiKey: apiKey,
                      targetLanguage: targetLanguage, extraInstructions: extraInstructions,
                      contextWindow: contextWindow)
        }

        var isComplete: Bool {
            !baseURL.isEmpty && !model.isEmpty && !apiKey.isEmpty && !targetLanguage.isEmpty
        }
    }

    public enum Failure: Error, Sendable, Equatable {
        /// The configuration is missing a field.
        case incomplete
        /// The provider answered with a non-200 status. Carries the code and a short body.
        case rejected(status: Int, body: String)
        /// The reply was not the JSON shape expected.
        case malformedReply
        /// The model returned a different number of lines than it was given.
        case lineCountMismatch(expected: Int, got: Int)
    }

    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    /// The instruction block. Kept as a function so the target language can be spliced in, and so
    /// the rules stay next to the reason for them.
    private func systemPrompt(for configuration: Configuration) -> String {
        var rules = """
        You translate subtitles. Reply with the translations only, one per line, in the same order \
        and the same count as the input. Do not add numbering, quotes, or commentary.

        Translate meaning, tone, register, humor, slang, and implied subjects using nearby subtitle \
        context. Keep names as they would be written in \(configuration.targetLanguage). Keep line \
        breaks inside a cue. If a line is a sound effect in brackets, translate it as an interjection \
        rather than describing it.

        The subtitles are in \(configuration.targetLanguage)'s target language when the request \
        reaches you; translate into \(configuration.targetLanguage).
        """
        if !configuration.extraInstructions.isEmpty {
            rules += "\n\nAdditionally: " + configuration.extraInstructions
        }
        return rules
    }

    /// Translates every cue, returning a track with the same timings and translated text.
    ///
    /// Cues are sent in batches of `contextWindow * 2 + 1`. Each batch is translated on its own, so
    /// a long film is many small requests rather than one huge one — that keeps a single bad reply
    /// from losing the whole file, and keeps each request inside a context limit.
    public func translate(_ track: SubtitleTrack,
                          configuration: Configuration,
                          progress: (@Sendable (Double) -> Void)? = nil) async throws -> SubtitleTrack {
        guard configuration.isComplete else { throw Failure.incomplete }
        let cues = track.cues
        guard !cues.isEmpty else { return track }

        let batchSize = max(1, configuration.contextWindow * 2 + 1)
        var translated: [SubtitleTrack.Cue] = []
        translated.reserveCapacity(cues.count)

        var start = 0
        while start < cues.count {
            try Task.checkCancellation()
            let end = min(start + batchSize, cues.count)
            let batch = Array(cues[start..<end])
            let lines = try await translateBatch(batch, configuration: configuration)
            for (cue, text) in zip(batch, lines) {
                translated.append(SubtitleTrack.Cue(start: cue.start, end: cue.end, text: text))
            }
            start = end
            progress?(Double(start) / Double(cues.count))
        }

        return SubtitleTrack(name: track.name, language: configuration.targetLanguage, cues: translated)
    }

    /// One request for one batch.
    private func translateBatch(_ batch: [SubtitleTrack.Cue],
                                configuration: Configuration) async throws -> [String] {
        // Context comes from the batch itself: the prompt already sees the neighbours, so the
        // input is just the batch in order. Empty cues are kept as empty lines so the reply's
        // line count still matches.
        let input = batch.map { $0.text.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\n")

        var request = URLRequest(url: url(for: configuration))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + configuration.apiKey, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": configuration.model,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": systemPrompt(for: configuration)],
                ["role": "user", "content": input],
            ],
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.malformedReply }
        guard http.statusCode == 200 else {
            throw Failure.rejected(status: http.statusCode,
                                   body: String(decoding: data.prefix(300), as: UTF8.self))
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { throw Failure.malformedReply }

        let lines = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                // Some providers wrap replies in quotes or number them despite being told not to.
                var text = String(line).trimmingCharacters(in: .whitespaces)
                if let range = text.range(of: #"^\d+[.)]\s*"#, options: .regularExpression) {
                    text.removeSubrange(range)
                }
                if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
                    text = String(text.dropFirst().dropLast())
                }
                return text
            }

        // Trailing blank lines are common; drop only those, so a genuinely empty cue in the middle
        // still lines up.
        var trimmed = lines
        while let last = trimmed.last, last.isEmpty { trimmed.removeLast() }

        guard trimmed.count == batch.count else {
            throw Failure.lineCountMismatch(expected: batch.count, got: trimmed.count)
        }
        return trimmed
    }

    private func url(for configuration: Configuration) -> URL {
        let base = configuration.baseURL.hasSuffix("/")
            ? String(configuration.baseURL.dropLast())
            : configuration.baseURL
        return URL(string: base + "/chat/completions") ?? URL(string: "https://invalid.invalid")!
    }
}

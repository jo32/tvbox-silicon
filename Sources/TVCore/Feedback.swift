import Foundation

/// Feedback written in Settings, posted as an issue on the app's public GitHub repository by the
/// error-report server (Services/error-reports, /v1/feedback). The server holds the GitHub token, so
/// nobody needs a GitHub account. The issue is public: the message, the app and system versions, the
/// device model and the app's language. The install's random ID goes to the server only, which keeps
/// it with the issue number, so the developer can find the same install's error reports.
public enum Feedback {
    public enum Kind: String, CaseIterable, Codable, Sendable {
        case bug, idea, other
        public var title: String {
            switch self {
            case .bug: L10n.text("Problem")
            case .idea: L10n.text("Suggestion")
            case .other: L10n.text("Other")
            }
        }
    }

    public struct Issue: Decodable, Equatable, Sendable {
        public let number: Int
        public let url: URL
    }

    public enum Failure: LocalizedError, Equatable {
        /// The server's caps, as its 429 names them: a minute's for this network, or the last 24 hours' for
        /// this install (`max` messages) or for everyone. `until` is when one more message fits.
        case tooFast
        case installLimit(max: Int, until: Date?)
        case everyoneLimit(until: Date?)
        /// A 429 that doesn't say which cap (a server from before it did).
        case tooMany
        case failed
        public var errorDescription: String? {
            switch self {
            case .tooFast: L10n.text("You're sending feedback too quickly. Wait a minute and try again.")
            case .installLimit(let max, let until):
                until.map { L10n.text("You can send %lld messages in 24 hours and have sent them all. You can send another after %@.", max, Feedback.moment($0)) }
                    ?? L10n.text("You can send %lld messages in 24 hours and have sent them all. Please try again tomorrow.", max)
            case .everyoneLimit(let until):
                until.map { L10n.text("Today's feedback from everyone has reached its limit. You can send yours after %@.", Feedback.moment($0)) }
                    ?? L10n.text("Today's feedback from everyone has reached its limit. Please try again later.")
            case .tooMany: L10n.text("You've sent a lot of feedback. Please try again later.")
            case .failed: L10n.text("Couldn't send feedback. Please try again later.")
            }
        }
    }

    /// Which cap refused a message, from the server's 429 body `{"limit", "max", "retryAfter"}` (seconds).
    static func refusal(_ data: Data, now: Date = Date()) -> Failure {
        struct Body: Decodable { let limit: String; let max: Int?; let retryAfter: Double? }
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { return .tooMany }
        let until = body.retryAfter.flatMap { $0.isFinite && $0 > 0 ? now.addingTimeInterval($0) : nil }
        switch body.limit {
        case "minute": return .tooFast
        case "install": return body.max.map { .installLimit(max: $0, until: until) } ?? .tooMany
        case "everyone": return .everyoneLimit(until: until)
        default: return .tooMany
        }
    }

    /// A time later today, or a day and time.
    static func moment(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened) : date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Characters kept; the server cuts there too.
    public static let limit = 5000
    static let endpoint = URL(string: "https://yingxia-reports.getmegaportal.com/v1/feedback")!

    /// What goes with a message, as the issue shows it, so the page can say so before it is sent.
    public struct Details: Sendable {
        public let app, system, model, language: String
    }

    public static var details: Details {
        let system = switch ErrorReports.platform { case "tvos": "tvOS"; case "ios": "iOS"; default: "macOS" }
        return Details(app: "\(ErrorReports.bundleValue("CFBundleShortVersionString")) (\(ErrorReports.bundleValue("CFBundleVersion")))",
                       system: "\(system) \(ErrorReports.osVersion)", model: ErrorReports.model, language: L10n.resolvedLanguage())
    }

    /// What the app was set up with and played lately, as text the page puts under the message for
    /// the viewer to edit or delete before sending: the subscriptions (with why one last failed) and
    /// the latest playback history. Sign-in parts of addresses are masked; the rest is public.
    public static func context(subscriptions: [SubscriptionEntry], errors: [String: String] = [:],
                               history: [PlaybackHistoryEntry], timeZone: TimeZone = .current) -> String {
        var lines = ["Subscriptions:"]
        if subscriptions.isEmpty { lines.append("- none") }
        for entry in subscriptions.prefix(contextItems) {
            let address = shareable(entry.address)
            lines.append("- " + (entry.name.isEmpty ? address : "\(entry.name): \(address)") + (entry.enabled ? "" : " (off)"))
            if let error = errors[entry.address] { lines.append("  - failed: " + error.prefix(200)) }
        }
        if subscriptions.count > contextItems { lines.append("- and \(subscriptions.count - contextItems) more") }
        lines += ["", "Recently played:"]
        if history.isEmpty { lines.append("- nothing") }
        let time = Date.ISO8601FormatStyle(dateSeparator: .dash, dateTimeSeparator: .space, timeZone: timeZone)
            .year().month().day().time(includingFractionalSeconds: false).timeZone(separator: .omitted)
        for entry in history.prefix(contextItems) {
            let item = entry.context
            let title = item.episodeName.isEmpty || item.episodeName == item.videoName ? item.videoName : "\(item.videoName) · \(item.episodeName)"
            let source = item.sourceName.isEmpty || item.sourceName == item.sourceKey ? item.sourceKey : "\(item.sourceName) (\(item.sourceKey))"
            let place = entry.duration > 0 ? "\(clock(entry.position)) / \(clock(entry.duration))" : clock(entry.position)
            lines.append("- \(title), \(source), \(place), \(entry.updatedAt.formatted(time))")
        }
        return lines.joined(separator: "\n")
    }

    static let contextItems = 5

    /// An address without what signs in with it: the user and password, and query values named
    /// like a key or token. A local file keeps only its name.
    static func shareable(_ address: String) -> String {
        guard var parts = URLComponents(string: address), let scheme = parts.scheme?.lowercased() else { return address }
        if scheme == "file" { return "file: " + (parts.path.split(separator: "/").last.map(String.init) ?? "") }
        if parts.user != nil || parts.password != nil { parts.user = "***"; parts.password = nil }
        let secret = ["token", "key", "pass", "pwd", "auth", "sign", "secret", "cookie", "session", "sid", "ticket", "uid", "user"]
        parts.queryItems = parts.queryItems?.map { item in
            let name = item.name.lowercased()
            return secret.contains(where: name.contains) && item.value?.isEmpty == false ? URLQueryItem(name: item.name, value: "***") : item
        }
        return parts.string ?? address
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// The message and, after a blank line, whatever is left of the context.
    public static func combined(_ message: String, context: String) -> String {
        let context = context.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return context.isEmpty ? message : message + "\n\n" + context
    }

    public static func send(_ message: String, kind: Kind, defaults: UserDefaults = .standard) async throws -> Issue {
        #if DEBUG
        // Debug builds and simulators only send with `-qaFeedback <url>` (e.g. a local `wrangler dev`).
        guard let address = defaults.string(forKey: "qaFeedback").flatMap(URL.init(string:)) else { throw Failure.failed }
        #else
        let address = endpoint
        #endif
        var request = URLRequest(url: address, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload(message, kind: kind, install: ErrorReports.shared.install))
        let (data, response) = try await URLSession.shared.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200..<300:
            guard let issue = try? JSONDecoder().decode(Issue.self, from: data) else { throw Failure.failed }
            remember(issue, message: message, kind: kind, defaults: defaults)
            return issue
        case 429: throw refusal(data)
        default: throw Failure.failed
        }
    }

    struct Payload: Encodable {
        let install, platform, os, model, lang, app, build, kind, message: String
    }

    static func payload(_ message: String, kind: Kind, install: String) -> Payload {
        Payload(install: install, platform: ErrorReports.platform, os: ErrorReports.osVersion, model: ErrorReports.model,
                lang: L10n.resolvedLanguage(), app: ErrorReports.bundleValue("CFBundleShortVersionString"),
                build: ErrorReports.bundleValue("CFBundleVersion"), kind: kind.rawValue,
                message: String(message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit)))
    }

    // MARK: Your Feedback
    // The issues sent from this device, kept here (the server forgets the install's after 30 days), and
    // how each is doing on GitHub: asked from the server only while Send Feedback is open.

    public struct Sent: Codable, Equatable, Identifiable, Sendable {
        public let number: Int
        public let url: URL
        public let title: String
        public let kind: Kind
        public let date: Date
        /// How many replies the viewer has read, so newer ones can be marked.
        public var seen = 0
        public var id: Int { number }
    }

    static let sentKey = "feedbackSent"
    static let sentLimit = 20
    /// How many of the newest are asked about; the server answers no more.
    public static let checked = 10

    /// Newest first.
    public static func sent(defaults: UserDefaults = .standard) -> [Sent] {
        defaults.data(forKey: sentKey).flatMap { try? JSONDecoder().decode([Sent].self, from: $0) } ?? []
    }

    static func save(_ list: [Sent], defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(Array(list.prefix(sentLimit))) { defaults.set(data, forKey: sentKey) }
    }

    static func remember(_ issue: Issue, message: String, kind: Kind, date: Date = Date(), defaults: UserDefaults) {
        let sent = Sent(number: issue.number, url: issue.url, title: title(message), kind: kind, date: date)
        save([sent] + self.sent(defaults: defaults).filter { $0.number != issue.number }, defaults: defaults)
    }

    /// The viewer has read an issue's first `replies` replies.
    public static func markSeen(_ number: Int, replies: Int, defaults: UserDefaults = .standard) {
        var list = sent(defaults: defaults)
        guard let index = list.firstIndex(where: { $0.number == number }), list[index].seen != replies else { return }
        list[index].seen = replies
        save(list, defaults: defaults)
    }

    /// The message's first line, as the server titles the issue.
    static func title(_ message: String) -> String {
        let line = message.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return line.count > 80 ? String(line.prefix(79)).trimmingCharacters(in: .whitespaces) + "…" : line
    }

    /// An issue's state and the developer's replies, oldest first (Services/error-reports, /v1/feedback/replies).
    public struct Status: Decodable, Equatable, Sendable {
        /// Closed is done; declined is closed as not planned.
        public enum State: String, Decodable, Sendable { case open, closed, declined }
        public struct Reply: Decodable, Equatable, Hashable, Sendable {
            public let date: Date
            public let text: String
        }
        public let number: Int
        public let state: State
        public let replies: [Reply]
    }

    /// The newest issues' statuses by number. Ones that are gone, or no longer feedback, are left out.
    public static func statuses(of numbers: [Int], defaults: UserDefaults = .standard) async throws -> [Int: Status] {
        guard !numbers.isEmpty else { return [:] }
        #if DEBUG
        guard let base = defaults.string(forKey: "qaFeedback").flatMap(URL.init(string:)) else { throw Failure.failed }
        #else
        let base = endpoint
        #endif
        let issues = numbers.prefix(checked).map(String.init).joined(separator: ",")
        let address = base.appending(path: "replies").appending(queryItems: [URLQueryItem(name: "issues", value: issues)])
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: address, timeoutInterval: 20))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.failed }
        return try statuses(data)
    }

    static func statuses(_ data: Data) throws -> [Int: Status] {
        struct Body: Decodable { let issues: [Status] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return Dictionary(try decoder.decode(Body.self, from: data).issues.map { ($0.number, $0) }) { first, _ in first }
    }

    /// A reply's markdown (links, bold, code) as text; lists and headings stay as written.
    public static func reply(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

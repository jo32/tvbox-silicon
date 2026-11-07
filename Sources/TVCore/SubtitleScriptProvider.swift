import Foundation

/// A subtitle source written as a script (#576 M2), on its own QuickJS runtime: the TVBox prelude, then
/// `assets://subtitles/prelude.js`, then the script, which sets `subtitleSource = { manifest, search, resolve }`.
///
/// The script reaches only the sites its manifest lists (`SubtitleHost`), loads no code from elsewhere, keeps
/// nothing on disk and logs nothing: what it handles (keys, signed addresses, subtitle text) stays out of the
/// diagnostics. One call runs at a time; each ends by its deadline, and requests it left running are cancelled.
public final class SubtitleScriptProvider: SubtitleProvider, @unchecked Sendable {
    public let manifest: SubtitleProviderManifest
    private let session: ScriptSession
    private let host: SubtitleHost
    private let turns = Turns()
    /// A source that answers with more than this is cut short.
    static let maximumCandidates = 50

    private init(manifest: SubtitleProviderManifest, session: ScriptSession, host: SubtitleHost) {
        self.manifest = manifest; self.session = session; self.host = host
    }
    deinit { host.cancelAll(); session.close() }

    /// Runs `script` and reads its manifest; a script this build can't run is refused here.
    public static func load(script: String, label: String) async throws -> SubtitleScriptProvider {
        let host = SubtitleHost()
        let profile = ScriptAssets.profiles.appendingPathComponent("subtitles-" + PluginChecksum.sha256(Data(label.utf8)).prefix(16), isDirectory: true)
        let session = try await ScriptSession.start(module: "assets://subtitles/prelude.js", supplied: ["subtitles://source": script],
                                                    profile: profile, label: "subtitles " + label, extension: host)
        let envelope = await session.evaluate("__subtitles.load()", within: 10)
        do {
            guard let value = envelope["value"] else {
                throw SubtitleProviderError.incompatible(String((envelope["error"]?.string ?? "").prefix(200)))
            }
            let manifest = try JSONDecoder().decode(SubtitleProviderManifest.self, from: JSONEncoder().encode(value))
            try manifest.validate()
            host.allow(manifest)
            return SubtitleScriptProvider(manifest: manifest, session: session, host: host)
        } catch let error as SubtitleProviderError {
            session.close(); throw error
        } catch {
            session.close(); throw SubtitleProviderError.incompatible(L10n.text("Its manifest can't be read."))
        }
    }

    public func search(_ hint: SubtitleHint, credentials: [String: String], within seconds: Double) async throws -> [SubtitleCandidate] {
        let value = try await call("search", Self.json(hint), credentials: credentials, seconds: seconds)
        guard let list = value.array else {
            if case .null = value { return [] }
            throw SubtitleProviderError.failed(L10n.text("The source answered something unexpected."))
        }
        return list.prefix(Self.maximumCandidates).compactMap { candidate($0) }
    }

    public func resolve(_ candidate: SubtitleCandidate, credentials: [String: String], within seconds: Double) async throws -> SubtitleResource {
        let value = try await call("resolve", Self.json(candidate), credentials: credentials, seconds: seconds)
        guard let object = value.object else { throw SubtitleProviderError.failed(L10n.text("The source answered something unexpected.")) }
        let url = object["url"]?.string.flatMap(URL.init(string:))
        let text = object["text"]?.string
        guard url != nil || text != nil else { throw SubtitleProviderError.downloadFailed(L10n.text("The source gave no file.")) }
        let expires: Date? = object["expires"].flatMap { value in
            if case .number(let seconds) = value { return Date(timeIntervalSince1970: seconds > 1e11 ? seconds / 1000 : seconds) }
            return value.string.flatMap { ISO8601DateFormatter().date(from: $0) }
        }
        return SubtitleResource(url: url, headers: object["headers"]?.object?.compactMapValues(\.string) ?? [:], text: text,
                                name: object["name"]?.string, format: object["format"]?.string, expires: expires)
    }

    /// One call of the script's `search` or `resolve`, after any call before it has ended.
    private func call(_ name: String, _ argument: String, credentials: [String: String], seconds: Double) async throws -> JSONValue {
        await turns.take()
        defer { Task { await turns.give() } }
        try Task.checkCancellation()
        let context = Self.json(Context(credentials: credentials, languages: SubtitleHint.preferredLanguages()))
        let started = Date()
        let reply = await session.evaluate("__subtitles.call(\(MusicExtensionSession.literal(name)), \(argument), \(context))", within: seconds)
        host.cancelAll()
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        if let value = reply["value"]?.object {
            if let failure = value["error"]?.object {
                let error = SubtitleProviderError(kind: failure["kind"]?.string ?? "failed", message: failure["message"]?.string ?? "", retryAfter: failure["retryAfter"]?.int)
                // The kind only: a script's own message can hold an address or a key.
                Diagnostics.shared.record(.warning, "subtitles", "source=\(manifest.id) \(name) failed kind=\(error.kind) ms=\(elapsed)")
                throw error
            }
            Diagnostics.shared.record(.info, "subtitles", "source=\(manifest.id) \(name) ms=\(elapsed) results=\(value["value"]?.array?.count ?? 1)")
            return value["value"] ?? .null
        }
        let message = reply["error"]?.string ?? ""
        if message.contains("interrupted") || Double(elapsed) >= seconds * 1000 {
            Diagnostics.shared.record(.warning, "subtitles", "source=\(manifest.id) \(name) timed out ms=\(elapsed)")
            throw SubtitleProviderError.timeout
        }
        Diagnostics.shared.record(.warning, "subtitles", "source=\(manifest.id) \(name) script error ms=\(elapsed)")
        throw SubtitleProviderError.failed(L10n.text("The source failed."))
    }

    private func candidate(_ value: JSONValue) -> SubtitleCandidate? {
        guard let item = value.object, let key = item["id"]?.string, !key.isEmpty else { return nil }
        func flag(_ name: String) -> Bool {
            switch item[name] {
            case .bool(let on)?: on
            case .number(let number)?: number != 0
            default: false
            }
        }
        let title = item["title"]?.string ?? item["name"]?.string ?? key
        return SubtitleCandidate(provider: manifest.id, providerName: manifest.name, key: key, title: String(title.prefix(300)),
                                 language: item["language"]?.string ?? "", format: item["format"]?.string?.lowercased(),
                                 forced: flag("forced"), hearingImpaired: flag("hearingImpaired"), season: item["season"]?.int, episode: item["episode"]?.int,
                                 fileMatch: flag("fileMatch"), downloads: item["downloads"]?.int,
                                 url: item["url"]?.string.flatMap(URL.init(string:)), token: item["token"]?.string)
    }

    static func json(_ value: some Encodable) -> String {
        String(decoding: (try? JSONEncoder().encode(value)) ?? Data("null".utf8), as: UTF8.self)
    }

    private struct Context: Encodable { let credentials: [String: String]; let languages: [String] }

    /// One call at a time, in the order they came.
    private actor Turns {
        private var busy = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        func take() async {
            guard busy else { busy = true; return }
            await withCheckedContinuation { waiting.append($0) }
        }
        func give() {
            if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
        }
    }
}

/// The host side of a subtitle source's script: requests to the manifest's sites only, each redirect hop
/// checked again (the prelude follows them), and no code loaded from anywhere but the app.
final class SubtitleHost: ScriptHostExtension, @unchecked Sendable {
    private let lock = NSLock()
    private var manifest: SubtitleProviderManifest?
    private let pending = PendingRequests()
    var allowsRemoteModules: Bool { false }
    deinit { pending.cancelAll() }

    func allow(_ manifest: SubtitleProviderManifest) { lock.withLock { self.manifest = manifest } }
    func cancelAll() { pending.cancelAll() }

    func answer(_ operation: String, _ argument: String) throws -> String?? {
        guard operation.hasPrefix("subtitle.") else { return nil }
        switch operation.dropFirst("subtitle.".count) {
        case "httpStart":
            var options = (try? JSONSerialization.jsonObject(with: Data(argument.utf8))) as? [String: Any] ?? [:]
            let address = options["url"] as? String ?? ""
            let url = URL(string: address)
            // Before the manifest is read (the script's first run), nothing is reachable.
            guard let url, let manifest = lock.withLock({ manifest }), manifest.allows(url) else {
                throw ScriptHostError("blocked:" + (url?.host() ?? "?"))
            }
            options["redirect"] = false
            let json = String(decoding: try JSONSerialization.data(withJSONObject: options), as: UTF8.self)
            let id = pending.add()
            let cancel = try ScriptHTTP.start(json) { [pending] answer in pending.finish(id, answer) }
            pending.setCancel(id, cancel)
            return .some(String(id))
        case "httpPoll": return .some(pending.take(Int(argument) ?? -1))
        case "httpCancel": pending.cancel(Int(argument) ?? -1); return .some(nil)
        default: return nil
        }
    }
}

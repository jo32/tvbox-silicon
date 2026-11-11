import Foundation
import CoreGraphics

/// Runs Venera comic sources (github.com/venera-app/venera-configs) in-process on QuickJS: one runtime per
/// source, with Venera's script API (ScriptAssets/venera) answered by MangaHost.
public actor MangaRuntime {
    public static let shared = MangaRuntime()
    /// Posted on the main queue when a source shows a message (userInfo "source", "text").
    public static let noticeNotification = Notification.Name("MangaRuntime.notice")
    /// Posted when a site makes requests wait (拷贝漫画's 210); userInfo "host", "seconds".
    public static let throttleNotification = Notification.Name("MangaRuntime.throttle")
    /// Chapters' page lists for a while: reopening one (Continue, the chapter list) doesn't ask the site again.
    private var pageLists: [String: (date: Date, pages: [String])] = [:]
    /// Comics' details for a while too, as the open-source copymanga clients keep them (30 min): reading on from a
    /// comic's page and coming back doesn't ask the site again. Try Again asks afresh.
    private var detailsKept: [String: (date: Date, details: MangaDetails)] = [:]
    /// Explore pages' first screens for ten minutes: going back to a source doesn't ask the site again.
    private var exploreKept: [String: (date: Date, value: (shelves: [MangaShelf], page: MangaPage))] = [:]

    final class Session: @unchecked Sendable {
        let script: ScriptSession
        let host: MangaHost
        let info: MangaSourceInfo
        let revision: String
        /// The page being unscrambled (MangaRuntime.modify), which the next one waits for.
        var modifying: Task<Void, Never>?
        init(script: ScriptSession, host: MangaHost, info: MangaSourceInfo, revision: String) { self.script = script; self.host = host; self.info = info; self.revision = revision }
    }
    private var sessions: [String: Session] = [:]
    private var starting: [String: Task<Session, Error>] = [:]

    /// Loads a source's script on its own and describes it, without keeping it (for installing).
    public func inspect(code: String) async throws -> MangaSourceInfo {
        let session = try await Self.start(key: "inspect-" + UUID().uuidString.prefix(8), code: code, revision: "")
        session.script.close()
        return session.info
    }

    public func info(_ key: String) async throws -> MangaSourceInfo { try await session(key).info }

    /// Drops a running source, e.g. after it was updated or removed.
    public func reset(_ key: String) {
        sessions.removeValue(forKey: key)?.script.close()
        starting.removeValue(forKey: key)?.cancel()
        pageLists = pageLists.filter { !$0.key.hasPrefix(key + "|") }
        detailsKept = detailsKept.filter { !$0.key.hasPrefix(key + "|") }
        exploreKept = exploreKept.filter { !$0.key.hasPrefix(key + "|") }
    }

    func session(_ key: String) async throws -> Session {
        guard let installed = MangaSources.shared.installed(key) else { throw TVError.unsupported(L10n.text("This comic source is no longer installed.")) }
        if let session = sessions[key], session.revision == installed.revision { return session }
        if let task = starting[key] { return try await task.value }
        sessions.removeValue(forKey: key)?.script.close()
        let task = Task { () throws -> Session in
            let code = try MangaSources.shared.code(key)
            return try await Self.start(key: key, code: code, revision: installed.revision)
        }
        starting[key] = task
        defer { starting[key] = nil }
        let session = try await task.value
        sessions[key] = session
        return session
    }

    static func start(key: String, code: String, revision: String, profile: URL? = nil) async throws -> Session {
        let host = MangaHost(sourceKey: key)
        let profile = profile ?? MangaLibrary.root.appendingPathComponent("Profiles/\(key)", isDirectory: true)
        let script = try await ScriptSession.start(module: "assets://venera/prelude.js", supplied: [:], profile: profile, label: "manga \(key)", extension: host)
        guard let api = ScriptAssets.bundled("assets://venera/init.js") else { script.close(); throw TVError.unsupported(L10n.text("The comic source runtime is missing from this build.")) }
        // A global script, so its classes and `let`s (ComicSource, Network, ...) are globals the source can see.
        let booted = await script.evaluate(api + "\n;true", within: 30)
        if let error = booted["error"]?.string { script.close(); throw TVError.unsupported(L10n.text("Comic source error: %@", String(error.prefix(300)))) }
        do {
            let value = try await call(script, "__venera.load(\(json(code)))", seconds: 60)
            return Session(script: script, host: host, info: try MangaSourceInfo(value), revision: revision)
        } catch {
            script.close()
            throw error
        }
    }

    /// Evaluates a `__venera` call and unwraps its {value} or {error}.
    private static func call(_ script: ScriptSession, _ expression: String, seconds: Double) async throws -> Any? {
        let envelope = await script.evaluate("Promise.resolve(\(expression)).then(value => JSON.stringify(value))", within: seconds)
        if let error = envelope["error"]?.string { throw TVError.unsupported(MangaRuntime.readable(error)) }
        guard let text = envelope["value"]?.string,
              let answer = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) as? [String: Any] else {
            throw TVError.unsupported(L10n.text("The comic source returned nothing."))
        }
        if let error = answer["error"] as? String { throw TVError.unsupported(MangaRuntime.readable(error)) }
        return answer["value"]
    }

    static func readable(_ error: String) -> String {
        let first = error.split(separator: "\n").first.map(String.init) ?? error
        if first.contains("did not finish in time") { return L10n.text("The comic source took too long to answer.") }
        return String(first.prefix(400))
    }

    static func json(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "null" }
        return (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    /// Calls the source's function at `path` with JSON-able arguments.
    public func call(_ key: String, _ path: String, _ arguments: [Any?], seconds: Double = 60) async throws -> Any? {
        let session = try await session(key)
        let started = ContinuousClock.now, since = Date()
        do {
            let value = try await Self.call(session.script, "__venera.call(\(Self.json(path)), \(Self.json(arguments.map { $0 ?? NSNull() })))", seconds: seconds)
            Diagnostics.shared.record(.info, "manga.call", "source=\(key) \(path) ok \(started.duration(to: .now))")
            return value
        } catch {
            Diagnostics.shared.record(.error, "manga.call", "source=\(key) \(path) failed: \(error.localizedDescription.prefix(300))")
            // The script's message ("Invalid status code: 403") hides why; the site's answer says.
            if var problem = MangaSiteProblem.latest(since: since) {
                problem.detail = error.localizedDescription
                throw problem
            }
            throw error
        }
    }

    func raw(_ key: String, _ expression: String, seconds: Double = 30) async throws -> Any? {
        try await Self.call(try await session(key).script, expression, seconds: seconds)
    }

    func host(_ key: String) async throws -> MangaHost { try await session(key).host }
}

// MARK: - The Venera API, typed

extension MangaRuntime {
    public func explore(_ key: String, page index: Int, cursor: MangaCursor?) async throws -> (shelves: [MangaShelf], page: MangaPage) {
        let kept = "\(key)|explore|\(index)"
        if cursor == nil, let entry = exploreKept[kept], Date().timeIntervalSince(entry.date) < 10 * 60 { return entry.value }
        let value = try await exploreAfresh(key, page: index, cursor: cursor)
        if cursor == nil { exploreKept[kept] = (Date(), value) }
        return value
    }

    private func exploreAfresh(_ key: String, page index: Int, cursor: MangaCursor?) async throws -> (shelves: [MangaShelf], page: MangaPage) {
        let info = try await info(key)
        guard info.explore.indices.contains(index) else { return ([], MangaPage(comics: [], next: nil)) }
        let page = info.explore[index]
        switch page.type {
        case "multiPartPage", "singlePageWithMultiPart":
            let value = try await call(key, "explore.\(index).load", [NSNull()])
            if let parts = value as? [Any] {
                return (parts.compactMap { Self.shelf($0, source: key) }, MangaPage(comics: [], next: nil))
            }
            // singlePageWithMultiPart: {title: [comics]}
            let shelves = MangaValue.pairs(value).map { MangaShelf(title: $0.0, comics: MangaComic.list($0.1, source: key), viewMore: nil) }
            return (shelves.filter { !$0.comics.isEmpty }, MangaPage(comics: [], next: nil))
        case "mixed":
            let number: Int
            if case .page(let value) = cursor { number = value } else { number = 1 }
            let value = try await call(key, "explore.\(index).load", [number]) as? [String: Any]
            var shelves: [MangaShelf] = [], comics: [MangaComic] = []
            for part in value?["data"] as? [Any] ?? [] {
                if part is [Any] { comics += MangaComic.list(part, source: key) } else if let shelf = Self.shelf(part, source: key) { shelves.append(shelf) }
            }
            let maxPage = MangaValue.int(value?["maxPage"])
            return (shelves, MangaPage(comics: comics, next: maxPage.map { number < $0 ? .page(number + 1) : nil } ?? nil))
        default:
            return ([], try await list(key, page.paged ? "explore.\(index).load" : "explore.\(index).loadNext", cursor: cursor, paged: page.paged) { $0 })
        }
    }

    private static func shelf(_ value: Any?, source: String) -> MangaShelf? {
        guard let item = value as? [String: Any] else { return nil }
        let comics = MangaComic.list(item["comics"], source: source)
        guard !comics.isEmpty else { return nil }
        return MangaShelf(title: MangaValue.string(item["title"]) ?? "", comics: comics, viewMore: MangaJump(item["viewMore"]))
    }

    /// A paged list: `load(..., page)` answering {comics, maxPage}, or `loadNext(..., next)` answering {comics, next}.
    private func list(_ key: String, _ path: String, cursor: MangaCursor?, paged: Bool, arguments: ([Any?]) -> [Any?]) async throws -> MangaPage {
        if paged {
            var number = 1
            if case .page(let value) = cursor { number = value }
            let value = try await call(key, path, arguments([number])) as? [String: Any]
            let comics = MangaComic.list(value?["comics"], source: key)
            let maxPage = MangaValue.int(value?["maxPage"])
            let more = maxPage.map { number < $0 } ?? !comics.isEmpty
            return MangaPage(comics: comics, next: more && !comics.isEmpty ? .page(number + 1) : nil)
        }
        var token: Any? = nil
        if case .token(let value) = cursor { token = value }
        let value = try await call(key, path, arguments([token])) as? [String: Any]
        let comics = MangaComic.list(value?["comics"], source: key)
        return MangaPage(comics: comics, next: MangaValue.string(value?["next"]).map { .token($0) })
    }

    public func search(_ key: String, keyword: String, options: [String?], cursor: MangaCursor?) async throws -> MangaPage {
        let info = try await info(key)
        guard info.canSearch else { return MangaPage(comics: [], next: nil) }
        return try await list(key, info.searchPaged ? "search.load" : "search.loadNext", cursor: cursor, paged: info.searchPaged) { [keyword, options.map { value -> Any in value ?? NSNull() }] + $0 }
    }

    public func category(_ key: String, name: String, param: String?, options: [String], cursor: MangaCursor?) async throws -> MangaPage {
        try await list(key, "categoryComics.load", cursor: cursor, paged: true) { [name, param ?? NSNull(), options] + $0 }
    }

    public func ranking(_ key: String, option: String, cursor: MangaCursor?) async throws -> MangaPage {
        try await list(key, "categoryComics.ranking.load", cursor: cursor, paged: true) { [option] + $0 }
    }

    public func details(_ key: String, id: String, fresh: Bool = false) async throws -> MangaDetails {
        let kept = "\(key)|\(id)"
        if !fresh, let entry = detailsKept[kept], Date().timeIntervalSince(entry.date) < 30 * 60 { return entry.details }
        let details = try MangaDetails(try await call(key, "comic.loadInfo", [id], seconds: 120), id: id, source: key)
        if detailsKept.count > 60 { detailsKept = detailsKept.filter { Date().timeIntervalSince($0.value.date) < 30 * 60 } }
        detailsKept[kept] = (Date(), details)
        return details
    }

    /// Page image addresses of a chapter (`nil` for a one-shot comic).
    public func pages(_ key: String, comic: String, chapter: String?) async throws -> [String] {
        let id = "\(key)|\(comic)|\(chapter ?? "")"
        if let kept = pageLists[id], Date().timeIntervalSince(kept.date) < 30 * 60 { return kept.pages }
        // Long enough for a site's waits: 拷贝漫画's script sleeps 40 s per "too many requests".
        let value = try await call(key, "comic.loadEp", [comic, chapter ?? NSNull()], seconds: 180) as? [String: Any]
        let images = MangaValue.strings(value?["images"])
        guard !images.isEmpty else { throw TVError.unsupported(L10n.text("This chapter has no pages.")) }
        if pageLists.count > 40 { pageLists = pageLists.filter { Date().timeIntervalSince($0.value.date) < 30 * 60 } }
        pageLists[id] = (Date(), images)
        return images
    }

    public func signIn(_ key: String, account: String, password: String) async throws {
        _ = try await call(key, "account.login", [account, password])
        MangaSourceData.shared.set(key, "account", [account, password])
    }

    public func signIn(_ key: String, cookies: [String]) async throws {
        let valid = try await call(key, "account.loginWithCookies.validate", [cookies]) as? Bool ?? false
        guard valid else { throw TVError.unsupported(L10n.text("The source did not accept these cookies.")) }
        MangaSourceData.shared.set(key, "account", "ok")
    }

    public func signOut(_ key: String) async {
        _ = try? await call(key, "account.logout", [])
        MangaSourceData.shared.set(key, "account", nil)
    }

    public func runSettingCallback(_ key: String, setting: String) async throws {
        _ = try await call(key, "settings.\(setting).callback", [])
    }

    /// Headers (and a possibly different address) for covers, from the source's onThumbnailLoad.
    public func thumbnailRequests(_ key: String, urls: [String]) async -> [String: (url: String, headers: [String: String])] {
        guard (try? await info(key))?.hasThumbnailConfig == true, !urls.isEmpty else { return [:] }
        guard let value = try? await raw(key, "__venera.thumbnailHeaders(\(Self.json(urls)))") as? [String: Any] else { return [:] }
        var out: [String: (url: String, headers: [String: String])] = [:]
        for (url, item) in value {
            guard let item = item as? [String: Any] else { continue }
            out[url] = (MangaValue.string(item["url"]) ?? url, (item["headers"] as? [String: Any] ?? [:]).compactMapValues { MangaValue.string($0) })
        }
        return out
    }

    struct ImageConfig {
        var id: Int
        var request: MangaHTTP.Request
        var onResponse: Bool
        var modifyImage: Bool
        var onLoadFailed: Bool
    }

    func imageConfig(_ key: String, kind: String, url: String, comic: String?, chapter: String?) async throws -> ImageConfig {
        let value = try await raw(key, "__venera.imageConfig(\(Self.json(kind)), \(Self.json(url)), \(Self.json(comic)), \(Self.json(chapter)))") as? [String: Any] ?? [:]
        let address = MangaValue.string(value["url"]) ?? url
        guard let target = URL(string: address) ?? address.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:)) else {
            throw TVError.unsupported(L10n.text("The page address is invalid."))
        }
        var request = MangaHTTP.Request(url: target, method: MangaValue.string(value["method"]) ?? "GET")
        request.headers = (value["headers"] as? [String: Any] ?? [:]).compactMapValues { MangaValue.string($0) }
        if let body = value["body"] as? String { request.body = Data(base64Encoded: body) }
        return ImageConfig(id: MangaValue.int(value["id"]) ?? 0, request: request, onResponse: value["onResponse"] as? Bool ?? false,
                           modifyImage: value["modifyImage"] as? Bool ?? false, onLoadFailed: value["onLoadFailed"] as? Bool ?? false)
    }

    func transformResponse(_ key: String, config: Int, data: Data) async throws -> Data {
        let value = try await raw(key, "__venera.onResponse(\(config), \(Self.json(data.base64EncodedString())))", seconds: 60)
        return Data(base64Encoded: MangaValue.string(value) ?? "") ?? data
    }

    func retryRequest(_ key: String, config: Int) async -> MangaHTTP.Request? {
        guard let value = try? await raw(key, "__venera.onLoadFailed(\(config))") as? [String: Any],
              let address = MangaValue.string(value["url"]), let url = URL(string: address) else { return nil }
        var request = MangaHTTP.Request(url: url)
        request.headers = (value["headers"] as? [String: Any] ?? [:]).compactMapValues { MangaValue.string($0) }
        return request
    }

    /// Runs the config's modifyImage script on the decoded page.
    func modify(_ key: String, config: Int, image: CGImage) async throws -> CGImage {
        try await modify(in: session(key), config: config, image: image)
    }

    /// One page at a time per source: the scripts' images share the source's store, which is emptied after each
    /// page. The reader loads several pages at once, and one page's cleanup used to drop the next page's image
    /// before its script ran, so that page stayed scrambled (#836). The scripts run one at a time anyway.
    func modify(in session: Session, config: Int, image: CGImage) async throws -> CGImage {
        let previous = session.modifying
        let work = Task {
            await previous?.value
            return try await Self.unscramble(session, config: config, image: image)
        }
        session.modifying = Task { _ = try? await work.value }
        return try await work.value
    }

    private static func unscramble(_ session: Session, config: Int, image: CGImage) async throws -> CGImage {
        let bitmaps = session.host.bitmaps
        guard let input = bitmaps.add(image) else { return image }
        defer { bitmaps.clear() }
        let output = MangaValue.int(try await Self.call(session.script, "__venera.modify(\(config), \(input))", seconds: 30)) ?? input
        return bitmaps.image(output) ?? image
    }

    func release(_ key: String, config: Int) async {
        _ = try? await raw(key, "__venera.release(\(config))", seconds: 5)
    }
}

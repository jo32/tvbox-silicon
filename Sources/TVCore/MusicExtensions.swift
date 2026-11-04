import Foundation

/// Music extensions in the Listenify / XPTV format (for example allfm.js): scripts a listener imports that
/// list charts and playlists (`getConfig`'s library groups), search, and give a song's address (`getSongInfo`).
/// Yingxia ships none. Each runs on QuickJS with the host API those apps provide (ScriptAssets/music/prelude.js),
/// on its own thread, so one extension does one thing at a time. Nothing runs until one is imported, and its
/// runtime starts only when the Music page, a search or a song first needs it.
///
/// Their songs, albums and playlists belong to `MusicPlatform.ext`: the ID is the extension's ID and the item's
/// `ext` (which the extension reads back), so the existing collection page, queue, history and favorites work
/// unchanged, and a song plays through `MusicExtensionProvider` like any other channel, probed first.

/// One imported extension.
public struct MusicExtension: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var summary: String
    public var version: String
    public var author: String
    /// The script functions it defines, read when it was imported.
    public var functions: [String]
    /// Where it was imported from, to fetch it again if the system cleared its copy (tvOS keeps files in Caches).
    public var origin: URL?
    public var enabled: Bool
    public var added: Date

    public init(id: String = UUID().uuidString, name: String, summary: String = "", version: String = "", author: String = "",
                functions: [String] = [], origin: URL? = nil, enabled: Bool = true, added: Date = Date()) {
        self.id = id; self.name = name; self.summary = summary; self.version = version; self.author = author
        self.functions = functions; self.origin = origin; self.enabled = enabled; self.added = added
    }

    public func has(_ function: String) -> Bool { functions.contains(function) }

    /// `@name`, `@description`, `@version` and `@author` from the comment that opens the script.
    static func header(_ script: String) -> [String: String] {
        var fields: [String: String] = [:]
        let text = script.drop { $0 == "\u{FEFF}" || $0.isWhitespace }
        guard text.hasPrefix("/*"), let end = text.range(of: "*/") else { return fields }
        for line in text[text.index(text.startIndex, offsetBy: 2)..<end.lowerBound].split(whereSeparator: \.isNewline) {
            let content = line.drop { $0 == " " || $0 == "\t" || $0 == "*" || $0 == "!" }
            guard content.hasPrefix("@") else { continue }
            let parts = content.dropFirst().split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]), value = String(parts[1].trimmingCharacters(in: .whitespaces).prefix(200))
            if fields[key] == nil, !value.isEmpty { fields[key] = value }
        }
        return fields
    }
}

/// How an extension's item is carried in a catalog ID: the extension's ID, a newline, and the item's `ext` as JSON.
public enum MusicExtensionReference {
    public static func encode(extensionID: String, ext: String) -> String { extensionID + "\n" + ext }
    public static func decode(_ value: String) -> (extensionID: String, ext: String)? {
        guard let newline = value.firstIndex(of: "\n") else { return nil }
        let id = String(value[..<newline])
        return id.isEmpty ? nil : (id, String(value[value.index(after: newline)...]))
    }
}

/// Reading what extensions answer. Every field is optional: these are third-party scripts.
public enum MusicExtensionItems {
    /// One library group from `getConfig`: what it lists and the `ext` to ask for it with.
    public struct Group: Equatable, Sendable {
        public var name: String
        public var type: String
        public var ext: JSONValue
    }

    static func json(_ text: String) -> JSONValue? { try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
    static func text(_ value: JSONValue) -> String {
        if case .string(let text) = value { return text }
        return (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// The items of a `{list: [...]}` answer, or of a bare array.
    public static func list(_ text: String) -> [JSONValue] {
        guard let value = json(text) else { return [] }
        return value["list"]?.array ?? value.array ?? []
    }

    public static func groups(_ config: String) -> [Group] {
        (json(config)?[path: "tabLibrary", "groups"]?.array ?? []).compactMap { group in
            guard let name = group["name"]?.string, !name.isEmpty else { return nil }
            return Group(name: name, type: group["type"]?.string ?? "playlist", ext: group["ext"] ?? .object([:]))
        }
    }

    /// `ext` with more fields (the page, where the list shows), when it is an object.
    static func ext(_ ext: JSONValue, adding fields: [String: JSONValue]) -> String {
        guard var object = ext.object else { return text(ext) }
        for (key, value) in fields { object[key] = value }
        return text(.object(object))
    }

    public static func track(_ item: JSONValue, extensionID: String) -> MusicTrack? {
        guard let title = item["name"]?.string ?? item["title"]?.string, !title.isEmpty else { return nil }
        let artist = item[path: "artist", "name"]?.string ?? item["singer"]?.string ?? item["artist"]?.string ?? ""
        let artists = artist.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var seconds = item["duration"]?.double ?? item["interval"]?.double
        // Some extensions give milliseconds.
        if let value = seconds, value > 36_000 { seconds = value / 1000 }
        let ext = item["ext"] ?? .object([:])
        let album = item[path: "album", "name"]?.string ?? ext["albumName"]?.string
        var track = MusicTrack(platform: .ext, songID: MusicExtensionReference.encode(extensionID: extensionID, ext: text(ext)),
                               title: title, artists: artists, album: album, duration: seconds, artwork: url(item["cover"]))
        // The full reference stays in `ids`; the ID names files and settings, so it stays short.
        track.id = "ext:" + extensionID + ":" + key(item["id"]?.string ?? text(ext))
        return track
    }

    /// An album, playlist or artist card. Opening it asks `getSongs` with its song group's `ext` when it has one
    /// (an artist's 热门歌曲), otherwise with its own.
    public static func collection(_ item: JSONValue, kind: MusicCollection.Kind, extensionID: String) -> MusicCollection? {
        guard let title = item["name"]?.string ?? item["title"]?.string, !title.isEmpty else { return nil }
        let songs = item["groups"]?.array?.first { $0["type"]?.string == "song" }?["ext"] ?? item["ext"] ?? .object([:])
        return MusicCollection(kind: kind, platform: .ext, collectionID: MusicExtensionReference.encode(extensionID: extensionID, ext: text(songs)),
                               title: title, subtitle: item[path: "artist", "name"]?.string ?? item["desc"]?.string,
                               artwork: url(item["cover"] ?? item["avatar"]))
    }

    /// The first address `getSongInfo` gave, with the headers to send, if it gave any.
    public static func stream(_ text: String) -> (url: URL, headers: [String: String])? {
        guard let value = json(text) else { return nil }
        let first = value["urls"]?.array?.first ?? value["url"]
        guard let address = first?.string ?? first?["url"]?.string, let url = URL(string: address),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host() != nil else { return nil }
        var headers: [String: String] = [:]
        let fields = value["headers"]?.array?.first ?? value["headers"] ?? first?["headers"]
        for (field, entry) in fields?.object ?? [:] {
            if let text = entry.string, !(field + text).contains(where: \.isNewline) { headers[field] = text }
        }
        return (url, headers)
    }

    private static func url(_ value: JSONValue?) -> URL? {
        guard let text = value?.string, !text.isEmpty, let url = URL(string: text), url.host() != nil else { return nil }
        return url
    }

    /// A short, path-safe key for an item's own ID.
    private static func key(_ id: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
        if !id.isEmpty, id.count <= 64, id.unicodeScalars.allSatisfy(safe.contains) { return id }
        return String(PluginChecksum.sha256(Data(id.utf8)).prefix(24))
    }
}

/// Answers an extension's `$lx.request(event, data, options)` through an LX Music source the listener imported.
public protocol MusicExtensionLXBridge: Sendable {
    func request(event: String, data: JSONValue, options: JSONValue) async throws -> JSONValue
}

/// For tests, and for anything that must not reach the LX sources: every request fails with a clear reason.
public struct MusicExtensionNoLX: MusicExtensionLXBridge {
    public init() {}
    public func request(event: String, data: JSONValue, options: JSONValue) async throws -> JSONValue {
        throw TVError.unsupported(L10n.text("This extension plays songs through an LX Music source."))
    }
}

// MARK: - Library

/// The imported extensions: a small list in user defaults and each script in a file.
public final class MusicExtensionLibrary: @unchecked Sendable {
    public static let shared = MusicExtensionLibrary(folder: MusicExtensionLibrary.defaultFolder, defaults: .standard)
    static var defaultFolder: URL {
        #if os(tvOS)
        // tvOS only permits Caches; a cleared script is fetched again from where it came from.
        URL.cachesDirectory.appending(path: "com.tvbox.yingxia/MusicExtensions", directoryHint: .isDirectory)
        #else
        URL.applicationSupportDirectory.appending(path: "com.tvbox.yingxia/MusicExtensions", directoryHint: .isDirectory)
        #endif
    }
    static let defaultsKey = "musicExtensions"
    static let scriptLimit = 5_000_000

    private let folder: URL
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var cached: [MusicExtension]?

    public init(folder: URL, defaults: UserDefaults) { self.folder = folder; self.defaults = defaults }

    public var extensions: [MusicExtension] {
        lock.withLock {
            if let cached { return cached }
            let loaded = defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode([MusicExtension].self, from: $0) } ?? []
            cached = loaded
            return loaded
        }
    }

    public var enabled: [MusicExtension] { extensions.filter(\.enabled) }
    public func item(_ id: String) -> MusicExtension? { extensions.first { $0.id == id } }

    /// Starts `script`, keeps it when it is a music extension (it lists or searches, and gives songs' addresses),
    /// and returns it.
    @discardableResult
    public func add(script: String, origin: URL?, runtime: MusicExtensionRuntime = .shared) async throws -> MusicExtension {
        guard !script.isEmpty, script.utf8.count <= Self.scriptLimit else { throw TVError.unsupported(L10n.text("This file is not a music extension.")) }
        let header = MusicExtension.header(script)
        var item = MusicExtension(name: header["name"] ?? L10n.text("Music Extension"), summary: header["description"] ?? "",
                                  version: header["version"] ?? "", author: header["author"] ?? "", origin: origin)
        item.functions = try await runtime.start(item, script: script)
        guard item.has("getSongInfo"), item.has("getConfig") || item.has("search") else {
            await runtime.close(item.id)
            throw TVError.unsupported(L10n.text("This file is not a music extension."))
        }
        if header["name"] == nil, item.has("getConfig"),
           let config = try? await runtime.call(item, "getConfig", "{}", seconds: 10), let name = MusicExtensionItems.json(config)?["name"]?.string, !name.isEmpty {
            item.name = String(name.prefix(60))
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(script.utf8).write(to: file(item.id), options: .atomic)
        update { $0.append(item) }
        Diagnostics.shared.record(.info, "music", "extension added: \(item.functions.joined(separator: ","))")
        return item
    }

    public func setEnabled(_ id: String, _ enabled: Bool) {
        update { list in
            if let index = list.firstIndex(where: { $0.id == id }) { list[index].enabled = enabled }
        }
        if !enabled { Task { await MusicExtensionRuntime.shared.close(id) } }
    }

    public func remove(_ id: String) {
        update { $0.removeAll { $0.id == id } }
        try? FileManager.default.removeItem(at: file(id))
        Task { await MusicExtensionRuntime.shared.close(id) }
    }

    /// The script, fetched again from its origin when the system cleared the copy.
    func script(for item: MusicExtension) async throws -> String {
        if let data = try? Data(contentsOf: file(item.id)) { return String(decoding: data, as: UTF8.self) }
        guard let origin = item.origin else { throw MusicProviderError.noResource }
        let script = try await Self.download(origin)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data(script.utf8).write(to: file(item.id), options: .atomic)
        return script
    }

    /// An extension's text from an HTTP or HTTPS address.
    public static func download(_ url: URL, transport: MusicTransport = URLSessionMusicTransport()) async throws -> String {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { throw TVError.invalidURL }
        let response = try await MusicHTTP.withTimeout(30) { try await transport.send(MusicHTTP.request(url, timeout: 30), limit: scriptLimit + 1) }
        guard (200..<300).contains(response.status) else { throw TVError.http(response.status) }
        guard response.body.count <= scriptLimit, let text = String(data: response.body, encoding: .utf8), !text.isEmpty else {
            throw TVError.unsupported(L10n.text("This file is not a music extension."))
        }
        return text
    }

    private func file(_ id: String) -> URL { folder.appending(path: id + ".js") }

    private func update(_ change: (inout [MusicExtension]) -> Void) {
        lock.withLock {
            var list = cached ?? defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode([MusicExtension].self, from: $0) } ?? []
            change(&list)
            cached = list
            if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: Self.defaultsKey) }
        }
    }
}

// MARK: - Runtime

/// The extensions' QuickJS runtimes, started on first use and kept for the next request.
public actor MusicExtensionRuntime {
    public static let shared = MusicExtensionRuntime()
    private var sessions: [String: MusicExtensionSession] = [:]
    private var recent: [String] = []
    private let library: MusicExtensionLibrary
    private let lx: any MusicExtensionLXBridge
    static let maximumSessions = 3

    public init(library: MusicExtensionLibrary = .shared, lx: any MusicExtensionLXBridge = MusicExtensionLX()) {
        self.library = library; self.lx = lx
    }

    /// Runs `script` and answers the functions it defines.
    func start(_ item: MusicExtension, script: String) async throws -> [String] {
        close(item.id)
        let profile = ScriptAssets.profiles.appendingPathComponent("music-" + item.id, isDirectory: true)
        let (session, functions) = try await MusicExtensionSession.start(script: script, profile: profile, label: "music " + item.name)
        keep(session, for: item.id)
        return functions
    }

    /// Calls `function` with `argument` (JSON text) and returns what it answered (JSON text). An LX Music request
    /// the function made is answered and the function called again.
    public func call(_ item: MusicExtension, _ function: String, _ argument: String, seconds: Double) async throws -> String {
        let session = try await session(for: item)
        var answered = 0
        var lxFailure: Error?
        while true {
            let reply = await session.call(function, argument, seconds: seconds)
            if let request = reply["lx"]?.object, let key = request["key"]?.string, answered < 2 {
                answered += 1
                do {
                    let value = try await lx.request(event: request["event"]?.string ?? "", data: request["data"] ?? .null, options: request["options"] ?? .null)
                    await session.answer(key, value: value, error: nil)
                } catch {
                    lxFailure = error
                    await session.answer(key, value: .null, error: error.localizedDescription)
                }
                continue
            }
            if let result = reply["result"]?.string { return result }
            // The LX source's own reason says more than the extension's echo of it.
            if let lxFailure { throw lxFailure }
            let message = reply["error"]?.string ?? ""
            if message.contains("interrupted") { throw MusicProviderError.timeout }
            // The script's own message can hold its API's address or key: it goes to the listener, not the log.
            Diagnostics.shared.record(.warning, "music", "extension \(function) failed")
            throw TVError.unsupported(L10n.text("The music extension failed: %@", String(message.prefix(200))))
        }
    }

    func close(_ id: String) {
        sessions.removeValue(forKey: id)?.close()
        recent.removeAll { $0 == id }
    }

    private func session(for item: MusicExtension) async throws -> MusicExtensionSession {
        if let running = sessions[item.id] {
            recent.removeAll { $0 == item.id }; recent.append(item.id)
            return running
        }
        let script = try await library.script(for: item)
        // Another call may have started it meanwhile.
        if let running = sessions[item.id] { return running }
        _ = try await start(item, script: script)
        guard let started = sessions[item.id] else { throw MusicProviderError.noResource }
        return started
    }

    private func keep(_ session: MusicExtensionSession, for id: String) {
        sessions[id] = session
        recent.append(id)
        while recent.count > Self.maximumSessions { close(recent[0]) }
    }
}

/// One extension's QuickJS runtime (ScriptSession's own thread): the TVBox prelude, the music prelude, then the script.
final class MusicExtensionSession: @unchecked Sendable {
    private let session: ScriptSession
    private init(_ session: ScriptSession) { self.session = session }

    static func start(script source: String, profile: URL, label: String, config: String = "{}") async throws -> (MusicExtensionSession, [String]) {
        let session = try await ScriptSession.start(module: "assets://music/prelude.js", supplied: ["music://extension": source], profile: profile, label: label)
        let envelope = await session.evaluate("__music.load(\(literal(config)))", within: 30)
        guard let functions = envelope["value"]?["functions"]?.array else {
            session.close()
            let reason = envelope["error"]?.string ?? "The script did not start"
            throw TVError.unsupported(L10n.text("The music extension failed: %@", String(reason.prefix(200))))
        }
        return (MusicExtensionSession(session), functions.compactMap(\.string))
    }

    /// `{"result": json, "lx": request?}` or `{"error": message, "lx": request?}`.
    func call(_ function: String, _ argument: String, seconds: Double) async -> [String: JSONValue] {
        let reply = await session.evaluate("__music.call(\(Self.literal(function)), \(Self.literal(argument)))", within: seconds)
        if let value = reply["value"]?.object { return value }
        return ["error": .string(reply["error"]?.string ?? "The script failed")]
    }

    func answer(_ key: String, value: JSONValue, error: String?) async {
        let json = String(decoding: (try? JSONEncoder().encode(value)) ?? Data("null".utf8), as: UTF8.self)
        _ = await session.evaluate("__music.answer(\(Self.literal(key)), \(json), \(error.map(Self.literal) ?? "null"))", within: 5)
    }

    func close() { session.close() }

    /// A JavaScript string literal.
    static func literal(_ text: String) -> String {
        (try? JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }
}

/// `$lx.request('musicUrl', {type, musicInfo}, {source})` answered by the LX Music sources the listener imported
/// (MusicLXSources.swift): each enabled source that covers the catalog is asked in turn.
public struct MusicExtensionLX: MusicExtensionLXBridge {
    let library: LXSourceLibrary
    let runtime: LXSourceRuntime
    public init(library: LXSourceLibrary = .shared, runtime: LXSourceRuntime = .shared) { self.library = library; self.runtime = runtime }

    public func request(event: String, data: JSONValue, options: JSONValue) async throws -> JSONValue {
        guard event == "musicUrl" else { throw TVError.unsupported(L10n.text("This extension asks an LX Music source for something Yingxia doesn't support.")) }
        let enabled = library.enabled
        guard !enabled.isEmpty else { throw TVError.unsupported(L10n.text("This extension plays songs through an LX Music source. Add one in Music Settings.")) }
        let key = options["source"]?.string ?? data[path: "musicInfo", "source"]?.string ?? ""
        let sources = enabled.filter { $0.sources[key] != nil }
        guard !sources.isEmpty else { throw TVError.unsupported(L10n.text("None of your LX Music sources plays this song's catalog.")) }
        let musicInfo = data["musicInfo"]?.object ?? [:]
        var failure: Error = MusicProviderError.noResource
        for source in sources {
            try Task.checkCancellation()
            let declared = source.sources[key] ?? []
            let quality = data["type"]?.string.flatMap { declared.contains($0) ? $0 : nil }
                ?? LXSourceKey.quality(from: declared, for: .lossless) ?? "320k"
            do {
                return .string(try await runtime.musicURL(source, library: library, key: key, quality: quality, musicInfo: musicInfo).absoluteString)
            } catch { failure = error }
        }
        throw failure
    }
}

// MARK: - Catalog and channel

/// The enabled extensions as one catalog: search, their library groups as Music page shelves, and the songs
/// of what they list.
public struct MusicExtensionCatalog: MusicCatalogSource, MusicCollectionSource, MusicBrowseSource {
    public let platform = MusicPlatform.ext
    let library: MusicExtensionLibrary
    let runtime: MusicExtensionRuntime
    /// Pages of a list read when it opens: extensions answer about 20 songs a page.
    static let pages = 5
    static let seconds: Double = 20

    public init(library: MusicExtensionLibrary = .shared, runtime: MusicExtensionRuntime = .shared) {
        self.library = library; self.runtime = runtime
    }

    /// With none imported there is nothing to show, and that is no failure.
    public var mayBeEmpty: Bool { true }

    public func search(_ query: String, page: Int) async throws -> [MusicTrack] {
        try await each("search") { item in
            let answer = try await runtime.call(item, "search", MusicExtensionItems.text(.object(["text": .string(query), "type": .string("song"), "page": .number(Double(page))])), seconds: Self.seconds)
            return MusicExtensionItems.list(answer).compactMap { MusicExtensionItems.track($0, extensionID: item.id) }
        }
    }

    public func searchCollections(_ query: String, kind: MusicCollection.Kind, page: Int) async throws -> [MusicCollection] {
        try await each("search") { item in
            let argument: JSONValue = .object(["text": .string(query), "type": .string(kind.rawValue), "page": .number(Double(page))])
            let answer = try await runtime.call(item, "search", MusicExtensionItems.text(argument), seconds: Self.seconds)
            return MusicExtensionItems.list(answer).compactMap { MusicExtensionItems.collection($0, kind: kind, extensionID: item.id) }
        }
    }

    public func tracks(of collection: MusicCollection) async throws -> [MusicTrack] {
        guard let reference = MusicExtensionReference.decode(collection.collectionID), let item = library.item(reference.extensionID) else {
            throw MusicProviderError.noResource
        }
        let ext = MusicExtensionItems.json(reference.ext) ?? .string(reference.ext)
        var tracks: [MusicTrack] = [], seen = Set<String>()
        for page in 1...Self.pages {
            let answer = try await runtime.call(item, "getSongs", MusicExtensionItems.ext(ext, adding: ["page": .number(Double(page))]), seconds: Self.seconds)
            let found = MusicExtensionItems.list(answer).compactMap { MusicExtensionItems.track($0, extensionID: item.id) }.filter { seen.insert($0.id).inserted }
            tracks += found
            // A list that ignores the page answers the same songs again; a string `ext` has no page to turn.
            guard !found.isEmpty, ext.object != nil, tracks.count < MusicCollections.trackLimit else { break }
        }
        return tracks
    }

    /// One shelf per library group of each enabled extension, after the built-in ones, named with the extension.
    public func browseSections() async throws -> [MusicBrowseSection] {
        let items = library.enabled.filter { $0.has("getConfig") }
        guard !items.isEmpty else { return [] }
        let answers = await withTaskGroup(of: (Int, [MusicBrowseSection]).self) { group in
            for (index, item) in items.enumerated() {
                group.addTask { (index, (try? await self.sections(item)) ?? []) }
            }
            var answers: [Int: [MusicBrowseSection]] = [:]
            for await (index, sections) in group { answers[index] = sections }
            return answers
        }
        let sections = items.indices.flatMap { answers[$0] ?? [] }
        if sections.isEmpty { throw MusicProviderError.noResource }
        return sections
    }

    func sections(_ item: MusicExtension) async throws -> [MusicBrowseSection] {
        let groups = MusicExtensionItems.groups(try await runtime.call(item, "getConfig", "{}", seconds: Self.seconds))
        var sections: [MusicBrowseSection] = []
        // One group after another: the extension's runtime does one thing at a time anyway.
        for (index, group) in groups.enumerated() {
            let argument = MusicExtensionItems.ext(group.ext, adding: ["page": .number(1), "from": .string("index")])
            let collections: [MusicCollection]
            switch group.type {
            case "song":
                // A list of songs shows as one card that opens it.
                guard item.has("getSongs"), let answer = try? await runtime.call(item, "getSongs", argument, seconds: Self.seconds),
                      let first = MusicExtensionItems.list(answer).first else { continue }
                collections = [MusicCollection(kind: .playlist, platform: .ext,
                                               collectionID: MusicExtensionReference.encode(extensionID: item.id, ext: MusicExtensionItems.text(group.ext)),
                                               title: group.name, subtitle: item.name, artwork: MusicExtensionItems.track(first, extensionID: item.id)?.artwork)]
            default:
                let function = group.type == "album" ? "getAlbums" : group.type == "artist" ? "getArtists" : "getPlaylists"
                guard item.has(function), let answer = try? await runtime.call(item, function, argument, seconds: Self.seconds) else { continue }
                collections = MusicExtensionItems.list(answer).prefix(MusicBrowse.shelfSize).compactMap {
                    MusicExtensionItems.collection($0, kind: group.type == "album" ? .album : .playlist, extensionID: item.id)
                }
            }
            guard !collections.isEmpty else { continue }
            sections.append(MusicBrowseSection(id: "ext:\(item.id):\(index)", title: item.name + " · " + group.name, collections: collections))
        }
        return sections
    }

    /// `body` for every enabled extension that has `function`, side by side, results in the library's order.
    /// Throws only when every one failed.
    private func each<T: Sendable>(_ function: String, _ body: @escaping @Sendable (MusicExtension) async throws -> [T]) async throws -> [T] {
        let items = library.enabled.filter { $0.has(function) }
        guard !items.isEmpty else { return [] }
        var answers: [Int: [T]] = [:], failure: Error?
        await withTaskGroup(of: (Int, Result<[T], Error>).self) { group in
            for (index, item) in items.enumerated() {
                group.addTask {
                    do { return (index, .success(try await body(item))) } catch { return (index, .failure(error)) }
                }
            }
            for await (index, result) in group {
                switch result {
                case .success(let list): answers[index] = list
                case .failure(let error): failure = failure ?? error
                }
            }
        }
        if answers.isEmpty, let failure { throw MusicProviderError(failure) }
        return items.indices.flatMap { answers[$0] ?? [] }
    }
}

/// The enabled extensions as a channel: a song from an extension plays from the address its `getSongInfo` gives.
public struct MusicExtensionProvider: MusicStreamProvider {
    public let id = MusicProviderID.extension
    public let platforms: Set<MusicPlatform> = [.ext]
    let library: MusicExtensionLibrary
    let runtime: MusicExtensionRuntime
    /// Within the resolver's eight seconds per channel.
    static let seconds: Double = 7.5

    public init?(library: MusicExtensionLibrary = .shared, runtime: MusicExtensionRuntime = .shared) {
        guard !library.enabled.isEmpty else { return nil }
        self.library = library; self.runtime = runtime
    }

    public func resolve(_ songID: String, platform: MusicPlatform, quality: MusicAudioQuality) async throws -> ResolvedMusicStream {
        // The extension decides what its getSongInfo answer holds; probing tells what it really is.
        guard let reference = MusicExtensionReference.decode(songID), let item = library.item(reference.extensionID), item.enabled else {
            throw MusicProviderError.noResource
        }
        let answer = try await runtime.call(item, "getSongInfo", reference.ext, seconds: Self.seconds)
        guard let stream = MusicExtensionItems.stream(answer) else { throw MusicProviderError.noResource }
        return ResolvedMusicStream(url: stream.url, headers: stream.headers, upstream: "ext:" + item.name)
    }
}

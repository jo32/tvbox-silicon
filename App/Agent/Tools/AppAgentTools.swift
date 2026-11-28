import Foundation
import TVCore

/// The assistant's tools (Docs/agent.md "Tools"): what the model may do in the app. Each goes through the code the
/// app's own pages use, reaches only what the viewer could reach on screen (sections the App Store build hides stay
/// hidden), and answers with compact JSON that never holds a password, cookie, token or full subscription address.
@MainActor enum AppAgentTools {
    static func all(store: Store) -> [any AgentTool] {
        let context = AgentToolContext(store: store)
        var tools: [AppTool] = []
        tools += AppTools.make(context)
        tools += SettingsTools.make(context)
        tools += VideoTools.make(context)
        tools += LibraryTools.make(context)
        tools += SubscriptionTools.make(context)
        tools += ScriptTools.make(context)
        tools += MediaTools.make(context)
        return tools
    }
}

/// What the tools share: the store, the assistant's own global search (so the viewer's Global Search page keeps
/// theirs), and what one tool found for a later one.
@MainActor final class AgentToolContext {
    let store: Store
    let search = SearchModel()
    /// Titles of videos the tools have seen, by video id, for the confirmation cards.
    var videoTitles: [String: String] = [:]
    /// Songs the last music searches found, by id.
    var tracks: [String: MusicTrack] = [:]
    /// Live playlists loaded, by live playlist id, with the guide they name and when.
    var playlists: [String: (channels: [Channel], guide: String?, at: Date)] = [:]
    /// Books and comics the last searches found, by id.
    var books: [String: NovelSearchHit] = [:]
    var comics: [String: MangaComic] = [:]
    /// The assistant's own music search, so Music's search page keeps the viewer's.
    lazy var musicSearch = MusicSearchModel(catalogs: MusicSearchModel.defaultCatalogs() + [MusicExtensionCatalog()])
    init(store: Store) {
        self.store = store
        search.order = store.sourceOrder
    }

    /// Whether `section` is one the viewer can open now.
    func isAvailable(_ section: AppSection) -> Bool { AgentNavigator.sections(store).contains(section) }

    func require(_ section: AppSection) throws {
        guard isAvailable(section) else {
            throw AgentToolError("\(section.rawValue) isn't available in this app right now.")
        }
    }
}

/// One tool: its spec, what it does, and how it reads on the confirmation card.
struct AppTool: AgentDescribedTool {
    let spec: AgentToolSpec
    private let body: @MainActor @Sendable (AgentArguments) async throws -> JSONValue
    private let describe: (@MainActor @Sendable (AgentArguments) -> (summary: String, detail: String?))?

    init(_ name: String, _ effect: AgentToolEffect, _ description: String, _ parameters: JSONValue,
         summary: (@MainActor @Sendable (AgentArguments) -> (summary: String, detail: String?))? = nil,
         run: @escaping @MainActor @Sendable (AgentArguments) async throws -> JSONValue) {
        spec = AgentToolSpec(name: name, description: description, parameters: parameters, effect: effect)
        body = run
        describe = summary
    }

    @MainActor func run(_ arguments: [String: JSONValue]) async throws -> JSONValue {
        let arguments = AgentArguments(arguments)
        if case .object(let fields) = spec.parameters, case .object(let properties)? = fields["properties"] {
            let unknown = arguments.unknownKeys(Set(properties.keys))
            if !unknown.isEmpty {
                throw AgentToolError("Unknown arguments: \(unknown.joined(separator: ", ")). This tool takes: \(properties.keys.sorted().joined(separator: ", ")).")
            }
        }
        return try await body(arguments)
    }

    @MainActor func summary(_ arguments: [String: JSONValue]) -> (summary: String, detail: String?) {
        describe?(AgentArguments(arguments)) ?? (L10n.text("Allow the assistant to use %@?", spec.name), nil)
    }
}

// MARK: JSON

extension JSONValue {
    static func str(_ text: String) -> JSONValue { .string(text) }
    static func num(_ number: Int) -> JSONValue { .number(Double(number)) }
    /// Rounded to two decimals, so positions and sizes stay short.
    static func num(_ number: Double) -> JSONValue { .number(number.isFinite ? (number * 100).rounded() / 100 : 0) }
    static func list(_ items: [JSONValue]) -> JSONValue { .array(items) }
    /// An object without the fields that are nil.
    static func obj(_ fields: [String: JSONValue?]) -> JSONValue { .object(fields.compactMapValues { $0 }) }
    /// A text field that is left out when empty.
    static func text(_ text: String?) -> JSONValue? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return .string(text)
    }
    /// A capped list: `items` and, when some were left out, `more`.
    static func capped(_ key: String, _ items: [JSONValue], limit: Int, extra: [String: JSONValue?] = [:]) -> JSONValue {
        let (kept, more) = AgentToolKit.capped(items, limit: limit)
        var fields = extra
        fields[key] = .array(kept)
        fields["more"] = more > 0 ? .num(more) : nil
        return .obj(fields)
    }
}

/// JSON Schema for the tools' arguments.
enum Schema {
    static func object(_ properties: [String: JSONValue] = [:], required: [String] = []) -> JSONValue {
        .object(["type": .str("object"), "properties": .object(properties), "required": .array(required.map { .string($0) }),
                 "additionalProperties": .bool(false)])
    }
    static func string(_ description: String, enum values: [String]? = nil) -> JSONValue {
        .obj(["type": .str("string"), "description": .string(description), "enum": values.map { .array($0.map { .string($0) }) }])
    }
    static func integer(_ description: String, minimum: Int? = nil, maximum: Int? = nil) -> JSONValue {
        .obj(["type": .str("integer"), "description": .string(description), "minimum": minimum.map(JSONValue.num), "maximum": maximum.map(JSONValue.num)])
    }
    static func number(_ description: String) -> JSONValue { .obj(["type": .str("number"), "description": .string(description)]) }
    static func boolean(_ description: String) -> JSONValue { .obj(["type": .str("boolean"), "description": .string(description)]) }
    static func strings(_ description: String) -> JSONValue {
        .obj(["type": .str("array"), "items": .object(["type": .str("string")]), "description": .string(description)])
    }
    /// A value that may be text, a number or true/false (a setting's value).
    static func value(_ description: String) -> JSONValue {
        .obj(["type": .array([.str("string"), .str("number"), .str("boolean")]), "description": .string(description)])
    }
    /// A number, or text such as a name (an episode by number or name).
    static func numberOrText(_ description: String) -> JSONValue {
        .obj(["type": .array([.str("integer"), .str("string")]), "description": .string(description)])
    }
}

// MARK: Shared lookups

@MainActor enum AgentLookup {
    /// The digest ids use for an address, which may carry a token, so the address itself is never shown.
    static func digest(_ url: URL) -> String { String(AgentToolKit.digest(url.absoluteString).prefix(10)) }

    /// A video's id: its source (by where the source's subscription lives and its own key) and the source's video id.
    static func videoID(_ site: Site, origin: URL, video: String) -> String {
        AgentToolKit.encodeID("v", [digest(site.origin(or: origin)), site.sourceKey, video])
    }

    static func sourceID(_ site: Site, origin: URL) -> String {
        AgentToolKit.encodeID("s", [digest(site.origin(or: origin)), site.sourceKey])
    }

    /// The subscription the viewer has on, or why there is none to use.
    static func subscription(_ store: Store) throws -> Subscription {
        guard let config = store.subscription, !config.sites.isEmpty else {
            throw AgentToolError("No video sources yet: add a subscription first (subscription_add), or turn one on (subscription_edit).")
        }
        return config
    }

    /// The source behind a source id, unless the viewer hid it.
    static func site(sourceID id: String, store: Store) throws -> (Site, Subscription) {
        let parts = try AgentToolKit.decodeID(id, prefix: "s", count: 2)
        return try site(origin: parts[0], key: parts[1], store: store)
    }

    static func site(origin: String, key: String, store: Store) throws -> (Site, Subscription) {
        let config = try subscription(store)
        guard let site = config.sites.first(where: { digest($0.origin(or: config.origin)) == origin && $0.sourceKey == key }) else {
            throw AgentToolError("That source is no longer in the subscriptions that are on.")
        }
        guard !store.hiddenSources.contains(site, origin: config.origin) else {
            throw AgentToolError("The viewer hid that source. Ask them to show it again in Sources first.")
        }
        return (site, config)
    }

    /// The source, its catalog client and the source's own id of the video behind a video id.
    static func video(_ id: String, store: Store) throws -> (site: Site, client: CatalogClient, videoID: String) {
        let parts = try AgentToolKit.decodeID(id, prefix: "v", count: 3)
        let (site, config) = try site(origin: parts[0], key: parts[1], store: store)
        return (site, CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL), parts[2])
    }

    /// A subscription by its id (the start of the digest of its address, as `subscriptions_list` gives it).
    static func subscriptionEntry(_ id: String, store: Store) throws -> SubscriptionEntry {
        guard let entry = store.subscriptions.first(where: { subscriptionID($0) == id }) else {
            throw AgentToolError("No subscription has the id `\(id)`. Call subscriptions_list for the ids.")
        }
        return entry
    }

    static func subscriptionID(_ entry: SubscriptionEntry) -> String { "sub_" + AgentToolKit.digest(entry.address).prefix(10) }

    /// Where a subscription lives, the host only: the rest of an address can carry a token.
    static func host(_ address: String) -> String {
        if ImportedFiles.isImported(address) { return URL(string: address)?.lastPathComponent ?? "" }
        return URL(string: address)?.host() ?? ""
    }

    /// A video's episodes by line, in the order the source lists them.
    static func lines(_ video: Video) -> [(name: String, episodes: [Episode])] {
        var order: [String] = [], groups: [String: [Episode]] = [:]
        for episode in video.episodes {
            if groups[episode.flag] == nil { order.append(episode.flag) }
            groups[episode.flag, default: []].append(episode)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    /// The line `line` names (its name or 1-based number), or the first.
    static func line(_ line: String?, in video: Video) throws -> (name: String, episodes: [Episode]) {
        let lines = lines(video)
        guard !lines.isEmpty else { throw AgentToolError("This video has no episodes to play.") }
        guard let line else { return lines[0] }
        if let number = Int(line), lines.indices.contains(number - 1) { return lines[number - 1] }
        if let match = lines.first(where: { $0.name == line }) ?? lines.first(where: { $0.name.localizedCaseInsensitiveContains(line) }) { return match }
        throw AgentToolError("No line is called “\(line)”. Lines: \(lines.map(\.name).joined(separator: ", ")).")
    }

    /// An episode by its 1-based number in its line, or by name.
    static func episode(_ value: JSONValue?, in episodes: [Episode]) throws -> Episode? {
        guard let value, value != .null else { return nil }
        if case .number(let number) = value {
            let index = Int(number) - 1
            guard episodes.indices.contains(index) else { throw AgentToolError("Episode \(Int(number)) doesn't exist; this line has \(episodes.count).") }
            return episodes[index]
        }
        guard let text = value.string?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let match = episodes.first(where: { $0.name == text }) { return match }
        if let number = Int(text), episodes.indices.contains(number - 1) { return episodes[number - 1] }
        if let match = episodes.first(where: { $0.name.localizedCaseInsensitiveContains(text) }) { return match }
        throw AgentToolError("No episode is called “\(text)”.")
    }

    static func isoDate(_ date: Date) -> String { date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)) }
}

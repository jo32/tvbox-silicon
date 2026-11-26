import Foundation
public struct Site: Identifiable, Sendable {
    public let key: String; public let name: String; public let type: Int; public let api: String
    public var raw: [String: JSONValue] = [:]
    public var provenance: SourceProvenance?
    public var id: String { key }
    var native: Bool { true }; var preferredRuntime: Runtime { .api }
    public var searchable: Bool { true }; public var isBuiltIn: Bool { false }
    public func canBrowse(jarURL: URL?) -> Bool { true }
    public init(key: String, name: String, type: Int, api: String, raw: [String: JSONValue] = [:]) { self.key = key; self.name = name; self.type = type; self.api = api; self.raw = raw }
}
public struct SourceProvenance: Sendable { let origin: URL; let spider: URL? }
enum Runtime { case api, jar, javascript, python }
enum EmbeddedJarHost { static let searchWidth = 1 }
enum Diagnostics { static let shared = DiagnosticsSink(); enum Level { case info, debug, warning } }
struct DiagnosticsSink { func record(_ level: Diagnostics.Level, _ category: String, _ message: String) {} }
enum L10n { static func text(_ value: String) -> String { value } }
struct PosterResource { let url: URL; let headers: [String: String] = [:]; init?(address: String, origin: URL) { guard let url = URL(string: address, relativeTo: origin) else { return nil }; self.url = url } }
struct CatalogClient {
    static func isDirectMedia(_ address: String) -> Bool { false }
    let site: Site; let origin: URL; let http: HTTPClient; let jarURL: URL?
    func list(category: String?, query: String, page: Int) async throws -> CatalogPage { try await http.reply(site, query, page) }
}

public struct Subscription: Sendable { let origin = URL(string: "https://example.invalid")!; let importedAt = Date(); let spiderURL: URL? = nil; let sites: [Site] }
public struct HTTPClient: Sendable {
    var reply: @Sendable (Site, String, Int) async throws -> CatalogPage = { _, _, _ in CatalogPage(videos: []) }
    public init() {}
}

public struct SourceOrder { var enabled = false; func arrange(_ sites: [Site], origin: URL) -> [Site] { sites } }
struct SourceStrategy { static func arrange(_ sites: [Site], where accept: (Site) -> Bool, failing: (Site) -> Bool) -> [Site] { sites } }
struct SourceHealth: Sendable { static let shared = Self(); func paused(_ site: Site, origin: URL, now: Date) -> Bool { false } }
actor LocalJarHost { static let shared = LocalJarHost(); func reusableSourceKeys() -> Set<String> { [] } }
struct Store {
    let subscription: Subscription?
    let hiddenSources = HiddenSources()
    let sourceOrder = SourceOrder()
    func recommendationSites(_ config: Subscription) -> [Site] { config.sites }
}
struct HiddenSources { func contains(_ site: Site, origin: URL) -> Bool { false } }
enum AudioSources { static func isCandidate(_ site: Site) -> Bool { false } }
enum TMDBCatalog { struct Item { let key: String; let name: String; var originalName = ""; var year: Int? } }

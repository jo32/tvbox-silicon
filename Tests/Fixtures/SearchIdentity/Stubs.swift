import Foundation
public struct Site: Identifiable, Sendable {
    public let key: String; public let name: String; public let type: Int; public let api: String
    public var id: String { key }; public var native: Bool { true }; public var preferredRuntime: Runtime { .native }; public var searchable: Bool { type >= 0 }; public var isBuiltIn: Bool { false }
    public init(key: String, name: String = "", type: Int = 1, api: String = "", raw: [String: JSONValue] = [:]) { self.key = key; self.name = name; self.type = type; self.api = api }
    public func canBrowse(jarURL: URL?) -> Bool { true }
}
public struct Video: Identifiable, Sendable { public let id: String; public let name: String; public init(id: String, name: String) { self.id = id; self.name = name } }
public struct CatalogPage: Sendable { public var videos: [Video]; public var pageCount: Int; public init(videos: [Video] = [], pageCount: Int = 1) { self.videos = videos; self.pageCount = pageCount } }
public struct Subscription: Sendable { let origin = URL(string: "https://example.invalid")!; let importedAt = Date(); let spiderURL: URL? = nil; let sites: [Site] }
public struct HTTPClient: Sendable { public init(session: URLSession = .shared) {} }
public struct CatalogClient { init(site: Site, origin: URL, http: HTTPClient, jarURL: URL?) {}; func list(category: String?, query: String, page: Int) async throws -> CatalogPage { CatalogPage() } }
public struct SourceOrder { var enabled = false; func arrange(_ sites: [Site], origin: URL) -> [Site] { sites } }
struct SourceStrategy { static func arrange(_ sites: [Site], where accept: (Site) -> Bool, failing: (Site) -> Bool) -> [Site] { sites } }
struct SourceHealth: Sendable { static let shared = Self(); func paused(_ site: Site, origin: URL, now: Date) -> Bool { false } }
actor LocalJarHost { static let shared = LocalJarHost(); func reusableSourceKeys() -> Set<String> { [] } }
enum EmbeddedJarHost { static let searchWidth = 4 }
public enum Runtime { case native, javascript, python, jar }
struct Diagnostics: Sendable {
    static let shared = Self()
    enum Level { case info, debug, warning }
    func record(_ level: Level, _ scope: String, _ text: String) {}
}

public enum JSONValue: Sendable { case string(String), array([JSONValue]), object([String: JSONValue]) }
extension CatalogPage {
    init(json: [String: JSONValue], origin: URL) {
        guard case .array(let list) = json["list"] else { self.init(); return }
        self.init(videos: list.compactMap { value in
            guard case .object(let fields) = value, case .string(let id) = fields["vod_id"], case .string(let name) = fields["vod_name"] else { return nil }
            return Video(id: id, name: name)
        })
    }
}

import Foundation

/// Lightweight site scripts bundled in `ScriptAssets/sites`: JavaScript ports of JAR spiders that run
/// on the in-process QuickJS runtime on every platform, with no JVM, DEX conversion or native guard.
/// `sites/index.json` lists the enabled `csp_` classes; any other class keeps its original runtime.
enum LiteSites {
    struct Entry: Decodable { let script: String }
    private struct Index: Decodable { let classes: [String: Entry] }

    static let enabled: [String: Entry] = {
        guard let text = ScriptAssets.bundled("assets://sites/index.json") else { return [:] }
        do { return try JSONDecoder().decode(Index.self, from: Data(text.utf8)).classes }
        catch {
            Diagnostics.shared.record(.error, "lite.index", "sites/index.json is invalid: \(error)")
            return [:]
        }
    }()

    /// The bundled script for a `csp_` class, or nil when the class has no enabled port.
    static func script(for api: String) -> URL? {
        guard api.hasPrefix("csp_"), let entry = enabled[String(api.dropFirst(4))] else { return nil }
        return URL(string: "assets://sites/" + entry.script)
    }
}

extension Site {
    /// The bundled lite script that replaces this source's JAR spider, if one is enabled.
    public var liteScript: URL? { type == 3 ? LiteSites.script(for: api) : nil }
}

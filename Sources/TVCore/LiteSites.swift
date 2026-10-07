import Foundation

/// Lightweight site scripts bundled in `ScriptAssets/sites`: JavaScript ports of JAR spiders that run
/// on the in-process QuickJS runtime on every platform, with no JVM, DEX conversion or native guard.
/// `sites/index.json` lists the enabled `csp_` classes; any other class keeps its original runtime.
///
/// A ported source is still a JAR source (`runtime == .jar`): its port is tried first, and when the
/// port fails or answers with nothing usable, the request goes to the source's JAR spider instead.
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

    /// Why a port's answer counts as unsupported, so the JAR should answer instead; nil when it is usable.
    /// Search may legitimately find nothing, and later pages may be empty, so neither falls back.
    static func unusable(_ json: [String: JSONValue], params: [String: String]) -> String? {
        func empty(_ key: String) -> Bool { json[key]?.array?.isEmpty ?? true }
        if params["play"] != nil {
            if let message = CatalogClient.providerError(json) { return message }
            let url = json["url"]
            return url == nil || url?.string?.isEmpty == true || url?.array?.isEmpty == true ? "no playback URL" : nil
        }
        if params["ids"] != nil { return empty("list") ? "no details" : nil }
        if params["wd"] != nil { return nil }
        if let category = params["t"] { return !category.isEmpty && (params["pg"] ?? "1") == "1" && empty("list") ? "no videos" : nil }
        return empty("class") && empty("list") ? "no categories" : nil
    }
}

/// Sources whose port recently fell back. They go straight to the JAR for a while, so one source does
/// not pay for a failing port on every request or mix the port's ids with the JAR's mid-session.
actor LiteFallback {
    static let shared = LiteFallback()
    static let cooldown: TimeInterval = 30 * 60
    private var fellBack: [String: Date] = [:]

    func prefersPort(_ key: String) -> Bool {
        guard let since = fellBack[key] else { return true }
        if Date().timeIntervalSince(since) < Self.cooldown { return false }
        fellBack[key] = nil
        return true
    }
    func record(_ key: String) { fellBack[key] = Date() }
}

extension Site {
    /// The bundled lite script tried before this source's JAR spider, if one is enabled. A source whose
    /// ext is itself a script (drpy-style `csp_` loaders) keeps the JAR: the port cannot run that script.
    public var liteScript: URL? {
        guard type == 3, !extIsScript else { return nil }
        return LiteSites.script(for: api)
    }
    /// Whether the source can run its lite port here.
    public var runsLitePort: Bool { liteScript != nil && ScriptRuntime.available }
    /// The runtime a request starts on: QuickJS for a runnable port, otherwise `runtime`.
    public var preferredRuntime: SourceRuntime { runsLitePort ? .javascript : runtime }

    private var extIsScript: Bool {
        guard let ext = raw["ext"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !ext.hasPrefix("{") else { return false }
        let path = ext.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ext
        return path.hasSuffix(".js") || path.hasSuffix(".py")
    }
}

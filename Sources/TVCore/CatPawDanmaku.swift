import Foundation

/// Danmaku from a CatPawOpen bundle's own comment service (#506). The 9280.kstore.vip bundle carries a danmu_api: a
/// moment after a play it asks the app what plays and sends back the address of the comments it matched, as the
/// CatVod Open apps take them. The hosts (Runtime/ScriptHost/host.mjs, Runtime/NodeHost/main.mjs) answer the bundle
/// and keep that address; `comments(for:)` asks the host for it (`catDanmaku`) and reads the bundle's Bilibili XML.
/// A bundle without one answers that address with 404 and the app's own matching goes on as before. Mac, iPhone and
/// iPad run bundles; tvOS has none.
public enum CatPawDanmaku {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var clients: [String: CatalogClient] = [:]

    /// Keeps the client of each CatPawOpen source that plays, for its episodes' comments.
    static func remember(_ client: CatalogClient) {
        guard client.site.raw["catPawOpen"] != nil else { return }
        lock.withLock { clients[client.site.sourceKey] = client }
    }

    static func client(for context: PlaybackHistoryContext) -> CatalogClient? {
        lock.withLock { clients[context.sourceKey] }
    }

    /// The bundle's comments for the episode, or nil when its source isn't a CatPawOpen one that played, or the
    /// bundle has none for it. Never throws: the other providers are asked next.
    public static func comments(for context: PlaybackHistoryContext) async -> AutomaticDanmakuResult? {
        guard let client = client(for: context) else { return nil }
        return await comments(for: context, source: client.site.name, http: .init()) { params in
            try await client.catPawRequest(params)
        }
    }

    static func comments(for context: PlaybackHistoryContext, source: String, http: DanmakuHTTP,
                         ask: @Sendable ([String: String]) async throws -> [String: JSONValue]) async -> AutomaticDanmakuResult? {
        let params = ["catDanmaku": "1", "name": context.videoName, "episode": context.episodeName]
        var answer: [String: JSONValue] = [:]
        // The bundle sends its address about a second after the play; the host says when one may still come.
        for attempt in 0..<8 {
            guard let reply = try? await ask(params), !Task.isCancelled else { return nil }
            answer = reply
            guard case .bool(true)? = reply["pending"], attempt < 7 else { break }
            try? await Task.sleep(for: .milliseconds(400))
        }
        guard let address = answer["url"]?.string, let url = URL(string: address), isLoopback(url) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 30)
        // The host's own calls aren't the player reading the bundle's media proxy.
        request.setValue("1", forHTTPHeaderField: "x-yingxia-host")
        let started = ContinuousClock.now
        do {
            let comments = try CatalogDanmakuParser.parse(try await http.send(request))
            Diagnostics.shared.record(.info, "danmaku.catpaw", "\(context.sourceKey) comments=\(comments.count) pushed=\(answer["pushed"] == .bool(true)) seconds=\(started.duration(to: .now).seconds)")
            guard !comments.isEmpty else { return nil }
            return AutomaticDanmakuResult(comments: comments, track: [context.videoName, context.episodeName].filter { !$0.isEmpty }.joined(separator: " · "),
                                          source: source, state: "loaded")
        } catch {
            Diagnostics.shared.record(.info, "danmaku.catpaw", "\(context.sourceKey) none: \(error)")
            return nil
        }
    }

    static func isLoopback(_ url: URL) -> Bool {
        url.scheme == "http" && ["127.0.0.1", "localhost"].contains(url.host() ?? "")
    }
}

extension CatalogClient {
    /// A call to the source's CatPawOpen bundle beside its spider routes: sign-ins, its comments' address.
    func catPawRequest(_ params: [String: String]) async throws -> [String: JSONValue] {
        #if os(macOS)
        return try await LocalJarHost.shared.request(site: site, jarURL: site.scriptURL(origin: origin), params: params, http: http, scriptOrigin: origin)
        #elseif os(iOS)
        return try await EmbeddedNodeHost.shared.request(site: site, bundleURL: site.scriptURL(origin: origin), params: params, http: http, origin: origin)
        #else
        throw TVError.unsupported(L10n.text("This device can't run CatPawOpen sources."))
        #endif
    }
}

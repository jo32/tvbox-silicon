import Foundation

/// CatPawOpen (猫源) bundles: one Node script, published as `index.js` beside its `index.js.md5`, that
/// serves its sources over HTTP the way the CatVod Open apps run it. Its `/config` lists the sources and
/// each answers at `/spider/<key>/<type>`. The Mac runs the bundle in the bundled Node host, iPhone and iPad
/// in the embedded nodejs-mobile (`EmbeddedNodeHost`); tvOS has no Node, so it cannot import one.
public enum CatPawOpen {
    /// The bundle an added address names: its checksum file (`…/index.js.md5`) or the bundle itself.
    static func bundle(_ data: Data, at url: URL) -> URL? {
        let path = url.path.lowercased()
        if path.hasSuffix(".js.md5") {
            let checksum = String(decoding: data.prefix(64), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard checksum.count == 32, checksum.allSatisfy(\.isHexDigit) else { return nil }
            return url.deletingPathExtension()
        }
        if path.hasSuffix(".js"), data.range(of: Data("catServerFactory".utf8)) != nil { return url }
        return nil
    }

    /// A bundle's own media proxy (`http://127.0.0.1:<port>/spider/<key>/<type>/proxy/…`), which streams drive files.
    static func isMediaProxy(_ url: URL) -> Bool {
        url.scheme == "http" && ["127.0.0.1", "localhost"].contains(url.host() ?? "")
            && url.path().range(of: #"^/spider/[^/]+/[^/]+/proxy/"#, options: .regularExpression) != nil
    }

    /// A bundle's media proxy address as a cloud stream, when it answers the bytes asked for. HEVC that an MP4 tags
    /// `hev1` then shows its picture instead of playing sound only (`CloudStreams.playableSampleEntries`).
    public static func proxiedMedia(_ url: URL, headers: [String: String]) async -> CloudStreams.Source? {
        guard isMediaProxy(url), let probe = try? await RangeConnection.open(url, headers: headers, from: 0, through: 1,
                                                                            configuration: RangeConnection.configuration, counter: CloudCounter()) else { return nil }
        probe.close()
        guard probe.last == 1, probe.length > 0 else { return nil }
        return CloudStreams.Source(url: url, headers: headers, length: Int(probe.length), name: url.lastPathComponent)
    }

    /// The bundle's video sources, each a type 3 source on the bundle with its `/spider/…` path in `catPawOpen`.
    static func subscription(bundle: URL, origin: URL, http: HTTPClient) async throws -> Subscription {
        #if os(macOS) || os(iOS)
        let host = Site(key: "catpaw_config", name: "CatPawOpen", type: 3, api: bundle.absoluteString, raw: ["catPawOpen": .string("")])
        #if os(macOS)
        let config = try await LocalJarHost.shared.request(site: host, jarURL: bundle, params: ["catConfig": "1"], http: http, scriptOrigin: origin)
        #else
        let config = try await EmbeddedNodeHost.shared.request(site: host, bundleURL: bundle, params: ["catConfig": "1"], http: http, origin: origin)
        #endif
        let sites = (config["video"]?.object?["sites"]?.array ?? []).compactMap { entry -> JSONValue? in
            guard var fields = entry.object, fields["type"]?.int == 3, let path = fields["api"]?.string, path.hasPrefix("/spider/") else { return nil }
            fields["api"] = .string(bundle.absoluteString)
            fields["catPawOpen"] = .string(path)
            return .object(fields)
        }
        guard !sites.isEmpty else { throw TVError.unsupported(L10n.text("This CatPawOpen bundle lists no video sources.")) }
        return try Subscription.parse(JSONEncoder().encode(["sites": JSONValue.array(sites)]), origin: origin)
        #else
        throw TVError.unsupported(L10n.text("This device can't run CatPawOpen sources."))
        #endif
    }
}

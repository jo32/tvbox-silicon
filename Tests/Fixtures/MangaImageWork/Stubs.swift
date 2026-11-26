import Foundation
import CoreGraphics
import CryptoKit
public struct MangaComic: Codable, Hashable, Sendable { public let identity: String }
enum TVError: Error { case unsupported(String), http(Int) }
enum L10n { static func text(_ text: String) -> String { text } }
enum PluginChecksum { static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() } }
enum MangaHost { static func json(_ value: Any) -> String? { (try? JSONSerialization.data(withJSONObject: value)).map { String(decoding: $0, as: UTF8.self) } } }
enum ScriptHTTP { static func text(_ data: Data, encoding: String) -> String { String(decoding: data, as: UTF8.self) } }
actor MangaRuntime {
    static let shared = MangaRuntime()
    static let throttleNotification = Notification.Name("MangaFixtureThrottle")
    struct Info { let hasImageConfig: Bool }
    struct ImageConfig: Sendable { let id: String; let request: MangaHTTP.Request; let onLoadFailed: Bool; let onResponse: Bool; let modifyImage: Bool }
    func thumbnailRequests(_ source: String, urls: [String]) -> [String: (url: String, headers: [String: String])] { [:] }
    func info(_ source: String) throws -> Info { Info(hasImageConfig: source.hasPrefix("fixture-transform")) }
    func imageConfig(_ source: String, kind: String, url: String, comic: String?, chapter: String?) throws -> ImageConfig {
        ImageConfig(id: source, request: MangaHTTP.Request(url: URL(string: url)!), onLoadFailed: false, onResponse: true, modifyImage: false)
    }
    func release(_ source: String, config: String) {}
    func retryRequest(_ source: String, config: String) -> MangaHTTP.Request? { nil }
    func transformResponse(_ source: String, config: String, data: Data) throws -> Data {
        source.hasPrefix("fixture-transform") ? Data(repeating: 1, count: 65 << 20) : data
    }
    func modify(_ source: String, config: String, image: CGImage) throws -> CGImage { image }
}

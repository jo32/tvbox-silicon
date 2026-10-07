import Foundation
import Compression

/// The plugin itself failed (crashed, could not convert, hit an Android gap) rather than its site.
/// Another archive's version of the same spider may work with this source's configuration.
public struct PluginIncompatible: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

/// A spider class the source's plugin archive does not contain.
public struct PluginClassMissing: LocalizedError, Sendable {
    public let className: String
    public let message: String
    public var errorDescription: String? { message }

    /// The class named by a CatVod `ClassNotFoundException` for `com.github.catvod.spider.<Name>`.
    static func className(in detail: String) -> String? {
        guard let range = detail.range(of: "ClassNotFoundException: com.github.catvod.spider.") else { return nil }
        let name = detail[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return name.isEmpty ? nil : String(name)
    }
}

extension Subscription {
    /// Every plugin archive the subscription names, most used first.
    public var pluginArchives: [URL] {
        var uses: [URL: Int] = [:]
        var order: [URL] = []
        for site in sites where site.runtime == .jar {
            guard let url = try? site.pluginURL(origin: origin, fallback: spiderURL) else { continue }
            if uses[url] == nil { order.append(url) }
            uses[url, default: 0] += 1
        }
        if let spider = spiderURL, uses[spider] == nil { order.append(spider) }
        return order.enumerated().sorted { (uses[$0.element] ?? 0, -$0.offset) > (uses[$1.element] ?? 0, -$1.offset) }.map(\.element)
    }
}

/// Merged subscriptions often point every source at one shared spider archive that lacks most of
/// their classes, while other archives in the same subscription carry them. This finds the
/// archive that defines a class, so such sources run as they did in their original subscription.
public actor PluginLocator {
    public static let shared = PluginLocator()
    private var candidates: [URL] = []
    private var resolved: [String: URL] = [:]
    /// Archives that worked for a specific source after its own version crashed.
    private var sources: [String: URL] = [:]
    private var classes: [String: Set<String>] = [:]
    private var unreadable: Set<URL> = []
    private let indexFile = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.tvbox.yingxia/PluginClassIndex.json")

    public func use(_ archives: [URL]) {
        guard archives != candidates else { return }
        candidates = archives
        resolved = [:]
        sources = [:]
        if classes.isEmpty, let data = try? Data(contentsOf: indexFile),
           let saved = try? JSONDecoder().decode([String: [String]].self, from: data) {
            classes = saved.mapValues(Set.init)
        }
    }

    /// The archive already found for a class, so later requests skip the failing one.
    public func known(_ className: String) -> URL? { resolved[className] }

    /// The archive that worked for this source after the shared one's version crashed.
    public func known(source key: String) -> URL? { sources[key] }
    public func remember(source key: String, archive: URL) { sources[key] = archive }

    /// Other subscription archives that define the spider class, most used first.
    public func alternatives(containing className: String, excluding: Set<URL>, limit: Int, http: HTTPClient) async -> [URL] {
        var found: [URL] = []
        for url in candidates where !excluding.contains(url) && !unreadable.contains(url) && found.count < limit {
            if let names = await classNames(in: url, http: http), names.contains(className) { found.append(url) }
        }
        return found
    }

    /// The first subscription archive other than `excluding` that defines the spider class.
    public func archive(containing className: String, excluding: URL, http: HTTPClient) async -> URL? {
        if let url = resolved[className], url != excluding { return url }
        for url in candidates where url != excluding && !unreadable.contains(url) {
            guard let names = await classNames(in: url, http: http) else { continue }
            if names.contains(className) {
                resolved[className] = url
                Diagnostics.shared.record(.info, "plugin.locate", "class=\(className) archive=\(url.lastPathComponent)")
                return url
            }
        }
        return nil
    }

    private func classNames(in url: URL, http: HTTPClient) async -> Set<String>? {
        guard let data = try? await PluginDownloads.shared.data(at: url, http: http) else { unreadable.insert(url); return nil }
        let digest = PluginChecksum.sha256(data)
        if let known = classes[digest] { return known }
        let names = Self.spiderClasses(inArchive: data)
        classes[digest] = names
        if let encoded = try? JSONEncoder().encode(classes.mapValues { $0.sorted() }) {
            try? FileManager.default.createDirectory(at: indexFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? encoded.write(to: indexFile, options: .atomic)
        }
        return names
    }

    /// Top-level `com.github.catvod.spider` classes named in the archive's DEX files.
    static func spiderClasses(inArchive archive: Data) -> Set<String> {
        var names = Set<String>()
        for dex in ZipArchive.entries(in: archive, where: { $0.hasSuffix(".dex") }) {
            let prefix = Data("Lcom/github/catvod/spider/".utf8)
            var cursor = dex.startIndex
            while let match = dex.range(of: prefix, in: cursor..<dex.endIndex) {
                var end = match.upperBound
                while end < dex.endIndex, end - match.upperBound < 128, dex[end] != UInt8(ascii: ";") { end += 1 }
                if end < dex.endIndex, dex[end] == UInt8(ascii: ";"),
                   let name = String(data: dex[match.upperBound..<end], encoding: .utf8),
                   !name.isEmpty, !name.contains("/"), !name.contains("$") { names.insert(name) }
                cursor = match.upperBound
            }
        }
        return names
    }
}

/// Just enough ZIP reading for plugin archives, including ones disguised behind image or text bytes.
enum ZipArchive {
    static func entries(in archive: Data, where include: (String) -> Bool) -> [Data] {
        let bytes = [UInt8](archive)
        func u16(_ at: Int) -> Int { at + 1 < bytes.count ? Int(bytes[at]) | Int(bytes[at + 1]) << 8 : 0 }
        func u32(_ at: Int) -> Int { at + 3 < bytes.count ? u16(at) | u16(at + 2) << 16 : 0 }
        // The end-of-central-directory record sits in the last 64 KiB plus its 22-byte header.
        var end = -1
        var position = bytes.count - 22
        while position >= max(0, bytes.count - 65_557) {
            if u32(position) == 0x0605_4b50 { end = position; break }
            position -= 1
        }
        guard end >= 0 else { return [] }
        let size = u32(end + 12), declared = u32(end + 16)
        // Bytes prepended to the archive shift every recorded offset by the same amount.
        let shift = end - size - declared
        var cursor = end - size
        var found: [Data] = []
        for _ in 0..<u16(end + 10) {
            guard cursor >= 0, u32(cursor) == 0x0201_4b50 else { break }
            let method = u16(cursor + 10), compressed = u32(cursor + 20), length = u32(cursor + 24)
            let nameLength = u16(cursor + 28), extra = u16(cursor + 30), comment = u16(cursor + 32)
            let local = u32(cursor + 42) + shift
            let name = String(decoding: bytes[min(bytes.count, cursor + 46)..<min(bytes.count, cursor + 46 + nameLength)], as: UTF8.self)
            cursor += 46 + nameLength + extra + comment
            guard include(name), local >= 0, u32(local) == 0x0403_4b50, length > 0, length < 64 << 20 else { continue }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + compressed <= bytes.count else { continue }
            if method == 0 { found.append(Data(bytes[start..<start + compressed])); continue }
            guard method == 8 else { continue }
            var output = [UInt8](repeating: 0, count: length)
            let written = bytes[start..<start + compressed].withUnsafeBufferPointer { source in
                compression_decode_buffer(&output, length, source.baseAddress!, compressed, nil, COMPRESSION_ZLIB)
            }
            if written == length { found.append(Data(output)) }
        }
        return found
    }
}

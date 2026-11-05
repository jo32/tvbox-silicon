import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Where the comic section keeps its files, and the viewer's shelf: favorites and reading history.
public enum MangaLibrary {
    public static var root: URL {
        #if os(tvOS)
        // tvOS apps have no persistent Application Support; Caches is what they keep.
        URL.cachesDirectory.appending(path: "com.tvbox.yingxia/Manga", directoryHint: .isDirectory)
        #else
        URL.applicationSupportDirectory.appending(path: "com.tvbox.yingxia/Manga", directoryHint: .isDirectory)
        #endif
    }

    /// Where reading stopped in one comic.
    public struct Progress: Codable, Hashable, Sendable, Identifiable {
        public var comic: MangaComic
        public var chapterID: String?
        public var chapterTitle: String
        public var chapterIndex: Int
        public var chapterCount: Int
        public var page: Int
        public var pageCount: Int
        public var updated: Date
        public var id: String { comic.identity }
        public init(comic: MangaComic, chapterID: String?, chapterTitle: String, chapterIndex: Int, chapterCount: Int, page: Int, pageCount: Int, updated: Date = Date()) {
            self.comic = comic; self.chapterID = chapterID; self.chapterTitle = chapterTitle; self.chapterIndex = chapterIndex
            self.chapterCount = chapterCount; self.page = page; self.pageCount = pageCount; self.updated = updated
        }
    }

    public struct Favorite: Codable, Hashable, Sendable, Identifiable {
        public var comic: MangaComic
        public var added: Date
        public var id: String { comic.identity }
        public init(comic: MangaComic, added: Date = Date()) { self.comic = comic; self.added = added }
    }

    public static func load<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        try? JSONDecoder().decode(type, from: Data(contentsOf: root.appendingPathComponent(name)))
    }
    public static func save<T: Encodable>(_ value: T, as name: String) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: root.appendingPathComponent(name), options: .atomic) }
    }
}

/// Covers and pages: requests the way each source asks (onImageLoad / onThumbnailLoad), its response and
/// unscrambling hooks, then a disk cache, so a chapter opens again at once and pages read offline.
public actor MangaImages {
    public static let shared = MangaImages()
    public enum Kind: Sendable { case page, cover }

    private var pending: [String: Task<Data, Error>] = [:]
    private var thumbnailRequests: [String: (url: String, headers: [String: String])] = [:]
    private var writes = 0
    private static var folder: URL { URL.cachesDirectory.appending(path: "com.tvbox.yingxia/MangaImages", directoryHint: .isDirectory) }
    private static let limit: Int64 = 1_000_000_000

    private static func file(_ key: String) -> URL { folder.appendingPathComponent(PluginChecksum.sha256(Data(key.utf8))) }

    /// Covers on a list: asks the source for their request headers in one call.
    public func prepareCovers(source: String, urls: [String]) async {
        let missing = urls.filter { thumbnailRequests[source + "\n" + $0] == nil && !$0.isEmpty }
        guard !missing.isEmpty else { return }
        let answers = await MangaRuntime.shared.thumbnailRequests(source, urls: missing)
        for url in missing { thumbnailRequests[source + "\n" + url] = answers[url] ?? (url, [:]) }
    }

    public func cached(source: String, url: String) -> Data? {
        try? Data(contentsOf: Self.file(source + "\n" + url))
    }

    public func data(source: String, url: String, kind: Kind, comic: String? = nil, chapter: String? = nil) async throws -> Data {
        let key = source + "\n" + url
        if let data = try? Data(contentsOf: Self.file(key)) { return data }
        if let task = pending[key] { return try await task.value }
        let thumbnail = kind == .cover ? thumbnailRequests[key] : nil
        let task = Task { try await Self.download(source: source, url: url, kind: kind, comic: comic, chapter: chapter, thumbnail: thumbnail) }
        pending[key] = task
        defer { pending[key] = nil }
        let data = try await task.value
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try? data.write(to: Self.file(key), options: .atomic)
        writes += 1
        if writes % 80 == 0 { Task.detached(priority: .background) { Self.trim() } }
        return data
    }

    private static func download(source: String, url: String, kind: Kind, comic: String?, chapter: String?,
                                 thumbnail: (url: String, headers: [String: String])?) async throws -> Data {
        let runtime = MangaRuntime.shared
        let info = try? await runtime.info(source)
        var config: MangaRuntime.ImageConfig?
        var request: MangaHTTP.Request
        if kind == .page, info?.hasImageConfig == true {
            config = try await runtime.imageConfig(source, kind: "image", url: url, comic: comic, chapter: chapter)
            request = config!.request
        } else if let thumbnail, let target = URL(string: thumbnail.url) {
            request = MangaHTTP.Request(url: target, headers: thumbnail.headers)
        } else {
            guard let target = URL(string: url) ?? url.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:)) else {
                throw TVError.unsupported(L10n.text("The page address is invalid."))
            }
            request = MangaHTTP.Request(url: target)
        }
        defer { if let config { Task { await runtime.release(source, config: config.id) } } }
        var (data, response) = try await MangaHTTP.data(request)
        if !(200..<300).contains(response.statusCode), let config, config.onLoadFailed, let retry = await runtime.retryRequest(source, config: config.id) {
            (data, response) = try await MangaHTTP.data(retry)
        }
        guard (200..<300).contains(response.statusCode) else { throw TVError.http(response.statusCode) }
        if let config, config.onResponse { data = try await runtime.transformResponse(source, config: config.id, data: data) }
        if let config, config.modifyImage, let image = decode(data) {
            let modified = try await runtime.modify(source, config: config.id, image: image)
            if let encoded = encode(modified) { data = encoded }
        }
        guard CGImageSourceCreateWithData(data as CFData, nil).map({ CGImageSourceGetCount($0) > 0 }) == true else {
            throw TVError.unsupported(L10n.text("The source sent something that is not an image."))
        }
        return data
    }

    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    static func encode(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Oldest files first until the cache is under its limit.
    nonisolated static func trim() {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        var entries = files.compactMap { file -> (URL, Int64, Date)? in
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (file, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        guard total > limit else { return }
        entries.sort { $0.2 < $1.2 }
        for entry in entries where total > limit * 8 / 10 {
            try? manager.removeItem(at: entry.0)
            total -= entry.1
        }
    }

    public nonisolated static func clearCache() { try? FileManager.default.removeItem(at: folder) }
    public nonisolated static func cacheSize() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// The image scaled to `width` pixels wide (never up), for display; tall strips keep their full length.
    public nonisolated static func bitmap(_ data: Data, width: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pixelWidth = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let pixelHeight = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        let longest = max(pixelWidth, pixelHeight)
        let scale = pixelWidth > 0 ? min(1, Double(width) / pixelWidth) : 1
        let maximum = longest > 0 ? max(64, longest * scale) : Double(width) * 3
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maximum, 16000),
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }
}

import Foundation
// Unrelated catalog/cache boundaries, so the real history and writer compile without native media libraries.
public struct Site { public let sourceKey: String; public let name: String; public func origin(or fallback: URL) -> URL { fallback } }
public struct Video { public let id: String; public let name: String; public let poster: URL?; public let year: String?; public let posterHeaders: [String: String] }
public struct Episode: Equatable { public let id: String; public let name: String; public let address: String; public let flag: String }
enum EpisodeSkipSettings { static func scope(origin: URL, source: String, video: String) -> String { origin.absoluteString + source + video }; static func remove(scope: String, defaults: UserDefaults) {} }
enum OfficialVideoPage { static func validated(_ value: String) -> URL? { nil } }
enum PosterResource { static func artworkScope(_ url: URL) -> String { url.absoluteString } }
enum CatalogDanmakuMatcher { static func episodeNumber(_ name: String) -> Int? { nil } }
struct EpisodePlaylist { init(_ episodes: [Episode]) {}; func next(after context: PlaybackHistoryContext) -> Episode? { nil } }
enum CloudFiles { static let sourceKey = "cloud" }
public struct FavoriteCloudFile { init(driveKey: String, folderID: String, folderName: String, fileID: String, fileName: String, size: Int) {} }
public struct FavoriteVideo { init(origin: URL, sourceKey: String, sourceName: String, videoID: String, videoName: String, poster: URL?, posterHeaders: [String: String], year: String?) {} }
public enum FavoriteItem { case cloud(FavoriteCloudFile), video(FavoriteVideo) }
public struct HiddenSources { let isEmpty = true; func contains(_ context: PlaybackHistoryContext) -> Bool { false } }
public final class MediaCache: @unchecked Sendable { public static let shared = MediaCache(); public func prioritize(_ scopes: Set<String>) {}; public func remove(scope: String) {} }
// Instrument only the I/O boundary in a temporary source copy. Production encode/write code is unchanged.
enum WriteProbe {
    static let lock = NSLock()
    nonisolated(unsafe) static var writes = 0
    nonisolated(unsafe) static var mainWrites = 0
    nonisolated(unsafe) static var fail = false
    static func beforeWrite() throws {
        let shouldFail = lock.withLock { writes += 1; if Thread.isMainThread { mainWrites += 1 }; return fail }
        Thread.sleep(forTimeInterval: 0.15)
        if shouldFail { throw CocoaError(.fileWriteNoPermission) }
    }
}

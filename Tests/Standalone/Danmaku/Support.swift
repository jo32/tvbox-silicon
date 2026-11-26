import Foundation
// The fixture compiles the complete production resolver/client/cache. Only unrelated app boundaries are replaced.
public struct PlaybackHistoryContext: Sendable {
    public let origin: URL; public let sourceKey: String; public let sourceName: String; public let videoID: String; public let videoName: String
    public let episodeID: String; public let episodeName: String; public let episodeFlag: String
    public var year: String?; public var officialPage: URL?; public var posterHeaders: [String: String]?
    public var id: String { origin.absoluteString + sourceKey + videoID }
    public init(origin: URL, sourceKey: String, sourceName: String, videoID: String, videoName: String, episodeID: String, episodeName: String, episodeFlag: String) {
        self.origin=origin; self.sourceKey=sourceKey; self.sourceName=sourceName; self.videoID=videoID; self.videoName=videoName; self.episodeID=episodeID; self.episodeName=episodeName; self.episodeFlag=episodeFlag
    }
}
public enum TVError: Error { case invalidURL, invalidConfiguration, http(Int), unsupported(String) }
enum L10n { static func text(_ value: String, _ arguments: CVarArg...) -> String { value } }
enum HTMLText { static func plain(_ value: String) -> String { value } }
enum Diagnostics { static let shared = Logger(); enum Level { case debug, info, warning }; struct Logger: Sendable { func record(_ level: Level, _ category: String, _ text: String) {} } }

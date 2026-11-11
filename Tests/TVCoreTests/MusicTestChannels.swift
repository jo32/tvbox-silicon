import Foundation
@testable import TVCore

/// Channels for tests, named and ordered as a subscription might list them: the app itself knows none.
extension MusicProviderID {
    static let vkeys = MusicProviderID(rawValue: "vkeys")
    static let gdstudio = MusicProviderID(rawValue: "gdstudio")
    static let hyw = MusicProviderID(rawValue: "hyw")
    static let migu = MusicProviderID(rawValue: "migu")
    static let nianxin = MusicProviderID(rawValue: "nianxin")
    static let xinghai = MusicProviderID(rawValue: "xinghai")
}

extension MusicRoutes {
    static let test = MusicRoutes(order: [
        Route(.migu, .migu), Route(.kuwo, .nianxin), Route(.qq, .vkeys), Route(.netease, .gdstudio),
        Route(.kuwo, .xinghai), Route(.netease, .nianxin), Route(.qq, .hyw), Route(.netease, .xinghai),
        Route(.qq, .lx), Route(.netease, .lx), Route(.kuwo, .lx), Route(.migu, .lx),
    ], primaries: 4)
}

/// A channel that has nothing: for tests of the order channels are asked in.
struct EmptyMusicProvider: MusicStreamProvider {
    let id: MusicProviderID
    let platforms: Set<MusicPlatform>
    func resolve(_ songID: String, platform: MusicPlatform, quality: MusicAudioQuality) async throws -> ResolvedMusicStream { throw MusicProviderError.noResource }
}

import Foundation

/// Turns a catalog song ID into a temporary audio address. A provider's answer is only a claim:
/// `MusicProber` reads what the address actually serves. The app holds no service's own logic: providers are
/// the subscription's channels (`CloudMusicProvider`) and the scripts the listener imports.
public protocol MusicStreamProvider: Sendable {
    var id: MusicProviderID { get }
    var platforms: Set<MusicPlatform> { get }
    /// Asks for `quality`: lossless, or 320 or 128 kbps lossy audio. A provider that can't ask for
    /// that tier plays its best instead, and probing tells what came back.
    func resolve(_ songID: String, platform: MusicPlatform, quality: MusicAudioQuality) async throws -> ResolvedMusicStream
    /// The same, for providers that also want the song's title and artist (LX Music sources).
    func resolve(_ songID: String, platform: MusicPlatform, track: MusicTrack?, quality: MusicAudioQuality) async throws -> ResolvedMusicStream
}

extension MusicStreamProvider {
    public func resolve(_ songID: String, platform: MusicPlatform, track: MusicTrack?, quality: MusicAudioQuality) async throws -> ResolvedMusicStream {
        try await resolve(songID, platform: platform, quality: quality)
    }
}

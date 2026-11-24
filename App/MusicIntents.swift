#if os(iOS)
import AppIntents
import TVCore

// Siri, Spotlight and Shortcuts (#845). "Play music in Yingxia" carries on where the music stopped, or plays the
// liked songs when there is nothing to carry on; "Shuffle my liked songs in Yingxia" shuffles them. Pause, Next and
// the rest already reach the app through the system's Now Playing controls. App Shortcuts need no Siri entitlement,
// and an audio intent plays without bringing the app to the front. Titles and phrases are in App/Resources/*.lproj.

struct PlayMusicIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Music"
    static let description = IntentDescription("Carries on with the music you were listening to, or plays your liked songs.")

    @MainActor func perform() async throws -> some IntentResult {
        let music = Store.shared.music
        if music.track != nil {
            if !music.isPlaying { music.toggle() }
        } else if music.library.resumePoint != nil {
            music.resume()
        } else {
            try MusicIntents.playLiked(shuffled: false)
        }
        return .result()
    }
}

struct ShuffleLikedSongsIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Shuffle Liked Songs"
    static let description = IntentDescription("Shuffles the songs you liked.")

    @MainActor func perform() async throws -> some IntentResult {
        try MusicIntents.playLiked(shuffled: true)
        return .result()
    }
}

enum MusicIntents {
    @MainActor static func playLiked(shuffled: Bool) throws {
        let tracks = Store.shared.favorites.musicTracks
        guard !tracks.isEmpty else { throw MusicIntentError.noLikedSongs }
        let source = MusicLikedView.title
        Store.shared.music.play(shuffled ? .shuffled(tracks, source: source) : MusicQueue(tracks: tracks, start: 0, source: source))
    }
}

enum MusicIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noLikedSongs
    var localizedStringResource: LocalizedStringResource {
        "You have no liked songs yet. Like a song from its menu first."
    }
}

struct YingxiaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayMusicIntent(), phrases: [
            "Play music in \(.applicationName)",
            "Play music with \(.applicationName)",
            "Resume music in \(.applicationName)",
        ], shortTitle: "Play Music", systemImageName: "music.note")
        AppShortcut(intent: ShuffleLikedSongsIntent(), phrases: [
            "Shuffle my liked songs in \(.applicationName)",
            "Play my liked songs in \(.applicationName)",
        ], shortTitle: "Shuffle Liked Songs", systemImageName: "heart.fill")
    }
}
#endif

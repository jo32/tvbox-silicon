import Foundation
import Testing
@testable import TVCore

private func song(_ title: String, _ id: String) -> MusicTrack {
    MusicTrack(platform: .qq, songID: id, title: title, artists: ["A"], duration: 200)
}

/// #1568: the listener's own playlists keep their names, their songs in order, and survive a restart.
@MainActor @Test func playlistsAreMadeFilledRenamedAndKept() throws {
    let suite = "playlists-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let playlists = MusicPlaylists(defaults: defaults)
    let a = song("A", "1"), b = song("B", "2"), c = song("C", "3")

    // From a song's menu: no name is asked, so it takes the fallback, numbered when taken.
    let first = playlists.create(name: "", fallback: "New Playlist", tracks: [a, a])
    let second = playlists.create(name: "  ", fallback: "New Playlist")
    let named = playlists.create(name: " Road ", fallback: "New Playlist")
    #expect(first.name == "New Playlist" && second.name == "New Playlist 2" && named.name == "Road")
    #expect(first.tracks == [a])
    // Newest first.
    #expect(playlists.playlists.map(\.id) == [named.id, second.id, first.id])

    // A song is in a playlist once, in the order added.
    #expect(playlists.add([b, a, c], to: first.id) == 2)
    #expect(playlists.add([b], to: first.id) == 0)
    #expect(playlists.add([b], to: "missing") == 0)
    #expect(playlists.playlist(first.id)?.tracks == [a, b, c])
    playlists.remove(b, from: first.id)
    #expect(playlists.playlist(first.id)?.tracks == [a, c])

    playlists.rename(first.id, to: " Evening ")
    playlists.rename(second.id, to: "   ")
    #expect(playlists.playlist(first.id)?.name == "Evening" && playlists.playlist(second.id)?.name == "New Playlist 2")
    playlists.delete(second.id)

    let reopened = MusicPlaylists(defaults: defaults)
    #expect(reopened.playlists.map(\.name) == ["Road", "Evening"])
    #expect(reopened.playlist(first.id)?.tracks == [a, c])
}

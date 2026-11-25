import Foundation
import Combine

/// A playlist the listener made (#1568): a name and songs, in the order they were added.
public struct MusicPlaylist: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var tracks: [MusicTrack]
    public var created: Date

    public init(id: String = UUID().uuidString, name: String, tracks: [MusicTrack] = [], created: Date = Date()) {
        self.id = id; self.name = name; self.tracks = tracks; self.created = created
    }
}

/// The listener's own playlists, newest first, kept in user defaults beside the favorites (and so per profile).
@MainActor public final class MusicPlaylists: ObservableObject {
    @Published public private(set) var playlists: [MusicPlaylist] = []
    private let defaults: UserDefaults
    private static let storageKey = "musicPlaylists"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey), let saved = try? JSONDecoder().decode([MusicPlaylist].self, from: data) {
            playlists = saved
        }
    }

    public func playlist(_ id: String) -> MusicPlaylist? { playlists.first { $0.id == id } }

    /// A new playlist at the top. A blank name becomes `fallback`, numbered when that name is taken.
    @discardableResult public func create(name: String, fallback: String, tracks: [MusicTrack] = []) -> MusicPlaylist {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var unique: [MusicTrack] = []
        for track in tracks where !unique.contains(where: { $0.id == track.id }) { unique.append(track) }
        let playlist = MusicPlaylist(name: typed.isEmpty ? unused(fallback) : typed, tracks: unique)
        playlists.insert(playlist, at: 0)
        save()
        return playlist
    }

    /// Adds the songs not already in the playlist, at its end. Returns how many were added.
    @discardableResult public func add(_ tracks: [MusicTrack], to id: String) -> Int {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return 0 }
        var added = 0
        for track in tracks where !playlists[index].tracks.contains(where: { $0.id == track.id }) {
            playlists[index].tracks.append(track); added += 1
        }
        if added > 0 { save() }
        return added
    }

    public func remove(_ track: MusicTrack, from id: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].tracks.removeAll { $0.id == track.id }
        save()
    }

    /// A blank name keeps the old one.
    public func rename(_ id: String, to name: String) {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].name = typed
        save()
    }

    public func delete(_ id: String) {
        playlists.removeAll { $0.id == id }
        save()
    }

    /// `name`, or `name 2`, `name 3`… when playlists already use it.
    private func unused(_ name: String) -> String {
        let taken = Set(playlists.map(\.name))
        guard taken.contains(name) else { return name }
        var number = 2
        while taken.contains("\(name) \(number)") { number += 1 }
        return "\(name) \(number)"
    }

    private func save() {
        if let data = try? JSONEncoder().encode(playlists) { defaults.set(data, forKey: Self.storageKey) }
    }
}

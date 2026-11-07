import Foundation

/// Narrows music search results by release decade, genre and language (#649), as Spotify's `year:` and
/// `genre:` search terms do. Apple Music's search only picks a kind (Songs, Artists, Albums…) and leaves
/// genres to Browse, so the kind chips come first and these sit after them.
///
/// Only QQ Music's search lists a song's release date, genre and language. Another catalog's song carries
/// them when it is the same recording as a QQ song; a song nobody labelled is hidden while a filter that
/// needs the label is on. Albums carry only a year, and playlists none, so the other filters leave them be.
public struct MusicSearchFilter: Hashable, Codable, Sendable {
    public var decade: MusicDecade?
    public var genre: MusicGenre?
    public var language: MusicLanguage?
    public init(decade: MusicDecade? = nil, genre: MusicGenre? = nil, language: MusicLanguage? = nil) {
        self.decade = decade; self.genre = genre; self.language = language
    }

    public var isEmpty: Bool { decade == nil && genre == nil && language == nil }

    public func admits(_ track: MusicTrack) -> Bool {
        if let decade, !(track.year.map(decade.contains) ?? false) { return false }
        if let genre, track.genre != genre { return false }
        if let language, track.language != language { return false }
        return true
    }

    public func admits(_ collection: MusicCollection) -> Bool {
        guard collection.kind == .album, let decade else { return true }
        return collection.year.flatMap { Int($0.prefix(4)) }.map(decade.contains) ?? false
    }

    /// The filters a kind's results can be narrowed by: none for playlists, the year for albums.
    public static func facets(for kind: MusicSearchKind) -> [Facet] {
        switch kind {
        case .playlists: []
        case .albums: [.decade]
        case .songs, .artists, .top: Facet.allCases
        }
    }

    public enum Facet: String, CaseIterable, Sendable { case decade, genre, language }
}

/// When a song or album came out, by decade; the last one is everything before 1980.
public enum MusicDecade: Int, Codable, Sendable, CaseIterable, Hashable {
    case d2020 = 2020, d2010 = 2010, d2000 = 2000, d1990 = 1990, d1980 = 1980, earlier = 0

    public func contains(_ year: Int) -> Bool {
        self == .earlier ? year < 1980 : (rawValue..<(rawValue + 10)).contains(year)
    }

    public var name: String {
        // A String, not %lld: L10n would print 2,020.
        self == .earlier ? L10n.text("Before 1980") : L10n.text("%@s", String(rawValue))
    }
}

/// A song's genre as QQ Music lists it. Dance and Electronica are one genre here, as are New Age and Easy Listening.
public enum MusicGenre: String, Codable, Sendable, CaseIterable, Hashable {
    case pop, rock, hipHop, rnb, electronic, folk, jazz, blues, classical, country, latin, metal, reggae, soundtrack, newAge

    /// QQ's `genre` numbers, as its song details name them (checked on 2026-11-07 against ~130 songs).
    public init?(qqCode: Int) {
        switch qqCode {
        case 1: self = .pop
        case 2: self = .classical
        case 3: self = .jazz
        case 15: self = .blues
        case 19: self = .country
        case 20, 22: self = .electronic
        case 21, 31: self = .newAge
        case 23: self = .folk
        case 27: self = .latin
        case 28: self = .metal
        case 33: self = .rnb
        case 34: self = .hipHop
        case 35: self = .reggae
        case 36: self = .rock
        case 37: self = .soundtrack
        default: return nil
        }
    }

    public var name: String {
        switch self {
        case .pop: L10n.text("Pop")
        case .rock: L10n.text("Rock")
        case .hipHop: L10n.text("Hip-Hop/Rap")
        case .rnb: L10n.text("R&B/Soul")
        case .electronic: L10n.text("Electronic/Dance")
        case .folk: L10n.text("Folk")
        case .jazz: L10n.text("Jazz")
        case .blues: L10n.text("Blues")
        case .classical: L10n.text("Classical")
        case .country: L10n.text("Country")
        case .latin: L10n.text("Latin")
        case .metal: L10n.text("Metal")
        case .reggae: L10n.text("Reggae")
        case .soundtrack: L10n.text("Soundtrack")
        case .newAge: L10n.text("New Age/Easy Listening")
        }
    }
}

/// The language a song is sung in, as QQ Music lists it; `instrumental` has no singing.
public enum MusicLanguage: String, Codable, Sendable, CaseIterable, Hashable {
    case mandarin, cantonese, english, japanese, korean, spanish, instrumental

    /// QQ's `language` numbers, as its song details name them (checked on 2026-11-07).
    public init?(qqCode: Int) {
        switch qqCode {
        case 0: self = .mandarin
        case 1: self = .cantonese
        case 3: self = .japanese
        case 4: self = .korean
        case 5: self = .english
        case 9: self = .instrumental
        case 16: self = .spanish
        default: return nil
        }
    }

    public var name: String {
        switch self {
        case .mandarin: L10n.text("Mandarin")
        case .cantonese: L10n.text("Cantonese")
        case .english: L10n.text("English")
        case .japanese: L10n.text("Japanese")
        case .korean: L10n.text("Korean")
        case .spanish: L10n.text("Spanish")
        case .instrumental: L10n.text("No Vocals")
        }
    }
}

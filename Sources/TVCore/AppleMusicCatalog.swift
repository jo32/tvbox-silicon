import Foundation

/// Apple Music's catalog, through the yingxia-music Worker (Services/apple-music), as TMDB comes through yingxia-tmdb:
/// the Worker holds the MusicKit key, so viewers need no Apple Music account and see no permission prompt. It adds what
/// QQ Music and NetEase don't say: artists' pictures and notes, albums' notes and labels, ISRCs, and the song a source's
/// file is. Nothing here is needed to play: when the Worker can't answer, the pages show what they showed before.
public actor AppleMusicCatalog {
    public static let shared = AppleMusicCatalog()
    public static let endpoint = URL(string: "https://yingxia-music.getmegaportal.com/v1/")!

    public struct Song: Codable, Hashable, Sendable {
        public var id: String
        public var title: String
        public var artist: String
        public var artists: [String]
        public var album: String?
        public var duration: Double?
        public var isrc: String?
        public var released: String?
        public var genres: [String]
        public var artwork: String?
        public var url: URL?
    }

    public struct AlbumBrief: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var artist: String
        public var released: String?
        public var artwork: String?
        public var trackCount: Int?
        public var url: URL?
        public var year: String? { released.map { String($0.prefix(4)) } }
    }

    public struct Album: Codable, Hashable, Sendable {
        public var id: String
        public var title: String
        public var artist: String
        public var released: String?
        public var artwork: String?
        public var trackCount: Int?
        public var url: URL?
        public var notes: String?
        public var label: String?
        public var genres: [String]
        public var copyright: String?
        public var tracks: [Song]
    }

    public struct Artist: Codable, Hashable, Sendable {
        public var id: String
        public var name: String
        public var genres: [String]
        public var artwork: String?
        public var notes: String?
        public var url: URL?
        public var topSongs: [Song]
        public var albums: [AlbumBrief]
    }

    /// An Apple artwork template (`…/{w}x{h}bb.jpg`) at `side` pixels square.
    public static func artwork(_ template: String?, side: Int) -> URL? {
        guard let template, !template.isEmpty else { return nil }
        return URL(string: template.replacingOccurrences(of: "{w}", with: String(side)).replacingOccurrences(of: "{h}", with: String(side))
            .replacingOccurrences(of: "{f}", with: "jpg"))
    }

    /// An artist's songs with the ones Apple Music ranks as their top songs first, in that order; the rest as found.
    /// A different version (a live take of a top song) is not moved up.
    public static func ranked(_ tracks: [MusicTrack], top: [Song]) -> [MusicTrack] {
        var rest = tracks, first: [MusicTrack] = []
        for song in top {
            let title = MusicMatching.baseTitle(song.title), tags = MusicMatching.tags(in: song.title)
            if let index = rest.firstIndex(where: { MusicMatching.baseTitle($0.title) == title && $0.tags == tags }) {
                first.append(rest.remove(at: index))
            }
        }
        return first + rest
    }

    /// The storefront whose names read in the app's language: mainland China's for Simplified Chinese, and so on.
    public static func storefront(language: String = L10n.resolvedLanguage()) -> String {
        switch language {
        case "zh-Hans": "cn"
        case "zh-Hant": "tw"
        case "ja": "jp"
        default: "us"
        }
    }

    private let transport: MusicTransport
    private let base: URL
    private let storefront: String
    /// Answers by question, found or not, for this run of the app; the Worker and its edge keep them for a day.
    private var answers: [String: Data] = [:]
    private var pending: [String: Task<Data?, Never>] = [:]

    public init(transport: MusicTransport = URLSessionMusicTransport(), base: URL = AppleMusicCatalog.endpoint, storefront: String = AppleMusicCatalog.storefront()) {
        self.transport = transport; self.base = base; self.storefront = storefront
    }

    /// The catalog song that is this recording: the same title, one of the artists, and about the same length.
    public func identify(title: String, artists: [String], duration: Double?) async -> Song? {
        var items = [URLQueryItem(name: "title", value: title)] + artists.prefix(4).map { URLQueryItem(name: "artist", value: $0) }
        if let duration, duration > 0 { items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded())))) }
        return await ask("identify", items, Wrapped<Song>.self)
    }

    public func artist(named name: String) async -> Artist? {
        await ask("artist", [URLQueryItem(name: "name", value: name)], Wrapped<Artist>.self)
    }

    public func album(title: String, artist: String?) async -> Album? {
        var items = [URLQueryItem(name: "title", value: title)]
        if let artist, !artist.isEmpty { items.append(URLQueryItem(name: "artist", value: artist)) }
        return await ask("album", items, Wrapped<Album>.self)
    }

    private struct Wrapped<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: AnyKey.self)
            value = try container.allKeys.first.flatMap { try container.decodeIfPresent(Value.self, forKey: $0) }
        }
    }
    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private func ask<Value: Decodable>(_ path: String, _ items: [URLQueryItem], _ type: Wrapped<Value>.Type) async -> Value? {
        guard var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = items + [URLQueryItem(name: "storefront", value: storefront)]
        guard let url = components.url else { return nil }
        let id = url.absoluteString
        let data: Data?
        if let kept = answers[id] { data = kept }
        else if let running = pending[id] { data = await running.value }
        else {
            let transport = self.transport
            let task = Task<Data?, Never> {
                var request = URLRequest(url: url, timeoutInterval: 8)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                guard let response = try? await transport.send(request, limit: 512 * 1024), response.status == 200 else { return nil }
                return response.body
            }
            pending[id] = task
            data = await task.value
            pending[id] = nil
            // Failures are asked again next time; answers, found or not, are kept.
            if let data { answers[id] = data }
        }
        guard let data else { return nil }
        return (try? JSONDecoder().decode(type, from: data))?.value
    }
}

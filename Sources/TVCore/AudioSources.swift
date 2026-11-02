import Foundation

/// An episode of a TVBox source that plays in the music player (#289): a chapter of an audiobook, a radio
/// show, a song. Its stream comes from the source, as a video's does, not from a music channel.
public struct MusicSourceEpisode: Codable, Hashable, Sendable {
    /// The book and the chapter, as the playback history keeps them: where listening stopped is saved under
    /// the book, like a series under its title.
    public var context: PlaybackHistoryContext
    /// The episode's play address, which the source turns into a stream.
    public var address: String
    public init(context: PlaybackHistoryContext, address: String) {
        self.context = context; self.address = address
    }
    public var episode: Episode {
        Episode(id: context.episodeID, name: context.episodeName, address: address, flag: context.episodeFlag, videoID: context.videoID)
    }
}

extension MusicTrack {
    /// A source's episode as a track: the episode's name, the book as its artist, the book's cover.
    public init(source context: PlaybackHistoryContext, address: String) {
        id = "source:" + context.id + "|" + context.episodeFlag + "|" + context.episodeID
        title = context.episodeName
        artists = [context.videoName]
        album = nil
        duration = nil
        artwork = context.poster
        tags = []
        ids = [:]
        evidence = []
        source = MusicSourceEpisode(context: context, address: address)
    }
}

/// TVBox sources for listening rather than watching: audiobooks (听书), radio (电台) and music.
/// Their episodes open in the music player, with the cover, the chapters as the queue, background playback and the
/// Lock Screen. A name is only a hint: the player checks the stream and hands one with a picture to the video player.
public enum AudioSources {
    /// Words in a source's name that mean listening. Not 儿歌: those sources mostly serve cartoon videos (BabyBus, Beva).
    static let audioWords = ["听书", "有声", "音乐", "电台", "广播", "相声", "评书", "播客", "舞曲", "听歌", "FM", "Radio", "Podcast"]
    /// Words that mean video even beside one of those: dance lessons (跳舞┃教学), opera (戏曲), karaoke (KTV┃音乐), MVs.
    static let videoWords = ["跳舞", "舞蹈", "教学", "戏曲", "视频", "MV", "KTV", "直播", "影视", "电影", "短剧", "动漫", "4K"]
    /// Spider classes that only serve audio, whatever the source is called.
    static let audioClasses = ["tingshu", "audiobook", "ximalaya", "podcast", "radio"]
    /// Episodes queued at once: a long book is played from a window of its chapters around the one chosen, so the
    /// saved queue stays the size of a playlist.
    public static let queueLimit = 200

    public static func isCandidate(_ site: Site) -> Bool { isCandidate(name: site.name, api: site.api) }

    public static func isCandidate(name: String, api: String) -> Bool {
        if videoWords.contains(where: { name.localizedCaseInsensitiveContains($0) }) { return false }
        if audioWords.contains(where: { name.contains($0) }) { return true }
        let spider = api.lowercased()
        return audioClasses.contains { spider.contains($0) }
    }

    /// `episode` and the episodes around it on its line, in the source's order, starting at `episode`.
    public static func queue(video: Video, from episode: Episode, site: Site, origin: URL) -> MusicQueue {
        var line = video.episodes.filter { $0.flag == episode.flag }
        var start = line.firstIndex { $0.id == episode.id } ?? -1
        if start < 0 { line = [episode]; start = 0 }
        let first = max(0, min(start - queueLimit / 10, line.count - queueLimit))
        let window = line[first..<min(line.count, first + queueLimit)]
        let tracks = window.map { MusicTrack(source: PlaybackHistoryContext(origin: origin, site: site, video: video, episode: $0), address: $0.address) }
        return MusicQueue(tracks: tracks, start: start - first)
    }
}

/// Sources whose streams turned out to have a picture, by source: their episodes open in the video player
/// from then on, without trying the music player first.
public struct AudioSourceVerdicts {
    static let key = "audioSourcesWithVideo"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func id(_ context: PlaybackHistoryContext) -> String { context.origin.absoluteString + "|" + context.sourceKey }

    public func showsVideo(_ context: PlaybackHistoryContext) -> Bool {
        (defaults.stringArray(forKey: Self.key) ?? []).contains(Self.id(context))
    }

    public func recordVideo(_ context: PlaybackHistoryContext) {
        var known = defaults.stringArray(forKey: Self.key) ?? []
        guard !known.contains(Self.id(context)) else { return }
        known.append(Self.id(context))
        defaults.set(Array(known.suffix(200)), forKey: Self.key)
    }
}

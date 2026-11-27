import Foundation

public extension PlaybackSkipLookup.Media {
    /// The viewer's explicit choice wins over a cached automatic match, including "None of these".
    static func match(answer: TMDBMatch.Answer?, choice: TMDBMatchStore.Choice?) -> TMDBMatch.Match? {
        if let choice {
            switch choice {
            case .none: return nil
            case .work(let type, let id, let season):
                guard id > 0 else { return nil }
                let previous = answer?.match
                let sameWork = previous?.id == id && previous?.mediaType == type
                return TMDBMatch.Match(mediaType: type, id: id, season: season,
                                       numbering: previous?.numbering ?? answer?.numbering ?? .season,
                                       offset: sameWork ? previous?.offset : nil, confidence: 1, unmatched: "")
            }
        }
        guard answer?.status == .matched, let match = answer?.match, match.id > 0 else { return nil }
        return match
    }

    /// A confirmed catalog match, with the source's episode converted to TMDB's season numbering.
    /// A title or an unnumbered episode alone is not enough to safely skip part of a video.
    init?(match: TMDBMatch.Match, details: TMDBMatch.Details?, episodeName: String, duration: Double) {
        guard match.id > 0, duration.isFinite, duration > 0 else { return nil }
        let details = details.flatMap { $0.id == match.id && $0.mediaType == match.mediaType ? $0 : nil }
        if match.mediaType == .movie {
            self.init(tmdbID: match.id, imdbID: details?.imdbID, isMovie: true, duration: duration)
            return
        }
        guard let season = match.season, (0...9999).contains(season),
              let sourceNumber = TMDBMatch.episodeNumber(episodeName), sourceNumber > 0 else { return nil }
        let episode: Int
        switch match.numbering {
        case .season:
            let shifted = sourceNumber.addingReportingOverflow(match.offset ?? 0)
            guard !shifted.overflow else { return nil }
            if let details, details.season?.number == season {
                // The same mapping the episode list shows also handles sources that already use TMDB's numbers.
                guard let mapped = details.episodes(for: [episodeName], numbering: .season, offset: match.offset ?? 0).first ?? nil else { return nil }
                episode = mapped.number
            } else {
                episode = shifted.partialValue
            }
        case .absolute:
            // Never send an absolute episode as S01E<n>. Without every earlier season's count it is ambiguous.
            guard let details, details.season?.number == season, season > 0 else { return nil }
            let counts = Dictionary(details.seasons.map { ($0.number, $0.episodeCount) }, uniquingKeysWith: { first, _ in first })
            var before = 0
            for number in 1..<season {
                guard let count = counts[number], (0...10000).contains(count) else { return nil }
                before += count
            }
            episode = sourceNumber - before
            guard details.season?.episodes.contains(where: { $0.number == episode }) == true else { return nil }
        }
        guard (1...10000).contains(episode) else { return nil }
        self.init(tmdbID: match.id, imdbID: details?.imdbID, season: season, episode: episode, duration: duration)
    }
}

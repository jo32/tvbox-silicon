import Foundation
import Testing
@testable import TVCore

struct PlaybackSkipIdentityTests {
    private typealias Media = PlaybackSkipLookup.Media

    private func match(type: TMDBMatch.MediaType = .tv, id: Int = 42, season: Int? = 2,
                       numbering: TMDBMatch.Numbering = .season, offset: Int? = nil) -> TMDBMatch.Match {
        TMDBMatch.Match(mediaType: type, id: id, season: season, numbering: numbering, offset: offset, confidence: 0.9, unmatched: "")
    }

    private func answer(_ match: TMDBMatch.Match?, status: TMDBMatch.Status = .matched) -> TMDBMatch.Answer {
        TMDBMatch.Answer(status: status, match: match, season: match?.season, numbering: match?.numbering ?? .season,
                         unmatched: "", candidates: [], details: nil)
    }

    private func details(type: TMDBMatch.MediaType = .tv, id: Int = 42, season: Int? = 2,
                         episodes: [Int] = Array(1...10), seasons: [(Int, Int)] = [(1, 12), (2, 10)],
                         imdbField: String = #","imdbID":"tt1234567""#) throws -> TMDBMatch.Details {
        let list = episodes.map { #"{"number":\#($0),"name":"E\#($0)","overview":""}"# }.joined(separator: ",")
        let summaries = seasons.map { #"{"number":\#($0.0),"name":"S\#($0.0)","episodeCount":\#($0.1)}"# }.joined(separator: ",")
        let selected = season.map { #"{"number":\#($0),"name":"S","overview":"","episodes":[\#(list)]}"# } ?? "null"
        let json = #"""
        {"mediaType":"\#(type.rawValue)","id":\#(id)\#(imdbField),"name":"Title","originalName":"Title","tagline":"","overview":"",
         "genres":[],"voteCount":0,"countries":[],"cast":[],"crew":[],"networks":[],"seasons":[\#(summaries)],
         "season":\#(selected),"link":"https://www.themoviedb.org/\#(type.rawValue)/\#(id)"}
        """#
        return try JSONDecoder().decode(TMDBMatch.Details.self, from: Data(json.utf8))
    }

    @Test func explicitChoicesTakePrecedenceOverAutomaticMatches() throws {
        let previous = answer(match(offset: 12))
        #expect(Media.match(answer: previous, choice: TMDBMatchStore.Choice.none) == nil)
        let chosen = try #require(Media.match(answer: previous, choice: .work(.tv, 99, season: 3)))
        #expect(chosen.id == 99 && chosen.mediaType == .tv && chosen.season == 3 && chosen.offset == nil)
        #expect(Media.match(answer: previous, choice: .work(.movie, 42, season: nil))?.offset == nil)
        #expect(Media.match(answer: previous, choice: .work(.tv, 42, season: 2))?.offset == 12)
        #expect(Media.match(answer: nil, choice: .work(.tv, 99, season: 1))?.id == 99)
        #expect(Media.match(answer: previous, choice: .work(.tv, 0, season: 1)) == nil)
    }

    @Test func automaticIdentityRequiresAMatchedPositiveID() {
        let automatic = match()
        #expect(Media.match(answer: answer(automatic), choice: nil) == automatic)
        for status in [TMDBMatch.Status.ambiguous, .notFound] {
            #expect(Media.match(answer: answer(automatic, status: status), choice: nil) == nil)
        }
        #expect(Media.match(answer: answer(nil), choice: nil) == nil)
        #expect(Media.match(answer: answer(match(id: 0)), choice: nil) == nil)
        #expect(Media.match(answer: nil, choice: nil) == nil)
    }

    @Test func moviesNeedNoEpisodeAndUseOnlyMatchingIMDbDetails() throws {
        let movie = match(type: .movie, season: nil)
        let selected = try details(type: .movie, season: nil)
        let media = try #require(Media(match: movie, details: selected, episodeName: "HD", duration: 7_200))
        #expect(media.isMovie && media.tmdbID == 42 && media.imdbID == "tt1234567")
        #expect(media.season == nil && media.episode == nil && media.duration == 7_200)
        #expect(Media(match: movie, details: try details(type: .movie, id: 99), episodeName: "", duration: 7_200)?.imdbID == nil)
        #expect(Media(match: movie, details: try details(), episodeName: "", duration: 7_200)?.imdbID == nil)
    }

    @Test func seasonNumberingUsesTheChosenSeasonAndOffset() throws {
        let shifted = try #require(Media(match: match(offset: 12), details: nil, episodeName: "第03集", duration: 2_700))
        #expect(!shifted.isMovie && shifted.tmdbID == 42 && shifted.season == 2 && shifted.episode == 15)
        let selected = try details()
        #expect(Media(match: match(offset: 5), details: selected, episodeName: "第01集", duration: 2_700)?.episode == 6)
        // A number already inside the TMDB season must not be shifted past its last episode.
        #expect(Media(match: match(offset: 5), details: selected, episodeName: "第08集", duration: 2_700)?.episode == 8)
        #expect(Media(match: match(), details: selected, episodeName: "EP03", duration: 2_700)?.imdbID == "tt1234567")
        #expect(Media(match: match(), details: nil, episodeName: "EP03", duration: 2_700)?.imdbID == nil)
    }

    @Test func absoluteNumbersRequireAllPriorSeasonCountsAndAnExistingEpisode() throws {
        let absolute = match(season: 3, numbering: .absolute)
        let selected = try details(season: 3, episodes: [1, 2, 3], seasons: [(0, 6), (1, 12), (2, 10), (3, 3)])
        let media = try #require(Media(match: absolute, details: selected, episodeName: "第25集", duration: 1_440))
        #expect(media.season == 3 && media.episode == 3)
        #expect(Media(match: absolute, details: nil, episodeName: "第25集", duration: 1_440) == nil)
        #expect(Media(match: absolute, details: try details(season: 3, seasons: [(1, 12), (3, 3)]), episodeName: "第25集", duration: 1_440) == nil)
        #expect(Media(match: absolute, details: try details(), episodeName: "第25集", duration: 1_440) == nil)
        #expect(Media(match: absolute, details: selected, episodeName: "第26集", duration: 1_440) == nil)
        #expect(Media(match: absolute, details: selected, episodeName: "第22集", duration: 1_440) == nil)
    }

    @Test func invalidOrUnnumberedTelevisionIdentityIsRejected() throws {
        for episode in ["HD中字", "预告", "1080P", "第00集"] {
            #expect(Media(match: match(), details: try details(), episodeName: episode, duration: 2_700) == nil)
        }
        #expect(Media(match: match(season: nil), details: nil, episodeName: "EP01", duration: 2_700) == nil)
        #expect(Media(match: match(season: -1), details: nil, episodeName: "EP01", duration: 2_700) == nil)
        #expect(Media(match: match(offset: -1), details: nil, episodeName: "EP01", duration: 2_700) == nil)
        #expect(Media(match: match(offset: Int.max), details: nil, episodeName: "EP01", duration: 2_700) == nil)
        #expect(Media(match: match(offset: Int.max), details: try details(), episodeName: "EP01", duration: 2_700) == nil)
        #expect(Media(match: match(id: 0), details: nil, episodeName: "EP01", duration: 2_700) == nil)
    }

    @Test func invalidDurationsNeverProduceLookupIdentity() {
        for duration in [0.0, -1, .infinity, -.infinity, .nan] {
            #expect(Media(match: match(), details: nil, episodeName: "EP01", duration: duration) == nil)
            #expect(Media(match: match(type: .movie), details: nil, episodeName: "HD", duration: duration) == nil)
        }
    }

    @Test func cachedDetailsDecodeMissingNullAndPresentIMDbIDs() throws {
        for field in ["", #","imdbID":null"#] {
            let legacy = try details(imdbField: field)
            #expect(legacy.imdbID == nil)
            #expect(try JSONDecoder().decode(TMDBMatch.Details.self, from: JSONEncoder().encode(legacy)) == legacy)
        }
        let current = try details()
        #expect(current.imdbID == "tt1234567")
        let encoded = try JSONEncoder().encode(current)
        #expect(try JSONDecoder().decode(TMDBMatch.Details.self, from: encoded) == current)
    }
}

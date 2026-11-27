import Foundation
import Testing
@testable import TVCore

struct PlaybackFailureTests {
    private let origin = URL(string: "https://example.com/config.json")!

    private func error(_ domain: String, _ code: Int, description: String? = nil, underlying: NSError? = nil) -> NSError {
        var info: [String: Any] = [:]
        if let description { info[NSLocalizedDescriptionKey] = description }
        if let underlying { info[NSUnderlyingErrorKey] = underlying }
        return NSError(domain: domain, code: code, userInfo: info)
    }

    private func context(flag: String, name: String, id: String = "e1", videoID: String = "v1") -> PlaybackHistoryContext {
        PlaybackHistoryContext(origin: origin, sourceKey: "src", sourceName: "Source",
                               videoID: videoID, videoName: "Show", episodeID: id, episodeName: name, episodeFlag: flag)
    }

    // MARK: Failure classification and technical details

    @Test func classifiesCommonPlaybackErrorsWithLocalizedMessagesAndDetails() {
        let offline = PlaybackFailure.describe(error("AVFoundationErrorDomain", -11800,
                                                     underlying: error(NSURLErrorDomain, NSURLErrorNotConnectedToInternet)),
                                               host: "cdn.example.com", language: "zh-Hans")
        #expect(offline.kind == .offline)
        #expect(!offline.allowsAutomaticLineSwitch)
        #expect(offline.symbol == "wifi.slash")
        #expect(offline.message == "没有网络连接，请检查网络后重试。")
        #expect(offline.details?.contains("AVFoundationErrorDomain -11800 → NSURLErrorDomain -1009") == true)
        #expect(offline.details?.contains("cdn.example.com") == true)

        let expired = PlaybackFailure.describe(error("AVFoundationErrorDomain", -11800,
                                                     underlying: error("CoreMediaErrorDomain", -12660)),
                                               httpStatus: 403, host: "cdn.example.com", language: "en")
        #expect(expired.kind == .expired)
        #expect(expired.allowsAutomaticLineSwitch)
        #expect(expired.symbol == "clock.badge.exclamationmark")
        #expect(expired.details?.contains("HTTP 403") == true)

        let server502 = PlaybackFailure.describe(nil, httpStatus: 502, host: "cdn.example.com", language: "en")
        #expect(server502.kind == .serverError)
        #expect(server502.message.contains("HTTP 502"))

        let tls = PlaybackFailure.describe(error(NSURLErrorDomain, NSURLErrorServerCertificateUntrusted), language: "en")
        #expect(tls.kind == .certificate)
        #expect(tls.symbol == "lock.slash")

        let local = PlaybackFailure.describe(error(NSURLErrorDomain, NSURLErrorCannotConnectToHost),
                                             host: "127.0.0.1", isLoopback: true, language: "en")
        #expect(local.kind == .localService)
        #expect(local.allowsAutomaticLineSwitch)
        #expect(local.details?.contains("127.0.0.1") == false)

        let timeout = PlaybackFailure.describe(error("CoreMediaErrorDomain", -15628), language: "en")
        #expect(timeout.kind == .network)
        #expect(timeout.symbol == "wifi.exclamationmark")

        let format = PlaybackFailure.describe(error("AVFoundationErrorDomain", -11828), language: "en")
        #expect(format.kind == .unsupportedFormat)
    }

    @Test func allPlaybackFailureMessagesAreTranslatedInEveryLanguage() {
        let samples: [(Error?, Int?, Bool)] = [
            (error(NSURLErrorDomain, NSURLErrorNotConnectedToInternet), nil, false),
            (error("CoreMediaErrorDomain", -12660), 403, false),
            (error(NSURLErrorDomain, NSURLErrorServerCertificateUntrusted), nil, false),
            (nil, 503, false),
            (error(NSURLErrorDomain, NSURLErrorCannotConnectToHost), nil, true),
            (error(NSURLErrorDomain, NSURLErrorTimedOut), nil, false),
            (error(NSURLErrorDomain, NSURLErrorCannotFindHost), nil, false),
            (error(NSURLErrorDomain, NSURLErrorCannotConnectToHost), nil, false),
            (error("AVFoundationErrorDomain", -11828), nil, false),
        ]
        for (err, status, loopback) in samples {
            let english = PlaybackFailure.describe(err, httpStatus: status, isLoopback: loopback, language: "en").message
            for language in ["zh-Hans", "zh-Hant", "ja"] {
                let localized = PlaybackFailure.describe(err, httpStatus: status, isLoopback: loopback, language: language).message
                #expect(!localized.isEmpty)
                #expect(localized != english)
            }
        }
    }

    @Test func codeChainDeduplicatesRepeatedAdjacentDomainAndCode() {
        let leaf = error(NSURLErrorDomain, -1004)
        let middle = error(NSURLErrorDomain, -1004, underlying: leaf)
        let top = error("AVFoundationErrorDomain", -11800, underlying: middle)
        #expect(PlaybackFailure.codeChain(top) == "AVFoundationErrorDomain -11800 → NSURLErrorDomain -1004")
    }

    // MARK: Same-episode alternate lines and bounded fallback

    @Test func findsAlternateLinesForTheSameEpisodeInWrappedOrder() {
        let episodes = [
            Episode(id: "a1", name: "第1集", address: "u1", flag: "Line A"),
            Episode(id: "a2", name: "第2集", address: "u2", flag: "Line A"),
            Episode(id: "b1", name: "第01集", address: "u3", flag: "Line B"),
            Episode(id: "b2", name: "第02集", address: "u4", flag: "Line B"),
            Episode(id: "c1", name: "第1集", address: "u5", flag: "Line C"),
            Episode(id: "c2", name: "第2集", address: "u6", flag: "Line C"),
        ]
        let playlist = EpisodePlaylist(episodes)
        let alternates = playlist.alternates(for: context(flag: "Line B", name: "第01集", id: "b1"))
        #expect(alternates.map(\.flag) == ["Line C", "Line A"])
        #expect(alternates.map(\.id) == ["c1", "a1"])
    }

    @Test func matchesSingleEpisodeFilmAcrossLinesWithDifferentFileNames() {
        let episodes = [
            Episode(id: "a", name: "Movie.4K.mkv", address: "u1", flag: "Quark"),
            Episode(id: "b", name: "HD中字", address: "u2", flag: "Direct"),
        ]
        let playlist = EpisodePlaylist(episodes)
        let alternates = playlist.alternates(for: context(flag: "Quark", name: "Movie.4K.mkv", id: "a"))
        #expect(alternates.map(\.id) == ["b"])
    }

    @Test func boundsAutomaticLineSwitchingAndSkipsDisallowedLines() {
        let candidates = [
            Episode(id: "b1", name: "第1集", address: "u2", flag: "BaiduQR"),
            Episode(id: "c1", name: "第1集", address: "u3", flag: "Line C"),
            Episode(id: "d1", name: "第1集", address: "u4", flag: "Line D"),
            Episode(id: "e1", name: "第1集", address: "u5", flag: "Line E"),
        ]
        var fallback = PlaybackLineFallback()
        let first = context(flag: "Line A", name: "第1集", id: "a1")

        let switch1 = fallback.nextAutomatic(for: first, candidates: candidates) { $0.flag != "BaiduQR" }
        #expect(switch1?.flag == "Line C")
        let second = context(flag: "Line C", name: "第1集", id: "c1")
        let switch2 = fallback.nextAutomatic(for: second, candidates: candidates) { $0.flag != "BaiduQR" }
        #expect(switch2?.flag == "Line D")
        // Third automatic switch stops at the bound (2).
        let third = context(flag: "Line D", name: "第1集", id: "d1")
        #expect(fallback.nextAutomatic(for: third, candidates: candidates) { $0.flag != "BaiduQR" } == nil)
        // Manual switch still offers an untried line (BaiduQR or Line E).
        #expect(fallback.nextManual(for: third, candidates: candidates)?.flag == "BaiduQR")

        // Moving to episode 2 resets the budget.
        let ep2 = context(flag: "Line A", name: "第2集", id: "a2")
        let ep2Candidates = [Episode(id: "c2", name: "第2集", address: "u6", flag: "Line C")]
        #expect(fallback.nextAutomatic(for: ep2, candidates: ep2Candidates)?.flag == "Line C")

        // Explicit reset clears tried flags and automatic count for retry.
        fallback.reset()
        #expect(fallback.triedFlags.isEmpty && fallback.automaticSwitches == 0)
    }

    @Test func detectsPluginLoopbackRefusalsAfterSuspension() {
        let local = URL(string: "http://127.0.0.1:19979/proxy?id=1")!
        let localhost = URL(string: "http://localhost:8080/video.m3u8")!
        let remote = URL(string: "https://cdn.example.com/video.m3u8")!
        #expect(PlaybackFailure.isLoopbackRefusal(local, errorCode: NSURLErrorCannotConnectToHost))
        #expect(PlaybackFailure.isLoopbackRefusal(localhost, errorCode: NSURLErrorNetworkConnectionLost))
        #expect(!PlaybackFailure.isLoopbackRefusal(local, errorCode: NSURLErrorTimedOut))
        #expect(!PlaybackFailure.isLoopbackRefusal(local, errorCode: nil))
        #expect(!PlaybackFailure.isLoopbackRefusal(remote, errorCode: NSURLErrorCannotConnectToHost))
    }
}

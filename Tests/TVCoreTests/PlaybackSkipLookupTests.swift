import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import TVCore

private let otherDBHost = "playback.theotherdb.org"
private let theIntroDBHost = "api.theintrodb.org"
private let introDBHost = "api.introdb.app"

/// Requests stay suspended until the test releases them: no real HTTP or timing-based races.
private actor SkipLookupTransport {
    private var pending: [String: CheckedContinuation<(Data, URLResponse), any Error>] = [:]
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var cancelWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private let holdOnCancellation: Set<String>
    private(set) var requests: [URLRequest] = []
    private(set) var cancelled: Set<String> = []

    init(holdOnCancellation: Set<String> = []) { self.holdOnCancellation = holdOnCancellation }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let host = request.url!.host!
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending[host] = continuation
                requests.append(request)
                let ready = startWaiters.filter { requests.count >= $0.0 }
                startWaiters.removeAll { requests.count >= $0.0 }
                for (_, waiter) in ready { waiter.resume() }
            }
        } onCancel: {
            Task { await self.cancel(host) }
        }
    }

    func waitForRequests(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }

    func waitForCancellations(_ count: Int) async {
        if cancelled.count >= count { return }
        await withCheckedContinuation { cancelWaiters.append((count, $0)) }
    }

    private func cancel(_ host: String) {
        cancelled.insert(host)
        if !holdOnCancellation.contains(host) { pending.removeValue(forKey: host)?.resume(throwing: CancellationError()) }
        let ready = cancelWaiters.filter { cancelled.count >= $0.0 }
        cancelWaiters.removeAll { cancelled.count >= $0.0 }
        for (_, waiter) in ready { waiter.resume() }
    }

    func respond(_ host: String, _ json: String, status: Int = 200) {
        let response = HTTPURLResponse(url: URL(string: "https://" + host)!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        pending.removeValue(forKey: host)?.resume(returning: (Data(json.utf8), response))
    }

    func fail(_ host: String, _ error: URLError) { pending.removeValue(forKey: host)?.resume(throwing: error) }
}

/// Tests release the deadline explicitly, and can hold its cleanup after cancellation too.
private actor SkipLookupDeadline {
    private var pending: CheckedContinuation<Void, any Error>?
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var cancelWaiter: CheckedContinuation<Void, Never>?
    private var started = false
    private let holdOnCancellation: Bool
    private(set) var cancelled = false

    init(holdOnCancellation: Bool = false) { self.holdOnCancellation = holdOnCancellation }

    func wait() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                started = true
                startWaiter?.resume(); startWaiter = nil
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func waitForStart() async {
        if !started { await withCheckedContinuation { startWaiter = $0 } }
    }

    func waitForCancellation() async {
        if !cancelled { await withCheckedContinuation { cancelWaiter = $0 } }
    }

    func fire() { pending?.resume(); pending = nil }

    private func cancel() {
        cancelled = true
        if !holdOnCancellation { pending?.resume(throwing: CancellationError()); pending = nil }
        cancelWaiter?.resume(); cancelWaiter = nil
    }
}

private func skipLookupMedia(duration: Double = 1_000) -> PlaybackSkipLookup.Media {
    .init(tmdbID: 226045, imdbID: "tt0903747", season: 1, episode: 1, duration: duration)
}

private func skipQuery(_ request: URLRequest) -> [String: String] {
    Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [])
        .compactMap { item in item.value.map { (item.name, $0) } })
}

private func skipParse(_ json: String, _ provider: PlaybackSkipLookup.Provider, duration: Double = 1_000) -> [PlaybackSkip] {
    PlaybackSkipLookup.parse(Data(json.utf8), from: provider, duration: duration)
}

@Suite(.timeLimit(.minutes(1)))
struct PlaybackSkipLookupTests {
    @Test(arguments: [false, true])
    func kindsWinIndependentlyAndFinishBeforeSlowThirdProvider(introFirst: Bool) async {
        // The third provider deliberately ignores cancellation until explicitly released below.
        let transport = SkipLookupTransport(holdOnCancellation: [introDBHost])
        let stream = PlaybackSkipLookup.lookup(skipLookupMedia(), transport: { try await transport.send($0) })
        var iterator = stream.makeAsyncIterator()
        await transport.waitForRequests(3) // proves all providers start before any one completes
        let firstJSON = introFirst
            ? #"{"items":[{"version_runtime":1000,"marker":[{"marker_type":"intro","time_start":0,"time_end":27}]}]}"#
            : #"{"items":[{"version_runtime":1000,"marker":[{"marker_type":"credits","time_start":900,"time_end":1000}]}]}"#
        await transport.respond(otherDBHost, firstJSON)
        let first = introFirst ? PlaybackSkip(start: 0, end: 27, kind: .intro) : PlaybackSkip(start: 900, end: 1_000, kind: .outro)
        #expect(await iterator.next() == [first])

        // This answer also supplies a competing value for the already won kind.
        await transport.respond(theIntroDBHost, #"{"intro":[{"start_ms":10000,"end_ms":20000}],"credits":[{"start_ms":910000,"end_ms":null}]}"#)
        let expected = introFirst
            ? [first, PlaybackSkip(start: 910, end: 1_000, kind: .outro)]
            : [PlaybackSkip(start: 10, end: 20, kind: .intro), first]
        #expect(await iterator.next() == expected)
        // End must arrive before the third response, even while its cleanup is still suspended.
        #expect(await iterator.next() == nil)
        await transport.waitForCancellations(1)
        #expect(await transport.cancelled == [introDBHost])
        await transport.respond(introDBHost, #"{"intro":{"start_ms":1000,"end_ms":3000},"outro":{"start_ms":990000,"end_ms":1000000}}"#)
    }

    @Test func oneSecondMarkerCannotLockOutALaterUsefulProviderMarker() async {
        let transport = SkipLookupTransport()
        var iterator = PlaybackSkipLookup.lookup(skipLookupMedia(), transport: { try await transport.send($0) }).makeAsyncIterator()
        await transport.waitForRequests(3)
        // The tiny intro is technically positive but PlaybackSkip.current can never expose it.
        await transport.respond(otherDBHost, #"{"items":[{"version_runtime":1000,"marker":[{"marker_type":"intro","time_start":0,"time_end":1},{"marker_type":"credits","time_start":900,"time_end":1000}]}]}"#)
        let outro = PlaybackSkip(start: 900, end: 1_000, kind: .outro)
        #expect(await iterator.next() == [outro])
        await transport.respond(theIntroDBHost, #"{"intro":[{"start_ms":1000,"end_ms":3000}],"credits":[{"start_ms":910000,"end_ms":null}]}"#)
        #expect(await iterator.next() == [PlaybackSkip(start: 1, end: 3, kind: .intro), outro])
        #expect(await iterator.next() == nil)
    }

    @Test func invalidOrFailedResponsesCannotWinOrCancelOtherProviders() async {
        let transport = SkipLookupTransport()
        var iterator = PlaybackSkipLookup.lookup(skipLookupMedia(), transport: { try await transport.send($0) }).makeAsyncIterator()
        await transport.waitForRequests(3)
        await transport.respond(otherDBHost, #"{"items":[{"version_runtime":1000,"marker":[{"marker_type":"intro","time_start":0,"time_end":999999999},{"marker_type":"credits","time_start":900,"time_end":1000}]}]}"#)
        let outro = PlaybackSkip(start: 900, end: 1_000, kind: .outro)
        #expect(await iterator.next() == [outro])
        #expect(await transport.cancelled.isEmpty)
        await transport.respond(theIntroDBHost, #"{"intro":[{"start_ms":1000,"end_ms":3000}]}"#, status: 503)
        await transport.respond(introDBHost, #"{"intro":{"start_ms":5000,"end_ms":8000},"outro":null}"#)
        #expect(await iterator.next() == [PlaybackSkip(start: 5, end: 8, kind: .intro), outro])
        #expect(await iterator.next() == nil)
    }

    @Test func noDataErrorsAndProviderCancellationFinishWithoutASnapshot() async {
        let transport = SkipLookupTransport()
        var iterator = PlaybackSkipLookup.lookup(skipLookupMedia(), transport: { try await transport.send($0) }).makeAsyncIterator()
        await transport.waitForRequests(3)
        await transport.respond(otherDBHost, #"{"page":1,"page_size":30,"has_more":true,"items":[]}"#)
        await transport.fail(theIntroDBHost, URLError(.cancelled))
        await transport.respond(introDBHost, #"{"intro":null,"outro":null,"no_intro":true,"no_outro":true}"#)
        #expect(await iterator.next() == nil)
        #expect(await transport.requests.count == 3) // has_more does not trigger bulk pagination
    }

    @Test(arguments: [false, true])
    func deadlineCancelsSuspendedProvidersWithPartialOrNoResults(hasIntro: Bool) async {
        let hosts: Set<String> = [otherDBHost, theIntroDBHost, introDBHost]
        let transport = SkipLookupTransport(holdOnCancellation: hosts)
        let deadline = SkipLookupDeadline()
        var iterator = PlaybackSkipLookup.lookup(skipLookupMedia(), transport: { try await transport.send($0) },
                                               waitForDeadline: { try await deadline.wait() }).makeAsyncIterator()
        await transport.waitForRequests(3)
        await deadline.waitForStart()
        if hasIntro {
            await transport.respond(otherDBHost, #"{"items":[{"version_runtime":1000,"marker":[{"marker_type":"intro","time_start":0,"time_end":27}]}]}"#)
            #expect(await iterator.next() == [PlaybackSkip(start: 0, end: 27, kind: .intro)])
        }

        await deadline.fire()
        // End arrives while the remaining requests still refuse to finish their cancellation cleanup.
        #expect(await iterator.next() == nil)
        let expected = hasIntro ? hosts.subtracting([otherDBHost]) : hosts
        await transport.waitForCancellations(expected.count)
        #expect(await transport.cancelled == expected)
        for host in expected {
            await transport.respond(host, #"{"intro":{"start_ms":1000,"end_ms":3000},"outro":{"start_ms":900000,"end_ms":1000000}}"#)
        }
        #expect(await iterator.next() == nil)
    }

    @Test(arguments: [false, true])
    func allProvidersFinishingDoesNotWaitForDeadline(hasIntro: Bool) async {
        let transport = SkipLookupTransport()
        let deadline = SkipLookupDeadline(holdOnCancellation: true)
        var iterator = PlaybackSkipLookup.lookup(skipLookupMedia(), transport: { try await transport.send($0) },
                                               waitForDeadline: { try await deadline.wait() }).makeAsyncIterator()
        await transport.waitForRequests(3)
        await deadline.waitForStart()
        if hasIntro {
            await transport.respond(otherDBHost, #"{"items":[{"version_runtime":1000,"marker":[{"marker_type":"intro","time_start":0,"time_end":27}]}]}"#)
            #expect(await iterator.next() == [PlaybackSkip(start: 0, end: 27, kind: .intro)])
        } else {
            await transport.respond(otherDBHost, #"{"items":[]}"#)
        }
        await transport.respond(theIntroDBHost, #"{"intro":[],"credits":[]}"#)
        await transport.respond(introDBHost, #"{"intro":null,"outro":null}"#)
        #expect(await iterator.next() == nil)
        await deadline.waitForCancellation()
        #expect(await deadline.cancelled)
        // The deadline itself is still suspended; stream completion must not wait for it either.
        await deadline.fire()
    }

    @Test func consumerCancellationCancelsEverySuspendedTransport() async {
        let transport = SkipLookupTransport()
        let deadline = SkipLookupDeadline()
        let consumer = Task {
            for await _ in PlaybackSkipLookup.lookup(skipLookupMedia(), transport: { try await transport.send($0) },
                                                   waitForDeadline: { try await deadline.wait() }) {}
        }
        await transport.waitForRequests(3)
        await deadline.waitForStart()
        consumer.cancel()
        await consumer.value
        await transport.waitForCancellations(3)
        #expect(await transport.cancelled == [otherDBHost, theIntroDBHost, introDBHost])
        await deadline.waitForCancellation()
        #expect(await deadline.cancelled)
    }

    @Test func otherDBUsesSecondsAndOnlyTheClosestCoherentVersion() {
        let result = skipParse(#"{"items":[{"version_runtime":700,"marker":[{"marker_type":"intro","time_start":0,"time_end":10},{"marker_type":"credits","time_start":650,"time_end":700}]},{"version_runtime":1000,"version_platform":"iqiyi","marker":[{"marker_type":"intro","time_start":0,"time_end":27},{"marker_type":"recap","time_start":30,"time_end":40}]},{"version_runtime":1002,"marker":[{"marker_type":"credits","time_start":900,"time_end":1000}]}]}"#, .theOtherDB)
        #expect(result == [PlaybackSkip(start: 0, end: 27, kind: .intro)])
        let sample = skipParse(#"{"items":[{"version_runtime":1300,"version_platform":"iqiyi","marker":[{"marker_type":"intro","time_start":0,"time_end":27},{"marker_type":"credits","time_start":1200,"time_end":1300}]}]}"#, .theOtherDB, duration: 1_300)
        #expect(sample == [PlaybackSkip(start: 0, end: 27, kind: .intro), PlaybackSkip(start: 1_200, end: 1_300, kind: .outro)])
    }

    @Test func otherDBRejectsGrosslyMismatchedOrMalformedRuntime() {
        for runtime in ["1600", "699", "1061", "939", "0", "true", "\"1000\"", "null"] {
            let json = "{\"items\":[{\"version_runtime\":\(runtime),\"marker\":[{\"marker_type\":\"intro\",\"time_start\":0,\"time_end\":10}]}]}"
            #expect(skipParse(json, .theOtherDB).isEmpty)
        }
        #expect(skipParse(#"{"items":[{"version_runtime":1030,"marker":[{"marker_type":"intro","time_start":0,"time_end":10}]}]}"#, .theOtherDB)
                == [PlaybackSkip(start: 0, end: 10, kind: .intro)])
    }

    @Test func onlineMarkersAreOffUntilTheViewerTurnsThemOn() {
        #expect(PlaybackSkipLookup.enabledKey == "player.onlineSkipMarkers")
        #expect(UserDefaults.standard.object(forKey: PlaybackSkipLookup.enabledKey) == nil ? !PlaybackSkipLookup.enabled : true)
    }

    @Test func theIntroDBConvertsMillisecondsOnceAndPreservesMultipleSegments() {
        let result = skipParse(#"{"intro":[{"start_ms":228632,"end_ms":246528},{"start_ms":null,"end_ms":27000}],"credits":[{"start_ms":3432873,"end_ms":null}],"recap":[{"start_ms":1,"end_ms":2}],"post_credits":[{"start_ms":1,"end_ms":2}],"no_intro":true,"no_outro":true}"#, .theIntroDB, duration: 3_500)
        #expect(result == [PlaybackSkip(start: 0, end: 27, kind: .intro),
                           PlaybackSkip(start: 228.632, end: 246.528, kind: .intro),
                           PlaybackSkip(start: 3_432.873, end: 3_500, kind: .outro)])
    }

    @Test func introDBUsesMillisecondsAndOnlyItsOwnNoMarkerFlags() {
        let json = #"{"intro":{"start_ms":228632,"end_ms":246528,"start_sec":999,"end_sec":1000},"outro":{"start_ms":3432873,"end_ms":3499999,"start_sec":0,"end_sec":1},"recap":{"start_ms":0,"end_ms":1},"post_credits":{"start_ms":0,"end_ms":1}}"#
        #expect(skipParse(json, .introDB, duration: 3_500) == [PlaybackSkip(start: 228.632, end: 246.528, kind: .intro),
                                                                           PlaybackSkip(start: 3_432.873, end: 3_499.999, kind: .outro)])
        #expect(skipParse(#"{"no_intro":true,"intro":{"start_ms":0,"end_ms":10000},"no_outro":false,"outro":{"start_ms":900000,"end_ms":1000000}}"#, .introDB)
                == [PlaybackSkip(start: 900, end: 1_000, kind: .outro)])
        #expect(skipParse(#"{"intro":{"start_sec":0,"end_sec":10},"outro":{"start_ms":900000,"end_ms":null}}"#, .introDB).isEmpty)
    }

    @Test func badNumericFieldsAndCorruptRangesDoNotDiscardValidOtherKind() {
        let theIntro = #"{"intro":[{"start_ms":true,"end_ms":1000},{"start_ms":"0","end_ms":1000},{"start_ms":0,"end_ms":"1000"},{"start_ms":"NaN","end_ms":1000},{"start_ms":-1000,"end_ms":1000},{"start_ms":0,"end_ms":0},{"start_ms":2000,"end_ms":1000},{"start_ms":0,"end_ms":999999999999},{"start_ms":0,"end_ms":1000000},{"end_ms":1000}],"credits":[{"start_ms":900000,"end_ms":1000000}]}"#
        let expected = [PlaybackSkip(start: 900, end: 1_000, kind: .outro)]
        #expect(skipParse(theIntro, .theIntroDB) == expected)
        #expect(skipParse(#"{"intro":[{"start_ms":0,"end_ms":1000}],"credits":[{"start_ms":999000,"end_ms":1000000},{"start_ms":900000,"end_ms":900500}]}"#, .theIntroDB).isEmpty)
        #expect(skipParse(#"{"intro":{"start_ms":false,"end_ms":10000},"outro":{"start_ms":900000,"end_ms":1000000}}"#, .introDB) == expected)
        #expect(skipParse(#"{"items":[{"version_runtime":1000,"marker":[{"marker_type":"intro","time_start":"0","time_end":27},{"marker_type":"intro","time_start":false,"time_end":27},{"marker_type":"credits","time_start":900,"time_end":1000}]}]}"#, .theOtherDB) == expected)
        #expect(skipParse(#"{"intro":[],"credits":[{"start_ms":null,"end_ms":1000000},{"start_ms":900000},{"start_ms":0,"end_ms":null}]}"#, .theIntroDB).isEmpty)
        #expect(skipParse(#"{"items":[{"version_runtime":1000,"marker":[{"marker_type":"intro","time_start":null,"time_end":27},{"marker_type":"credits","time_start":900,"time_end":null}]}]}"#, .theOtherDB).isEmpty)
    }

    @Test(arguments: PlaybackSkipLookup.Provider.allCases)
    func malformedAndNoDataPayloadsNeverBecomeMarkers(_ provider: PlaybackSkipLookup.Provider) {
        for json in ["not json", "null", "[]", "{}", #"{"intro":[{"start_ms":0,"end_ms":0}],"credits":[],"items":[]}"#] {
            #expect(skipParse(json, provider).isEmpty)
        }
    }

    @Test func tvRequestsMatchEveryProviderContract() throws {
        let media = skipLookupMedia(duration: 3_500)
        let other = try #require(PlaybackSkipLookup.request(for: .theOtherDB, media: media))
        #expect(other.url?.absoluteString == "https://playback.theotherdb.org/api/metadata")
        #expect(other.httpMethod == "POST")
        #expect(other.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(other.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try JSONDecoder().decode(JSONValue.self, from: #require(other.httpBody))
        #expect(body == .object(["platform_type": .string("tmdb_id_tv"), "platform_value": .string("226045"),
                                 "season_number": .number(1), "episode_number": .number(1),
                                 "includes": .array([.string("marker")]), "page": .number(1), "page_size": .number(30)]))
        let theIntro = try #require(PlaybackSkipLookup.request(for: .theIntroDB, media: media))
        #expect(theIntro.url?.host == theIntroDBHost)
        #expect(theIntro.url?.path == "/v4/media")
        #expect(theIntro.httpMethod == "GET")
        #expect(skipQuery(theIntro) == ["tmdb_id": "226045", "season": "1", "episode": "1", "duration_ms": "3500000"])
        let intro = try #require(PlaybackSkipLookup.request(for: .introDB, media: media))
        #expect(intro.url?.host == introDBHost)
        #expect(intro.url?.path == "/segments")
        #expect(skipQuery(intro) == ["imdb_id": "tt0903747", "season": "1", "episode": "1"])
        #expect(intro.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func movieRequestsOmitTvFields() throws {
        let media = PlaybackSkipLookup.Media(tmdbID: 27205, imdbID: "tt1375666", season: -1, episode: 0, isMovie: true, duration: 3_500)
        let other = try #require(PlaybackSkipLookup.request(for: .theOtherDB, media: media))
        let body = try JSONDecoder().decode(JSONValue.self, from: #require(other.httpBody)).object
        #expect(body?["platform_type"] == .string("tmdb_id_movie"))
        #expect(body?["season_number"] == nil && body?["episode_number"] == nil)
        #expect(skipQuery(try #require(PlaybackSkipLookup.request(for: .theIntroDB, media: media)))
                == ["tmdb_id": "27205", "duration_ms": "3500000"])
        #expect(skipQuery(try #require(PlaybackSkipLookup.request(for: .introDB, media: media)))
                == ["imdb_id": "tt1375666", "is_movie": "true"])
    }

    @Test func identitiesAreValidatedAndProvidersRemainIndependentlyEligible() throws {
        let imdbOnly = PlaybackSkipLookup.Media(tmdbID: 0, imdbID: " tt0903747 ", season: 1, episode: 1, duration: 3_500)
        #expect(PlaybackSkipLookup.request(for: .theOtherDB, media: imdbOnly) == nil)
        #expect(skipQuery(try #require(PlaybackSkipLookup.request(for: .theIntroDB, media: imdbOnly)))
                == ["imdb_id": "tt0903747", "season": "1", "episode": "1", "duration_ms": "3500000"])
        let tmdbOnly = PlaybackSkipLookup.Media(tmdbID: 1396, season: 1, episode: 1, duration: 1_000)
        #expect(PlaybackSkipLookup.request(for: .theOtherDB, media: tmdbOnly) != nil)
        #expect(PlaybackSkipLookup.request(for: .theIntroDB, media: tmdbOnly) != nil)
        #expect(PlaybackSkipLookup.request(for: .introDB, media: tmdbOnly) == nil)
        let special = PlaybackSkipLookup.Media(tmdbID: 1396, imdbID: "tt0903747", season: 0, episode: 1, duration: 1_000)
        #expect(PlaybackSkipLookup.request(for: .theIntroDB, media: special) != nil)
        #expect(PlaybackSkipLookup.request(for: .introDB, media: special) == nil)
        let eightDigitID = PlaybackSkipLookup.Media(imdbID: "tt12345678", season: 1, episode: 1, duration: 1_000)
        #expect(PlaybackSkipLookup.request(for: .introDB, media: eightDigitID) != nil)
        for media in [PlaybackSkipLookup.Media(tmdbID: 1396, season: 10_000, episode: 1, duration: 1_000),
                      .init(tmdbID: 1396, season: 1, episode: 10_001, duration: 1_000)] {
            #expect(PlaybackSkipLookup.request(for: .theIntroDB, media: media) == nil)
            #expect(PlaybackSkipLookup.request(for: .theOtherDB, media: media) != nil)
        }
        for invalid in ["", "tt123", "tt0903747&season=9", "tt０９０３７４７", "nm0903747", "tt090374x", "tt090374789"] {
            let media = PlaybackSkipLookup.Media(tmdbID: -1, imdbID: invalid, season: 1, episode: 1, duration: 1_000)
            #expect(PlaybackSkipLookup.Provider.allCases.allSatisfy { PlaybackSkipLookup.request(for: $0, media: media) == nil })
        }
        for media in [PlaybackSkipLookup.Media(tmdbID: 1396, duration: 1_000),
                      .init(tmdbID: 1396, season: -1, episode: 1, duration: 1_000),
                      .init(tmdbID: 1396, season: 1, episode: 0, duration: 1_000)] {
            #expect(PlaybackSkipLookup.Provider.allCases.allSatisfy { PlaybackSkipLookup.request(for: $0, media: media) == nil })
        }
    }

    @Test func unavailableDurationFinishesWithoutSendingARequest() async {
        let transport = SkipLookupTransport()
        for duration in [0, -1, Double.infinity, -Double.infinity, Double.nan] {
            var iterator = PlaybackSkipLookup.lookup(skipLookupMedia(duration: duration), transport: { try await transport.send($0) }).makeAsyncIterator()
            #expect(await iterator.next() == nil)
        }
        #expect(await transport.requests.isEmpty)
        // No Int conversion may trap even if the caller supplies an enormous but finite duration.
        #expect(PlaybackSkipLookup.request(for: .theIntroDB, media: skipLookupMedia(duration: .greatestFiniteMagnitude)) != nil)
    }

    @Test func publicSessionRequestsAreCancelledWhenConsumerStops() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SkipSessionProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let consumer = Task {
            for await _ in PlaybackSkipLookup.lookup(skipLookupMedia(duration: 3_500), session: session) {}
        }
        await SkipSessionProtocol.probe.waitForStarts(3)
        let requests = await SkipSessionProtocol.probe.requests
        #expect(Set(requests.compactMap { $0.url?.host }) == [otherDBHost, theIntroDBHost, introDBHost])
        #expect(requests.first { $0.url?.host == otherDBHost }?.httpMethod == "POST")
        let request = requests.first { $0.url?.host == theIntroDBHost }
        #expect(request.map(skipQuery)?["duration_ms"] == "3500000")
        consumer.cancel()
        await consumer.value
        await SkipSessionProtocol.probe.waitForStops(3)
        #expect(await SkipSessionProtocol.probe.stops == 3)
    }
}

private actor SkipSessionProbe {
    private(set) var requests: [URLRequest] = []
    private(set) var stops = 0
    private var startWaiter: (Int, CheckedContinuation<Void, Never>)?
    private var stopWaiter: (Int, CheckedContinuation<Void, Never>)?
    func start(_ request: URLRequest) {
        requests.append(request)
        if let (count, waiter) = startWaiter, requests.count >= count { startWaiter = nil; waiter.resume() }
    }
    func stop() {
        stops += 1
        if let (count, waiter) = stopWaiter, stops >= count { stopWaiter = nil; waiter.resume() }
    }
    func waitForStarts(_ count: Int) async {
        if requests.count < count { await withCheckedContinuation { startWaiter = (count, $0) } }
    }
    func waitForStops(_ count: Int) async {
        if stops < count { await withCheckedContinuation { stopWaiter = (count, $0) } }
    }
}

private final class SkipSessionProtocol: URLProtocol, @unchecked Sendable {
    static let probe = SkipSessionProbe()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let request = self.request
        let probe = Self.probe
        Task { [request, probe] in await probe.start(request) }
    }
    override func stopLoading() { Task { await Self.probe.stop() } }
}

import Foundation
import Testing
@testable import TVCore

private let catchupStart = Date(timeIntervalSince1970: 1_700_000_000)
private let catchupShow = Programme(title: "Evening news", start: catchupStart, end: catchupStart.addingTimeInterval(3600))
private let catchupNow = catchupStart.addingTimeInterval(7200)
private func catchupChannel(_ declaration: String, address: String = "https://tv.example/live/index.m3u8?sig=live%2F%2b+A") throws -> Channel {
    try Playlist.parse("#EXTM3U\n#EXTINF:-1 \(declaration),News\n\(address)", origin: URL(string: "https://list.example/tv.m3u")!)[0]
}

@Test func catchupRequiresDeclaredSupportedTemplateAndEndedProgramme() throws {
    let plain = try catchupChannel("")
    #expect(ProgramCatchup.replay(plain, programme: catchupShow, now: catchupNow) == nil)
    #expect(!ProgramCatchup.supports(try catchupChannel(#"not-catchup-source="/{utc}""#)))
    let titleOnly = try Playlist.parse("#EXTM3U\n#EXTINF:-1,Title catchup-source=\"/{utc}\"\nhttps://tv.example/live.m3u8", origin: URL(string: "https://list.example/list.m3u")!)[0]
    #expect(!ProgramCatchup.supports(titleOnly))
    for declaration in [#"catchup="default""#, #"catchup="unknown" catchup-source="?start={utc}""#,
                        #"catchup="append" catchup-source="?start={unknown}""#,
                        #"catchup="append" catchup-source="?start={utc}" catchup-days="0""#,
                        #"catchup="append" catchup-source="?start={utc}" catchup-days="-1""#,
                        #"catchup="append" catchup-source="?start={utc}" catchup-days="bad""#] {
        #expect(ProgramCatchup.replay(try catchupChannel(declaration), programme: catchupShow, now: catchupNow) == nil)
    }
    let channel = try catchupChannel(#"catchup="append" catchup-source="?start={utc}&end={utcend}""#)
    #expect(ProgramCatchup.replay(channel, programme: catchupShow, now: catchupStart) == nil)
    #expect(ProgramCatchup.replay(channel, programme: Programme(title: "bad", start: catchupStart, end: catchupStart), now: catchupNow) == nil)
    #expect(ProgramCatchup.replay(channel, programme: catchupShow, now: catchupShow.end) != nil)
    #expect(ProgramCatchup.replay(channel, programme: catchupShow, now: catchupNow) != nil) // omitted retention is allowed
}

@Test func catchupAppendKeepsSignedQueryAndReplacesOnlyPath() throws {
    let live = try catchupChannel(#"catchup="append" catchup-source="?begin=${utc}&end={utcend}&duration={duration}" catchup-replace="live,replay" catchup-days="3""#)
    let replay = try #require(ProgramCatchup.replay(live, programme: catchupShow, now: catchupNow))
    #expect(replay.url.absoluteString == "https://tv.example/replay/index.m3u8?sig=live%2F%2b+A&begin=1700000000&end=1700003600&duration=3600")
    #expect(replay.replay?.channelID == live.id && replay.replay?.start == catchupShow.start && replay.replay?.end == catchupShow.end)
    #expect(replay.alternates.isEmpty && replay.catchup == nil && replay.historyContext == nil)
    #expect(ProgramCatchup.replay(replay, programme: catchupShow, now: catchupNow) == nil)
    #expect(LiveLineup(title: "TV", channels: [live]).position(of: replay) == nil)
    #expect(ProgramCatchup.replay(live, programme: catchupShow, now: catchupStart.addingTimeInterval(3 * 86400)) != nil)
    #expect(ProgramCatchup.replay(live, programme: catchupShow, now: catchupStart.addingTimeInterval(3 * 86400 + 1)) == nil)
}

@Test func catchupDefaultsOverridesAndEachLineKeepTheirOwnDeclaration() throws {
    let text = """
    #EXTM3U catchup="append" catchup-source="?start={utc}" catchup-days="7" catchup-timezone="Asia/Shanghai"
    #EXTINF:-1,News
    https://one.example/news.m3u8
    #EXTINF:-1 catchup="default" catchup-source="/archive/{start}/{end}.m3u8" catchup-days="2",News
    https://two.example/news.m3u8
    #EXTINF:-1 catchup="none",Disabled
    https://three.example/news.m3u8
    #EXTINF:-1,Recording
    https://one.example/movie.mp4
    """
    let channels = try Playlist.parse(text, origin: URL(string: "https://list.example/list.m3u")!)
    #expect(channels[0].catchup?.days == 7 && channels[0].lines[1].catchup?.days == 2)
    let alternate = try #require(ProgramCatchup.replay(channels[0], programme: catchupShow, line: 1, now: catchupNow))
    #expect(alternate.url.absoluteString == "https://two.example/archive/1700000000/1700003600.m3u8")
    #expect(alternate.replay?.channelID == channels[0].id)
    #expect(!ProgramCatchup.supports(channels[1]) && !ProgramCatchup.supports(channels[2]))
    let otherSource = try catchupChannel(#"catchup-source="/another/{utc}""#, address: "https://four.example/news.m3u8")
    #expect(ProgramCatchup.replay(otherSource, programme: catchupShow, now: catchupNow)?.url.host == "four.example")
    let sameURL = try Playlist.parse("""
    #EXTM3U
    #EXTINF:-1 catchup-source="/one/{utc}",News
    https://same.example/live.m3u8
    #EXTINF:-1 catchup-source="/two/{utc}",News
    https://same.example/live.m3u8
    """, origin: URL(string: "https://list.example/list.m3u")!)
    // Lines are one per address: the first declaration of an address is its line's.
    #expect(sameURL[0].lines.count == 1)
    #expect(ProgramCatchup.replay(sameURL[0], programme: catchupShow, now: catchupNow)?.url.path == "/one/1700000000")
    var alternateOnly = try catchupChannel("")
    alternateOnly.alternates = [ChannelLine(url: URL(string: "https://archive.example/live.m3u8")!, catchup: ChannelCatchup(source: "/{utc}"))]
    #expect(ProgramCatchup.supports(alternateOnly) && !ProgramCatchup.supports(alternateOnly, line: 0)
            && ProgramCatchup.supports(alternateOnly, line: 1))
}

@Test func catchupDatesUseSourceTimeZoneAcrossMidnightAndDST() throws {
    let formatter = ISO8601DateFormatter()
    let start = try #require(formatter.date(from: "2026-03-08T06:30:00Z"))
    let show = Programme(title: "DST", start: start, end: start.addingTimeInterval(7200))
    let channel = try catchupChannel(#"catchup-source="/replay/{(b)yyyy-MM-ddTHH:mm:ss}/{(e)yyyy-MM-ddTHH:mm:ss}?duration={duration}" catchup-timezone="America/New_York""#)
    let replay = try #require(ProgramCatchup.replay(channel, programme: show, now: show.end))
    #expect(replay.url.absoluteString == "https://tv.example/replay/2026-03-08T01:30:00/2026-03-08T04:30:00?duration=7200")
    let midnight = try #require(formatter.date(from: "2026-11-25T15:30:00Z"))
    let overnight = Programme(title: "Overnight", start: midnight, end: midnight.addingTimeInterval(3600))
    let china = try catchupChannel(#"catchup-source="/{(b)yyyyMMddHHmmss}/{(e)yyyyMMddHHmmss}" catchup-timezone="Asia/Shanghai""#)
    #expect(ProgramCatchup.replay(china, programme: overnight, now: overnight.end)?.url.path == "/20261125233000/20261126003000")
    let badZone = try catchupChannel(#"catchup-source="/{utc}" catchup-timezone="not-a-zone""#)
    #expect(!ProgramCatchup.supports(badZone))
}

/// Without catchup-timezone, a playseek's `(b)`/`(e)` times are the device's local time, as playlists mean them.
@Test func catchupDatesDefaultToTheDeviceTimeZone() throws {
    let channel = try catchupChannel(#"catchup="append" catchup-source="?playseek=${(b)yyyyMMddHHmmss}-${(e)yyyyMMddHHmmss}""#)
    let local = DateFormatter()
    local.locale = Locale(identifier: "en_US_POSIX"); local.timeZone = .current; local.dateFormat = "yyyyMMddHHmmss"
    let replay = try #require(ProgramCatchup.replay(channel, programme: catchupShow, now: catchupNow))
    #expect(replay.url.query?.hasSuffix("playseek=\(local.string(from: catchupShow.start))-\(local.string(from: catchupShow.end))") == true)
}

/// The same address listed twice is one line, whatever its headers or catchup say.
@Test func catchupKeepsLinesUniqueByAddress() throws {
    let text = """
    #EXTM3U
    #EXTINF:-1 catchup="append" catchup-source="?a={utc}",News
    https://tv.example/news.m3u8
    #EXTINF:-1 catchup="append" catchup-source="?b={utc}",News
    https://tv.example/news.m3u8
    #EXTINF:-1,News
    https://tv.example/news-2.m3u8
    """
    let channels = try Playlist.parse(text, origin: URL(string: "https://list.example/tv.m3u")!)
    #expect(channels.count == 1)
    #expect(channels.first?.lines.map(\.url.lastPathComponent) == ["news.m3u8", "news-2.m3u8"])
}

@Test func catchupBoundsTemplatesAndRejectsUnusableAddresses() throws {
    for template in ["file:///private/{utc}", "javascript:{utc}", "https://tv.example/{bad}", "https://tv.example/{(b)yyyyEEE}", "https://tv.example/{utc", "https://tv.example/%ZZ/{utc}", String(repeating: "x", count: 16385)] {
        #expect(ProgramCatchup.replay(try catchupChannel("catchup-source=\"\(template)\""), programme: catchupShow, now: catchupNow) == nil)
    }
    let channel = try catchupChannel(#"catchup-source="?start={utc}""#)
    #expect(ProgramCatchup.replay(channel, programme: Programme(title: "invalid", start: .init(timeIntervalSince1970: -.infinity), end: catchupStart), now: catchupNow) == nil)
    #expect(ProgramCatchup.replay(channel, programme: catchupShow, line: -1, now: catchupNow) == nil)
    for suffix in ["?start={utc}&bad=%", "?start={utc}&bad=%ZZ"] {
        let invalid = try catchupChannel("catchup=\"append\" catchup-source=\"\(suffix)\"")
        #expect(ProgramCatchup.replay(invalid, programme: catchupShow, now: catchupNow) == nil)
    }
    let expansion = try catchupChannel("catchup=\"append\" catchup-source=\"?start={utc}\" catchup-replace=\"a," + String(repeating: "b", count: 1000) + "\"",
                                      address: "https://tv.example/" + String(repeating: "a", count: 100))
    #expect(ProgramCatchup.replay(expansion, programme: catchupShow, now: catchupNow) == nil)
    let tooMany = try catchupChannel("catchup-source=\"/" + String(repeating: "{utc}", count: 65) + "\"")
    #expect(ProgramCatchup.replay(tooMany, programme: catchupShow, now: catchupNow) == nil)
}

@Test func catchupHeadersDoNotCrossOriginAndFavoritesRoundTrip() throws {
    var channel = try catchupChannel(#"catchup-source="https://other.example/{utc}""#, address: "https://tv.example/live.m3u8|Authorization=Bearer%20private&Cookie=private&User-Agent=TV")
    var replay = try #require(ProgramCatchup.replay(channel, programme: catchupShow, now: catchupNow))
    #expect(replay.headers["Authorization"] == nil && replay.headers["Cookie"] == nil && replay.headers["User-Agent"] == "TV")
    channel = try catchupChannel(#"catchup-source="/replay/{utc}""#, address: "https://tv.example/live.m3u8|Authorization=Bearer%20private")
    replay = try #require(ProgramCatchup.replay(channel, programme: catchupShow, now: catchupNow))
    #expect(replay.headers["Authorization"] == "Bearer private")
    for value in [channel, replay] {
        #expect(try JSONDecoder().decode(Channel.self, from: JSONEncoder().encode(value)) == value)
    }
    let old = Data(#"{"name":"Old","group":"TV","url":"https://tv.example/old.m3u8","headers":{},"alternates":[{"url":"https://tv.example/alt.m3u8","headers":{}}]}"#.utf8)
    let decoded = try JSONDecoder().decode(Channel.self, from: old)
    #expect(decoded.catchup == nil && decoded.replay == nil && decoded.lines[1].catchup == nil)
}

@Test func catchupXMLTVRetainsDeclaredHistoryAndDIYPUsesRequestedDay() throws {
    let channel = try catchupChannel(#"catchup="append" catchup-source="?start={utc}" catchup-days="3""#)
    #expect(ProgramCatchup.lookback(for: [channel]) == 3 * 86400)
    #expect(ProgramCatchup.lookback(for: [try catchupChannel("")]) == 3600)
    let huge = try catchupChannel(#"catchup-source="/{utc}" catchup-days="999999""#)
    #expect(ProgramCatchup.lookback(for: [huge]) == 31 * 86400)
    let address = try #require(GuideAddress("https://guide.example/{name}?date={date}"))
    #expect(address.address(for: "News", on: catchupStart)?.absoluteString == "https://guide.example/News?date=2023-11-15")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CATCHUP_TEST_SERVER"] != nil))
func catchupHistoricalGuideAndSignedPlaybackOverHTTP() async throws {
    let base = try #require(ProcessInfo.processInfo.environment["CATCHUP_TEST_SERVER"])
    let plain = try catchupChannel("", address: base + "/live/index.m3u8?sig=live%2F%2b+A")
    let channel = try catchupChannel(#"catchup="append" catchup-source="?begin={utc}&end={utcend}" catchup-replace="live,replay" catchup-days="3""#,
                                     address: plain.url.absoluteString)
    let url = try #require(URL(string: base + "/guide.xml"))
    let initial = try await ProgramGuides.shared.guide(url, for: [plain])
    #expect(initial.schedule(for: plain)?.contains { $0.title == "Two days ago" } != true)
    // The same cached URL must reload when a replay channel expands the requested history horizon.
    let expanded = try await ProgramGuides.shared.guide(url, for: [channel])
    let show = try #require(expanded.schedule(for: channel)?.first { $0.title == "Two days ago" })
    let replay = try #require(ProgramCatchup.replay(channel, programme: show))
    var request = URLRequest(url: replay.url)
    for (key, value) in replay.headers { request.setValue(value, forHTTPHeaderField: key) }
    let (data, response) = try await URLSession.shared.data(for: request)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(String(decoding: data, as: UTF8.self).contains("#EXT-X-ENDLIST"))
    let address = try #require(GuideAddress(base + "/epg/{name}?date={date}"))
    let day = Date(timeIntervalSince1970: 1_700_000_000)
    let schedule = try #require(await ProgramGuides.shared.schedule(address, name: "News", on: day))
    #expect(schedule.first?.title == "2023-11-15")
    #expect(schedule.first?.start == ProgramGuide.xmltvDate("20231115080000 +0800"))
    let todayOnly = try #require(GuideAddress(base + "/epg/{name}"))
    #expect(await ProgramGuides.shared.schedule(todayOnly, name: "News", on: day) == [])
}

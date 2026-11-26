import Foundation
import Testing
@testable import TVCore

@Test(.enabled(if: ProcessInfo.processInfo.environment["GUIDE_HTTP_FIXTURE"] != nil)) func guideRequestContextSeparatesSourceHeadersAndDates() async throws {
    guard let base = ProcessInfo.processInfo.environment["GUIDE_HTTP_FIXTURE"].flatMap(URL.init(string:)) else { return }
    let first = GuideRequestContext(sourceID: "source-a", origin: base, headers: ["Authorization": "account-a", "Cookie": "a=1"])
    let second = GuideRequestContext(sourceID: "source-b", origin: base, headers: ["Authorization": "account-b", "Cookie": "b=1"])
    let address = GuideAddress.perChannel(base.appendingPathComponent("epg").absoluteString + "?name={name}")
    let guides = ProgramGuides()
    let day = Date(timeIntervalSince1970: 1794614400)
    let a = await guides.schedule(address, name: "News", context: first, on: day)
    let b = await guides.schedule(address, name: "News", context: second, on: day)
    #expect(a?.first?.title == "account-a|a=1")
    #expect(b?.first?.title == "account-b|b=1")
    let changedHeaders = GuideRequestContext(sourceID: "source-a", origin: base, headers: ["Authorization": "account-b", "Cookie": "b=1"])
    let changed = await guides.schedule(address, name: "News", context: changedHeaders, on: day)
    #expect(changed?.first?.title == "account-b|b=1")
    let next = await guides.schedule(address, name: "News", context: first, on: day.addingTimeInterval(86400))
    #expect(next?.first?.start.timeIntervalSince((try #require(a?.first)).start) == 86400)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["GUIDE_HTTP_FIXTURE"] != nil)) func guideRedirectsKeepSameOriginCredentialsAndNeverResurrectThem() async throws {
    guard let base = ProcessInfo.processInfo.environment["GUIDE_HTTP_FIXTURE"].flatMap(URL.init(string:)) else { return }
    let context = GuideRequestContext(sourceID: "source", origin: base, headers: ["Authorization": "account-a", "Cookie": "a=1", "X-API-Key": "key", "User-Agent": "GuideTest"])
    let same = try await GuideDownload.fetch(base.appendingPathComponent("same"), context: context, limit: 4096)
    let returned = try await GuideDownload.fetch(base.appendingPathComponent("cross"), context: context, limit: 4096)
    #expect(String(decoding: same.data, as: UTF8.self) == "account-a|a=1|key|GuideTest")
    #expect(String(decoding: returned.data, as: UTF8.self) == "|||GuideTest")
    let foreign = URL(string: base.absoluteString.replacingOccurrences(of: "127.0.0.1", with: "localhost"))!.appendingPathComponent("echo")
    let initial = try await GuideDownload.fetch(foreign, context: context, limit: 4096)
    #expect(String(decoding: initial.data, as: UTF8.self) == "|||GuideTest")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["GUIDE_HTTP_FIXTURE"] != nil)) func guideHTTPBoundsAndCachePolicy() async throws {
    guard let base = ProcessInfo.processInfo.environment["GUIDE_HTTP_FIXTURE"].flatMap(URL.init(string:)) else { return }
    let context = GuideRequestContext(sourceID: "cache", origin: base)
    let noStore = try await GuideDownload.fetch(base.appendingPathComponent("no-store"), context: context, limit: 4096)
    #expect(noStore.lifetime == 0)
    await #expect(throws: (any Error).self) { _ = try await GuideDownload.fetch(base.appendingPathComponent("large"), context: context, limit: 32) }
    await #expect(throws: (any Error).self) { _ = try await GuideDownload.fetch(base.appendingPathComponent("chunked-large"), context: context, limit: 32) }
    let guides = ProgramGuides()
    let address = GuideAddress.perChannel(base.appendingPathComponent("uncached-epg").absoluteString + "?name={name}")
    let one = await guides.schedule(address, name: "News", context: context)
    let two = await guides.schedule(address, name: "News", context: context)
    #expect(one?.first?.title != two?.first?.title)
    let failed = GuideAddress.perChannel(base.appendingPathComponent("failure").absoluteString + "?name={name}")
    _ = await guides.schedule(failed, name: "News", context: context)
    _ = await guides.schedule(failed, name: "News", context: context)
    let counts = try await GuideDownload.fetch(base.appendingPathComponent("failure-count"), context: context, limit: 32)
    #expect(String(decoding: counts.data, as: UTF8.self) == "1")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["GUIDE_HTTP_FIXTURE"] != nil)) func guideXMLCacheSeparatesAccountSourceAndRequestedDay() async throws {
    guard let base = ProcessInfo.processInfo.environment["GUIDE_HTTP_FIXTURE"].flatMap(URL.init(string:)) else { return }
    let guides = ProgramGuides(), url = base.appendingPathComponent("guide.xml")
    var channel = Channel(name: "News", url: base); channel.guideID = "news"
    let day = Date(timeIntervalSince1970: 1794614400)
    let a = GuideRequestContext(sourceID: "one", origin: base, headers: ["Authorization": "a"])
    let b = GuideRequestContext(sourceID: "one", origin: base, headers: ["Authorization": "b"])
    let other = GuideRequestContext(sourceID: "two", origin: base, headers: ["Authorization": "b"])
    let first = try await guides.guide(url, for: [channel], context: a, on: day)
    let second = try await guides.guide(url, for: [channel], context: b, on: day)
    let third = try await guides.guide(url, for: [channel], context: other, on: day)
    #expect(first.schedule(for: channel)?.first?.title == "a-1")
    #expect(second.schedule(for: channel)?.first?.title == "b-2")
    #expect(third.schedule(for: channel)?.first?.title == "b-3")
    let next = try await guides.guide(url, for: [channel], context: a, on: day.addingTimeInterval(86400))
    #expect(next.schedule(for: channel)?.first?.title == "next-4")
}

@Test func guideRequestsRespectSourceCalendarAndDST() throws {
    let zone = try #require(TimeZone(identifier: "America/New_York"))
    let date = Date(timeIntervalSince1970: 1772974800) // 2026-03-08, spring forward
    let address = GuideAddress.perChannel("https://example.com/{name}/{date}")
    #expect(address.address(for: "News", on: date, timeZone: zone)?.path == "/News/2026-03-08")
    let data = Data(#"{"epg_data":[{"start":"08:00","end":"09:00","title":"Morning"}]}"#.utf8)
    let schedule = ProgramGuide.diyp(data, on: date, timeZone: zone)
    #expect(schedule.first?.start == Date(timeIntervalSince1970: 1772971200)) // 12:00 UTC
}

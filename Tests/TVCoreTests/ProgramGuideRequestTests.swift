import Foundation
import Testing
@testable import TVCore

/// Answers guide requests with the Authorization each carried ("-" for none), and counts them by host.
private final class GuideProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    static func count(_ host: String) -> Int { lock.withLock { counts[host, default: 0] } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.lock.withLock { Self.counts[url.host ?? "", default: 0] += 1 }
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? "-"
        let body: String
        if url.path.hasSuffix(".xml") {
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = TimeZone(identifier: "UTC"); format.dateFormat = "yyyyMMddHHmmss"
            let start = format.string(from: Date().addingTimeInterval(-600)), stop = format.string(from: Date().addingTimeInterval(1800))
            body = #"<tv><channel id="news"><display-name>News</display-name></channel>"#
                + #"<programme channel="news" start="\#(start) +0000" stop="\#(stop) +0000"><title>\#(auth)</title></programme></tv>"#
        } else {
            body = #"{"epg_data":[{"start":"08:00","end":"09:00","title":"\#(auth)"}]}"#
        }
        let response = HTTPURLResponse(url: url, statusCode: url.path.contains("fail") ? 503 : 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func guides() -> ProgramGuides {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [GuideProtocol.self]
    return ProgramGuides(http: HTTPClient(session: URLSession(configuration: config)))
}

@Test func guideHeadersStayOnTheSourceOrigin() {
    let headers = ["Authorization": "token", "Cookie": "a=1", "User-Agent": "Player"]
    let context = GuideRequestContext(origin: URL(string: "https://live.example/list.m3u"), headers: headers)
    #expect(context.headers(for: URL(string: "https://live.example/epg?ch=1")!) == ["authorization": "token", "cookie": "a=1", "user-agent": "Player"])
    for other in ["https://epg.example/e.xml", "http://live.example/e.xml", "https://live.example:8443/e.xml"] {
        #expect(context.headers(for: URL(string: other)!) == ["user-agent": "Player"], "\(other)")
    }
    #expect(GuideRequestContext(headers: headers).headers(for: URL(string: "https://live.example/e.xml")!) == ["user-agent": "Player"])
}

/// A per-channel guide on the source's own server is asked, and kept, per account.
@Test func perChannelGuidesAreKeptPerAccount() async throws {
    let guides = guides(), day = Date()
    let address = try #require(GuideAddress("https://diyp.guide.test/epg?ch={name}&date={date}"))
    let origin = URL(string: "https://diyp.guide.test/list.m3u")
    let a = GuideRequestContext(sourceID: "a", origin: origin, headers: ["Authorization": "account-a"])
    let b = GuideRequestContext(sourceID: "b", origin: origin, headers: ["Authorization": "account-b"])
    #expect(await guides.schedule(address, name: "News", context: a, on: day)?.first?.title == "account-a")
    #expect(await guides.schedule(address, name: "News", context: b, on: day)?.first?.title == "account-b")
    #expect(await guides.schedule(address, name: "News", context: a, on: day)?.first?.title == "account-a")
    #expect(GuideProtocol.count("diyp.guide.test") == 2)
}

/// Playlists that ask a guide elsewhere the same way share one download; on the guide's own origin each account's
/// credentials ask for, and keep, its own.
@Test func xmltvGuidesAreSharedUnlessCredentialsDiffer() async throws {
    let guides = guides()
    let url = try #require(URL(string: "https://xml.guide.test/guide.xml"))
    var channel = Channel(name: "News", url: URL(string: "https://live.example/1")!); channel.guideID = "news"
    let one = GuideRequestContext(sourceID: "one", origin: URL(string: "https://one.example/list.m3u"), headers: ["Authorization": "one"])
    let two = GuideRequestContext(sourceID: "two", origin: URL(string: "https://two.example/list.m3u"), headers: ["Authorization": "two"])
    #expect(try await guides.guide(url, for: [channel], context: one).schedule(for: channel)?.first?.title == "-")
    #expect(try await guides.guide(url, for: [channel], context: two).schedule(for: channel)?.first?.title == "-")
    #expect(GuideProtocol.count("xml.guide.test") == 1)
    let origin = URL(string: "https://xml.guide.test/list.m3u")
    let a = GuideRequestContext(sourceID: "a", origin: origin, headers: ["Authorization": "account-a"])
    let b = GuideRequestContext(sourceID: "b", origin: origin, headers: ["Authorization": "account-b"])
    #expect(try await guides.guide(url, for: [channel], context: a).schedule(for: channel)?.first?.title == "account-a")
    #expect(try await guides.guide(url, for: [channel], context: b).schedule(for: channel)?.first?.title == "account-b")
    #expect(try await guides.guide(url, for: [channel], context: a).schedule(for: channel)?.first?.title == "account-a")
    #expect(GuideProtocol.count("xml.guide.test") == 3)
}

@Test func aFailedPerChannelGuideIsNotAskedAgainAtOnce() async throws {
    let guides = guides()
    let address = try #require(GuideAddress("https://fail.guide.test/fail?ch={name}"))
    #expect(await guides.schedule(address, name: "News") == [])
    #expect(await guides.schedule(address, name: "News") == [])
    #expect(GuideProtocol.count("fail.guide.test") == 1)
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

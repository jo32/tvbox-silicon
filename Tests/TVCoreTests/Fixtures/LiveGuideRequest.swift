import Foundation
import Testing
@testable import TVCore

@MainActor @Test func liveGuideUsesDIYPNameWhenXMLTVIDIsOpaque() async throws {
    let base = try #require(ProcessInfo.processInfo.environment["GUIDE_HTTP_FIXTURE"].flatMap(URL.init(string:)))
    let address = GuideAddress.perChannel(base.appendingPathComponent("named-epg").absoluteString + "?name={name}")
    let guide = LiveGuide(address: address, context: GuideRequestContext(sourceID: "named", origin: base))
    var channel = Channel(name: "News", url: base)
    channel.guideID = "xmltv-opaque-2718"
    await guide.fetch(channel)
    #expect(guide.schedule(for: channel)?.first?.title == "Named News Bulletin")
}

@MainActor @Test func visibleGuideRowsRefetchWhenTheSourceAccountChanges() async throws {
    let base = try #require(ProcessInfo.processInfo.environment["GUIDE_HTTP_FIXTURE"].flatMap(URL.init(string:)))
    let address = GuideAddress.perChannel(base.appendingPathComponent("epg").absoluteString + "?name={name}")
    let first = LiveGuide(address: address, context: GuideRequestContext(sourceID: "playlist", origin: base, headers: ["Authorization": "first"]))
    let second = LiveGuide(address: address, context: GuideRequestContext(sourceID: "playlist", origin: base, headers: ["Authorization": "second"]))
    let channel = Channel(name: "News", url: base)
    for key in [GuideRowFixture.now, GuideRowFixture.next] {
        let prefix = key(first, channel)
        #expect(key(nil, channel) != prefix)
        #expect(key(first, channel) == prefix)
        #expect(key(first, Channel(name: "Sports", url: base)) != prefix)
        if key(second, channel) != prefix { await second.fetch(channel) }
        #expect(key(second, channel) != prefix)
        #expect(second.schedule(for: channel)?.first?.title == "second|")
    }
}

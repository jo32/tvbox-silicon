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

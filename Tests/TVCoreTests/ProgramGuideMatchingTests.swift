import Foundation
import Testing
@testable import TVCore

private func matchingGuide(_ channels: String, _ programmes: String, wanted: Set<String>? = nil) throws -> ProgramGuide {
    try ProgramGuide.xmltv(Data("<tv>\(channels)\(programmes)</tv>".utf8), wanted: wanted,
                           from: Date(timeIntervalSince1970: 0), to: .distantFuture)
}
private func matchingChannel(_ name: String, id: String? = nil, group: String = "") -> Channel {
    var channel = Channel(name: name, group: group, url: URL(string: "https://example.com/stream")!)
    channel.guideID = id
    return channel
}
private func matchingProgramme(_ id: String, title: String) -> String {
    "<programme channel=\"\(id)\" start=\"20261114080000 +0000\" stop=\"20261114090000 +0000\"><title>\(title)</title></programme>"
}

@Test func guideKeepsExactIDsSeparateFromNormalizedNames() throws {
    let channel = matchingChannel("News", id: "News-HD")
    let guide = try matchingGuide("<channel id=\"News-HD\"><display-name>News</display-name></channel><channel id=\"news\"><display-name>News</display-name></channel>",
                                  matchingProgramme("News-HD", title: "HD bulletin") + matchingProgramme("news", title: "Local bulletin"),
                                  wanted: ProgramGuide.wanted([channel]))
    #expect(guide.schedule(for: channel)?.first?.title == "HD bulletin")
    #expect(guide.schedule(for: matchingChannel("News", id: "news"))?.first?.title == "Local bulletin")
    #expect(guide.schedule(for: matchingChannel("News")) == nil)
}

@Test func guideRejectsAmbiguousAliasEvenIfOnlyOneHasProgrammes() throws {
    let guide = try matchingGuide("<channel id=\"one\"><display-name>News</display-name></channel><channel id=\"two\"><display-name>News HD</display-name></channel>", matchingProgramme("one", title: "Bulletin"))
    #expect(guide.schedule(for: matchingChannel("News")) == nil)
    #expect(guide.schedule(for: matchingChannel("News", id: "one"))?.first?.title == "Bulletin")
    #expect(guide.schedule(for: matchingChannel("News", id: "two")) == nil)
}

@Test func guideKeepsExplicitUniqueAliases() throws {
    let guide = try matchingGuide("<channel id=\"one\"><display-name>Regional News</display-name><display-name>Regional News HD</display-name></channel>", matchingProgramme("one", title: "Bulletin"))
    #expect(guide.schedule(for: matchingChannel("Different display name", id: "Regional News HD"))?.first?.title == "Bulletin")
    #expect(guide.schedule(for: matchingChannel("Regional News"))?.first?.title == "Bulletin")
}

@Test func guideRejectsImplicitDuplicatePlaylistNamesButKeepsExplicitAlias() throws {
    let guide = try matchingGuide("<channel id=\"one\"><display-name>News</display-name></channel>", matchingProgramme("one", title: "Bulletin"))
    let first = matchingChannel("News", group: "North")
    let second = matchingChannel("News HD", group: "South")
    #expect(guide.schedule(for: first, among: [first, second]) == nil)
    #expect(guide.schedule(for: matchingChannel("News", id: "one"), among: [first, second])?.first?.title == "Bulletin")
    #expect(guide.schedule(for: matchingChannel("News", id: "News"), among: [first, second])?.first?.title == "Bulletin")
}

@Test func guideReusesPlaylistAmbiguityIndexAcrossVisibleRows() throws {
    let guide = try matchingGuide("<channel id=\"one\"><display-name>News</display-name></channel>", matchingProgramme("one", title: "Bulletin"))
    let channels = (0..<2000).map { matchingChannel("Station \($0)") } + [matchingChannel("News", group: "North"), matchingChannel("News HD", group: "South")]
    let ambiguous = ProgramGuide.ambiguousNames(in: channels)
    #expect(ambiguous == ["news"])
    for _ in 0..<40 {
        #expect(guide.schedule(for: matchingChannel("News"), excludingImplicitNames: ambiguous) == nil)
        #expect(guide.schedule(for: matchingChannel("News", id: "one"), excludingImplicitNames: ambiguous)?.first?.title == "Bulletin")
    }
}

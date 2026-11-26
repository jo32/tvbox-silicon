import Foundation
import Testing
@testable import TVCore

private func matchingGuide(_ xml: String, for channels: [Channel]?) throws -> ProgramGuide {
    try ProgramGuide.xmltv(Data("<tv>\(xml)</tv>".utf8), wanted: channels.map(ProgramGuide.wanted),
                           from: Date(timeIntervalSince1970: 0), to: .distantFuture)
}
private func matchingChannel(_ name: String, id: String? = nil, group: String = "") -> Channel {
    var channel = Channel(name: name, group: group, url: URL(string: "https://example.com/\(UUID().uuidString)")!)
    channel.guideID = id
    return channel
}
/// A guide channel with its display names and one programme.
private func listing(_ id: String, _ names: [String], title: String) -> String {
    "<channel id=\"\(id)\">" + names.map { "<display-name>\($0)</display-name>" }.joined() + "</channel>"
        + "<programme channel=\"\(id)\" start=\"20261114080000 +0000\" stop=\"20261114090000 +0000\"><title>\(title)</title></programme>"
}

/// "CCTV1" and "CCTV-1 综合" in one playlist are one channel: both find its programmes.
@Test func guideMatchesEverySpellingOfAChannel() throws {
    let channels = [matchingChannel("CCTV1", group: "央视"), matchingChannel("CCTV-1 综合", group: "央视")]
    for wanted in [channels, nil] {
        let guide = try matchingGuide(listing("CCTV1", ["CCTV1"], title: "新闻联播"), for: wanted)
        for channel in channels { #expect(guide.schedule(for: channel)?.first?.title == "新闻联播") }
    }
}

/// A channel a playlist lists in two groups has its programmes in both.
@Test func guideMatchesAChannelListedInTwoGroups() throws {
    let channels = [matchingChannel("CCTV1", group: "央视"), matchingChannel("CCTV1", group: "高清")]
    let guide = try matchingGuide(listing("CCTV1", ["CCTV1"], title: "新闻联播"), for: channels)
    for channel in channels { #expect(guide.schedule(for: channel)?.first?.title == "新闻联播") }
}

/// A guide naming both "CCTV1" and "CCTV1 HD" still answers, with the first of them in the guide.
@Test func guideWithTwoChannelsOfOneNameKeepsTheFirst() throws {
    let channel = matchingChannel("CCTV-1 综合")
    let xml = listing("CCTV1", ["CCTV1"], title: "SD") + listing("CCTV1HD", ["CCTV1 HD"], title: "HD")
    for wanted in [[channel], nil] {
        #expect(try matchingGuide(xml, for: wanted).schedule(for: channel)?.first?.title == "SD")
    }
}

/// A `tvg-id` names one guide channel exactly, even where another channel has the same name.
@Test func exactGuideIDBeatsANameMatch() throws {
    let hd = matchingChannel("News", id: "News-HD"), local = matchingChannel("News", id: "news")
    let xml = listing("news", ["News"], title: "Local") + listing("News-HD", ["News"], title: "HD")
    for wanted in [[hd, local], nil] {
        let guide = try matchingGuide(xml, for: wanted)
        #expect(guide.schedule(for: hd)?.first?.title == "HD")
        #expect(guide.schedule(for: local)?.first?.title == "Local")
    }
    // Without an id, the name finds the first channel of that name.
    #expect(try matchingGuide(xml, for: nil).schedule(for: matchingChannel("News"))?.first?.title == "Local")
}

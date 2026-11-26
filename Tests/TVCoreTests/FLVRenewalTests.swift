import Foundation
import Testing
@testable import TVCore

@Test func renewedFLVSkipsCachedGOPsButAcceptsDistantClockReset() throws {
    let config = FLVTagReader.Tag(type: 9, time: 0, body: Data([0x17, 0, 0, 0, 0, 1, 2, 3]))
    func key(_ time: UInt32) -> FLVTagReader.Tag { .init(type: 9, time: time, body: Data([0x17, 1, 0, 0, 0, 9])) }
    var renewed = FLVSegmenter(minimumTimestamp: 6000)
    _ = renewed.add(config)
    for time: UInt32 in [0, 2000, 4000] { #expect(renewed.add(key(time)) == nil) }
    #expect(renewed.add(key(6000)) == nil)
    let closed = renewed.add(key(8000))
    let first = try #require(closed)
    #expect(first.start == 6000 && first.duration == 2 && first.discontinuity)
    var reset = FLVSegmenter(minimumTimestamp: 200_000)
    _ = reset.add(config); _ = reset.add(key(0))
    let resetClosed = reset.add(key(2000))
    let afterReset = try #require(resetClosed)
    #expect(afterReset.start == 0 && afterReset.discontinuity)
}

@Test func emptyFLVRenewalPublishesNoFakeBoundary() {
    var segmenter = FLVSegmenter(minimumTimestamp: 6000)
    _ = segmenter.add(.init(type: 9, time: 0, body: Data([0x17, 0, 0, 0, 0, 1, 2, 3])))
    _ = segmenter.add(.init(type: 9, time: 2000, body: Data([0x17, 1, 0, 0, 0, 9])))
    #expect(segmenter.finish() == nil)
}

@Test func liveQualityRenewalUsesNamesAndRejectsAmbiguity() {
    let selected = PlaybackChoice(id: 1, name: "1080p", address: "old")
    let other = PlaybackChoice(id: 0, name: "720p", address: "other")
    let fresh = PlaybackChoice(id: 0, name: "1080p", address: "fresh")
    #expect(selected.renewed(in: [fresh, other], from: [other, selected])?.address == "fresh")
    #expect(selected.renewed(in: [other], from: [other, selected]) == nil)
    #expect(selected.renewed(in: [fresh, selected], from: [other, selected]) == nil)
    #expect(selected.renewed(in: [fresh, other], from: [fresh, selected]) == nil)
    #expect(selected.renewed(in: [.init(id: 0, name: "sole", address: "fresh")], from: [selected])?.address == "fresh")
}

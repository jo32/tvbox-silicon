import AVFoundation
import Foundation
import Testing
@testable import TVCore

/// A second of silent video with a Mandarin and a Cantonese track: `audio-ungrouped.mp4` has both enabled and in
/// no alternate group (#428), `audio-grouped.mp4` has them in one group as FFmpeg writes it.
@MainActor struct UngroupedAudioTests {
    private func readyItem(_ name: String) async throws -> (AVPlayer, AVPlayerItem) {
        let url = try #require(Bundle.module.url(forResource: (name as NSString).deletingPathExtension, withExtension: "mp4", subdirectory: "Fixtures"))
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        for _ in 0..<200 where item.status == .unknown { try await Task.sleep(for: .milliseconds(25)) }
        #expect(item.status == .readyToPlay)
        return (player, item)
    }

    private func enabledAudio(_ item: AVPlayerItem) -> [CMPersistentTrackID] {
        item.tracks.filter { $0.isEnabled && $0.assetTrack?.mediaType == .audio }.compactMap { $0.assetTrack?.trackID }
    }

    @Test func ungroupedDubsPlayOneAtATimeAndCanBeChosen() async throws {
        let (player, item) = try await readyItem("audio-ungrouped.mp4")
        // What AVFoundation does by itself: both dubs at once, and no selection group to offer them.
        #expect(enabledAudio(item) == [2, 3])
        #expect(try await item.asset.loadMediaSelectionGroup(for: .audible)?.options.count ?? 0 < 2)
        #expect(UngroupedAudio.playOne(item))
        #expect(enabledAudio(item) == [2])
        #expect(!UngroupedAudio.playOne(item))
        let choices = await UngroupedAudio.choices(item)
        #expect(choices.map(\.id) == [2, 3])
        #expect(Set(choices.map(\.name)).count == 2)
        #expect(UngroupedAudio.playing(item) == 2)
        UngroupedAudio.play(3, in: item)
        #expect(enabledAudio(item) == [3] && UngroupedAudio.playing(item) == 3)
        UngroupedAudio.play(99, in: item)
        #expect(enabledAudio(item) == [3])
        _ = player
    }

    @Test func groupedDubsAreLeftToTheSelectionGroup() async throws {
        let (player, item) = try await readyItem("audio-grouped.mp4")
        #expect(enabledAudio(item) == [2])
        #expect(!UngroupedAudio.playOne(item))
        #expect(await UngroupedAudio.choices(item).isEmpty)
        _ = player
    }

    @Test func tracksAreNamedByTitleThenLanguage() {
        #expect(UngroupedAudio.names(titles: ["国语", " "], languages: ["chi", "yue"], language: "en") == ["国语", "Cantonese"])
        #expect(UngroupedAudio.names(titles: [nil, nil], languages: ["und", nil], language: "en") == ["Audio 1", "Audio 2"])
        #expect(UngroupedAudio.names(titles: [nil, nil, nil], languages: ["zh", "chi", "eng"], language: "en") == ["Chinese 1", "Chinese 2", "English"])
        #expect(UngroupedAudio.names(titles: [nil, nil], languages: ["chi", "yue"], language: "zh-Hans") == ["中文", "粤语"])
    }

    @Test func playOnePreservesPreferredTrackAndReportsTrackIDs() async throws {
        let (player, item) = try await readyItem("audio-ungrouped.mp4")
        #expect(UngroupedAudio.trackIDs(item) == [2, 3])
        #expect(UngroupedAudio.playOne(item, keeping: 3))
        #expect(enabledAudio(item) == [3] && UngroupedAudio.playing(item) == 3)
        // Re-enabling both simulates a late track update: keeping 3 preserves the viewer's choice (#1694).
        for track in item.tracks where track.assetTrack?.mediaType == .audio { track.isEnabled = true }
        #expect(UngroupedAudio.playOne(item, keeping: 3))
        #expect(enabledAudio(item) == [3])
        _ = player
    }

    @Test func separateAlternateGroupsPlayOneAndOfferBoth() async throws {
        // Put track 2 in alternate group 1 and track 3 in alternate group 2 (both enabled): AVFoundation's audible
        // selection group then only sees one option and plays both tracks at once (#1694).
        let source = try #require(Bundle.module.url(forResource: "audio-grouped", withExtension: "mp4", subdirectory: "Fixtures"))
        var data = try Data(contentsOf: source)
        let marker = Data("tkhd".utf8)
        var search = data.startIndex
        while let found = data.range(of: marker, in: search..<data.endIndex) {
            let base = found.lowerBound
            let trackID = data[base + 16..<base + 20].reduce(0) { ($0 << 8) | Int($1) }
            if trackID == 2 || trackID == 3 {
                // flags = 3 (track enabled + in movie), alternate_group = 1 or 2.
                data.replaceSubrange(base + 5..<base + 8, with: [0, 0, 3])
                data.replaceSubrange(base + 38..<base + 40, with: [0, UInt8(trackID - 1)])
            }
            search = found.upperBound
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("audio-diff-groups-\(UUID().uuidString).mp4")
        try data.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }

        let item = AVPlayerItem(url: temp)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        for _ in 0..<200 where item.status == .unknown { try await Task.sleep(for: .milliseconds(25)) }
        #expect(item.status == .readyToPlay)
        #expect(enabledAudio(item) == [2, 3])
        #expect(UngroupedAudio.playOne(item))
        #expect(enabledAudio(item) == [2])
        let choices = await UngroupedAudio.choices(item)
        #expect(choices.map(\.id) == [2, 3])
        UngroupedAudio.play(3, in: item)
        #expect(enabledAudio(item) == [3])
        _ = player
    }

    @Test func mixedGroupedAndUngroupedTracksStillOfferPicker() {
        #expect(!UngroupedAudio.needsPicker(trackCount: 1, audibleOptionCount: 0))
        #expect(!UngroupedAudio.needsPicker(trackCount: 2, audibleOptionCount: 2))
        #expect(UngroupedAudio.needsPicker(trackCount: 2, audibleOptionCount: 0))
        #expect(UngroupedAudio.needsPicker(trackCount: 2, audibleOptionCount: 1))
        #expect(UngroupedAudio.needsPicker(trackCount: 3, audibleOptionCount: 2))
    }
}

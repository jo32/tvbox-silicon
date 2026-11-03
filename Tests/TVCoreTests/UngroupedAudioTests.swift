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
}

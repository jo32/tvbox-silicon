import AVFoundation
import Foundation
import Testing
@testable import TVCore

/// A second of video whose sound AVPlayer can't decode (#1774, #2119), made with FFmpeg: `sound-dts.mp4` has DTS, which
/// AVFoundation doesn't list; `sound-truehd-aac.mp4` a TrueHD and an AAC track in one group, the TrueHD one the
/// default; `sound-truehd-aac-ungrouped.mp4` the same two enabled and in no group; `sound-none.mp4` no sound.
@MainActor struct PlayableSoundTests {
    private func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: "mp4", subdirectory: "Fixtures"))
    }

    private func readyItem(_ name: String) async throws -> (AVPlayer, AVPlayerItem) {
        let item = AVPlayerItem(url: try fixture(name))
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        for _ in 0..<200 where item.status == .unknown || item.tracks.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        #expect(item.status == .readyToPlay)
        return (player, item)
    }

    private func enabledAudio(_ item: AVPlayerItem) -> [CMPersistentTrackID] {
        item.tracks.filter { $0.isEnabled && $0.assetTrack?.mediaType == .audio }.compactMap { $0.assetTrack?.trackID }
    }

    @Test func onlyTracksThatDecodePlayInPlaceOfOnesThatDont() {
        #expect(PlayableSound.replacement(playing: [true, false], decodes: [false, true]) == 1)
        #expect(PlayableSound.replacement(playing: [false, false], decodes: [false, true]) == 1)
        // One that decodes plays already, or none decodes: left as it is.
        #expect(PlayableSound.replacement(playing: [true, true], decodes: [false, true]) == nil)
        #expect(PlayableSound.replacement(playing: [false, true], decodes: [false, true]) == nil)
        #expect(PlayableSound.replacement(playing: [true], decodes: [false]) == nil)
        #expect(PlayableSound.replacement(playing: [], decodes: []) == nil)
    }

    @Test func soundAVFoundationLeavesOutIsMissing() async throws {
        let (player, item) = try await readyItem("sound-dts")
        let check = await PlayableSound.check(item)
        #expect(check.tracks.isEmpty && check.verdict == .missing && check.needsConverting)
        #expect(check.summary == "none")
        _ = player
    }

    @Test func groupedDubStartsOnOneThatDecodes() async throws {
        let (player, item) = try await readyItem("sound-truehd-aac")
        let group = try #require(try await item.asset.loadMediaSelectionGroup(for: .audible))
        // What AVFoundation picks by itself: the TrueHD dub, which plays silence.
        #expect(item.currentMediaSelection.selectedMediaOption(in: group)?.isPlayable == false)
        let check = await PlayableSound.check(item)
        #expect(check.verdict == .switched && !check.needsConverting)
        #expect(check.summary == "mlpa!,aac")
        #expect(item.currentMediaSelection.selectedMediaOption(in: group)?.isPlayable == true)
        #expect(check.ungroupedUnplayable.isEmpty)
        #expect(await PlayableSound.check(item).verdict == .plays)
        _ = player
    }

    @Test func ungroupedDubsKeepOneThatDecodes() async throws {
        let (player, item) = try await readyItem("sound-truehd-aac-ungrouped")
        #expect(enabledAudio(item) == [2, 3])
        let check = await PlayableSound.check(item)
        // Both play, the AAC one heard: nothing to switch, but the TrueHD one is never the one kept.
        #expect(check.verdict == .plays && check.ungroupedUnplayable == [2])
        #expect(UngroupedAudio.playOne(item, avoiding: check.ungroupedUnplayable))
        #expect(enabledAudio(item) == [3])
        // A remembered TrueHD dub, or the first track kept before this check: back to the one that decodes.
        UngroupedAudio.play(2, in: item)
        #expect(UngroupedAudio.playDecodable(item, avoiding: check.ungroupedUnplayable))
        #expect(enabledAudio(item) == [3])
        #expect(!UngroupedAudio.playDecodable(item, avoiding: check.ungroupedUnplayable))
        UngroupedAudio.play(2, in: item)
        #expect(await PlayableSound.check(item).verdict == .switched)
        #expect(enabledAudio(item) == [3])
        _ = player
    }

    @Test func theRepackagerFindsSoundAVFoundationLeftOut() async throws {
        let dts = try await Remux.open(try Remux.fileSource(try fixture("sound-dts")))
        defer { Remux.stop(dts) }
        #expect(Remux.hasSound(dts))
        let silent = try await Remux.open(try Remux.fileSource(try fixture("sound-none")))
        defer { Remux.stop(silent) }
        #expect(!Remux.hasSound(silent))
    }

    /// A look that finds no sound mustn't close the stream AVPlayer still reads; the repackaged file closes it once adopted.
    @Test func aSharedSourceClosesOnlyOnceAdopted() async throws {
        final class Counting: RemuxSource, @unchecked Sendable {
            var closed = 0
            var length: Int64 { 4 }
            func read(at offset: Int64, count: Int) async throws -> Data { Data(repeating: 1, count: min(count, Int(4 - offset))) }
            var transfer: (received: Int64, host: String?)? { nil }
            func close() async { closed += 1 }
        }
        let base = Counting(), shared = SharedRemuxSource(base)
        #expect(try await shared.read(at: 1, count: 8).count == 3)
        await shared.close()
        #expect(base.closed == 0)
        shared.adopt()
        await shared.close()
        #expect(base.closed == 1)
    }
}

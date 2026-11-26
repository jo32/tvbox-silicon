import AVFoundation
import Foundation
import Testing
@testable import TVCore

/// A drag on the seek bar asks a generator for frames far from where the movie plays. Those reads must not turn into
/// a second download running ahead from the dragged place (seen on a 4K Quark file: the dragged place kept reading for
/// 40 s after the finger lifted, half the bandwidth, while the movie waited). Set TVBOX_CLOUD_MEDIA to a large MP4
/// whose moov comes after its mdat.
@Suite(.serialized) struct ScrubPreviewBandwidthTests {
    static let media = ProcessInfo.processInfo.environment["TVBOX_CLOUD_MEDIA"]

    @Test(.enabled(if: media != nil))
    func previewFramesDownloadOnlyWhatTheyShow() async throws {
        let media = try Data(contentsOf: URL(fileURLWithPath: Self.media!))
        let size = media.count, chunk = CloudByteStream.chunkSize
        let name = "scrub-\(UUID().uuidString).mp4"
        let served = RangeServer.add(name, media)
        let url = CloudStreams.register(.init(url: served, headers: [:], length: size, name: "movie.mp4"), session: RangeServer.session) { nil }
        let asset = try #require(CloudStreams.asset(for: url))
        let duration = try await asset.load(.duration).seconds
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 4
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.play()
        var waited = 0
        while player.currentTime().seconds < 2, item.status != .failed, waited < 200 { try await Task.sleep(for: .milliseconds(100)); waited += 1 }
        #expect(player.currentTime().seconds >= 2)
        try await Task.sleep(for: .seconds(2))

        // The drag: frames at three places in the last fifth, as MobilePlayer asks for them.
        let chunks = (size + chunk - 1) / chunk
        let region = (chunks * 4 / 5)..<(chunks - 2)
        func inRegion() -> Set<Int> { Set(RangeServer.starts(name).map { $0 / chunk }.filter { region.contains($0) }) }
        let before = inRegion()
        let preview = CloudStreams.previewAsset(for: url) ?? asset
        let generator = AVAssetImageGenerator(asset: preview)
        generator.maximumSize = CGSize(width: 320, height: 320)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
        var frames = 0
        for share in [0.84, 0.88, 0.92] {
            let (image, _) = try await generator.image(at: CMTime(seconds: duration * share, preferredTimescale: 600))
            if image.width > 0 { frames += 1 }
        }
        #expect(frames == 3)
        let atLift = inRegion()
        // The finger lifts.
        CloudStreams.endPreview(preview)
        try await Task.sleep(for: .seconds(4))
        let after = inRegion()
        // Three frames need a chunk or two each, not the rest of the file (16 of the 20 chunks on the playing asset).
        #expect(preview !== asset)
        #expect(after.count - before.count <= 6)
        #expect(after.count == atLift.count)
        player.pause()
        CloudStreams.stop(url)
    }
}
